// Prefs.m — 开关读取器实现
// 设计（与 SystemX 一致的三层）：
//  1) dictionaryWithContentsOfFile 直读 plist（快，主线程零成本）
//  2) CFPreferencesCopyAppValue 回退（plist 尚未落盘时）
//  3) Darwin 通知 com.sytem.pro.prefschanged 触发重载（设置面板改完即生效）
#import "Prefs.h"
#import "Common.h"

static void SPPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo);

@implementation SPPrefs {
    NSDictionary *_cache;
}

+ (instancetype)shared {
    static SPPrefs *gShared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gShared = [[SPPrefs alloc] init];
        [gShared load];
        [gShared observeReload];
    });
    return gShared;
}

- (void)load {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SPPreferencesPath()];
    if (![d isKindOfClass:[NSDictionary class]]) d = @{};
    @synchronized (self) {
        _cache = d;
    }
    SPLog(@"prefs loaded: %lu keys", (unsigned long)d.count);
}

- (void)observeReload {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    SPPrefsChangedCallback,
                                    CFSTR("com.sytem.pro.prefschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

// ⚠️ 性能：旧实现「键不存在时重读 plist + CFPreferences」——热路径（状态栏每次更新、
// 每个图标标签更新）里所有未设置过的开关都会触发磁盘 IO + 跨进程调用，长期白烧 CPU。
// 现在只查内存缓存：未命中即视为「关闭」；面板写入后由 Darwin 通知触发 load 刷新缓存。
- (id)valueFor:(NSString *)key {
    if (!SPGatePassed) return nil; // 门禁未过：一切开关视为关闭

    NSDictionary *cache = nil;
    @synchronized (self) { cache = _cache; }
    if (!cache) {                  // 仅首次（尚未加载）才读盘
        [self load];
        @synchronized (self) { cache = _cache; }
    }
    return cache[key];
}

- (BOOL)boolFor:(NSString *)key {
    id v = [self valueFor:key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return NO;
}

- (long)intFor:(NSString *)key {
    id v = [self valueFor:key];
    if ([v isKindOfClass:[NSNumber class]]) return [v longValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue]; // 面板以字符串存数字
    return 0;
}
- (double)floatFor:(NSString *)key  { id v = [self valueFor:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }

- (NSString *)stringFor:(NSString *)key default:(NSString *)def {
    id v = [self valueFor:key];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return def;
}

@end

static void SPPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[SPPrefs shared] load];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SPPrefsReloaded" object:nil];
}

// ---------- C 便捷入口 ----------
BOOL SPBool(NSString *key)        { return [[SPPrefs shared] boolFor:key]; }
long SPInt(NSString *key)         { return [[SPPrefs shared] intFor:key]; }
double SPFloat(NSString *key)     { return [[SPPrefs shared] floatFor:key]; }
NSString *SPString(NSString *key, NSString *def) { return [[SPPrefs shared] stringFor:key default:def]; }
