// Features_Disable.x — 注销不锁屏 + 长按桌面禁用
// 对标 SystemX 两个键：
//   noLockAfterRespring        SBBootDefaults dontLockAfterCrash（注销/崩溃后不自动上锁）
//   disableHomeScreenLongPress 干掉 SBIconController 的 _longPressToEditGestureRecognizer
//                             （长按进编辑模式=jiggle 的手势本体），长按桌面/图标不再有任何动作；
//                             3D Touch 长按菜单是另一条手势链，不受影响（与 SystemX 同行为）。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"
#import <objc/runtime.h>

// 编辑态长按手势的标记 key（viewDidLoad 里给手势打标，delegate 钩子凭标拦截）
static const void *kSPEditGestureKey = &kSPEditGestureKey;

static BOOL SPGestureIsEditLongPress(UIGestureRecognizer *g) {
    if (!g) return NO;
    return objc_getAssociatedObject(g, kSPEditGestureKey) != nil;
}

// 从 SBIconController 取出编辑态长按手势（ivar _longPressToEditGestureRecognizer，iOS16 dump +0x4b0）
static UILongPressGestureRecognizer *SPEditLongPressGesture(SBIconController *controller) {
    UILongPressGestureRecognizer *g = nil;
    @try {
        g = [controller valueForKey:@"_longPressToEditGestureRecognizer"];
    } @catch (NSException *e) {
        return nil;   // 个别系统版本没有该 ivar，静默放弃
    }
    return [g isKindOfClass:[UILongPressGestureRecognizer class]] ? g : nil;
}

%hook SBIconController
- (void)viewDidLoad {
    %orig;
    if (!SPIsSpringBoard || !SPBool(kDisableHomeScreenLongPress)) return;
    UILongPressGestureRecognizer *g = SPEditLongPressGesture(self);
    if (!g) return;
    g.enabled = NO;                                   // 直接废掉手势
    objc_setAssociatedObject(g, kSPEditGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 兜底：万一系统后续又重新启用手势，delegate 层凭标记拦死
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (SPIsSpringBoard && SPBool(kDisableHomeScreenLongPress) && SPGestureIsEditLongPress(g)) {
        return NO;
    }
    return %orig;
}
%end

// 双保险：编辑手势的 delegate 若是 SBIconView 而非 SBIconController，这里也拦
%hook SBIconView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (SPIsSpringBoard && SPBool(kDisableHomeScreenLongPress) && SPGestureIsEditLongPress(g)) {
        return NO;
    }
    return %orig;
}
%end

// 注销/重启后不锁屏：挂钩 SBBootDefaults dontLockAfterCrash（与 SystemX 同点，干净可靠）
%hook SBBootDefaults
- (BOOL)dontLockAfterCrash {
    if (SPBool(kNoLockAfterRespring)) return YES;
    return %orig;
}
%end
