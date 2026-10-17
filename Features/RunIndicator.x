// Features_RunIndicator.x — APP 运行指示点（移植自 SystemX runIndicatorEnabled）
// SystemX 原版语义（设置面板原文）：「当 APP 在前台运行时，APP 的名字会替换为一个指示点，
// 代表当前 APP 正在运行中。」
//
// 实现要点（选择器均经 springboard-dump 核对；返回类型一律按最保守方式处理）：
//  1) SBHIconManager -iconViewDisplaysLabel:  运行中的 App 不显示名称（BOOL，标准 delegate 签名）；
//  2) 名称隐藏用 labelView.hidden（UIView 公开 API），不碰 setLabelHidden:（参数类型不明）；
//  3) 圆点 8pt，颜色 = 电池充电绿（systemGreen #34C759，老板指定）；
//  4) 位置：等图标布局完成（bounds 有效）才摆，并在 layoutSubviews 里只做「位置校正」，
//     避免之前「先在图标上方出现一个点、再跳到下方」的抖动；
//  5) 运行判定：FBProcessManager processesForBundleIdentifier:（含后台挂起）；
//  6) 刷新：进程事件 dispatch 主队列（FB 的 call-out 是后台线程，直接动 UI 会 CA abort）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"
#import <objc/runtime.h>

static const void *kSPDotKey       = &kSPDotKey;      // 我们的圆点 view
static const void *kSPHidLabelKey  = &kSPHidLabelKey; // 是否被我们隐藏了名称（恢复时用）
static NSHashTable *gSPIconViews   = nil;             // 弱引用表：见过的图标 view

static const CGFloat SP_DOT_SIZE = 8.0;               // 直径 8pt（上一版 6pt 偏小）

// 老板指定：指示点颜色 = 电池充电图标的绿色
static UIColor *SPRunDotColor(void) {
    return [UIColor systemGreenColor];
}

static UIView *SPRunLabelView(SBIconView *iconView) {
    @try {
        id lv = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(labelView));
        if ([lv isKindOfClass:[UIView class]]) return (UIView *)lv;
    } @catch (NSException *e) {}
    return nil;
}

// 摆圆点：图标还没布局（bounds 无效）就直接跳过，等 layoutSubviews 再摆 —— 这是消除
// 「先在图标上方显示一个点、再跳到下方」抖动的关键。
static void SPRunDotPosition(SBIconView *iconView, UIView *dot) {
    CGRect b = iconView.bounds;
    if (b.size.width < 10.0 || b.size.height < 10.0) return;

    CGFloat cx = b.size.width / 2.0;
    CGFloat cy = b.size.height - 14.0;      // 名称行所在高度
    UIView *lv = SPRunLabelView(iconView);
    if (lv && !CGRectIsEmpty(lv.frame)) {
        cx = CGRectGetMidX(lv.frame);
        cy = CGRectGetMidY(lv.frame);
    }
    dot.frame = CGRectMake(round(cx - SP_DOT_SIZE / 2.0), round(cy - SP_DOT_SIZE / 2.0),
                           SP_DOT_SIZE, SP_DOT_SIZE);
}

// 取图标的 bundleID（仅普通 App 图标；文件夹/小组件返回 nil，天然排除）
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

// App 是否在运行（FBProcessManager 有它的进程 = 活着，含后台挂起）
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
    return SPRunIndicatorAppIsRunning(SPRunIndicatorBundleID(iconView));
}

// 核心：按运行态决定「隐藏名称 + 画点」/「恢复名称 + 收点」
static void SPRunIndicatorApply(SBIconView *iconView) {
    BOOL active = SPRunIndicatorActiveForView(iconView);
    UIView *dot = objc_getAssociatedObject(iconView, kSPDotKey);
    BOOL weHid = [objc_getAssociatedObject(iconView, kSPHidLabelKey) boolValue];
    UIView *labelView = SPRunLabelView(iconView);

    if (active) {
        if (!dot) {
            dot = [UIView new];
            dot.layer.cornerRadius = SP_DOT_SIZE / 2.0;
            dot.backgroundColor = SPRunDotColor();
            dot.userInteractionEnabled = NO;
            objc_setAssociatedObject(iconView, kSPDotKey, dot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        SPRunDotPosition(iconView, dot);
        if (dot.superview != iconView) [iconView addSubview:dot];
        [iconView bringSubviewToFront:dot];

        if (labelView) {
            labelView.hidden = YES;
            objc_setAssociatedObject(iconView, kSPHidLabelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        if (dot) [dot removeFromSuperview];
        // 只恢复被我们隐藏过的名称，避免和系统自身隐藏策略打架
        if (labelView && weHid) labelView.hidden = NO;
        objc_setAssociatedObject(iconView, kSPHidLabelKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!gSPIconViews) gSPIconViews = [NSHashTable weakObjectsHashTable];
    [gSPIconViews addObject:iconView];
}

// 进程启动/退出 → 刷新可见图标（事件驱动，零轮询）
static void SPRunIndicatorRefreshVisible(void) {
    if (!SPBool(kRunIndicatorEnabled)) return;
    for (SBIconView *v in [gSPIconViews allObjects]) {
        if (![v isKindOfClass:NSClassFromString(@"SBIconView")]) continue;
        if (!v.window) continue;                        // 只刷可见的
        SPRunIndicatorApply(v);
        if ([v respondsToSelector:@selector(_updateLabel)]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(v, @selector(_updateLabel)); } @catch (NSException *e) {}
        }
    }
}

static void SPRunIndicatorScheduleRefresh(void) {
    // ⚠️ FBProcessManager 的 call-out 队列是后台线程（崩溃日志实证：
    // queue=com.apple.frontboard.process.call-out → UIView setNeedsLayout → CA abort）。
    // 所有 UI 操作必须切主队列；合并短时间内的多次进程事件。
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduled = NO;
        SPRunIndicatorRefreshVisible();
    });
}

#pragma mark - 钩子

// 系统问「这个图标要不要显示名称」——运行中的 App 不要；顺带在这里维护圆点
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

%hook SBIconView
- (void)didMoveToWindow {
    %orig;
    if (SPBool(kRunIndicatorEnabled)) SPRunIndicatorApply(self);
}
// 只做位置校正（不发进程查询），保证圆点随图标布局稳定跟随、不跳动
- (void)layoutSubviews {
    %orig;
    UIView *dot = objc_getAssociatedObject(self, kSPDotKey);
    if (dot && dot.superview == self) SPRunDotPosition(self, dot);
}
%end

// 进程事件 → 主队列延后刷新
// ⚠️ 刷新动作 dispatch 延后、方法声明 void：即使真实返回类型是 id，
// x0 里的原返回值也不会被我们的代码破坏。
%hook FBProcessManager
- (void)noteProcessDidExit:(id)process {
    SPRunIndicatorScheduleRefresh();
    %orig;
}
- (void)launchProcessWithContext:(id)context {
    SPRunIndicatorScheduleRefresh();
    %orig;
}
%end
