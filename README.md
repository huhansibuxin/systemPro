# systemPro

标识符 `com.sytem.pro` · 作者 **D** · 当前版本 **1.0.0-15**

systemPro 精简版：从 duck1001/systemPro（38 项功能）裁到 **6 项刚需**，全部只注入 **SpringBoard**。
功能面移植自 SystemX（com.wkk.systembox）逆向成果（机制均有 iOS16 运行时 dump 实证），
设置界面沿用自研分页面板框架，GitHub Actions（macOS）自动打包 rootless + roothide 双 deb。

---

## 功能（6 项）

| 功能 | 键 | 说明 |
|------|----|------|
| 注销不锁屏 | `noLockAfterRespring` | 注销/重启后直接进入桌面，不回锁屏（hook `SBBootDefaults dontLockAfterCrash`，与 SystemX 同点） |
| 长按桌面禁用 | `disableHomeScreenLongPress` | 长按桌面/图标不再进入编辑模式：不抖动、无任何动作；3D Touch 长按菜单保留（废掉 `SBIconController` 的 `_longPressToEditGestureRecognizer`，delegate 层双保险） |
| VPN 上色 | `colorizeVPNStatusBar` | VPN 连接时 VPN/WiFi/蜂窝一起变为 **#A7C6FF**，并**隐藏原版带方框的 VPN 图标**（`canEnableDisplayItem:fromData:` 返回 NO + view 隐藏双保险） |
| VPN 图标不飞入 | `hideVPNFlyInAnimation` | VPN 图标瞬间出现，不播滑入动画（`additionAnimationForDisplayItemWithIdentifier:` 返回 nil） |
| 伪装电量 | `fakeBatteryPercent` | 输入 1-100 立即伪装，0 恢复；只改内置电池（`BCBatteryDevice isInternal` 判定），手表/耳机不受影响 |
| APP 运行指示点 | `runIndicatorEnabled` | 运行中的 App（含后台挂起，`FBProcessManager` 实证）图标名称替换为 8pt 绿点（电池充电绿）；事件驱动刷新，零轮询 |
| 长按菜单隐藏删除 | `hideIconDeleteMenu` | 长按 App 的菜单去掉「删除 App」，其余项保留（`SBHIconManager -iconView:applicationShortcutItemsWithProposedItems:` 过滤） |

> 强调色 #A7C6FF = RGB(167,198,255)，取自老板设备 SystemX 配置文件实读
> （`vpnStatusBarColor{R,G,B,A}` = 0.6549 / 0.7765 / 1.0 / 1.0）。VPN 上色与运行指示点共用，
> 换色只改 `Tweak.x` 的 `SPTintColor()` 一处（以后换"电池充电色"同理）。

## 设置界面

进入 设置 → systemPro：单页 7 行（6 开关 + 1 数值项），改动即时生效（本插件不提供注销按钮）。

## 仓库结构

```
systemPro/
├── Makefile                 # 越狱插件主工程（rootless 默认；CI 可切 roothide）
├── control                  # 包信息（1.0.0-1）
├── systemPro.plist          # 注入过滤：仅 com.apple.springboard
├── Tweak.x                  # 主入口：进程判定 + 可选自检门禁 + SPTintColor
├── Common.h                 # 开关键名（单一来源，与 SystemX 对齐）/ jbroot 解析 / 进程判定
├── Prefs.h / Prefs.m        # 开关读取（plist 直读 + CFPreferences 回退 + 热重载）
├── PrivateHeaders.h         # 需要 hook 的私有类声明（iOS16 dump 实证签名）
├── Features/                # 功能源码
│   ├── StatusBar.x          #   伪装电量
│   ├── Disable.x            #   注销不锁屏 + 长按桌面禁用 + 长按菜单隐藏删除
│   ├── VPN.x                #   VPN 上色 + 隐藏原图标 + 不飞入
│   └── RunIndicator.x       #   APP 运行指示点
├── prefs/                   # 设置面板（自绘 UI，PSListController 系）
├── Scripts/bump-version.sh  # 一键同步版本号
└── .github/workflows/build.yml  # GitHub Actions 打包（macOS，rootless + roothide）
```

## 构建

```bash
make package FINALPACKAGE=1                                  # 默认 rootless
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide    # roothide 越狱
```

推送到 GitHub → Actions 自动构建，产物 `systemPro-rootless-deb` / `systemPro-roothide-deb`；
打 `v*` tag 自动建 Release 附双 deb。

## 版本规则

- 每次更新（无论大小）只把尾号 +1：1.0.0-1 → 1.0.0-2 → …，不跳段、不并段。
- 出包前三处同步（脚本已代劳）：`control` 的 Version、`prefs/Info.plist` 两个 string、
  `prefs/Version.h`。

## 开发注意（踩坑记录，沿用自原工程）

- **面板控制器基类**：PreferenceLoader 的 detail 控制器必须挂在 `PSViewController` / `PSListController`
  系上；面板表格走框架 specifier 模型（分节 = group specifier），只重写
  `tableView:cellForRowAtIndexPath:` 自定义样式。
- **bundle 资源文件必须放 `prefs/Resources/`**，Info.plist 放错位置会导致面板根本无法加载。
- **状态栏类 iOS 15/16 叫 `STUIStatusBar*`、17+ 叫 `_UIStatusBar*`**，两套都要挂。
- **私有类/方法没有头文件时走 `objc_msgSend`**；KVC 取 ivar（如 `_longPressToEditGestureRecognizer`）
  要包 `@try/@catch`，个别系统版本没有该 ivar 时静默放弃。
- **logos 文件完整性**：每次批量编辑后跑一遍括号配平 + `%hook`/`%end` 计数再推 CI。
- **roothide 双兼容**：prefs 路径解析（`JBROOT` 环境变量 → `.jbroot-*` 扫描）在 `Common.h`，
  插件与面板必须解析到同一份 plist。
