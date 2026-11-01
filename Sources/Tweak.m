// SPDX-License-Identifier: MIT
// CoolCharge: charging telemetry, a conservative SpringBoard guard, and a
// small Lock Screen status panel. This deliberately does not write Apple's
// private charging or power-controller registers.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/resource.h>
#import <limits.h>
#import <errno.h>
#import <math.h>
#import <unistd.h>
#import <notify.h>
#import "CCSettings.h"

#ifndef APELIN_PACKAGE_ID
#define APELIN_PACKAGE_ID "com.ilyastekdin.coolcharge"
#endif
#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "development"
#endif

// IOKit's power-source declarations are not shipped in the iPhoneOS SDK.
// Charging state and percentage use UIKit; IOKit remains for battery temperature.

static os_log_t CCLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "coolcharge");
    });
    return log;
}

static double CCNumber(CFTypeRef value) {
    if (value == NULL) return 0.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        double result = 0.0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result);
        return result;
    }
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)value) ? 1.0 : 0.0;
    }
    return 0.0;
}



typedef struct {
    BOOL charging;
    double watts;
    double voltage;
    double amperage;
    double percent;
    double temperature;
    double etaSeconds;
    double throttle;
    double sessionStart;
    double lastSessionStart;
    double lastSessionStop;
    double lastSessionDuration;
    BOOL etaValid;
    BOOL enabled;
    BOOL showWidget;
    BOOL showSessionTimes;
    BOOL showTemperature;
    BOOL showRecentSession;
    BOOL recentSession;
    BOOL locked;
    BOOL protectWhenLocked;
    double thermalThreshold;
} CCSnapshot;

static CCSnapshot gSnapshot;
static double gLastPercent = 0.0;
static CFAbsoluteTime gLastSampleTime = 0.0;
static double gPercentRate = 0.0;
static BOOL gLastWasCharging = NO;
static int gBasePriority = 0;
static BOOL gBasePriorityCaptured = NO;
static int gAppliedPriority = INT_MIN;
static double gSessionStartedAt = 0.0;
static BOOL gCoverSheetVisible = NO;

static const double kCCDefaultThermalThresholdC = 36.5;
static const double kCCMinimumThermalThresholdC = 32.0;
static const double kCCMaximumThermalThresholdC = 42.0;

static double CCBatteryTemperature(void) {
    typedef io_service_t (*CCIOServiceGetMatchingService)(mach_port_t, CFDictionaryRef);
    typedef CFMutableDictionaryRef (*CCIOServiceMatching)(const char *);
    typedef kern_return_t (*CCIORegistryEntryCreateCFProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits);
    typedef kern_return_t (*CCIOObjectRelease)(io_object_t);

    CCIOServiceGetMatchingService getMatchingService = (CCIOServiceGetMatchingService)dlsym(RTLD_DEFAULT, "IOServiceGetMatchingService");
    CCIOServiceMatching serviceMatching = (CCIOServiceMatching)dlsym(RTLD_DEFAULT, "IOServiceMatching");
    CCIORegistryEntryCreateCFProperties createProperties = (CCIORegistryEntryCreateCFProperties)dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperties");
    CCIOObjectRelease objectRelease = (CCIOObjectRelease)dlsym(RTLD_DEFAULT, "IOObjectRelease");
    if (getMatchingService == NULL || serviceMatching == NULL || createProperties == NULL || objectRelease == NULL) return -1.0;

    io_service_t service = getMatchingService(MACH_PORT_NULL, serviceMatching("AppleSmartBattery"));
    if (service == MACH_PORT_NULL) return -1.0;

    CFMutableDictionaryRef properties = NULL;
    double temperature = -1.0;
    if (createProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties != NULL) {
        CFTypeRef value = CFDictionaryGetValue(properties, CFSTR("Temperature"));
        if (value == NULL) {
            CFTypeRef batteryData = CFDictionaryGetValue(properties, CFSTR("BatteryData"));
            if (batteryData != NULL && CFGetTypeID(batteryData) == CFDictionaryGetTypeID()) {
                value = CFDictionaryGetValue((CFDictionaryRef)batteryData, CFSTR("Temperature"));
            }
        }
        if (value != NULL) {
            temperature = CCNumber(value);
            // AppleSmartBattery normally reports centi-degrees Celsius.
            if (temperature > 1000.0) temperature /= 100.0;
            else if (temperature > 100.0) temperature /= 10.0;
        }
        CFRelease(properties);
    }
    objectRelease(service);
    return temperature;
}

