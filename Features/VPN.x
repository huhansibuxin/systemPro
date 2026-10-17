// Features_VPN.x — VPN 上色 + 隐藏原版 VPN 图标 + VPN 图标不飞入
//
// 染色方案对齐 OwnGoalStudio/SingleVPN（MIT，iOS16 实测可用）。三个染色点：
//   ① _UIStatusBarWifiItem -applyUpdate:toDisplayItem: → networkIconView(_UIStatusBarImageView) setTintColor:
//   ② _UIStatusBarWifiItem -_fillColorForUpdate:entry: → 返回我们的色
//   ③ _UIStatusBarCellularItem -applyUpdate:toDisplayItem: → 网络类型文字（4G/5G）setTextColor:
//      （蜂窝信号塔保持原色，对齐 SystemX 语义）
//
// 隐藏原版 VPN 图标：_UIStatusBar -_updateDisplayedItemsWithData: 里剥 vpnEntry 的副本
// （原对象保持完整，否则下一轮读到被剥数据会闪色）。
//
// 性能：所有私有类查找结果缓存；诊断日志由 SP_ENABLE_DIAG 编译期开关控制（默认关，零开销）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"

#pragma mark - 私有类缓存（热路径：每次状态栏更新都会用到）

static Class SPImageViewClass(void) {
    static Class c = Nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = NSClassFromString(@"_UIStatusBarImageView"); });
    return c;
}
static Class SPNetTypeViewClass(void) {
    static Class c = Nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = NSClassFromString(@"_UIStatusBarCellularNetworkTypeView"); });
    return c;
}
static Class SPStringViewClass(void) {
    static Class c = Nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = NSClassFromString(@"_UIStatusBarStringView"); });
    return c;
}

#pragma mark - VPN 活跃检测（数据层权威判据 + 防抖）

static BOOL gSPVPNFromData  = NO;
static BOOL gSPVPNDataSeen  = NO;
static BOOL gSPVPNNEVCache  = NO;
static NSTimeInterval gSPVPNNEVCacheAt = 0;
static int gSPVPNMissCount = 0;

static void SPVPNRefreshFromData(id data) {
    BOOL present = NO;
    if (data) {
        SEL vpnSel = NSSelectorFromString(@"vpnEntry");
        if ([data respondsToSelector:vpnSel]) {
            id entry = ((id (*)(id, SEL))objc_msgSend)(data, vpnSel);
            if (entry) {
                SEL enSel = NSSelectorFromString(@"isEnabled");
                if ([entry respondsToSelector:enSel]) {
                    present = ((BOOL (*)(id, SEL))objc_msgSend)(entry, enSel);
                } else {
                    present = YES;
                }
            }
        }
        gSPVPNDataSeen = YES;
    }
    if (present) {
        gSPVPNFromData = YES;
        gSPVPNMissCount = 0;
    } else if (gSPVPNFromData) {
        if (++gSPVPNMissCount >= 3) {   // 连续 3 次缺失才认为真断开（overlay 数据不算）
            gSPVPNFromData = NO;
            gSPVPNMissCount = 0;
        }
    }
}

// 首帧数据到达前的兜底（之后完全以数据层为准，不再做任何 IPC）
static BOOL SPVPNNEVConnected(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gSPVPNNEVCacheAt > 0 && now - gSPVPNNEVCacheAt < 5.0) return gSPVPNNEVCache;

    BOOL connected = NO;
    Class m = NSClassFromString(@"NEVPNManager");
    if (m && [m respondsToSelector:NSSelectorFromString(@"sharedManager")]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"sharedManager"));
        if (mgr && [mgr respondsToSelector:NSSelectorFromString(@"connection")]) {
            id conn = ((id (*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"connection"));
            if (conn && [conn respondsToSelector:NSSelectorFromString(@"status")]) {
                long long st = ((long long (*)(id, SEL))objc_msgSend)(conn, NSSelectorFromString(@"status"));
                if (st == 3) connected = YES;   // NEVPNStatusConnected
            }
        }
    }
    gSPVPNNEVCache = connected;
    gSPVPNNEVCacheAt = now;
    return connected;
}

