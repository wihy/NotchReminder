# NotchReminder

围绕 MacBook Pro 刘海渲染「类灵动岛」浮层的健康提醒工具: 久坐起身 / 定时喝水 / 护眼远眺 / 熬夜劝退。计时以**系统全局活跃时长**为主, 并用 **Claude Code 活跃信号**补强(盯着 CC 跑、手没动键鼠也算活跃), 提醒文案带上当前项目名。

设计详见 [`docs/2026-07-07-notch-reminder-design.md`](docs/2026-07-07-notch-reminder-design.md)。

## 架构

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│  CC 插件 (notchreminder)  │  写→   │   NotchReminder (菜单栏常驻)     │
│  .claude-plugin/hooks     │ ~/.notchreminder/cc.json │ ①计时引擎 ②提醒调度 ③刘海浮层 │
│  SessionStart/UserPrompt- │──────▶│                              │
│  Submit/Stop/SessionEnd   │        │  DynamicNotchKit 渲染卡片 → 刘海 │
└─────────────────────────┘        └──────────────────────────────┘
       "CC 加成信号"                    主计时 = 系统全局活跃 (idle time)
```

两部件**不直接通信**, 只通过状态文件 `~/.notchreminder/cc.json` 握手; 任一边挂掉, 另一边照常工作。

- **App**(裸 SwiftPM 可执行, 菜单栏 accessory, `setActivationPolicy(.accessory)`, 无 Dock 图标): 每 ~10s 采样系统 idle time, 跑纯函数状态机 `ReminderEngine.advance` 决定是否弹提醒。核心逻辑在 library target `ReminderCore`, 可 `swift test`。
- **CC 插件**(纯传感器): 4 个 hook 都调 `touch_activity.py`, 把 `cc_active / project / session_start / last_event` 写进 `cc.json`。

## 构建与运行

依赖: macOS 14+(本机 macOS 26.5 / Apple M5)、Swift 6+。App 依赖 [`DynamicNotchKit`](https://github.com/MrKai77/DynamicNotchKit)(MIT, SPM 自动拉取)。

```bash
# 构建 release 二进制
swift build -c release
# 直接前台跑(Ctrl-C 退出; 菜单栏出现时钟图标)
./.build/release/NotchReminder
# 只跑纯逻辑单测(不碰 AppKit)
swift test
```

一键安装(构建 + 装 CC 插件 + 开机自启):

```bash
./install.sh
```

## 四类提醒与默认阈值

阈值均可在菜单栏「设置」里改; 下表为出厂默认(与 `ReminderCore.ReminderConfig` 逐一对应)。

| 提醒 | 默认触发 | 样式 | 触发后 |
|---|---|---|---|
| 🧍 久坐起身 | 连续活跃 **50 分钟**(`sitThreshold`) | 强(带按钮, 停留久) | 忽略后静默 **15 分钟**(`sitSnooze`)再补; 真休息才清零 |
| 💧 喝水 | 累计工作 **60 分钟**(`waterThreshold`) | 轻(一闪自动收) | 弹后清零; 真休息期间暂停累加(不加不清) |
| 👀 护眼远眺 | 连续盯屏 **30 分钟**(`eyeThreshold`) | 轻(一闪自动收) | 弹后清零; 真休息清零 |
| 🌙 熬夜劝退 | 墙钟 **≥23:00**(含 00:00–01:59)且当前活跃 | 强(停留久) | 每 **30 分钟**(`nightRepeat`)仍在敲则再敲 |

判定口径(`ReminderConfig`):

- **活跃** = 系统 idle < **60s**(`activeIdleCeiling`), 或 CC 补活跃。
- **真休息** = idle ≥ **5 分钟**(`restThreshold`)且非 CC 活跃 → 久坐/护眼清零、喝水暂停。
- **CC 补活跃** = `cc_active=true` 且 `last_event` 在 **90s**(`ccGrace`)内 → 即使无键鼠输入也算活跃。
- **免打扰**: 菜单栏「专注 1 小时」把 `mutedUntil` 前移; 全屏(演示/看片/会议)时静默入队、退出全屏后自动补放; 静音窗口内计时照常推进但不弹任何提醒。

## 安装 Claude Code 插件

`install.sh` 已自动完成; 手动等价步骤:

```bash
# 把 cc-plugin/ 作为本地 marketplace 加进 Claude Code
claude plugin marketplace add ./cc-plugin
claude plugin install notchreminder@notchreminder --scope user
claude plugin enable  notchreminder@notchreminder --scope user
```

hooks 在**下一次 claude 会话启动**时加载(不热重载)。之后每发起一轮对话, `~/.notchreminder/cc.json` 会被刷新, App 即读到「正在跑 CC + 当前项目」的加成信号。

## 开机自启

`install.sh` 生成并加载 `~/Library/LaunchAgents/com.notchreminder.agent.plist`(launchd LaunchAgent, `RunAtLoad=true`, 崩溃自愈, `ProcessType=Interactive`, 仅在图形会话 `Aqua` 加载)。登录后自动拉起菜单栏 App。

查看运行状态 / 日志:

```bash
launchctl print gui/$(id -u)/com.notchreminder.agent | head -20
cat ~/.notchreminder/agent.err.log
```

## 权限说明

主计时用系统 idle time API `CGEventSource.secondsSinceLastEventType`, 只**被动读取**「距上次任意键鼠输入过了多久」, 不记录任何按键内容 —— 本机实测**无需辅助功能 / 输入监测权限, 启动无 TCC 授权弹窗**。App 不申请通知、麦克风、摄像头等敏感权限。CC 插件只在本地读写 `~/.notchreminder/cc.json`, 不联网。

## 卸载

```bash
./uninstall.sh            # 停并删 LaunchAgent、卸 CC 插件与 marketplace, 保留 ~/.notchreminder
./uninstall.sh --purge    # 上述 + 删除 ~/.notchreminder(状态与日志)
```

## 目录结构

```
NotchReminder/
├── Package.swift                       # ReminderCore(库) + NotchReminder(可执行)
├── Sources/
│   ├── ReminderCore/                    # 纯逻辑状态机(可 swift test)
│   │   ├── Models.swift
│   │   └── ReminderEngine.swift
│   └── NotchReminder/                   # 菜单栏 App(AppKit + SwiftUI + DynamicNotchKit)
├── Tests/                               # ReminderCore 引擎单测 + NotchReminder App 层单测
├── cc-plugin/                           # Claude Code 传感器插件(name=notchreminder)
│   ├── .claude-plugin/{plugin.json,marketplace.json}
│   └── hooks/{hooks.json,touch_activity.py}
├── install.sh · uninstall.sh
└── docs/                                # 设计 spec + 实施计划
```

## 许可与致谢

刘海浮层基座: [MrKai77/DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)(MIT)。