static NSString *CCClockString(double timestamp) {
    if (timestamp <= 0.0) return @"—";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.dateStyle = NSDateFormatterNoStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

static NSString *CCDurationString(double seconds) {
    if (seconds <= 0.0) return @"—";
    NSInteger minutes = (NSInteger)ceil(seconds / 60.0);
    if (minutes < 1) minutes = 1;
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    return [NSString stringWithFormat:@"%ld h %ld min", (long)(minutes / 60), (long)(minutes % 60)];
}

static CCSnapshot CCCollectSnapshot(void) {
    CCSnapshot result = {0};
    NSDictionary *state = CCReadCoolChargeState();
    result.enabled = CCPreferenceBool(state, @"enabled", YES);
    result.showWidget = CCPreferenceBool(state, @"showLockScreenWidget", YES);
    result.showSessionTimes = CCPreferenceBool(state, @"showSessionTimes", YES);
    result.showTemperature = CCPreferenceBool(state, @"showTemperature", YES);
    result.showRecentSession = CCPreferenceBool(state, @"showRecentSession", YES);
    result.thermalThreshold = CCPreferenceDouble(state, @"temperatureLimitC", kCCDefaultThermalThresholdC);
    if (result.thermalThreshold < kCCMinimumThermalThresholdC || result.thermalThreshold > kCCMaximumThermalThresholdC) {
        result.thermalThreshold = kCCDefaultThermalThresholdC;
    }
    result.protectWhenLocked = CCPreferenceBool(state, @"protectWhenLocked", YES);
    result.locked = gCoverSheetVisible;
    result.sessionStart = CCPreferenceDouble(state, @"sessionStart", 0.0);
    result.lastSessionStart = CCPreferenceDouble(state, @"lastSessionStart", 0.0);
    result.lastSessionStop = CCPreferenceDouble(state, @"lastSessionStop", 0.0);
    result.lastSessionDuration = CCPreferenceDouble(state, @"lastSessionDuration", 0.0);
    result.temperature = CCBatteryTemperature();

    UIDevice *device = UIDevice.currentDevice;
    BOOL wasMonitoring = device.batteryMonitoringEnabled;
    device.batteryMonitoringEnabled = YES;
    UIDeviceBatteryState batteryState = device.batteryState;
    float batteryLevel = device.batteryLevel;
    device.batteryMonitoringEnabled = wasMonitoring;
    result.charging = batteryState == UIDeviceBatteryStateCharging || batteryState == UIDeviceBatteryStateFull;
    if (batteryLevel >= 0.0f) result.percent = batteryLevel * 100.0;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval wallNow = [NSDate date].timeIntervalSince1970;
    BOOL hadPersistedSession = result.sessionStart > 0.0;
    if (result.charging) {
        // Keep a session's original start across SpringBoard restarts. A
        // restart must not manufacture a new charging start time or reset the
        // duration shown in Settings and on the Lock Screen.
        if (!hadPersistedSession) {
            gSessionStartedAt = wallNow;
            result.sessionStart = wallNow;
            CCWriteCoolChargeState(@{ @"sessionStart": @(wallNow) });
            NSString *clock = CCClockString(wallNow);
            os_log(CCLog(), "Began Charging: %{public}s", clock.UTF8String);
        } else {
            gSessionStartedAt = result.sessionStart;
        }
    } else if ((gLastWasCharging || hadPersistedSession) && hadPersistedSession) {
        double started = gSessionStartedAt > 0.0 ? gSessionStartedAt : result.sessionStart;
        double duration = started > 0.0 ? fmax(0.0, wallNow - started) : 0.0;
        result.lastSessionStart = started;
        result.lastSessionStop = wallNow;
        result.lastSessionDuration = duration;
        result.sessionStart = 0.0;
        gSessionStartedAt = 0.0;
        CCWriteCoolChargeState(@{
            @"sessionStart": @0.0,
            @"lastSessionStart": @(started),
            @"lastSessionStop": @(wallNow),
            @"lastSessionDuration": @(duration)
        });
        NSString *startedClock = CCClockString(started);
        NSString *stoppedClock = CCClockString(wallNow);
        NSString *durationText = CCDurationString(duration);
        os_log(CCLog(), "Stopped Charging: %{public}s (begun %{public}s, total %{public}s)",
               stoppedClock.UTF8String, startedClock.UTF8String, durationText.UTF8String);
    }
    result.recentSession = !result.charging && result.showRecentSession && result.lastSessionStop > 0.0 && (wallNow - result.lastSessionStop) < 600.0;
    if (result.charging && gLastWasCharging && gLastSampleTime > 0.0) {
        double elapsed = now - gLastSampleTime;
        double delta = result.percent - gLastPercent;
        if (elapsed >= 2.0 && delta > 0.01 && delta < 10.0) {
            double instantaneousRate = delta / elapsed;
            gPercentRate = gPercentRate <= 0.0 ? instantaneousRate
                                               : (gPercentRate * 0.75) + (instantaneousRate * 0.25);
        }
    } else if (!result.charging) {
        gPercentRate = 0.0;
    }
    if (result.charging && gPercentRate > 0.00001 && result.percent < 100.0) {
        result.etaSeconds = (100.0 - result.percent) / gPercentRate;
        result.etaValid = isfinite(result.etaSeconds) && result.etaSeconds > 0.0 && result.etaSeconds < 7.0 * 24.0 * 3600.0;
    }
    gLastPercent = result.percent;
    gLastSampleTime = now;
    gLastWasCharging = result.charging;

    NSProcessInfoThermalState thermalState = [NSProcessInfo processInfo].thermalState;
    double thermalFactor = 0.0;
    if (thermalState == NSProcessInfoThermalStateFair) thermalFactor = 0.25;
    else if (thermalState == NSProcessInfoThermalStateSerious) thermalFactor = 0.60;
    else if (thermalState == NSProcessInfoThermalStateCritical) thermalFactor = 1.0;

    // Start reducing SpringBoard work before the ceiling, then escalate
    // sharply at/above it. This is intentionally cooperative: iOS remains in
    // charge of PMIC and hardware thermal management.
    if (result.temperature > 0.0) {
        double rampStart = result.thermalThreshold - 3.0;
        double temperatureFactor = (result.temperature - rampStart) / 3.0;
        if (temperatureFactor > thermalFactor) thermalFactor = temperatureFactor;
        if (result.temperature >= result.thermalThreshold) {
            double aboveLimit = fmin(fmax(result.temperature - result.thermalThreshold, 0.0) / 4.0, 1.0);
            double limitFactor = 0.72 + (aboveLimit * 0.28);
            if (limitFactor > thermalFactor) thermalFactor = limitFactor;
        }
    }
    if (result.watts > 0.0) {
        double chargingFactor = fmin(result.watts / 30.0, 1.0) * 0.12;
        if (chargingFactor > thermalFactor) thermalFactor = chargingFactor;
    }
    result.throttle = fmax(0.0, fmin(1.0, thermalFactor));
    return result;
}

static void CCApplyCooperativeThrottle(CCSnapshot snapshot) {
    if (!gBasePriorityCaptured) {
        errno = 0;
        int priority = getpriority(PRIO_PROCESS, 0);
        if (priority != -1 || errno == 0) {
            gBasePriority = priority;
            gBasePriorityCaptured = YES;
        }
    }
    if (!gBasePriorityCaptured) return;

    int desired = gBasePriority;
    BOOL lockedAndHot = snapshot.protectWhenLocked && snapshot.locked && snapshot.temperature >= snapshot.thermalThreshold;
    BOOL guardActive = snapshot.enabled && (snapshot.charging || lockedAndHot);
    if (guardActive) {
        // This only yields SpringBoard CPU scheduling time. iOS remains the
        // authority for system-wide and hardware thermal throttling.
        desired = gBasePriority + (int)ceil(snapshot.throttle * 19.0);
        if (desired > 19) desired = 19;
    }
    if (desired != gAppliedPriority) {
        if (setpriority(PRIO_PROCESS, 0, desired) == 0) {
            gAppliedPriority = desired;
            os_log(CCLog(), "CoolCharge thermal guard: charging=%{public}s locked=%{public}s temperature=%.1fC limit=%.1fC watts=%.1f priority=%d throttle=%.0f%%",
                   snapshot.charging ? "yes" : "no", snapshot.locked ? "yes" : "no",
                   snapshot.temperature, snapshot.thermalThreshold, snapshot.watts,
                   desired, snapshot.throttle * 100.0);
        } else {
            os_log_error(CCLog(), "CoolCharge could not set SpringBoard priority: errno=%d", errno);
        }
    }
}

@interface CCCoolChargeWidget : UIView
- (void)cc_update:(CCSnapshot)snapshot;
- (void)cc_setOwnerView:(UIView *)view;
- (void)cc_restoreAfterAppearance;
- (void)cc_refreshPlacement;
@end

static BOOL CCIsNotificationLikeView(UIView *view) {
    if (view == nil || view.hidden || view.alpha < 0.01) return NO;
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    if (![name containsString:@"notification"] && ![name containsString:@"bulletin"]) return NO;
    return view.bounds.size.width > 100.0 && view.bounds.size.height > 20.0;
}

static void CCFindLockScreenMetrics(UIView *view, CGFloat *largestScrollDelta, NSMutableArray<NSValue *> *avoidRects, UIView *rootView) {
    if (view == nil || view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        CGFloat contentHeight = scrollView.contentSize.height;
        CGFloat viewportHeight = scrollView.bounds.size.height;
        if (contentHeight > viewportHeight + 4.0) {
            CGFloat normalizedOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
            if (fabs(normalizedOffset) > fabs(*largestScrollDelta)) *largestScrollDelta = normalizedOffset;
        }
    }
    if (CCIsNotificationLikeView(view) && view != rootView) {
        CGRect rect = [view.superview convertRect:view.frame toView:rootView];
        if (rect.size.height < rootView.bounds.size.height * 0.65) {
            [avoidRects addObject:[NSValue valueWithCGRect:rect]];
        }
    }
    for (UIView *child in view.subviews) {
        CCFindLockScreenMetrics(child, largestScrollDelta, avoidRects, rootView);
    }
}

@implementation CCCoolChargeWidget {
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIImageView *_boltImageView;
    CAShapeLayer *_ringTrackLayer;
    CAShapeLayer *_ringProgressLayer;
    UIVisualEffectView *_blurView;
    UIView *_highlightView;
    __weak UIView *_ownerView;
    BOOL _shouldDisplay;
    BOOL _hasPresented;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.userInteractionEnabled = NO;
        self.hidden = YES;
        self.alpha = 0.0;
        self.layer.cornerRadius = 20.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.75;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.userInteractionEnabled = NO;
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blurView];

        _highlightView = [[UIView alloc] initWithFrame:CGRectZero];
        _highlightView.userInteractionEnabled = NO;
        _highlightView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        _highlightView.layer.cornerRadius = 20.0;
        _highlightView.layer.cornerCurve = kCACornerCurveContinuous;
        _highlightView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_highlightView];

        _ringTrackLayer = [CAShapeLayer layer];
        _ringTrackLayer.fillColor = UIColor.clearColor.CGColor;
        _ringTrackLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        _ringTrackLayer.lineWidth = 2.0;
        _ringTrackLayer.lineCap = kCALineCapRound;
        [self.layer addSublayer:_ringTrackLayer];

        _ringProgressLayer = [CAShapeLayer layer];
        _ringProgressLayer.fillColor = UIColor.clearColor.CGColor;
        _ringProgressLayer.strokeColor = UIColor.systemGreenColor.CGColor;
        _ringProgressLayer.lineWidth = 2.0;
        _ringProgressLayer.lineCap = kCALineCapRound;
        _ringProgressLayer.strokeEnd = 0.0;
        [self.layer addSublayer:_ringProgressLayer];

        _boltImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.fill"]];
        _boltImageView.userInteractionEnabled = NO;
        _boltImageView.contentMode = UIViewContentModeScaleAspectFit;
        _boltImageView.tintColor = UIColor.systemGreenColor;
        [self addSubview:_boltImageView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        for (UILabel *label in @[_titleLabel, _detailLabel]) {
            label.userInteractionEnabled = NO;
            label.textColor = UIColor.whiteColor;
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.78;
            [self addSubview:label];
        }
        _titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:18.0 weight:UIFontWeightSemibold];
        _detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightRegular];
        self.accessibilityIdentifier = @"CoolCharge.LockScreenWidget";
        self.accessibilityTraits = UIAccessibilityTraitStaticText;
    }
    return self;
}

