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

// IOKit's power-source declarations are not shipped in the iPhoneOS SDK, but
// these are the stable C entry points exported by IOKit on iOS.
typedef CFTypeRef (*CCIOPSCopyPowerSourcesInfo)(void);
typedef CFArrayRef (*CCIOPSCopyPowerSourcesList)(CFTypeRef blob);
typedef CFDictionaryRef (*CCIOPSGetPowerSourceDescription)(CFTypeRef blob, CFTypeRef source);
typedef void (*CCIOPSReleasePowerSource)(CFTypeRef blob);

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

static BOOL CCBool(CFTypeRef value) {
    if (value == NULL) return NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)value);
    }
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        return CCNumber(value) != 0.0;
    }
    return NO;
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

static double CCBatteryTemperature(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSmartBattery"));
    if (service == MACH_PORT_NULL) return -1.0;

    CFMutableDictionaryRef properties = NULL;
    double temperature = -1.0;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties != NULL) {
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
    IOObjectRelease(service);
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
    result.sessionStart = CCPreferenceDouble(state, @"sessionStart", 0.0);
    result.lastSessionStart = CCPreferenceDouble(state, @"lastSessionStart", 0.0);
    result.lastSessionStop = CCPreferenceDouble(state, @"lastSessionStop", 0.0);
    result.lastSessionDuration = CCPreferenceDouble(state, @"lastSessionDuration", 0.0);
    result.temperature = CCBatteryTemperature();

    CCIOPSCopyPowerSourcesInfo copyInfo = (CCIOPSCopyPowerSourcesInfo)dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesInfo");
    CCIOPSCopyPowerSourcesList copyList = (CCIOPSCopyPowerSourcesList)dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesList");
    CCIOPSGetPowerSourceDescription getDescription = (CCIOPSGetPowerSourceDescription)dlsym(RTLD_DEFAULT, "IOPSGetPowerSourceDescription");
    CCIOPSReleasePowerSource releaseInfo = (CCIOPSReleasePowerSource)dlsym(RTLD_DEFAULT, "IOPSReleasePowerSource");
    if (copyInfo == NULL || copyList == NULL || getDescription == NULL || releaseInfo == NULL) {
        return result;
    }

    CFTypeRef info = copyInfo();
    CFArrayRef sources = info == NULL ? NULL : copyList(info);
    if (info != NULL && sources != NULL && CFArrayGetCount(sources) > 0) {
        CFTypeRef source = CFArrayGetValueAtIndex(sources, 0);
        CFDictionaryRef description = getDescription(info, source);
        if (description != NULL) {
            result.charging = CCBool(CFDictionaryGetValue(description, CFSTR("Is Charging")));
            result.voltage = CCNumber(CFDictionaryGetValue(description, CFSTR("Voltage")));
            result.amperage = CCNumber(CFDictionaryGetValue(description, CFSTR("Amperage")));
            result.percent = CCNumber(CFDictionaryGetValue(description, CFSTR("Current Capacity")));
            if (result.voltage > 100.0) result.voltage /= 1000.0;
            if (result.amperage > 1000.0) result.amperage /= 1000.0;
            result.watts = fabs(result.voltage * result.amperage);
        }
    }
    if (sources != NULL) CFRelease(sources);
    if (info != NULL) releaseInfo(info);

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
    else if (thermalState == NSProcessInfoThermalStateSerious) thermalFactor = 0.55;
    else if (thermalState == NSProcessInfoThermalStateCritical) thermalFactor = 0.85;
    if (result.temperature > 0.0) {
        double temperatureFactor = (result.temperature - 29.0) / 13.0;
        if (temperatureFactor > thermalFactor) thermalFactor = temperatureFactor;
    }
    if (result.watts > 0.0) {
        double chargingFactor = fmin(result.watts / 30.0, 1.0) * 0.15;
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
    if (snapshot.charging && snapshot.enabled) {
        desired = gBasePriority + (int)ceil(snapshot.throttle * 10.0);
        if (desired > 19) desired = 19;
    }
    if (desired != gAppliedPriority) {
        if (setpriority(PRIO_PROCESS, 0, desired) == 0) {
            gAppliedPriority = desired;
            os_log(CCLog(), "CoolCharge cooperative guard: charging=%{public}s temperature=%.1fC watts=%.1f priority=%d throttle=%.0f%%",
                   snapshot.charging ? "yes" : "no", snapshot.temperature, snapshot.watts,
                   desired, snapshot.throttle * 100.0);
        } else {
            os_log_error(CCLog(), "CoolCharge could not set SpringBoard priority: errno=%d", errno);
        }
    }
}

@interface CCCoolChargeWidget : UIView
- (void)cc_update:(CCSnapshot)snapshot;
@end

@implementation CCCoolChargeWidget {
    UILabel *_titleLabel;
    UILabel *_detailLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
        self.layer.cornerRadius = 16.0;
        self.layer.masksToBounds = YES;
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        for (UILabel *label in @[_titleLabel, _detailLabel]) {
            label.textColor = UIColor.whiteColor;
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            [self addSubview:label];
        }
        _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _detailLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        self.accessibilityIdentifier = @"CoolCharge.LockScreenWidget";
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _titleLabel.frame = CGRectMake(10.0, 6.0, self.bounds.size.width - 20.0, 21.0);
    _detailLabel.frame = CGRectMake(10.0, 27.0, self.bounds.size.width - 20.0, 18.0);
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
    self.hidden = !shouldShow;
    if (!shouldShow) return;
    if (snapshot.charging) {
        NSString *power = snapshot.watts > 0.05 ? [NSString stringWithFormat:@"%.1f W", snapshot.watts] : @"Power —";
        NSString *capacity = [NSString stringWithFormat:@"%.0f%%", snapshot.percent];
        _titleLabel.text = [NSString stringWithFormat:@"CoolCharge  •  %@  •  %@", power, capacity];
        NSString *eta = snapshot.etaValid ? [NSString stringWithFormat:@"Full in %@", CCMinutes(snapshot.etaSeconds)] : @"Full-time estimate learning";
        NSString *temperature = snapshot.showTemperature && snapshot.temperature > 0.0 ? [NSString stringWithFormat:@"%.1f°C", snapshot.temperature] : @"temperature hidden";
        NSString *session = snapshot.showSessionTimes ? [NSString stringWithFormat:@"Started %@", CCClockString(snapshot.sessionStart)] : @"live charging";
        _detailLabel.text = [NSString stringWithFormat:@"%@  •  %@  •  %@", eta, temperature, session];
        self.accessibilityLabel = [NSString stringWithFormat:@"Charging at %@, %@, %@", power, capacity, eta];
    } else {
        _titleLabel.text = @"CoolCharge  •  Charge receipt";
        _detailLabel.text = snapshot.showSessionTimes ? [NSString stringWithFormat:@"Stopped %@  •  Charged %@", CCClockString(snapshot.lastSessionStop), CCDurationString(snapshot.lastSessionDuration)] : @"Charging session complete";
        self.accessibilityLabel = _detailLabel.text;
    }
}
@end

static NSHashTable<CCCoolChargeWidget *> *gWidgets;
static const char gWidgetAssociationKey;

typedef void (*CCViewDidAppearIMP)(id, SEL, BOOL);
static CCViewDidAppearIMP gOriginalBaseViewDidAppear;
static CCViewDidAppearIMP gOriginalLockViewDidAppear;
typedef void (*CCViewWillDisappearIMP)(id, SEL, BOOL);
static CCViewWillDisappearIMP gOriginalBaseViewWillDisappear;
static CCViewWillDisappearIMP gOriginalLockViewWillDisappear;
typedef void (*CCMSHookMessageEx)(Class, SEL, IMP, IMP *);

static void CCAttachWidget(id controller) {
    if (gWidgets == nil) gWidgets = [NSHashTable weakObjectsHashTable];
    UIView *rootView = [controller view];
    if (rootView == nil) return;
    CCCoolChargeWidget *widget = objc_getAssociatedObject(controller, &gWidgetAssociationKey);
    if (widget == nil) {
        CGFloat width = MIN(CGRectGetWidth(rootView.bounds) - 40.0, 360.0);
        widget = [[CCCoolChargeWidget alloc] initWithFrame:CGRectMake((CGRectGetWidth(rootView.bounds) - width) / 2.0, 108.0, width, 51.0)];
        widget.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        objc_setAssociatedObject(controller, &gWidgetAssociationKey, widget, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [rootView addSubview:widget];
        [gWidgets addObject:widget];
    } else if (widget.superview != rootView) {
        [rootView addSubview:widget];
    }
    [rootView bringSubviewToFront:widget];
    [widget cc_update:gSnapshot];
}

static void CCUpdateWidgets(CCSnapshot snapshot) {
    gSnapshot = snapshot;
    for (CCCoolChargeWidget *widget in gWidgets.allObjects) {
        [widget cc_update:snapshot];
    }
}

static void HookedBaseViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalBaseViewDidAppear != NULL) gOriginalBaseViewDidAppear(self, _cmd, animated);
    dispatch_async(dispatch_get_main_queue(), ^{ CCAttachWidget(self); });
}

