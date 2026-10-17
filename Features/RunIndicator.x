// Features_RunIndicator.x — APP 运行指示点（移植自 SystemX runIndicatorEnabled）
// SystemX 原版语义（设置面板原文）：「当 APP 在前台运行时，APP 的名字会替换为一个指示点，
// 代表当前 APP 正在运行中。」
//
// 实现要点（选择器均经 springboard-dump 核对；返回类型一律按最保守方式处理）：
//  1) SBHIconManager -iconViewDisplaysLabel:  运行中的 App 不显示名称（BOOL，标准 delegate 签名）；
//  2) 名称隐藏用 labelView.hidden（UIView 公开 API），不碰 setLabelHidden:（参数类型不明）；
//  3) 圆点 10pt，颜色 = 电池充电绿（systemGreen #34C759，老板指定）；
//  4) 只画在**真正位于图标列表里的图标视图**上（superview 链含 IconList/Dock）。
//     ⚠️ 之前「App 缩回桌面 / 注销后出现两个大小不同的点」：过渡用的代理图标视图
//     （跟随 App 快照缩放）也被我们加了点。现在用列表归属 + 专用 dot 类做双重防重。
//  5) 位置：bounds 有效才摆 + layoutSubviews 只做位置校正（不跳动）；
//  6) 运行判定：FBProcessManager processesForBundleIdentifier:（含后台挂起）；
//  7) 刷新：进程事件 dispatch 主队列（FB call-out 是后台线程，直接动 UI 会 CA abort）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"
#import <objc/runtime.h>

// 专用圆点类：便于精确识别/清理我们自己的点，不会和系统视图混淆
@interface SPRunDotView : UIView
@end
@implementation SPRunDotView
@end

static const void *kSPDotKey       = &kSPDotKey;
static const void *kSPHidLabelKey  = &kSPHidLabelKey;
static NSHashTable *gSPIconViews   = nil;

static const CGFloat SP_DOT_SIZE = 10.0;              // 直径 10pt（6→8→10，老板要求再大一点）

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

// 是否真的挂在图标列表里（排除 App 缩放/过渡用的代理图标视图）
static BOOL SPRunIconViewInList(SBIconView *iconView) {
    UIView *v = iconView.superview;
    for (int i = 0; v && i < 4; i++, v = v.superview) {
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"IconList"] || [cn containsString:@"Dock"]) return YES;
    }
    return NO;
}

// 摆圆点：图标还没布局（bounds 无效）就跳过，等 layoutSubviews 再摆
static void SPRunDotPosition(SBIconView *iconView, UIView *dot) {
    CGRect b = iconView.bounds;
    if (b.size.width < 10.0 || b.size.height < 10.0) return;

    CGFloat cx = b.size.width / 2.0;
    CGFloat cy = b.size.height - 14.0;      // 名称行高度
    UIView *lv = SPRunLabelView(iconView);
    if (lv && !CGRectIsEmpty(lv.frame)) {
        cx = CGRectGetMidX(lv.frame);
        cy = CGRectGetMidY(lv.frame);
    }
    dot.frame = CGRectMake(round(cx - SP_DOT_SIZE / 2.0), round(cy - SP_DOT_SIZE / 2.0),
                           SP_DOT_SIZE, SP_DOT_SIZE);
}

// 取图标的 bundleID（仅普通 App 图标；文件夹/小组件返回 nil）
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
    if (!SPRunIconViewInList(iconView)) return NO;              // 代理/过渡图标视图不加点
    return SPRunIndicatorAppIsRunning(SPRunIndicatorBundleID(iconView));
}

static void SPRunIndicatorApply(SBIconView *iconView) {
    BOOL active = SPRunIndicatorActiveForView(iconView);
    UIView *dot = objc_getAssociatedObject(iconView, kSPDotKey);
    BOOL weHid = [objc_getAssociatedObject(iconView, kSPHidLabelKey) boolValue];
    UIView *labelView = SPRunLabelView(iconView);

    // 防重：清掉除当前 dot 之外所有遗留的 SPRunDotView（图标视图复用/多路回调都不怕）
    for (UIView *sv in [iconView.subviews copy]) {
        if ([sv isKindOfClass:[SPRunDotView class]] && sv != dot) [sv removeFromSuperview];
    }

    if (active) {
        if (!dot) {
            dot = [SPRunDotView new];
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
        if (labelView && weHid) labelView.hidden = NO;
        objc_setAssociatedObject(iconView, kSPHidLabelKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!gSPIconViews) gSPIconViews = [NSHashTable weakObjectsHashTable];
    [gSPIconViews addObject:iconView];
}

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

#pragma mark - 钩子

// 系统问「这个图标要不要显示名称」——运行中的 App 不要；顺带在这里维护圆点。
// 只挂这一条 + 进程事件刷新（不再挂 didMoveToWindow：过渡代理视图也会被加点到）。
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
// 只做位置校正（不发进程查询）
- (void)layoutSubviews {
    %orig;
    UIView *dot = objc_getAssociatedObject(self, kSPDotKey);
    if (dot && dot.superview == self) SPRunDotPosition(self, dot);
}
%end

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