- (void)cc_setOwnerView:(UIView *)view {
    _ownerView = view;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
    _highlightView.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;

    CGPoint ringCenter = CGPointMake(25.0, CGRectGetMidY(self.bounds));
    CGFloat ringRadius = 13.0;
    CGRect ringBounds = CGRectMake(ringCenter.x - ringRadius, ringCenter.y - ringRadius, ringRadius * 2.0, ringRadius * 2.0);
    UIBezierPath *ringPath = [UIBezierPath bezierPathWithOvalInRect:ringBounds];
    _ringTrackLayer.frame = self.bounds;
    _ringTrackLayer.path = ringPath.CGPath;
    _ringProgressLayer.frame = self.bounds;
    _ringProgressLayer.path = ringPath.CGPath;

    _boltImageView.frame = CGRectMake(17.0, CGRectGetMidY(self.bounds) - 8.0, 16.0, 16.0);
    _titleLabel.frame = CGRectMake(49.0, 8.0, MAX(0.0, self.bounds.size.width - 61.0), 25.0);
    _detailLabel.frame = CGRectMake(49.0, 35.0, MAX(0.0, self.bounds.size.width - 61.0), 17.0);
}

static NSString *CCMinutes(double seconds) {
    NSInteger minutes = (NSInteger)ceil(seconds / 60.0);
    if (minutes < 1) minutes = 1;
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    NSInteger hours = minutes / 60;
    NSInteger remainder = minutes % 60;
    return remainder == 0 ? [NSString stringWithFormat:@"%ld h", (long)hours]
                          : [NSString stringWithFormat:@"%ld h %ld min", (long)hours, (long)remainder];
}

