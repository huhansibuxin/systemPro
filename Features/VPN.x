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
    gSPVPNFromData = present;
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

#pragma mark - 状态栏数据层刷新（每次更新唯一入口）

%hook _UIStatusBar
// ⚠️ 真实返回类型是 void（iOS 18 运行时头文件实证）。之前写成 id：
// ARC 会对「返回的对象指针」做 objc_autoreleaseReturnValue，而 void 方法返回的是垃圾值
// → autorelease 非对象 → SpringBoard 崩溃进安全模式。
- (void)_updateDisplayedItemsWithData:(id)data styleAttributes:(id)attributes extraAnimations:(id)animations {
    SPVPNRefreshFromData(data);   // 先用「原始数据」判定 VPN 活跃

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

    %orig(workData);
}
%end

#pragma mark - 钩子：上色

// 信号条：**只染 WiFi 图标**（_UIStatusBarWifiSignalView 的弧线）。
// ⚠️ 上一版挂基类 _UIStatusBarSignalView → 蜂窝信号塔（bars）也被染了，老板明确不要
//（SystemX 原版语义：给 Wi-Fi 图标和蜂窝网络类型文字上色，不改变蜂窝信号塔）。
%hook _UIStatusBarWifiSignalView
- (void)setActiveColor:(id)color {
    %orig(SPVPNColorGate() ? SPTintColor() : color);
}
- (void)setInactiveColor:(id)color {
    %orig(SPVPNColorGate() ? SPTintColor() : color);
}
%end

// WiFi 信号条（STUI 老样式）
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

#pragma mark - 钩子：上色生效时隐藏原版带方框的 VPN 图标
// 方式：让 VPN 指示器取不到图（imageName 返回 nil）——返回 nil 对 id 返回类型绝对安全，
// 不走 BOOL 返回的门控方法（canEnableDisplayItem:fromData: 真实返回类型无法静态确认，
// 写错 BOOL/id 会在 ABI 上互撞：BOOL→id 会让调用方把 0x1 当对象指针用）。

%hook _UIStatusBarIndicatorVPNItem
- (id)imageNameForUpdate:(id)update {
    if (SPVPNColorGate()) return nil;   // 上色生效 → 原版 VPN 图标不显示
    return %orig;
}
- (id)systemImageNameForUpdate:(id)update {
    if (SPVPNColorGate()) return nil;
    return %orig;
}
// VPN 图标不飞入：入场动画对象返回 nil = 瞬间出现
- (id)additionAnimationForDisplayItemWithIdentifier:(id)identifier {
    if (SPIsSpringBoard && SPBool(kHideVPNFlyInAnimation)) return nil;
    return %orig;
}
%end
