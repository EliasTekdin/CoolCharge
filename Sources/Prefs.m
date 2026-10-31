#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <math.h>
#import <dlfcn.h>
#import <Preferences/PSListController.h>
#import "CCSettings.h"

static double CCPrefNumber(CFTypeRef value) {
    if (value == NULL) return 0.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        double number = 0.0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
        return number;
    }
    return 0.0;
}

typedef CFTypeRef (*CCPrefCopySourcesInfo)(void);
typedef CFArrayRef (*CCPrefCopySourcesList)(CFTypeRef);
typedef CFDictionaryRef (*CCPrefGetSourceDescription)(CFTypeRef, CFTypeRef);
typedef void (*CCPrefReleaseSources)(CFTypeRef);

static BOOL CCPrefCharging(double *watts, double *percent) {
    if (watts != NULL) *watts = 0.0;
    if (percent != NULL) *percent = 0.0;
    CCPrefCopySourcesInfo copyInfo = (CCPrefCopySourcesInfo)dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesInfo");
    CCPrefCopySourcesList copyList = (CCPrefCopySourcesList)dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesList");
    CCPrefGetSourceDescription getDescription = (CCPrefGetSourceDescription)dlsym(RTLD_DEFAULT, "IOPSGetPowerSourceDescription");
    CCPrefReleaseSources releaseInfo = (CCPrefReleaseSources)dlsym(RTLD_DEFAULT, "IOPSReleasePowerSource");
    if (copyInfo == NULL || copyList == NULL || getDescription == NULL || releaseInfo == NULL) return NO;
    CFTypeRef info = copyInfo();
    CFArrayRef sources = info == NULL ? NULL : copyList(info);
    BOOL charging = NO;
    if (info != NULL && sources != NULL && CFArrayGetCount(sources) > 0) {
        CFDictionaryRef description = getDescription(info, CFArrayGetValueAtIndex(sources, 0));
        if (description != NULL) {
            CFTypeRef chargingValue = CFDictionaryGetValue(description, CFSTR("Is Charging"));
            charging = chargingValue != NULL && CFGetTypeID(chargingValue) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)chargingValue);
            double voltage = CCPrefNumber(CFDictionaryGetValue(description, CFSTR("Voltage")));
            double amperage = CCPrefNumber(CFDictionaryGetValue(description, CFSTR("Amperage")));
            if (voltage > 100.0) voltage /= 1000.0;
            if (amperage > 1000.0) amperage /= 1000.0;
            if (watts != NULL) *watts = fabs(voltage * amperage);
            if (percent != NULL) *percent = CCPrefNumber(CFDictionaryGetValue(description, CFSTR("Current Capacity")));
        }
    }
    if (sources != NULL) CFRelease(sources);
    if (info != NULL) releaseInfo(info);
    return charging;
}