- (void)cc_update:(CCSnapshot)snapshot {
    BOOL shouldShow = snapshot.enabled && snapshot.showWidget && (snapshot.charging || snapshot.recentSession);
    if (shouldShow != _shouldDisplay) {
        _shouldDisplay = shouldShow;
        if (shouldShow) {
            self.hidden = NO;
            self.alpha = 0.0;
            self.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.94, 0.94), CGAffineTransformMakeTranslation(0.0, -10.0));
            [UIView animateWithDuration:0.48 delay:0.0 usingSpringWithDamping:0.82 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
                self.alpha = 1.0;
                self.transform = CGAffineTransformIdentity;
            } completion:^(__unused BOOL finished) {
                self->_hasPresented = YES;
            }];
        } else if (_hasPresented) {
            [UIView animateWithDuration:0.24 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{
                self.alpha = 0.0;
                self.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.96, 0.96), CGAffineTransformMakeTranslation(0.0, -6.0));
            } completion:^(__unused BOOL finished) {
                if (!self->_shouldDisplay) self.hidden = YES;
            }];
        } else {
            self.hidden = YES;
        }
    }
    if (!shouldShow) return;
    CGFloat progress = fmax(0.0, fmin(1.0, snapshot.percent / 100.0));
    if (!snapshot.charging && snapshot.recentSession) progress = 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _ringProgressLayer.strokeEnd = progress;
    _ringProgressLayer.strokeColor = (snapshot.charging ? UIColor.systemGreenColor : UIColor.systemYellowColor).CGColor;
    _boltImageView.tintColor = snapshot.charging ? UIColor.systemGreenColor : UIColor.systemYellowColor;
    [CATransaction commit];
    if (snapshot.charging) {
        NSString *power = snapshot.watts > 0.05 ? [NSString stringWithFormat:@"%.1f W", snapshot.watts] : @"Power —";
        NSString *capacity = [NSString stringWithFormat:@"%.0f%%", snapshot.percent];
        NSString *eta = snapshot.etaValid ? [NSString stringWithFormat:@"Full in %@", CCMinutes(snapshot.etaSeconds)] : @"Learning estimate";
        NSString *temperature = snapshot.showTemperature && snapshot.temperature > 0.0 ? [NSString stringWithFormat:@"%.1f°C", snapshot.temperature] : @"Temp hidden";
        NSString *session = snapshot.showSessionTimes ? [NSString stringWithFormat:@"Started %@", CCClockString(snapshot.sessionStart)] : @"Live charging";
        _titleLabel.text = eta;
        _detailLabel.text = [NSString stringWithFormat:@"%@  •  %@  •  %@", capacity, power, temperature];
        _boltImageView.tintColor = UIColor.systemGreenColor;
        self.accessibilityLabel = [NSString stringWithFormat:@"Charging at %@, %@, %@, %@", power, capacity, eta, session];
    } else {
        _titleLabel.text = @"Charge complete";
        _detailLabel.text = snapshot.showSessionTimes ? [NSString stringWithFormat:@"Stopped %@  •  %@", CCClockString(snapshot.lastSessionStop), CCDurationString(snapshot.lastSessionDuration)] : @"Charging session complete";
        _boltImageView.tintColor = UIColor.systemYellowColor;
        self.accessibilityLabel = _detailLabel.text;
    }
}

