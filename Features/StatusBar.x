// Features_StatusBar.x — 伪装电量（对齐 SystemX fakeBatteryPercent 的四个覆盖面）
// UIDevice.batteryLevel / BCBatteryDevice.percentCharge /
// SBUIController.batteryCapacity(AsPercentage) / UIStatusBarBatteryPercentItemView
// 输入 1-100 立即伪装；0（或非法值）= 恢复真实电量。
#import "../Common.h"
#import "../PrivateHeaders.h"
#import "../Prefs.h"

static inline BOOL SPFakeBatteryValue(int *out) {
    long v = SPInt(kFakeBatteryPercent);
    if (v >= 1 && v <= 100) { if (out) *out = (int)v; return YES; }
    return NO;
}

%hook UIDevice
- (float)batteryLevel {
    int fake;
    if (SPFakeBatteryValue(&fake)) return fake / 100.0f;
    return %orig;
}
%end

%hook BCBatteryDevice
- (long)percentCharge {
    int fake;
    if (SPFakeBatteryValue(&fake)) return fake;
    return %orig;
}
%end

%hook SBUIController
- (int)batteryCapacityAsPercentage {
    int fake;
    if (SPFakeBatteryValue(&fake)) return fake;
    return %orig;
}
// ⚠️ iOS16 dump 实证：batteryCapacity 返回 float（不是 int）——返回类型写错会落错寄存器出乱值
- (float)batteryCapacity {
    int fake;
    if (SPFakeBatteryValue(&fake)) return (float)fake;
    return %orig;
}
%end

// 状态栏电量百分比文字：update 后直接把文字改成伪装值
// ⚠️ iOS16 dump 实证：actions 参数是 id（不是 int）——int 会把指针高位清零，SpringBoard 安全模式
%hook UIStatusBarBatteryPercentItemView
- (id)updateForNewData:(id)data actions:(id)actions {
    id ret = %orig;
    int fake;
    if (SPFakeBatteryValue(&fake) && [self respondsToSelector:NSSelectorFromString(@"setText:")]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"setText:"),
            [NSString stringWithFormat:@"%d%%", fake]);
    }
    return ret;
}
%end
