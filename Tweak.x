// Tweak.x — systemPro 主入口（精简版：6 项功能，全部只注入 SpringBoard）
// 流程（对标 SystemX 核心）：
//   1) 进程判定（SpringBoard；可执行名 + bundleId 双通道，不依赖 mainBundle）
//   2) （可选）dpkg-status 自检门禁 —— 读 /var/jb/var/lib/dpkg/status，
//      校验"自己的包名 + install ok installed + 作者"三项，任何一项不符就整体摆烂。
//      默认关，打包时开。
//   3) 加载开关（SPPrefs 惰性 + Darwin 热重载）
#import "Common.h"
#import "PrivateHeaders.h"
#import "Prefs.h"

BOOL SPIsSpringBoard = NO;
BOOL SPGatePassed    = YES;

// 共享强调色 #A7C6FF = RGB(167,198,255)
// 取自老板设备 SystemX 配置文件实读（vpnStatusBarColor{R,G,B,A} = 0.6549/0.7765/1.0/1.0）。
// VPN 上色与 APP 运行指示点共用；以后要换"电池充电色"只改这里一处。
UIColor *SPTintColor(void) {
    return [UIColor colorWithRed:167.0/255.0 green:198.0/255.0 blue:255.0/255.0 alpha:1.0];
}

// ---------- 轻量诊断日志 ----------
// 每次 SpringBoard 启动清空重建（只保留当前这轮现场）；追加写，调用点都很稀疏。
static NSString *SPDiagPath(void) {
    return @"/var/mobile/Library/Logs/systemPro.log";
}

void SPDiagReset(void) {
    NSString *head = [NSString stringWithFormat:@"=== systemPro boot %@ ===\n", [NSDate date]];
    [[head dataUsingEncoding:NSUTF8StringEncoding] writeToFile:SPDiagPath() atomically:YES];
}

void SPDiagLog(NSString *line) {
    if (!line.length) return;
    @synchronized ([SPDiagLog class]) {
        NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:SPDiagPath()];
        if (!fh) {
            [[entry dataUsingEncoding:NSUTF8StringEncoding] writeToFile:SPDiagPath() atomically:YES];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

// ---------- dpkg-status 自检（可选门禁） ----------
#if SP_ENABLE_INTEGRITY_CHECK
#define SP_PKG_ID     @"com.sytem.pro"
#define SP_PKG_AUTHOR @"operator"

static BOOL SPIntegrityCheckPasses(void) {
    NSArray *candidates = @[
        @"/var/jb/var/lib/dpkg/status",          // rootless
        @"/var/lib/dpkg/status",                  // 老式
        @"/var/mobile/Library/pkgmirror/DEBIAN.com.sytem.pro/control" // 只含 control 的兜底
    ];
    NSString *raw = nil;
    for (NSString *p in candidates) {
        raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (raw.length) break;
    }
    if (!raw.length) { SPLog(@"integrity: no status file"); return NO; }

    // dpkg control 是 RFC822 段落格式：空行分段，段内 "Key: Value"
    BOOL found = NO;
    for (NSString *para in [raw componentsSeparatedByString:@"\n\n"]) {
        NSMutableDictionary *kv = [NSMutableDictionary dictionary];
        for (NSString *line in [para componentsSeparatedByString:@"\n"]) {
            NSRange r = [line rangeOfString:@":"];
            if (r.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:r.location];
            NSString *v = [[line substringFromIndex:r.location + 1]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            kv[k] = v;
        }
        if (![kv[@"Package"] isEqualToString:SP_PKG_ID]) continue;
        BOOL okStatus = [kv[@"Status"] isEqualToString:@"install ok installed"];
        BOOL okAuthor = [kv[@"Author"] containsString:SP_PKG_AUTHOR] ||
                        [kv[@"Maintainer"] containsString:SP_PKG_AUTHOR];
        if (okStatus && okAuthor) { found = YES; break; }
    }
    if (!found) SPLog(@"integrity: package check failed");
    return found;
}
#endif

// ---------- 构造函数 ----------
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *pn = SPProcessName();
        // 进程判定双通道：可执行名（roothide/越狱环境可靠）或 bundleId
        SPIsSpringBoard = SPProcessIs(@"SpringBoard");
        SPLog(@"ctor: exec=%@ bid=%@ (sb=%d)", pn, bid, SPIsSpringBoard);

#if SP_ENABLE_INTEGRITY_CHECK
        SPGatePassed = SPIntegrityCheckPasses();
        if (!SPGatePassed) { SPLog(@"gate failed, tweak inert"); return; }
#endif
        (void)[SPPrefs shared];        // 懒加载 + 挂 Darwin 通知

        SPDiagReset();                 // 清空上一版日志，只保留本 BOOT 现场
        SPDiagLog([NSString stringWithFormat:@"ctor sb=%d tint=%@ jbroot=%@",
                   SPIsSpringBoard, SPTintColor(), SPJailbreakRoot() ?: @"(none)"]);

        // 诊断：把解析结果和当前开关状态打到日志（syslog / Console 可查）
        SPLog(@"jbroot=%@ prefsPath=%@", SPJailbreakRoot() ?: @"(none)", SPPreferencesPath());
        SPLog(@"keys: noLock=%d longPressOff=%d vpnTint=%d vpnNoFly=%d fakeBat=%ld runDot=%d",
              SPBool(kNoLockAfterRespring), SPBool(kDisableHomeScreenLongPress),
              SPBool(kColorizeVPNStatusBar), SPBool(kHideVPNFlyInAnimation),
              SPInt(kFakeBatteryPercent), SPBool(kRunIndicatorEnabled));
    }
}