- (void)cc_restoreAfterAppearance {
    if (!_shouldDisplay || !self.hidden) return;
    self.hidden = NO;
    self.alpha = 0.0;
    self.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.96, 0.96), CGAffineTransformMakeTranslation(0.0, -8.0));
    [UIView animateWithDuration:0.38 delay:0.0 usingSpringWithDamping:0.84 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        self->_hasPresented = YES;
    }];
}

- (void)cc_refreshPlacement {
    UIView *rootView = _ownerView;
    if (rootView == nil || rootView.bounds.size.width <= 0.0 || rootView.bounds.size.height <= 0.0) return;
    CGFloat width = MIN(MAX(CGRectGetWidth(rootView.bounds) - 40.0, 220.0), 360.0);
    CGFloat height = 64.0;
    CGFloat safeTop = rootView.safeAreaInsets.top + 64.0;
    CGFloat safeBottom = rootView.bounds.size.height - rootView.safeAreaInsets.bottom - 12.0;
    CGFloat minimumY = safeTop;
    CGFloat maximumY = MAX(minimumY, safeBottom - height);
    CGFloat scrollDelta = 0.0;
    NSMutableArray<NSValue *> *avoidRects = [NSMutableArray array];
    CCFindLockScreenMetrics(rootView, &scrollDelta, avoidRects, rootView);
    CGFloat y = safeTop + fmax(-150.0, fmin(110.0, -scrollDelta));
    y = fmax(minimumY, fmin(maximumY, y));

    for (int pass = 0; pass < 3; pass++) {
        CGRect candidate = CGRectMake((CGRectGetWidth(rootView.bounds) - width) / 2.0, y, width, height);
        BOOL moved = NO;
        for (NSValue *value in avoidRects) {
            CGRect occupied = value.CGRectValue;
            if (!CGRectIntersectsRect(candidate, occupied)) continue;
            CGFloat above = CGRectGetMinY(occupied) - height - 10.0;
            CGFloat below = CGRectGetMaxY(occupied) + 10.0;
            if (above >= minimumY) y = above;
            else if (below <= maximumY) y = below;
            else y = minimumY;
            y = fmax(minimumY, fmin(maximumY, y));
            moved = YES;
            break;
        }
        if (!moved) break;
    }

    CGRect targetFrame = CGRectMake((CGRectGetWidth(rootView.bounds) - width) / 2.0, y, width, height);
    if (!CGRectEqualToRect(self.frame, targetFrame)) {
        [UIView performWithoutAnimation:^{ self.frame = targetFrame; }];
    }
}
@end

