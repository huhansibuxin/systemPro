// Features_VPN.x — VPN 上色 + 隐藏原版 VPN 图标 + VPN 图标不飞入
// 对标 SystemX（com.wkk.systembox）三个键：
//   colorizeVPNStatusBar  上色（VPN 连接时 VPN/WiFi/蜂窝一起变 #A7C6FF）
//   colorizeVPNStatusBar  同时隐藏原版带方框的 VPN 图标
//   hideVPNFlyInAnimation VPN 图标不播滑入动画、瞬间出现
//
// ⚠️ VPN 活跃检测（2026-10-17 修：原实现 getifaddrs 扫 utun* 有误报）：
//   iOS 系统服务（AirDrop / Continuity / iCloud 等）常年占用 utun0..utun3 且带地址 UP，
//   扫 utun 会把「没开 VPN」误判成「VPN 已连接」→ 没连 VPN 也上色。
//   改为权威判据：状态栏数据层 `_UIStatusBarData.vpnEntry.isEnabled`
//   —— 它就是「状态栏要不要显示 VPN 指示器」的同一个开关，与用户所见严格一致。
//   刷新点：`_UIStatusBar -_updateDisplayedItemsWithData:styleAttributes:extraAnimations:`
//   （每次状态栏数据更新的唯一入口，枚举条目前的钩子先刷新，无轮询、无 TTL）。
//   兜底：首帧数据到达前用 NEVPNManager.connection.status==3（5s TTL）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"

#pragma mark - VPN 活跃检测（数据层权威判据）

static BOOL gSPVPNFromData  = NO;   // 状态栏数据：vpnEntry 是否存在且 enabled
static BOOL gSPVPNDataSeen  = NO;   // 是否收到过状态栏数据（收到过就只信数据）
static BOOL gSPVPNNEVCache  = NO;   // NEVPNManager 兜底缓存
static NSTimeInterval gSPVPNNEVCacheAt = 0;

// 从 _UIStatusBarData 里读 vpnEntry.isEnabled（iOS16 dump 实证的 API）
// ⚠️ 控制中心下拉等场景会送来「只含部分条目的 overlay 数据」，vpnEntry 缺失 ≠ VPN 断开。
// 用「连续 3 次缺失才判定断开」过滤误判，避免染色忽有忽无（老板实测会闪）。
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
                    present = YES;   // 有条目即视为在显示
                }
            }
        }
        gSPVPNDataSeen = YES;
    }
    if (present) {
        gSPVPNFromData = YES;
        gSPVPNMissCount = 0;
    } else if (gSPVPNFromData) {
        if (++gSPVPNMissCount >= 3) {   // 连续 3 次缺失才认为真断开
            gSPVPNFromData = NO;
            gSPVPNMissCount = 0;
        }
    }
}

// NEVPNManager 兜底（仅首帧数据到达前使用）
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
    if (gSPVPNDataSeen) return gSPVPNFromData;   // 数据层说了算，绝无误报
    return SPVPNNEVConnected();
}

// 上色/隐藏门控：SpringBoard + 开关 + VPN 真连着
static BOOL SPVPNColorGate(void) {
    return SPIsSpringBoard && SPBool(kColorizeVPNStatusBar) && SPVPNActive();
}

#pragma mark - 属性串上色（SystemX 真做法：在 setText:/applyStyleAttributes: 里构造带色属性串，
// 光事后 setTextColor 会被系统随后重设样式冲掉）

static NSAttributedString *SPVPNColorizedAttributed(NSAttributedString *src, UIColor *color) {
    if (![src isKindOfClass:[NSAttributedString class]]) return nil;
    NSMutableAttributedString *m = [src mutableCopy];
    if (!m) return nil;
    [m addAttribute:NSForegroundColorAttributeName value:color
              range:NSMakeRange(0, m.length)];
    return m;
}

// 只对显示 "VPN" 的串上色（其余状态栏文字一律不动）
static NSMutableAttributedString *SPVPNMaybeColorize(NSAttributedString *attr, NSString *plain) {
    if (!SPVPNColorGate()) return nil;
    NSString *text = plain;
    if (![text isKindOfClass:[NSString class]] && [attr isKindOfClass:[NSAttributedString class]]) {
        text = attr.string;
    }
    if (![text isKindOfClass:[NSString class]] || ![text containsString:@"VPN"]) return nil;

    UIColor *c = SPTintColor();
    if ([attr isKindOfClass:[NSAttributedString class]] && attr.length > 0) {
        return (NSMutableAttributedString *)SPVPNColorizedAttributed(attr, c);
    }
    return [[NSMutableAttributedString alloc] initWithString:text
                                                  attributes:@{ NSForegroundColorAttributeName: c }];
}

