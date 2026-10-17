// Features_RunIndicator.x — APP 运行指示点（移植自 SystemX runIndicatorEnabled）
// SystemX 原版语义（设置面板原文）：「当 APP 在前台运行时，APP 的名字会替换为一个指示点，
// 代表当前 APP 正在运行中。」
//
// 实现（全部选择器均经 springboard-dump 核对，返回类型按最保守方式处理）：
//  1) SBHIconManager -iconViewDisplaysLabel:  运行中的 App 不显示名称（BOOL，标准 delegate 签名）；
//  2) 名称隐藏用 labelView.hidden（UIView 公开 API），不碰 setLabelHidden:（参数类型不明，
//     传错 BOOL/id 会崩）；
//  3) 圆点：在原名称位置画 6pt #A7C6FF 圆点；
//  4) 运行判定：FBProcessManager processesForBundleIdentifier:（含后台挂起也算运行）；
//  5) 刷新：进程事件驱动（dispatch 到主队列延后刷新，不轮询）。
//     ⚠️ 不再 hook SBIconView._updateLabel —— 其返回类型无法确认（id/void），
//     void 声明会让调用方读到被清空的 x0 把垃圾当对象用 → 崩溃。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"
#import <objc/runtime.h>

static const void *kSPDotKey       = &kSPDotKey;      // 我们的圆点 view
static const void *kSPHidLabelKey  = &kSPHidLabelKey; // 是否被我们隐藏了名称（恢复时用）
static NSHashTable *gSPIconViews   = nil;             // 弱引用表：见过的图标 view

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

    UIView *labelView = nil;
    @try {
        id lv = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(labelView));
        if ([lv isKindOfClass:[UIView class]]) labelView = (UIView *)lv;
    } @catch (NSException *e) {}

    if (active) {
        CGRect labelFrame = labelView ? labelView.frame : CGRectZero;

        if (!dot) {
            dot = [UIView new];
            dot.layer.cornerRadius = 3.0;               // 6pt 圆点
            dot.backgroundColor = SPTintColor();
            dot.userInteractionEnabled = NO;
            objc_setAssociatedObject(iconView, kSPDotKey, dot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGRect f = dot.frame;
        f.size = CGSizeMake(6.0, 6.0);
        if (!CGRectIsEmpty(labelFrame)) {
            f.origin.x = CGRectGetMidX(labelFrame) - 3.0;
            f.origin.y = CGRectGetMidY(labelFrame) - 3.0;
        } else {
            f.origin.x = iconView.bounds.size.width  / 2.0 - 3.0;
            f.origin.y = iconView.bounds.size.height - 16.0;
        }
        dot.frame = f;
        [iconView addSubview:dot];
        [iconView bringSubviewToFront:dot];

        // 隐藏名称：只改公开视图的 hidden（绝对安全）
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
        SPRunIndicatorApply(v);                         // 先自己更新圆点
        // 再触发系统标签更新，让名称显隐跟随（_updateLabel 是否存在用 respondsToSelector 守卫）
        if ([v respondsToSelector:@selector(_updateLabel)]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(v, @selector(_updateLabel)); } @catch (NSException *e) {}
        }
    }
}

static void SPRunIndicatorScheduleRefresh(void) {
    // ⚠️ FBProcessManager 的 call-out 队列是后台线程（崩溃日志实证：
    // queue=com.apple.frontboard.process.call-out → UIView setNeedsLayout → CA abort）。
    // 所有 UI 操作必须切主队列；gSPRefreshScheduled 合并短时间内的多次进程事件。
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
// （每次标签更新都会走，天然覆盖「App 启动/退出后图标状态变化」）
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
