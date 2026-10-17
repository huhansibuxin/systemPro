// Features_Disable.x — 注销不锁屏 + 长按桌面禁用
// 对标 SystemX 两个键：
//   noLockAfterRespring        SBBootDefaults dontLockAfterCrash（注销/崩溃后不自动上锁）
//   disableHomeScreenLongPress 禁止进入编辑模式（jiggle + 删除按钮）
//
// ⚠️ 第一版走手势级（SBIconController._longPressToEditGestureRecognizer + delegate 拦截）实测无效：
// 系统仍能进编辑态。改为**编辑态入口级**拦截 —— 谁把 editing 打开就强制改回 NO，
// 覆盖长按空白/长按图标/上下文菜单等所有入口。3D Touch 菜单不受影响。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"

static BOOL SPEditBlockActive(void) {
    return SPIsSpringBoard && SPBool(kDisableHomeScreenLongPress);
}

// ⚠️ editing 参数按 BOOL 声明并传 NO：真实签名无论是 BOOL 还是 NSNumber*，
// NO(0)/nil 都是「假」，两种解释下都安全（反过来：给 BOOL 参数传 @NO 会变成真）。
%hook SBHIconManager
- (void)setEditing:(BOOL)editing forIconLocation:(id)location {
    if (SPEditBlockActive()) {
        %orig(NO, location);   // 桌面入口：永远不进编辑态
        return;
    }
    %orig;
}
%end

%hook SBFolderView
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    if (SPEditBlockActive()) {
        %orig(NO, animated);
        return;
    }
    %orig;
}
%end

%hook SBFloatingDockView
- (void)setEditing:(BOOL)editing {
    if (SPEditBlockActive()) {
        %orig(NO);
        return;
    }
    %orig;
}
%end

// 注销/重启后不锁屏：挂钩 SBBootDefaults dontLockAfterCrash（与 SystemX 同点，干净可靠）
%hook SBBootDefaults
- (BOOL)dontLockAfterCrash {
    if (SPBool(kNoLockAfterRespring)) return YES;
    return %orig;
}
%end

#pragma mark - 长按菜单：去掉「删除 App」
// 长按图标弹出的菜单项由 SBHIconManager 组装（applicationShortcutItemsWithProposedItems:），
// 返回的是菜单条目数组。这里按条目的 type/title 过滤掉删除/移除类动作，
// 「编辑主屏幕」等其余项原样保留。
static BOOL SPShortcutIsDeleteAction(id item) {
    if (!item) return NO;
    NSMutableString *sig = [NSMutableString string];
    for (NSString *k in @[@"type", @"title", @"localizedTitle", @"identifier", @"displayName"]) {
        @try {
            id v = [item valueForKey:k];
            if ([v isKindOfClass:[NSString class]]) [sig appendFormat:@" %@", v];
        } @catch (NSException *e) {}
    }
    NSString *s = sig.lowercaseString;
    return [s containsString:@"delete"] || [s containsString:@"remove"] ||
           [s containsString:@"删除"] || [s containsString:@"移除"];
}

%hook SBHIconManager
- (id)iconView:(id)iconView applicationShortcutItemsWithProposedItems:(id)items {
    id ret = %orig;
    if (!SPIsSpringBoard || !SPBool(kHideIconDeleteMenu)) return ret;
    if (![ret isKindOfClass:[NSArray class]]) return ret;

    NSMutableArray *kept = [NSMutableArray array];
    for (id item in (NSArray *)ret) {
        if (!SPShortcutIsDeleteAction(item)) [kept addObject:item];
    }
    return kept;
}
%end