static NSString *CCPrefClock(double timestamp) {
    if (timestamp <= 0.0) return @"—";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.dateStyle = NSDateFormatterNoStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

static NSString *CCPrefDuration(double seconds) {
    if (seconds <= 0.0) return @"—";
    NSInteger minutes = (NSInteger)llround(seconds / 60.0);
    if (minutes < 1) minutes = 1;
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    return [NSString stringWithFormat:@"%ld h %ld min", (long)(minutes / 60), (long)(minutes % 60)];
}

@interface CCSettingsPreview : UIView
- (void)refresh;
@end

@implementation CCSettingsPreview {
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UILabel *_footerLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        self.layer.cornerRadius = 18.0;
        self.layer.masksToBounds = YES;
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _detailLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        _footerLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        for (UILabel *label in @[_titleLabel, _detailLabel, _footerLabel]) {
            label.textColor = UIColor.whiteColor;
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            [self addSubview:label];
        }
        _footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
        self.accessibilityIdentifier = @"CoolCharge.SettingsPreview";
        [self refresh];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width - 24.0;
    _titleLabel.frame = CGRectMake(12.0, 9.0, width, 21.0);
    _detailLabel.frame = CGRectMake(12.0, 32.0, width, 21.0);
    _footerLabel.frame = CGRectMake(12.0, 55.0, width, 17.0);
}

- (void)refresh {
    NSDictionary *state = CCReadCoolChargeState();
    BOOL enabled = CCPreferenceBool(state, @"enabled", YES);
    BOOL showWidget = CCPreferenceBool(state, @"showLockScreenWidget", YES);
    BOOL showSessionTimes = CCPreferenceBool(state, @"showSessionTimes", YES);
    double watts = 0.0;
    double percent = 0.0;
    BOOL charging = CCPrefCharging(&watts, &percent);
    if (!enabled) {
        _titleLabel.text = @"CoolCharge disabled";
        _detailLabel.text = @"No thermal guard or Lock Screen widget";
    } else if (!showWidget) {
        _titleLabel.text = @"Lock Screen widget hidden";
        _detailLabel.text = charging ? [NSString stringWithFormat:@"Charging • %.1f W • %.0f%%", watts, percent] : @"Not charging";
    } else if (charging) {
        _titleLabel.text = [NSString stringWithFormat:@"CoolCharge preview • %.1f W • %.0f%%", watts, percent];
        double start = CCPreferenceDouble(state, @"sessionStart", 0.0);
        _detailLabel.text = showSessionTimes ? [NSString stringWithFormat:@"Charging now • Started %@", CCPrefClock(start)] : @"Charging now • live preview";
    } else {
        _titleLabel.text = @"CoolCharge preview • Not charging";
        double stopped = CCPreferenceDouble(state, @"lastSessionStop", 0.0);
        double duration = CCPreferenceDouble(state, @"lastSessionDuration", 0.0);
        _detailLabel.text = showSessionTimes ? [NSString stringWithFormat:@"Stopped %@ • Charged %@", CCPrefClock(stopped), CCPrefDuration(duration)] : @"Waiting for a charger";
    }
    _footerLabel.text = @"Live preview • changes apply without respring";
}
@end

@interface CoolChargeRootListController : PSListController
@end

@implementation CoolChargeRootListController {
    CCSettingsPreview *_preview;
    NSTimer *_refreshTimer;
    int _notificationToken;
}

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_preview == nil) {
        _preview = [[CCSettingsPreview alloc] initWithFrame:CGRectMake(16.0, 0.0, 320.0, 82.0)];
        _preview.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    }
    if ([self.view isKindOfClass:[UITableView class]]) {
        UITableView *table = (UITableView *)self.view;
        CGFloat width = table.bounds.size.width - 32.0;
        _preview.frame = CGRectMake(16.0, 10.0, width, 82.0);
        table.tableHeaderView = _preview;
    }
    [_preview refresh];
    [_refreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        CoolChargeRootListController *strongSelf = weakSelf;
        if (strongSelf != nil) [strongSelf->_preview refresh];
    }];
    if (_notificationToken == 0) {
        notify_register_dispatch(CCPreferenceChangedNotification, &_notificationToken, dispatch_get_main_queue(), ^(__unused int token) {
            CoolChargeRootListController *strongSelf = weakSelf;
            if (strongSelf != nil) [strongSelf->_preview refresh];
        });
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)resetLearning:(PSSpecifier *)specifier {
    NSMutableDictionary *state = [CCReadCoolChargeState() mutableCopy];
    for (NSString *key in @[@"sessionStart", @"lastSessionStart", @"lastSessionStop", @"lastSessionDuration"]) {
        [state removeObjectForKey:key];
    }
    [state writeToFile:CCCoolChargePreferencesPath() atomically:YES];
    [_preview refresh];
    notify_post(CCPreferenceChangedNotification);
}

- (void)dealloc {
    [_refreshTimer invalidate];
    if (_notificationToken != 0) notify_cancel(_notificationToken);
}
@end
