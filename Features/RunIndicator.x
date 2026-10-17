// Features_RunIndicator.x — APP 运行指示点（移植自 SystemX runIndicatorEnabled）
// SystemX 原版语义（设置面板原文）：「当 APP 在前台运行时，APP 的名字会替换为一个指示点，
// 代表当前 APP 正在运行中。」
//
// 设计原则（老板要求：全部事件驱动、不许常驻占 CPU）：
//   • 触发点只有两个：① 系统标签更新回调 iconViewDisplaysLabel:；② 进程启动/退出事件。
//   • **不再 hook layoutSubviews**（那是每帧调用）。圆点位置交给 Auto Layout 约束，一次设定永久生效。
//   • 无定时器、无轮询；运行判定只在上述事件里做一次 FBProcessManager 查询。
//
// 其它要点：
//  1) 名称隐藏 = labelView.hidden（公开 API），不碰 setLabelHidden:（参数类型不明）；
//  2) 圆点 8pt，颜色 = 电池充电绿（systemGreen #34C759）；
//  3) 只画在真正位于图标列表里的图标视图上（superview 链含 IconList/Dock），排除过渡代理视图；
//  4) 系统自带的小圆点 SBIconDotLabelAccessoryView（约 4-5pt）在功能开启时一律隐藏，
//     避免「两个点、大小不一样」；
//  5) 诊断日志 /var/mobile/Library/Preferences/systemPro.log（mobile 可写）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"
#import <objc/runtime.h>

// 专用圆点类：便于精确识别/清理我们自己的点
@interface SPRunDotView : UIView
@end
@implementation SPRunDotView
@end

static const void *kSPDotKey       = &kSPDotKey;
static const void *kSPHidLabelKey  = &kSPHidLabelKey;
static NSHashTable *gSPIconViews   = nil;

static const CGFloat SP_DOT_SIZE = 8.0;               // 直径 8pt（10pt 实测偏大，减 2pt）

static UIColor *SPRunDotColor(void) {
    return [UIColor systemGreenColor];                // 老板指定：电池充电绿
}

static UIView *SPRunLabelView(SBIconView *iconView) {
    @try {
        id lv = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(labelView));
        if ([lv isKindOfClass:[UIView class]]) return (UIView *)lv;
    } @catch (NSException *e) {}
    return nil;
}

// 是否真的挂在图标列表里（排除 App 缩放/过渡用的代理图标视图）
static BOOL SPRunIconViewInList(SBIconView *iconView) {
    UIView *v = iconView.superview;
    for (int i = 0; v && i < 4; i++, v = v.superview) {
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"IconList"] || [cn containsString:@"Dock"]) return YES;
    }
    return NO;
}

static NSString *SPRunIndicatorBundleID(SBIconView *iconView) {
    id icon = nil;
    @try { icon = [iconView valueForKey:@"icon"]; } @catch (NSException *e) { return nil; }
    if (![icon respondsToSelector:@selector(applicationBundleID)]) return nil;
    if (![icon respondsToSelector:@selector(isApplicationIcon)]) return nil;
    @try {
        if (!((BOOL (*)(id, SEL))objc_msgSend)(icon, @selector(isApplicationIcon))) return nil;
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(applicationBundleID));
        return [bid isKindOfClass:[NSString class]] ? bid : nil;
    } @catch (NSException *e) { return nil; }
}

static BOOL SPRunIndicatorAppIsRunning(NSString *bid) {
    if (!bid.length) return NO;
    static Class gMgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gMgr = NSClassFromString(@"FBProcessManager"); });
    if (!gMgr) return NO;
    @try {
        SEL sharedSel = @selector(sharedInstance);
        if (![gMgr respondsToSelector:sharedSel]) return NO;
        id inst = ((id (*)(id, SEL))objc_msgSend)(gMgr, sharedSel);
        if (!inst) return NO;
        SEL sel = @selector(processesForBundleIdentifier:);
        if (![inst respondsToSelector:sel]) return NO;
        NSArray *procs = ((id (*)(id, SEL, id))objc_msgSend)(inst, sel, bid);
        return [procs isKindOfClass:[NSArray class]] && procs.count > 0;
    } @catch (NSException *e) { return NO; }
}

