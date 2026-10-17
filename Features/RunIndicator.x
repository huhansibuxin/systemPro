// Features_RunIndicator.x — APP 运行指示点（移植自 SystemX runIndicatorEnabled）
// SystemX 原版语义（设置面板原文）：「当 APP 在前台运行时，APP 的名字会替换为一个指示点，
// 代表当前 APP 正在运行中。」逆向报告机制：SBIconView 标签层 + 运行中判定 + 自定义色圆点。
//
// 本实现（iOS16 实证 API，全部走 springboard-dump 核对过的选择器）：
//  1) SBHIconManager -iconViewDisplaysLabel:      运行中的 App 不显示名称；
//  2) SBIconView -_updateLabel / -didMoveToWindow 在原名称位置画 6pt #A7C6FF 圆点；
//  3) FBProcessManager -processesForBundleIdentifier:  判断 App 是否真在跑（含后台挂起）；
//  4) FBProcessManager -noteProcessDidExit: / -launchProcessWithContext: 进程事件驱动刷新
//     （事件驱动、零轮询；只刷新可见图标，进程事件稀少，CPU 代价可忽略）。
// 颜色暂用共享强调色 #A7C6FF（老板指定：以后换"电池充电色"时只改 SPTintColor 一处）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"
#import <objc/runtime.h>

static const void *kSPDotKey       = &kSPDotKey;    // 我们的圆点 view
static const void *kSPHidLabelKey  = &kSPHidLabelKey; // 是否被我们隐藏了名称（恢复时用）
static NSHashTable *gSPIconViews   = nil;           // 弱引用表：见过的图标 view

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
        id inst = ((id (*)(id, SEL))objc_msgSend)(gMgr, @selector(sharedInstance));
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
    UIView *dot = objc_getAssociatedObject(iconView, kSPDotKey);
    BOOL hidByUs = [objc_getAssociatedObject(iconView, kSPHidLabelKey) boolValue];
    BOOL active = SPRunIndicatorActiveForView(iconView);

    if (active) {
        // 记住名称 view 的位置（隐藏后 frame 仍在），圆点画在它的中心
        CGRect labelFrame = CGRectZero;
        @try {
            id lv = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(labelView));
            if ([lv isKindOfClass:[UIView class]]) labelFrame = ((UIView *)lv).frame;
        } @catch (NSException *e) {}

        if ([iconView respondsToSelector:@selector(setLabelHidden:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, @selector(setLabelHidden:), YES);
            objc_setAssociatedObject(iconView, kSPHidLabelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            hidByUs = YES;
        }
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
            // 名称 view 拿不到的兜底：图标底部居中附近
            f.origin.x = iconView.bounds.size.width  / 2.0 - 3.0;
            f.origin.y = iconView.bounds.size.height - 16.0;
        }
        dot.frame = f;
        [iconView addSubview:dot];
    } else {
        if (dot) [dot removeFromSuperview];
        // 只有被我们隐藏过的名称才恢复，避免和系统自身的隐藏策略打架
        if (hidByUs && [iconView respondsToSelector:@selector(setLabelHidden:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, @selector(setLabelHidden:), NO);
        }
        objc_setAssociatedObject(iconView, kSPHidLabelKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!gSPIconViews) gSPIconViews = [NSHashTable weakObjectsHashTable];
    [gSPIconViews addObject:iconView];
}

// 进程启动/退出 → 刷新所有可见图标（事件驱动，不轮询）
static void SPRunIndicatorRefreshVisible(void) {
    if (!SPBool(kRunIndicatorEnabled)) return;
    for (SBIconView *v in [gSPIconViews allObjects]) {
        if (![v isKindOfClass:NSClassFromString(@"SBIconView")]) continue;
        if (!v.window) continue;                        // 只刷可见的
        @try { [v _updateLabel]; } @catch (NSException *e) {}
    }
}

#pragma mark - 钩子

%hook SBIconView
- (void)_updateLabel {
    %orig;
    SPRunIndicatorApply(self);
}
- (void)didMoveToWindow {
    %orig;
    SPRunIndicatorApply(self);
}
%end

// 系统问「这个图标要不要显示名称」——运行中的 App 不要
%hook SBHIconManager
- (BOOL)iconViewDisplaysLabel:(id)iconView {
    if ([iconView isKindOfClass:NSClassFromString(@"SBIconView")]
        && SPRunIndicatorActiveForView((SBIconView *)iconView)) {
        return NO;
    }
    return %orig;
}
%end

// 进程事件 → 刷新圆点（启动补点 / 退出收点）
%hook FBProcessManager
- (void)noteProcessDidExit:(id)process {
    %orig;
    SPRunIndicatorRefreshVisible();
}
- (id)launchProcessWithContext:(id)context {
    id r = %orig;
    SPRunIndicatorRefreshVisible();
    return r;
}
%end