static BOOL SPVPNActive(void) {
    if (gSPVPNDataSeen) return gSPVPNFromData;
    return SPVPNNEVConnected();
}

// 上色/隐藏总门控（每帧仅几个布尔判断 + 一次字典读，无 IPC）
static BOOL SPVPNColorGate(void) {
    return SPIsSpringBoard && SPBool(kColorizeVPNStatusBar) && SPVPNActive();
}

// 网络类型文字判定（对齐 SingleVPN 的 IsNetworkTypeText）
static BOOL SPIsNetworkTypeText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return NO;
    return [text isEqualToString:@"G"] || [text isEqualToString:@"3G"] ||
           [text isEqualToString:@"4G"] || [text containsString:@"5G"] ||
           [text isEqualToString:@"LTE"];
}

#pragma mark - 诊断（仅 SP_ENABLE_DIAG=1 时编入，关闭时为空实现、不做字符串拼接）

#if SP_ENABLE_DIAG
static void SPVPNTintDiag(id view, const char *via) {
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%s:%@", via, NSStringFromClass([view class])];
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    SPDiagLog([NSString stringWithFormat:@"tint %s view=%@", via, NSStringFromClass([view class])]);
}
static void SPStatusBarTreeDiag(UIView *root) {
    static NSMutableSet *logged = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
    if (!root) return;
    NSString *key = [NSString stringWithFormat:@"%p", root];
    @synchronized (logged) {
        if ([logged containsObject:key]) return;
        [logged addObject:key];
    }
    NSMutableString *line = [NSMutableString stringWithFormat:@"sb-tree(%@):", NSStringFromClass([root class])];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    int count = 0;
    while (queue.count && count < 150) {
        UIView *v = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];
        count++;
        [line appendFormat:@" %@", NSStringFromClass([v class])];
        for (UIView *s in v.subviews) [queue addObject:s];
    }
    SPDiagLog(line);
}
#else
#define SPVPNTintDiag(view, via)      do { (void)(view); } while (0)
#define SPStatusBarTreeDiag(root)     do { (void)(root); } while (0)
#endif

#pragma mark - 钩子：状态栏容器（数据层刷新 + 动画开关）

%hook _UIStatusBar
// ⚠️ 真实返回类型是 void（iOS 18 运行时头文件 + 崩溃日志双实证），勿写 id。
- (void)_updateDisplayedItemsWithData:(id)data styleAttributes:(id)attributes extraAnimations:(id)animations {
    SPVPNRefreshFromData(data);   // 先用「原始数据」判定 VPN 活跃

#if SP_ENABLE_DIAG
    // 每个状态栏实例做一次视图树诊断（App 内染色、主屏不染时用来对比类树）
    {
        static NSMutableSet *scheduled = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ scheduled = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%p", self];
        BOOL need = NO;
        @synchronized (scheduled) {
            if (![scheduled containsObject:key]) { [scheduled addObject:key]; need = YES; }
        }
        if (need) {
            UIView *sbView = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SPStatusBarTreeDiag(sbView);
            });
        }
    }
#endif

    // 上色生效 → 剥掉 vpnEntry 的「副本」交给系统（原对象保持完整，避免下一轮判定退化导致闪色）
    id workData = data;
    if (data && SPVPNColorGate()) {
        @try {
            id copy = [data copy];
            SEL setSel = NSSelectorFromString(@"setVpnEntry:");
            if (copy && [copy respondsToSelector:setSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(copy, setSel, nil);
                workData = copy;
            }
        } @catch (NSException *e) {}
    }

    // ⚠️ %orig 显式传参必须给全部实参
    %orig(workData, attributes, animations);
}