static BOOL SPRunIndicatorActiveForView(SBIconView *iconView) {
    if (!SPIsSpringBoard || !SPBool(kRunIndicatorEnabled)) return NO;
    if (!SPRunIconViewInList(iconView)) return NO;
    return SPRunIndicatorAppIsRunning(SPRunIndicatorBundleID(iconView));
}

// 诊断：只在「状态签名」变化时记一条（不刷屏）。
// 记录 apply 结束后的真实现场：superview、bounds、以及所有点状子视图的类名/尺寸/隐藏态。
// 读法（SSH 真实根前缀）：/rootfs/var/mobile/Library/Logs/systemPro.log
static void SPRunDotDiagState(SBIconView *iconView, NSString *phase) {
    static NSMutableDictionary *lastSig = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastSig = [NSMutableDictionary dictionary]; });

    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ icon=%@ super=%@ bounds=%@ tf=%@",
                             phase,
                             NSStringFromClass([iconView class]),
                             iconView.superview ? NSStringFromClass([iconView.superview class]) : @"(nil)",
                             NSStringFromCGRect(iconView.bounds),
                             NSStringFromCGAffineTransform(iconView.transform)];
    NSInteger n = 0;
    for (UIView *sv in iconView.subviews) {
        NSString *cn = NSStringFromClass([sv class]);
        CGRect f = sv.frame;
        BOOL small = (f.size.width > 0 && f.size.width <= 14.0) || (f.size.height > 0 && f.size.height <= 14.0);
        if ([sv isKindOfClass:[SPRunDotView class]] || [cn containsString:@"Dot"] ||
            [cn containsString:@"Accessory"] || small) {
            // 指纹：背景色 / 圆角 / tag —— 不同插件画点时特征不同，用来锁定归属
            UIColor *bg = sv.backgroundColor;
            CGFloat cr = sv.layer.cornerRadius;
            [line appendFormat:@" [%@ %@ bg=%@ r=%.1f tag=%ld%@%@]", cn, NSStringFromCGRect(f),
                               bg ? [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f",
                                     CGColorGetComponents(bg.CGColor)[0],
                                     CGColorGetComponents(bg.CGColor)[1],
                                     CGColorGetComponents(bg.CGColor)[2],
                                     CGColorGetNumberOfComponents(bg.CGColor) > 3 ? CGColorGetComponents(bg.CGColor)[3] : 1.0] : @"nil",
                               cr, (long)sv.tag,
                               sv.hidden ? @" hidden" : @"", sv.superview == iconView ? @"" : @" detached"];
            n++;
        }
    }
    NSString *sig = [NSString stringWithFormat:@"%@|%ld", line, (long)n];
    NSString *key = [NSString stringWithFormat:@"%p", iconView];
    @synchronized (lastSig) {
        if ([lastSig[key] isEqualToString:sig]) return;
        lastSig[key] = sig;
    }
    SPDiagLog(line);
}

