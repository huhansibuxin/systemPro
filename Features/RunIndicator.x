// Features_RunIndicator.x — APP 运行指示点
//
// 设计原则：全部事件驱动、不占 CPU。
//   • 触发点：① 系统标签更新回调 iconViewDisplaysLabel:；② 视图进窗口/换父视图；
//     ③ 进程启动退出事件（dispatch 主队列，合并防抖）。
//   • 无 layoutSubviews 钩子（那是每帧）、无定时器、无轮询。
//   • 圆点位置交给 Auto Layout 约束（一次设定）：首页锚 labelView 中心（与文字同线），
//     Dock 放图标正下方。
//   • 运行判定：FBProcessManager（进程内字典查询，无 IPC）。
//   • 性能：类查找缓存；每次 apply 只做一次进程查询；诊断由 SP_ENABLE_DIAG 控制（默认关）。
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

static const CGFloat SP_DOT_SIZE = 8.0;

static UIColor *SPRunDotColor(void) {
    return [UIColor systemGreenColor];                // 电池充电绿
}

// 类缓存（热路径）
static Class SPSBIconViewClass(void) {
    static Class c = Nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = NSClassFromString(@"SBIconView"); });
    return c;
}
static Class SPProcessManagerClass(void) {
    static Class c = Nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = NSClassFromString(@"FBProcessManager"); });
    return c;
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
    Class mgrClass = SPProcessManagerClass();
    if (!mgrClass) return NO;
    @try {
        SEL sharedSel = @selector(sharedInstance);
        if (![mgrClass respondsToSelector:sharedSel]) return NO;
        id inst = ((id (*)(id, SEL))objc_msgSend)(mgrClass, sharedSel);
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

// 把圆点装到图标视图上（位置交给 Auto Layout，一次设定）
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

        NSString *superName = iconView.superview ? NSStringFromClass([iconView.superview class]) : @"";
        BOOL isDock = [superName containsString:@"Dock"];
        UIView *labelView = SPRunLabelView(iconView);

        NSMutableArray *cs = [@[
            [dot.widthAnchor  constraintEqualToConstant:SP_DOT_SIZE],
            [dot.heightAnchor constraintEqualToConstant:SP_DOT_SIZE],
        ] mutableCopy];

        if (isDock) {
            [cs addObject:[dot.centerXAnchor constraintEqualToAnchor:iconView.centerXAnchor]];
            [cs addObject:[dot.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:2.0]];
        } else if (labelView) {
            [cs addObject:[dot.centerXAnchor constraintEqualToAnchor:labelView.centerXAnchor]];
            [cs addObject:[dot.centerYAnchor constraintEqualToAnchor:labelView.centerYAnchor]];
        } else {
            [cs addObject:[dot.centerXAnchor constraintEqualToAnchor:iconView.centerXAnchor]];
            [cs addObject:[dot.bottomAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:-1.0]];
        }
        [NSLayoutConstraint activateConstraints:cs];
    }
    [iconView bringSubviewToFront:dot];
    return dot;
}

// 核心：按运行态决定「隐藏名称 + 画点」/「恢复名称 + 收点」；返回是否处于运行态
// ⚠️ 只允许主线程调用（动 UI）；外部误用时自动切回主队列。
static BOOL SPRunIndicatorApply(SBIconView *iconView) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SPRunIndicatorApply(iconView); });
        return NO;
    }

    BOOL active = SPRunIndicatorActiveForView(iconView);   // 一次 apply 只查一次进程
    UIView *dot = objc_getAssociatedObject(iconView, kSPDotKey);

    if (active) {
        // 防重：清掉除当前 dot 外的遗留点（只在需要画点时才做，避免无谓分配）
        for (UIView *sv in [iconView.subviews copy]) {
            if ([sv isKindOfClass:[SPRunDotView class]] && sv != dot) [sv removeFromSuperview];
        }
        SPRunDotInstall(iconView);

        UIView *labelView = SPRunLabelView(iconView);
        if (labelView) {
            labelView.hidden = YES;
            objc_setAssociatedObject(iconView, kSPHidLabelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        if (dot) [dot removeFromSuperview];
        BOOL weHid = [objc_getAssociatedObject(iconView, kSPHidLabelKey) boolValue];
        if (weHid) {
            UIView *labelView = SPRunLabelView(iconView);
            if (labelView) labelView.hidden = NO;
        }
        objc_setAssociatedObject(iconView, kSPHidLabelKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!gSPIconViews) gSPIconViews = [NSHashTable weakObjectsHashTable];
    [gSPIconViews addObject:iconView];

#if SP_ENABLE_DIAG
    {
        static NSMutableSet *seen = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%p-%d", iconView, active];
        @synchronized (seen) {
            if (![seen containsObject:key]) {
                [seen addObject:key];
                SPDiagLog([NSString stringWithFormat:@"dot %@ super=%@ bounds=%@",
                           active ? @"on" : @"off",
                           iconView.superview ? NSStringFromClass([iconView.superview class]) : @"(nil)",
                           NSStringFromCGRect(iconView.bounds)]);
            }
        }
    }
#endif
    return active;
}

// 进程启动/退出 → 刷新可见图标（事件驱动，零轮询）
static void SPRunIndicatorRefreshVisible(void) {
    if (!SPBool(kRunIndicatorEnabled)) return;
    for (SBIconView *v in [gSPIconViews allObjects]) {
        Class c = SPSBIconViewClass();
        if (c && ![v isKindOfClass:c]) continue;
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

// App 启动时进程注册有延迟：补一次 0.6s 后的一次性刷新（一次性 dispatch_after，非轮询）
static void SPRunIndicatorScheduleRefreshDelayed(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SPRunIndicatorRefreshVisible();
    });
}

#pragma mark - 钩子

// 系统问「这个图标要不要显示名称」——运行中的 App 不要；顺带维护圆点
%hook SBHIconManager
- (BOOL)iconViewDisplaysLabel:(id)iconView {
    Class c = SPSBIconViewClass();
    if (c && [iconView isKindOfClass:c]) {
        SBIconView *v = (SBIconView *)iconView;
        if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) {
            if (SPRunIndicatorApply(v)) return NO;   // 复用 apply 的判定结果，不重复查进程
        }
    }
    return %orig;
}
%end

// 视图进窗口 / 换父视图时补一次（Dock、新页面、移动图标都走这两条路；代理视图被列表归属判定挡掉）
%hook SBIconView
- (void)didMoveToWindow {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) SPRunIndicatorApply(self);
}
- (void)didMoveToSuperview {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) SPRunIndicatorApply(self);
}
%end

// 系统自带的 label accessory 小圆点：功能开启时一律隐藏，只保留我们的绿点
%hook SBIconDotLabelAccessoryView
- (void)didMoveToSuperview {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) self.hidden = YES;
}
- (void)layoutSubviews {
    %orig;
    if (SPIsSpringBoard && SPBool(kRunIndicatorEnabled)) self.hidden = YES;
}
%end

// 进程事件 → 主队列延后刷新；刷新动作在 %orig 之前派发，x0 原返回值不被破坏
%hook FBProcessManager
- (void)noteProcessDidExit:(id)process {
    SPRunIndicatorScheduleRefresh();
    %orig;
}
- (void)launchProcessWithContext:(id)context {
    SPRunIndicatorScheduleRefresh();
    SPRunIndicatorScheduleRefreshDelayed();
    %orig;
}
%end