static NSHashTable<CCCoolChargeWidget *> *gWidgets;
static const char gWidgetAssociationKey;
static CADisplayLink *gWidgetDisplayLink;

@interface CCWidgetDisplayLinkTarget : NSObject
@end

@implementation CCWidgetDisplayLinkTarget
- (void)cc_displayLinkTick:(CADisplayLink *)displayLink {
    if (gWidgets.allObjects.count == 0) {
        displayLink.paused = YES;
        return;
    }
    for (CCCoolChargeWidget *widget in gWidgets.allObjects) {
        if (!widget.hidden) [widget cc_refreshPlacement];
    }
}
@end

static void CCStartWidgetDisplayLink(void) {
    if (gWidgetDisplayLink != nil) return;
    CCWidgetDisplayLinkTarget *target = [[CCWidgetDisplayLinkTarget alloc] init];
    gWidgetDisplayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(cc_displayLinkTick:)];
    gWidgetDisplayLink.preferredFramesPerSecond = 30;
    [gWidgetDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void CCUpdateWidgets(CCSnapshot snapshot) {
    gSnapshot = snapshot;
    for (CCCoolChargeWidget *widget in gWidgets.allObjects) {
        [widget cc_update:snapshot];
        if (!widget.hidden) [widget cc_refreshPlacement];
    }
    gWidgetDisplayLink.paused = gWidgets.allObjects.count == 0;
}

static void CCAttachWidgetToView(UIView *hostView) {
    if (hostView == nil) return;
    if (gWidgets == nil) gWidgets = [NSHashTable weakObjectsHashTable];
    CCCoolChargeWidget *widget = objc_getAssociatedObject(hostView, &gWidgetAssociationKey);
    if (widget == nil) {
        widget = [[CCCoolChargeWidget alloc] initWithFrame:CGRectZero];
        [widget cc_setOwnerView:hostView];
        objc_setAssociatedObject(hostView, &gWidgetAssociationKey, widget, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [hostView addSubview:widget];
        [gWidgets addObject:widget];
        CCStartWidgetDisplayLink();
    } else if (widget.superview != hostView) {
        [hostView addSubview:widget];
    }
    [hostView bringSubviewToFront:widget];
    [widget cc_refreshPlacement];
    [widget cc_update:gSnapshot];
    [widget cc_restoreAfterAppearance];
}

typedef void (*CCViewDidMoveToWindowIMP)(id, SEL);
typedef void (*CCViewLayoutIMP)(id, SEL);
typedef void (*CCViewControllerAppearanceIMP)(id, SEL, BOOL);
static CCViewDidMoveToWindowIMP gOriginalCoverSheetDidMoveToWindow;
static CCViewLayoutIMP gOriginalCoverSheetLayoutSubviews;
static CCViewControllerAppearanceIMP gOriginalCoverSheetViewDidAppear;
static CCViewControllerAppearanceIMP gOriginalCoverSheetViewWillDisappear;
static CCViewControllerAppearanceIMP gOriginalCoverSheetViewDidDisappear;
typedef void (*CCMSHookMessageEx)(Class, SEL, IMP, IMP *);

static void CCHideWidgetForView(id object) {
    CCCoolChargeWidget *widget = objc_getAssociatedObject(object, &gWidgetAssociationKey);
    widget.hidden = YES;
}

static void HookedCoverSheetDidMoveToWindow(id self, SEL _cmd) {
    if (gOriginalCoverSheetDidMoveToWindow != NULL) gOriginalCoverSheetDidMoveToWindow(self, _cmd);
    UIView *view = (UIView *)self;
    if (view.window != nil) CCAttachWidgetToView(view);
    else CCHideWidgetForView(self);
}

static void HookedCoverSheetLayoutSubviews(id self, SEL _cmd) {
    if (gOriginalCoverSheetLayoutSubviews != NULL) gOriginalCoverSheetLayoutSubviews(self, _cmd);
    UIView *view = (UIView *)self;
    if (view.window != nil) CCAttachWidgetToView(view);
}

static void HookedCoverSheetViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalCoverSheetViewDidAppear != NULL) gOriginalCoverSheetViewDidAppear(self, _cmd, animated);
    gCoverSheetVisible = YES;
    UIView *view = [(UIViewController *)self view];
    Class coverSheetClass = objc_getClass("CSCoverSheetView");
    if (view != nil && (coverSheetClass == Nil || [view isKindOfClass:coverSheetClass])) CCAttachWidgetToView(view);
}