static void HookedLockViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalLockViewDidAppear != NULL) gOriginalLockViewDidAppear(self, _cmd, animated);
    dispatch_async(dispatch_get_main_queue(), ^{ CCAttachWidget(self); });
}

static void HookedBaseViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalBaseViewWillDisappear != NULL) gOriginalBaseViewWillDisappear(self, _cmd, animated);
    CCCoolChargeWidget *widget = objc_getAssociatedObject(self, &gWidgetAssociationKey);
    widget.hidden = YES;
}

static void HookedLockViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalLockViewWillDisappear != NULL) gOriginalLockViewWillDisappear(self, _cmd, animated);
    CCCoolChargeWidget *widget = objc_getAssociatedObject(self, &gWidgetAssociationKey);
    widget.hidden = YES;
}

static void CCInstallHooks(void) {
    CCMSHookMessageEx hooker = (CCMSHookMessageEx)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (hooker == NULL) {
        os_log_error(CCLog(), "CoolCharge could not find MSHookMessageEx; Lock Screen panel disabled");
        return;
    }
    Class base = objc_getClass("SBLockScreenViewControllerBase");
    if (base != Nil) {
        hooker(base, @selector(viewDidAppear:), (IMP)HookedBaseViewDidAppear, (IMP *)&gOriginalBaseViewDidAppear);
        hooker(base, @selector(viewWillDisappear:), (IMP)HookedBaseViewWillDisappear, (IMP *)&gOriginalBaseViewWillDisappear);
        os_log(CCLog(), "CoolCharge installed SBLockScreenViewControllerBase hooks");
    }
    Class lockView = objc_getClass("SBLockScreenViewController");
    if (lockView != Nil && lockView != base) {
        hooker(lockView, @selector(viewDidAppear:), (IMP)HookedLockViewDidAppear, (IMP *)&gOriginalLockViewDidAppear);
        hooker(lockView, @selector(viewWillDisappear:), (IMP)HookedLockViewWillDisappear, (IMP *)&gOriginalLockViewWillDisappear);
        os_log(CCLog(), "CoolCharge installed SBLockScreenViewController hooks");
    }
    if (base == Nil && lockView == Nil) {
        os_log_error(CCLog(), "CoolCharge found no known Lock Screen controller class");
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
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, 300 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        CCSnapshot snapshot = CCCollectSnapshot();
        CCApplyCooperativeThrottle(snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{ CCUpdateWidgets(snapshot); });
    });
    dispatch_resume(timer);
}

__attribute__((constructor)) static void CoolChargeInitialize(void) {
    os_log(CCLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());
    if (objc_getClass("SpringBoard") == Nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gWidgets = [NSHashTable weakObjectsHashTable];
        CCInstallHooks();
    });
    CCStartTelemetry();
}
