// Common.h — systemPro 公共定义（精简版：仅 6 项功能，全部只注入 SpringBoard）
// 功能面移植自 SystemX（com.wkk.systembox）逆向成果 + duck1001/systemPro 自研框架：
//   noLockAfterRespring / disableHomeScreenLongPress / colorizeVPNStatusBar /
//   hideVPNFlyInAnimation / fakeBatteryPercent / runIndicatorEnabled
// 键名与 SystemX 对齐（便于配置迁移），domain 仍为 com.sytem.pro。
#ifndef SP_COMMON_H
#define SP_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdlib.h>

// ---------- 基本信息 ----------
#define SP_DOMAIN        @"com.sytem.pro"
#define SP_PREFS_PATH    @"/var/mobile/Library/Preferences/com.sytem.pro.plist"
#define SP_NOTIFY_RELOAD "com.sytem.pro.prefschanged"

// 打包时把这里改成 1 可开启 dpkg 状态自检（对齐 SystemX 的思路：
// 读取 /var/jb/var/lib/dpkg/status，校验自己包名+作者，防止被改包）
#ifndef SP_ENABLE_INTEGRITY_CHECK
#define SP_ENABLE_INTEGRITY_CHECK 0
#endif

// 诊断日志开关（默认 0 = 关闭）。
// 关闭时所有 SPDiagLog 调用点都被 #if 剔除：不拼字符串、不写文件 —— 生产环境零开销。
// 需要抓现场时改成 1 重新编译；日志路径 /var/mobile/Library/Logs/systemPro.log
// （SSH 读取要加真实根前缀 /rootfs）。
#ifndef SP_ENABLE_DIAG
#define SP_ENABLE_DIAG 0
#endif

// ---------- 日志 ----------
#define SPLog(fmt, ...) NSLog(@"[systemPro] " fmt, ##__VA_ARGS__)

// ---------- 越狱根路径解析（rootless / roothide 双兼容）----------
// roothide 把越狱根挂在隐藏目录 `.jbroot-*` 下，真实 /var 与面板可见路径不同；
// 插件与面板必须解析到同一份 plist，否则「开关存住了但功能不生效」。
// 解析顺序：环境变量 JBROOT（roothide 运行时提供）→ 扫描 /.jbroot-* → 老式绝对路径。
__attribute__((unused)) static NSString *SPJailbreakRoot(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        const char *env = getenv("JBROOT");
        if (env && strlen(env)) [candidates addObject:[NSString stringWithUTF8String:env]];

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *base in @[@"/", @"/var/containers/Bundle/Application"]) {
            NSArray *subs = [fm contentsOfDirectoryAtPath:base error:nil];
            for (NSString *s in subs) {
                if ([s hasPrefix:@".jbroot-"]) {
                    [candidates addObject:[base stringByAppendingPathComponent:s]];
                }
            }
        }
        for (NSString *c in candidates) {
            if ([fm fileExistsAtPath:[c stringByAppendingPathComponent:@"usr/bin"]]) {
                cached = c;
                break;
            }
        }
        NSLog(@"[systemPro] jbroot resolved: %@", cached ?: @"(none/rootless)");
    });
    return cached;
}

// 解析首选项 plist 的真实路径：优先 roothide jbroot 镜像，回退标准路径
__attribute__((unused)) static NSString *SPPreferencesPath(void) {
    NSString *rel = @"var/mobile/Library/Preferences/com.sytem.pro.plist";
    NSString *root = SPJailbreakRoot();
    if (root.length) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
        // 即使不存在也先用 jbroot 镜像路径（首次写入就落这里）
        return p;
    }
    return [@"/" stringByAppendingPathComponent:rel];
}


// ---------- 进程判定 ----------
// ⚠️ 不能用 [[NSBundle mainBundle] bundleIdentifier]：roothide/部分越狱下
// SpringBoard 的 mainBundle 为空或异常 → 所有 SPIsXxx 为 false → 全部门禁不放行（功能全组死）。
// 正确姿势：进程可执行路径 + 进程名（argv[0] / 可执行路径尾部），不依赖 bundle。
__attribute__((unused)) static NSString *SPProcessName(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *p = [[NSProcessInfo processInfo] processName];
        if (!p.length) {
            NSString *exec = [[NSProcessInfo processInfo] arguments].firstObject;
            p = exec.lastPathComponent;
        }
        cached = p ?: @"";
    });
    return cached;
}

__attribute__((unused)) static BOOL SPProcessIs(NSString *name) {
    NSString *p = SPProcessName();
    if (p.length && [p isEqualToString:name]) return YES;
    // 兜底：再用 bundleId 判一次（两条都中任一即可）
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return bid.length > 0 && [bid isEqualToString:name];
}
extern BOOL SPIsSpringBoard;

// 自检门禁（SP_ENABLE_INTEGRITY_CHECK=1 且校验失败时整体禁用）
extern BOOL SPGatePassed;

// ---------- 开关读取（惰性加载 + Darwin 热重载 见 Prefs.m） ----------
BOOL  SPBool(NSString *key);
long  SPInt(NSString *key);
double SPFloat(NSString *key);
NSString *SPString(NSString *key, NSString *def);

// ---------- 共享强调色 ----------
// VPN 上色 / APP 运行指示点共用（与 SystemX 同思路：一套色两处用）。
// 默认值取自老板设备 SystemX 配置文件实读：RGB(167,198,255) = #A7C6FF。
UIColor *SPTintColor(void);

// ---------- 轻量诊断日志 ----------
// 写到 /var/mobile/Library/Logs/systemPro.log（SpringBoard 可写）。
// 每次 SpringBoard 启动（%ctor）清空重建，只记当前这一轮的现场，避免旧日志干扰。
void SPDiagReset(void);
void SPDiagLog(NSString *line);

// ---------- 开关键名（与 SystemX 对齐；设置面板同一套） ----------
// General
#define kNoLockAfterRespring         @"noLockAfterRespring"          // 注销/重启后直接进桌面
#define kDisableHomeScreenLongPress  @"disableHomeScreenLongPress"   // 长按桌面啥都不干 + 图标不抖动
#define kColorizeVPNStatusBar        @"colorizeVPNStatusBar"         // VPN 上色（#A7C6FF，联动 WiFi/蜂窝，隐藏原 VPN 图标）
#define kHideVPNFlyInAnimation       @"hideVPNFlyInAnimation"        // VPN 图标不飞入、瞬间出现
#define kFakeBatteryPercent          @"fakeBatteryPercent"           // 伪装电量 1-100，0=关
#define kRunIndicatorEnabled         @"runIndicatorEnabled"          // APP 运行指示点（名称替换为圆点）
#define kHideIconDeleteMenu          @"hideIconDeleteMenu"           // 长按 App 菜单里去掉「删除 App」

#endif