// VPN 图标不飞入：VPN 活跃 + 开关开启 → 本次状态栏更新不做动画
- (BOOL)areAnimationsEnabled {
    if (SPIsSpringBoard && SPBool(kHideVPNFlyInAnimation) && SPVPNActive()) return NO;
    return %orig;
}
%end

#pragma mark - 钩子：WiFi 图标（SingleVPN 通道）

%hook _UIStatusBarWifiItem
- (id)applyUpdate:(id)update toDisplayItem:(id)displayItem {
    BOOL vpnOn = SPVPNColorGate();
    id ret = %orig;
    if (!vpnOn) return ret;

    @try {
        NSDictionary *items = [self displayItems];
        UIView *iconView = ((id (*)(id, SEL))objc_msgSend)(self, @selector(networkIconView));
        Class ivClass = SPImageViewClass();
        for (id item in [items allValues]) {
            // 与 SingleVPN 一致：逐个 displayItem 补一次原始更新，再设 tintColor
            %orig(update, item);
            if (item == iconView && ivClass && [item isKindOfClass:ivClass]) {
                [(UIImageView *)item setTintColor:SPTintColor()];
                SPVPNTintDiag(item, "wifi-icon");
            }
        }
    } @catch (NSException *e) {}
    return ret;
}
- (UIColor *)_fillColorForUpdate:(id)update entry:(id)entry {
    if (SPVPNColorGate()) return SPTintColor();
    return %orig;
}
%end

#pragma mark - 钩子：蜂窝网络类型文字（4G/5G）

%hook _UIStatusBarCellularItem
- (id)applyUpdate:(id)update toDisplayItem:(id)displayItem {
    BOOL vpnOn = SPVPNColorGate();
    id ret = %orig;

    // 未开启时完全不做后续遍历
    if (!vpnOn) return ret;

    UIColor *originalColor = nil;
    @try { originalColor = [[update styleAttributes] textColor]; } @catch (NSException *e) {}

    @try {
        Class ntClass = SPNetTypeViewClass();
        Class svClass = SPStringViewClass();
        for (id item in [[self displayItems] allValues]) {
            UIView *v = [item view];
            if (!v) continue;
            UIView *sv = nil;
            if (ntClass && [v isKindOfClass:ntClass]) {
                sv = ((id (*)(id, SEL))objc_msgSend)(v, @selector(stringView));
            } else if (svClass && [v isKindOfClass:svClass]) {
                sv = v;
            }
            if (!sv || (svClass && ![sv isKindOfClass:svClass])) continue;

            NSString *text = ((id (*)(id, SEL))objc_msgSend)(sv, @selector(text));
            if (!SPIsNetworkTypeText(text)) continue;

            ((void (*)(id, SEL, UIColor *))objc_msgSend)(sv, @selector(setTextColor:), SPTintColor());
            SPVPNTintDiag(sv, "cell-text");
        }
    } @catch (NSException *e) {}
    return ret;
}
%end

// 兜底：样式刷新时网络类型文字再补一次色（对齐 SingleVPN 的 _UIStatusBarStringView 钩子）
%hook _UIStatusBarStringView
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (!SPVPNColorGate()) return;
    @try {
        NSString *text = ((id (*)(id, SEL))objc_msgSend)(self, @selector(text));
        if (SPIsNetworkTypeText(text)) {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(self, @selector(setTextColor:), SPTintColor());
        }
    } @catch (NSException *e) {}
}
%end

#pragma mark - 钩子：隐藏原版 VPN 图标（imageName 返回 nil，id 返回类型绝对安全）

%hook _UIStatusBarIndicatorVPNItem
- (id)imageNameForUpdate:(id)update {
    if (SPVPNColorGate()) return nil;
    return %orig;
}
- (id)systemImageNameForUpdate:(id)update {
    if (SPVPNColorGate()) return nil;
    return %orig;
}
%end