// 把圆点装到图标视图上。位置交给 Auto Layout 约束：一次设定，layout 阶段零额外代码。
static UIView *SPRunDotInstall(SBIconView *iconView) {
    UIView *dot = objc_getAssociatedObject(iconView, kSPDotKey);
    if (!dot) {
        dot = [SPRunDotView new];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        dot.layer.cornerRadius = SP_DOT_SIZE / 2.0;
        dot.backgroundColor = SPRunDotColor();
        dot.userInteractionEnabled = NO;
        objc_setAssociatedObject(iconView, kSPDotKey, dot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (dot.superview != iconView) {
        [iconView addSubview:dot];
        [NSLayoutConstraint activateConstraints:@[
            [dot.widthAnchor     constraintEqualToConstant:SP_DOT_SIZE],
            [dot.heightAnchor    constraintEqualToConstant:SP_DOT_SIZE],
            [dot.centerXAnchor   constraintEqualToAnchor:iconView.centerXAnchor],
            // 贴到名称行（≈ 图标视图底部）：老板实测「正常位置」就在这里；
            // 之前 -10 偏高，看起来像压在图标上
            [dot.bottomAnchor    constraintEqualToAnchor:iconView.bottomAnchor constant:-1.0],
        ]];
    }
    [iconView bringSubviewToFront:dot];
    return dot;
}

static void SPRunIndicatorApply(SBIconView *iconView) {
    BOOL active = SPRunIndicatorActiveForView(iconView);
    UIView *dot = objc_getAssociatedObject(iconView, kSPDotKey);
    BOOL weHid = [objc_getAssociatedObject(iconView, kSPHidLabelKey) boolValue];
    UIView *labelView = SPRunLabelView(iconView);

    // 防重：清掉除当前 dot 外的遗留点
    for (UIView *sv in [iconView.subviews copy]) {
        if ([sv isKindOfClass:[SPRunDotView class]] && sv != dot) [sv removeFromSuperview];
    }

    if (active) {
        SPRunDotInstall(iconView);
        if (labelView) {
            labelView.hidden = YES;
            objc_setAssociatedObject(iconView, kSPHidLabelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        if (dot) [dot removeFromSuperview];
        if (labelView && weHid) labelView.hidden = NO;
        objc_setAssociatedObject(iconView, kSPHidLabelKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!gSPIconViews) gSPIconViews = [NSHashTable weakObjectsHashTable];
    [gSPIconViews addObject:iconView];

    SPRunDotDiagState(iconView, active ? @"apply-on" : @"apply-off");
}

// 进程事件才刷新（事件驱动，零轮询）
static void SPRunIndicatorRefreshVisible(void) {
    if (!SPBool(kRunIndicatorEnabled)) return;
    for (SBIconView *v in [gSPIconViews allObjects]) {
        if (![v isKindOfClass:NSClassFromString(@"SBIconView")]) continue;
        if (!v.window) continue;
        SPRunIndicatorApply(v);
        if ([v respondsToSelector:@selector(_updateLabel)]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(v, @selector(_updateLabel)); } @catch (NSException *e) {}
        }
    }
}

static void SPRunIndicatorScheduleRefresh(void) {
    // ⚠️ FBProcessManager call-out 是后台线程，UI 必须切主队列；合并短时间内的多次事件
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduled = NO;
        SPRunIndicatorRefreshVisible();
    });
}

// App 启动时进程注册有延迟：立即刷那一次常常还查不到进程 → 补一次 0.6s 后的一次性刷新。
// 只是一次性 dispatch_after，不是轮询/定时器（老板要求：事件驱动、不常驻占 CPU）。
static void SPRunIndicatorScheduleRefreshDelayed(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SPRunIndicatorRefreshVisible();
    });
}

#pragma mark - 钩子

// 系统问「这个图标要不要显示名称」——运行中的 App 不要；顺带维护圆点。
// 这是唯一的常规触发点（每次标签更新都会走），无 layoutSubviews / 无定时器。
%hook SBHIconManager
- (BOOL)iconViewDisplaysLabel:(id)iconView {
    if ([iconView isKindOfClass:NSClassFromString(@"SBIconView")]) {
        SBIconView *v = (SBIconView *)iconView;
        if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) SPRunIndicatorApply(v);
        if (SPRunIndicatorActiveForView(v)) return NO;
    }
    return %orig;
}
%end

// 系统自带的 label accessory 小圆点（约 4-5pt）：功能开启时一律隐藏，只留我们的 8pt 绿点
%hook SBIconDotLabelAccessoryView
- (void)didMoveToSuperview {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) {
        self.hidden = YES;
        static int logs = 0;
        if (logs < 15) {
            logs++;
            SPDiagLog([NSString stringWithFormat:@"accessory hidden super=%@ frame=%@",
                       NSStringFromClass([self.superview class]), NSStringFromCGRect(self.frame)]);
        }
    }
}
- (void)layoutSubviews {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) self.hidden = YES;
}
%end

// 视图进入窗口时补一次（Dock / 新页面首次出现走这条路；代理视图被 SPRunIconViewInList 挡掉）。
// 只在「进入窗口」这个事件里执行，不是每帧。
%hook SBIconView
- (void)didMoveToWindow {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) SPRunIndicatorApply(self);
}
%end

%hook FBProcessManager
- (void)noteProcessDidExit:(id)process {
    SPRunIndicatorScheduleRefresh();
    %orig;
}
- (void)launchProcessWithContext:(id)context {
    SPRunIndicatorScheduleRefresh();
    SPRunIndicatorScheduleRefreshDelayed();   // 进程注册有延迟，补一次
    %orig;
}
%end
