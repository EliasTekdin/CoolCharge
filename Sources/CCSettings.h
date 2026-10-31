#import <Foundation/Foundation.h>

#define CCPreferenceDomain @"com.ilyastekdin.coolcharge"
#define CCPreferenceChangedNotification "com.ilyastekdin.coolcharge/changed"

// PreferenceLoader stores this domain in the real mobile preference vault.
// It is a system path, so it must not be prefixed with the bootstrap root.
static inline NSString *CCCoolChargePreferencesPath(void) {
    return @"/var/mobile/Library/Preferences/com.ilyastekdin.coolcharge.plist";
}

static inline NSDictionary *CCReadCoolChargeState(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:CCCoolChargePreferencesPath()];
    return [state isKindOfClass:[NSDictionary class]] ? state : @{};
}

static inline void CCWriteCoolChargeState(NSDictionary *updates) {
    if (![updates isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *state = [CCReadCoolChargeState() mutableCopy];
    [state addEntriesFromDictionary:updates];
    [state writeToFile:CCCoolChargePreferencesPath() atomically:YES];
}

static inline BOOL CCPreferenceBool(NSDictionary *state, NSString *key, BOOL fallback) {
    id value = state[key];
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    CFTypeRef preference = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)CCPreferenceDomain);
    BOOL result = preference == NULL ? fallback : CFBooleanGetValue((CFBooleanRef)preference);
    if (preference != NULL) CFRelease(preference);
    return result;
}

static inline double CCPreferenceDouble(NSDictionary *state, NSString *key, double fallback) {
    id value = state[key];
    if ([value respondsToSelector:@selector(doubleValue)]) return [value doubleValue];
    return fallback;
}