#pragma mark - 状态栏视图树诊断（一次性）
// 把 _UIStatusBar 整棵子树的类名抓出来 —— 主屏状态栏的 WiFi 图标到底是哪个类画的，一眼可见。
// ⚠️ 每个 _UIStatusBar 实例各记一次（老板实测：App 内染色、主屏不染 → 两个实例可能不是同一套类）。
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

#pragma mark - 钩子：状态栏图标染色（模板图 + tintColor 通道）
// iOS16 主屏状态栏的图标（WiFi/电池等）是 _UIStatusBarImageView 里的模板图，
// 颜色来自样式的前景色 —— 之前挂的「信号视图颜色」通道根本不在这条路上（日志实证 tint 为空）。
// 做法：WiFi 语境下的模板图强制 AlwaysTemplate + tintColor = 我们的淡蓝；蜂窝信号塔不动。
static BOOL SPImageViewIsWifiContext(UIView *v) {
    UIView *p = v.superview;
    for (int i = 0; p && i < 5; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"Wifi"]) return YES;
        if ([cn containsString:@"Cellular"] || [cn containsString:@"Battery"]) return NO;
    }
    return NO;
}

%hook _UIStatusBarImageView
- (void)setTintColor:(UIColor *)color {
    if (SPVPNColorGate() && SPImageViewIsWifiContext(self)) {
        %orig(SPTintColor());
        SPVPNTintDiag(self, "iv-tint");
        return;
    }
    %orig;
}
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (!SPVPNColorGate() || !SPImageViewIsWifiContext(self)) return;
    @try {
        self.image = [self.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.tintColor = SPTintColor();
        SPVPNTintDiag(self, "iv-style");
    } @catch (NSException *e) {}
}
%end

#pragma mark - 钩子：状态栏数据层刷新（每次更新唯一入口）

%hook _UIStatusBar
// ⚠️ 真实返回类型是 void（iOS 18 运行时头文件实证）。之前写成 id：
// ARC 会对「返回的对象指针」做 objc_autoreleaseReturnValue，而 void 方法返回的是垃圾值
// → autorelease 非对象 → SpringBoard 崩溃进安全模式。
- (void)_updateDisplayedItemsWithData:(id)data styleAttributes:(id)attributes extraAnimations:(id)animations {
    SPVPNRefreshFromData(data);   // 先用「原始数据」判定 VPN 活跃

    // 每个状态栏实例做一次视图树诊断（App 内染色、主屏不染 → 需要看两个实例各自的类树）
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

    // 上色生效 → 把 vpnEntry 从状态栏数据里剥掉：条目不存在 → 指示器不创建、不占位、
    // 没有入场动画（也不会挤掉电池/信号/WiFi）。
    // ⚠️ 必须剥**副本**再交给系统：直接改原对象的话，下一轮更新拿到的还是这份被剥掉的数据，
    // 判定退化成「VPN 未连接」→ 染/不染来回闪（老板实测「偶尔跳白、偶尔跳淡蓝」就是这个）。
    id workData = data;
    if (SPVPNColorGate() && data) {
        @try {
            id copy = [data copy];
            SEL setSel = NSSelectorFromString(@"setVpnEntry:");
            if (copy && [copy respondsToSelector:setSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(copy, setSel, nil);
                workData = copy;
            }
        } @catch (NSException *e) {}
    }

    // ⚠️ %orig 显式传参时必须给全部实参（data / styleAttributes / extraAnimations 三个）
    %orig(workData, attributes, animations);
}
%end

#pragma mark - 钩子：上色

// 信号条：**只染 WiFi 图标**。两条通道都要挂：
//  ① 基类 _UIStatusBarSignalView 的 setActiveColor:/setInactiveColor:（颜色设置入口）
//  ② 基类 applyStyleAttributes: 之后补色 —— 主桌面状态栏的 WiFi 实例在样式刷新后会重设颜色，
//     只靠 setter 会被冲掉（老板实测「主桌面不染色，只有控制中心那颗染」就是它）。
// 用类名含 "Wifi" 过滤，蜂窝信号塔保持原色（SystemX 语义：不动信号塔）。
static BOOL SPIsWifiSignalView(id view) {
    NSString *cn = NSStringFromClass([view class]);
    return [cn containsString:@"Wifi"];
}

// 一次性诊断：记录「实际被我们染色」的视图类名。
// 用来定位「主屏不染、只有控制中心染」——如果主屏那个实例的类名从没出现，说明它走的是另一条通道。
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

%hook _UIStatusBarSignalView
- (void)setActiveColor:(id)color {
    if (SPVPNColorGate() && SPIsWifiSignalView(self)) {
        %orig(SPTintColor());
        return;
    }
    %orig;
}
- (void)setInactiveColor:(id)color {
    if (SPVPNColorGate() && SPIsWifiSignalView(self)) {
        %orig(SPTintColor());
        return;
    }
    %orig;
}
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (!SPVPNColorGate() || !SPIsWifiSignalView(self)) return;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setActiveColor:), SPTintColor());
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setInactiveColor:), SPTintColor());
        SPVPNTintDiag(self, "style");
    } @catch (NSException *e) {}
}
%end

