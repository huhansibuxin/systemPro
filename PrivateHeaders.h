// PrivateHeaders.h — 需要 hook 的私有类声明（有签名就按签名，没把握的按编译期认得出的保守签名）
// 只声明"我们要 hook 的方法"。iOS16 实证来源：springboard-dump/headers（rootless 运行时 dump）。
// 注意：状态栏类在 iOS 15/16 叫 STUIStatusBar*，17+ 叫 _UIStatusBar*，两套都挂。
#ifndef SP_PRIVATE_HEADERS_H
#define SP_PRIVATE_HEADERS_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ---------- SpringBoard：注销不锁屏 / 长按禁用 ----------
@interface SBBootDefaults : NSObject
- (BOOL)dontLockAfterCrash;
@end

// _longPressToEditGestureRecognizer 是该类的 ivar（iOS16 dump: SBIconController +0x4b0），
// 即"长按进编辑模式（jiggle）"的手势本体。
@interface SBIconController : NSObject
- (void)viewDidLoad;
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g;
@end

// ---------- APP 运行指示点 ----------
@interface SBIconView : UIView
- (void)didMoveToWindow;
- (void)_updateLabel;      // 只用于「调用」，不 hook（返回类型无法静态确认）
- (id)labelView;
@end

@interface SBHIconManager : NSObject
- (BOOL)iconViewDisplaysLabel:(id)iconView;
@end

// ⚠️ noteProcessDidExit: / launchProcessWithContext: 在 FrontBoard 的后台 call-out 队列回调，
// 回调里绝不能直接动 UI（会触发 CA_ASSERT_MAIN_THREAD_TRANSACTIONS abort）。
@interface FBProcessManager : NSObject
+ (id)sharedInstance;
- (id)processesForBundleIdentifier:(id)bundleID;
- (void)noteProcessDidExit:(id)process;
- (void)launchProcessWithContext:(id)context;
@end

// ---------- 伪装电量（对齐 SystemX 四个覆盖面） ----------
@interface BCBatteryDevice : NSObject
- (long)percentCharge;
@end

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (float)batteryCapacity;               // iOS16 dump 实证：float（勿写 int）
- (int)batteryCapacityAsPercentage;
@end

@interface UIStatusBarBatteryPercentItemView : UIView
- (id)updateForNewData:(id)data actions:(id)actions;  // iOS16 dump 实证：actions 是 id
@end

// ---------- 状态栏：VPN 上色 / 隐藏原图标 / 去飞入 ----------
// 状态栏容器（iOS16 实证）：每次数据更新的唯一入口，data 是 _UIStatusBarData，
// 其中 vpnEntry.isEnabled = 状态栏是否显示 VPN 指示器（与用户所见一致的权威判据）。
// ⚠️ 返回类型是 void（iOS 18 运行时头文件 + 崩溃日志双实证），写成 id 会被 ARC autorelease 垃圾值 → 崩。
@interface _UIStatusBar : UIView
- (void)_updateDisplayedItemsWithData:(id)data styleAttributes:(id)attributes extraAnimations:(id)animations;
@end

// VPN 指示器本体（iOS16 dump: _UIStatusBarIndicatorVPNItem : _UIStatusBarIndicatorItem）
// 隐藏图标 = 让它取不到图（imageName 返回 nil，对 id 返回类型绝对安全）。
@interface _UIStatusBarIndicatorVPNItem : NSObject
- (id)imageNameForUpdate:(id)update;
- (id)systemImageNameForUpdate:(id)update;
- (id)additionAnimationForDisplayItemWithIdentifier:(id)identifier;
@end

// WiFi 信号条（STUI 老样式：颜色通道；_UI 新样式：fillColor）
@interface STUIStatusBarWifiSignalView : UIView
- (void)setActiveColor:(id)color;
- (void)setInactiveColor:(id)color;
@end

@interface _UIStatusBarWifiItem : NSObject
- (id)_fillColorForUpdate:(id)update entry:(id)entry;
@end

// 蜂窝网络类型（5G/4G 那行文字）
@interface STUIStatusBarCellularNetworkTypeView : UIView
- (void)applyStyleAttributes:(id)attributes;
@end

@interface _UIStatusBarCellularNetworkTypeView : UIView
- (void)applyStyleAttributes:(id)attributes;
@end

// 状态栏字符串视图（VPN 胶囊就在这层）
@interface STUIStatusBarStringView : UIView
- (void)setText:(id)text;
- (void)applyStyleAttributes:(id)attributes;
@end

@interface _UIStatusBarStringView : UIView
- (void)setText:(id)text;
- (void)applyStyleAttributes:(id)attributes;
@end

#endif