static void HookedCoverSheetViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalCoverSheetViewWillDisappear != NULL) gOriginalCoverSheetViewWillDisappear(self, _cmd, animated);
    gCoverSheetVisible = NO;
    UIView *view = [(UIViewController *)self view];
    if (view != nil) CCHideWidgetForView(view);
}

static void HookedCoverSheetViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalCoverSheetViewDidDisappear != NULL) gOriginalCoverSheetViewDidDisappear(self, _cmd, animated);
    gCoverSheetVisible = NO;
}

static void CCInstallCoverSheetHooks(void) {
    CCMSHookMessageEx hooker = (CCMSHookMessageEx)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (hooker == NULL) {
        os_log_error(CCLog(), "CoolCharge could not find MSHookMessageEx; Cover Sheet overlay disabled");
        return;
    }

    Class coverSheet = objc_getClass("CSCoverSheetView");
    if (coverSheet != Nil) {
        hooker(coverSheet, @selector(didMoveToWindow), (IMP)HookedCoverSheetDidMoveToWindow, (IMP *)&gOriginalCoverSheetDidMoveToWindow);
        hooker(coverSheet, @selector(layoutSubviews), (IMP)HookedCoverSheetLayoutSubviews, (IMP *)&gOriginalCoverSheetLayoutSubviews);
        os_log(CCLog(), "CoolCharge installed CSCoverSheetView lifecycle hooks");
    } else {
        os_log_error(CCLog(), "CoolCharge could not find CSCoverSheetView");
    }

    Class controller = objc_getClass("CSCoverSheetViewController");
    if (controller != Nil) {
        hooker(controller, @selector(viewDidAppear:), (IMP)HookedCoverSheetViewDidAppear, (IMP *)&gOriginalCoverSheetViewDidAppear);
        hooker(controller, @selector(viewWillDisappear:), (IMP)HookedCoverSheetViewWillDisappear, (IMP *)&gOriginalCoverSheetViewWillDisappear);
        hooker(controller, @selector(viewDidDisappear:), (IMP)HookedCoverSheetViewDidDisappear, (IMP *)&gOriginalCoverSheetViewDidDisappear);
        os_log(CCLog(), "CoolCharge installed CSCoverSheetViewController lifecycle hooks");
    } else {
        os_log_error(CCLog(), "CoolCharge could not find CSCoverSheetViewController");
    }
}

static int gSettingsNotificationToken = 0;

static void CCStartTelemetry(void) {
    dispatch_queue_t queue = dispatch_queue_create("local.apelin.coolcharge.telemetry", DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(CCPreferenceChangedNotification, &gSettingsNotificationToken, queue, ^(__unused int token) {
        CCSnapshot snapshot = CCCollectSnapshot();
        CCApplyCooperativeThrottle(snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{ CCUpdateWidgets(snapshot); });
    });
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        CCSnapshot snapshot = CCCollectSnapshot();
        CCApplyCooperativeThrottle(snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{ CCUpdateWidgets(snapshot); });
    });
    dispatch_resume(timer);
}

__attribute__((constructor)) static void CoolChargeInitialize(void) {
    os_log_error(CCLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());
    NSLog(@"ApelinLoaded %s in %s", APELIN_BUILD_ID, getprogname());
    if (objc_getClass("SpringBoard") == Nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gWidgets = [NSHashTable weakObjectsHashTable];
        CCInstallCoverSheetHooks();
    });
    CCStartTelemetry();
}