// WiFi 信号条（STUI 老样式）—— 同样要管 applyStyleAttributes:，否则样式刷新会把颜色冲回去
%hook STUIStatusBarWifiSignalView
- (void)setActiveColor:(id)color {
    UIColor *spc = color;
    if (SPVPNColorGate()) spc = SPTintColor();
    %orig(spc);
}
- (void)setInactiveColor:(id)color {
    UIColor *spc = color;
    if (SPVPNColorGate()) spc = SPTintColor();
    %orig(spc);
}
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (!SPVPNColorGate()) return;
    @try {
        [(id)self setActiveColor:SPTintColor()];
        [(id)self setInactiveColor:SPTintColor()];
        SPVPNTintDiag(self, "stui-style");
    } @catch (NSException *e) {}
}
%end

// WiFi 信号条（_UI 新样式：颜色由 fillColor 决定）
%hook _UIStatusBarWifiItem
- (id)_fillColorForUpdate:(id)update entry:(id)entry {
    if (SPVPNColorGate()) return SPTintColor();
    return %orig;
}
%end

// 蜂窝网络类型（5G/4G 那行）：走属性串通道 + 事后补色
%hook STUIStatusBarCellularNetworkTypeView
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (SPVPNColorGate()) [(id)self setTextColor:SPTintColor()];
}
%end

%hook _UIStatusBarCellularNetworkTypeView
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (SPVPNColorGate()) [(id)self setTextColor:SPTintColor()];
}
%end

// 状态栏文字（VPN 胶囊就在这层）：拦截带色属性串 + setText
%hook STUIStatusBarStringView
- (void)setText:(id)text {
    id out = text;
    NSAttributedString *colored = SPVPNMaybeColorize(nil, text);
    if (colored) out = colored;
    %orig(out);
}
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (!SPVPNColorGate()) return;
    NSString *t = nil;
    @try { t = [(id)self text]; } @catch (NSException *e) {}
    if ([t isKindOfClass:[NSString class]] && [t containsString:@"VPN"]) {
        @try { [(id)self setTextColor:SPTintColor()]; } @catch (NSException *e) {}
    }
}
%end

%hook _UIStatusBarStringView
- (void)setText:(id)text {
    id out = text;
    NSAttributedString *colored = SPVPNMaybeColorize(nil, text);
    if (colored) out = colored;
    %orig(out);
}
- (void)applyStyleAttributes:(id)attributes {
    %orig;
    if (!SPVPNColorGate()) return;
    NSString *t = nil;
    @try { t = [(id)self text]; } @catch (NSException *e) {}
    if ([t isKindOfClass:[NSString class]] && [t containsString:@"VPN"]) {
        @try { [(id)self setTextColor:SPTintColor()]; } @catch (NSException *e) {}
    }
}
%end

#pragma mark - 钩子：VPN 图标不飞入
// 分三层拦，因为实测只挂 additionAnimation 不够（状态栏的入场动画还有别的来源）：
//  ① 状态栏级动画总开关：VPN 活跃 + 功能开启 → 直接关闭本次更新的动画（最有效）
//  ② item 级 prepareAnimation / ③ additionAnimation 都返回 nil（细粒度兜底）
%hook _UIStatusBar
- (BOOL)areAnimationsEnabled {
    if (SPIsSpringBoard && SPBool(kHideVPNFlyInAnimation) && SPVPNActive()) return NO;
    return %orig;
}
%end

%hook _UIStatusBarIndicatorVPNItem
- (id)imageNameForUpdate:(id)update {
    if (SPVPNColorGate()) return nil;   // 上色生效 → 原版 VPN 图标不显示
    return %orig;
}
- (id)systemImageNameForUpdate:(id)update {
    if (SPVPNColorGate()) return nil;
    return %orig;
}
- (id)prepareAnimation:(id)animation forDisplayItem:(id)displayItem {
    if (SPIsSpringBoard && SPBool(kHideVPNFlyInAnimation)) return nil;
    return %orig;
}
- (id)additionAnimationForDisplayItemWithIdentifier:(id)identifier {
    if (SPIsSpringBoard && SPBool(kHideVPNFlyInAnimation)) return nil;
    return %orig;
}
%end
