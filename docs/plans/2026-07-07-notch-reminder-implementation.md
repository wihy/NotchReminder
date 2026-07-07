# NotchReminder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个围绕 MacBook Pro 刘海渲染「类灵动岛」浮层的健康提醒工具(久坐/喝水/护眼/熬夜),以系统全局活跃时长为主计时、Claude Code 活跃信号补强。

**Architecture:** 两个部件——菜单栏 accessory App(`NotchReminder`,负责 idle 采样 / 提醒调度 / 刘海浮层)与 CC 插件(纯传感器,写活跃信号)——**不直接通信**,只通过状态文件 `~/.notchreminder/cc.json` 握手,任一边挂掉另一边照常工作。触发判断收敛在纯函数状态机 `ReminderEngine.advance`(library target `ReminderCore`,无副作用、不 import AppKit、可 `swift test`),App 层只做采样接线与展示。

**Tech Stack:** Swift / Swift Package Manager(单一 root `Package.swift`,library `ReminderCore` + executableTarget `NotchReminder`)/ DynamicNotchKit 1.1.0(MIT,刘海浮层基座)/ AppKit + SwiftUI(菜单栏 + 设置窗 + 强样式视图)/ launchd LaunchAgent(开机自启)/ Python 3 标准库(CC 插件 hook 脚本)。

---

## Global Constraints

逐条 verbatim(下游所有 Task 遵循):

- 部署目标 macOS 13+; 本机 macOS 26.5 / Apple M5。
- Swift Package Manager 工程(非 Xcode 工程)。纯逻辑放 library target ReminderCore(可 `swift test`); App 为 executableTarget NotchReminder。
- 菜单栏 App: NSApplication.shared.setActivationPolicy(.accessory)(免 Info.plist / LSUIElement)。
- 依赖 DynamicNotchKit(MIT); SPM: .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0")。
- 开机自启: 生成 ~/Library/LaunchAgents/com.notchreminder.agent.plist(launchd), 非 SMAppService。
- 状态文件契约 ~/.notchreminder/cc.json, 字段 cc_active/project/session_start/last_event(见 spec §5.2)。
- 默认阈值: 久坐 sit=50min, 喝水 water=60min, 护眼 eye=30min, 熬夜 night≥23:00(含凌晨至 02:00); 真休息 rest=idle≥5min; 活跃 active=idle<60s; CC 补活跃 grace=90s; 久坐 snooze=15min; 熬夜重复间隔 30min。
- ReminderEngine.advance 是纯函数(无副作用), 必须先测后写。

---

## Shared CONTRACT (freeze before implementation)

以下签名是跨 Task 的权威契约。**上游 Task 定义、下游 Task 逐字对齐,不得各写各的。** 这一段专门解决 review 发现的跨 Task 接口漂移(AppController / NotchPresenter 三处冲突、插件名不一致、testTarget 声明不一)。

### C1. ReminderCore(Task 2 定义,Task 3/4/5/6/7 消费)

```swift
public struct Sample: Equatable {
    public var now: Date
    public var idleSeconds: Double
    public var ccActive: Bool
    public var ccLastEvent: Date?
    public var project: String?
    public init(now: Date, idleSeconds: Double, ccActive: Bool = false,
                ccLastEvent: Date? = nil, project: String? = nil)
}
public struct ReminderConfig: Equatable { /* 见 Task 2 Models.swift 全字段 + 默认值 */ }
public struct ReminderState: Equatable {
    public var sitAccum: TimeInterval; public var waterAccum: TimeInterval; public var eyeAccum: TimeInterval
    public var lastSample: Date?; public var lastSitAlert: Date?; public var lastNightAlert: Date?
}
public enum Reminder: Equatable {
    case sit(minutes: Int, project: String?); case water; case eye; case night(clock: String)
}
public enum ReminderEngine {
    public static func advance(_ state: ReminderState, config: ReminderConfig, sample: Sample) -> (ReminderState, [Reminder])
    public static func isNight(_ now: Date, calendar: Calendar) -> Bool
    public static func clockString(_ now: Date, calendar: Calendar) -> String
}
```

### C2. NotchPresenter(唯一对外渲染入口)

- **唯一对外方法是 `present(_:onAction:)`。不存在 `show(_:)`。** 早先 review 发现 Task 3 的 `show(_:)` 与 Task 5 的 `present(_:onAction:)` 冲突——本计划已统一为 `present`,删除 `show(_:)` 版本。
- **可访问性从 Task 1 起就是 `public final class` + `public init()`**(供跨 target 临时验证 `import NotchReminder` 用),Task 1 的 `showTest()` 只是临时演示方法,Task 5 用 `present(_:onAction:)` 取代它并保留 public。

```swift
public enum SitAction: Equatable { case snooze; case dismiss }

@MainActor
public final class NotchPresenter {
    public init()
    /// 唯一对外渲染入口。
    /// - 强样式(sit/night)带按钮, onAction 回调携带 SitAction(snooze=起身5分钟, dismiss=知道了)。
    /// - 轻样式(water/eye)无按钮, expand 后停留 autoHideSeconds 秒自动 hide, onAction 不触发。
    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?)
}
```

### C3. AppController(单一权威类型,Task 3 是唯一 owner)

**Task 3 用 `Create` 建立完整表面;Task 5 / Task 6 / Task 7 一律 `Modify`(增量),不得重复 Create/覆盖。** AppController 同时具备三个面:

- (a) **采样面**(Task 3):`start(interval:)` / `tick() -> [Reminder]` / 可注入 `idleProvider`·`clock`;内部持有 `state`/`config` + 每 10s 采样循环。
- (b) **路由面**(Task 5 Modify 追加):`route(_:)` / `flushPending()` / `onSitSnooze` / `pending` + 注入 `FullscreenProbe`。tick() 内部把 `[Reminder]` 交给 `route(_:)`(不再直接 present);每次 tick 开头先 `flushPending()`(免打扰结束后自动补放,见 §5.4 auto-resume)。
- (c) **命令+只读面**(Task 7 Modify 追加/对齐):`static let shared` / `var config { get }` / `var state { get }` / `applyConfig(_:)` / `manualRest()` / `muteFor(_:)`。

```swift
public typealias FullscreenProbe = () -> Bool

@MainActor
public final class AppController {
    public static let shared: AppController                 // Task 7 接线用;由 App 启动时赋值/或懒构造
    // (a) 采样面
    public init(presenter: NotchPresenter,
                config: ReminderConfig = ReminderConfig(),
                idleProvider: @escaping () -> Double = ActivityMonitor.currentIdleSeconds,
                clock: @escaping () -> Date = { Date() },
                dnd: @escaping FullscreenProbe = DoNotDisturb.isFullscreenActive)
    public func start(interval: TimeInterval = 10)          // 立即 tick + 每 interval 秒重复
    @discardableResult public func tick() -> [Reminder]     // flushPending → 采样 → advance → route → 返回本次 [Reminder]
    // (b) 路由面
    public func route(_ reminders: [Reminder])              // 全屏 → 记 pending; 否则 present
    public func flushPending()                              // 免打扰结束后补放 pending
    public var onSitSnooze: (() -> Void)?                   // 强样式 snooze 回调
    public private(set) var pending: [Reminder]             // 全屏期间挂起的提醒
    // (c) 命令+只读面
    public var config: ReminderConfig { get }
    public var state: ReminderState { get }
    public func applyConfig(_ config: ReminderConfig)       // 替换配置, 下一拍生效
    public func manualRest()                                // 置 sitAccum=0、lastSitAlert=nil
    public func muteFor(_ seconds: TimeInterval)            // config.mutedUntil = now+seconds 并 applyConfig
}
```

**manualRest / onSitSnooze 统一语义(解决 review minor):** 二者都执行 `state.sitAccum = 0; state.lastSitAlert = nil`。菜单「我起身了」直接调 `manualRest()`;强样式浮层「起身5分钟」snooze 回调经 `onSitSnooze` 也调同一实现——不走两套清零逻辑,避免 snooze 窗口行为分叉(清 `lastSitAlert` 让下次攒够 50min 能立即再报,而非受 15min snooze 压制)。App 启动时须 `self.onSitSnooze = { [weak self] in self?.manualRest() }`。

### C4. 唯一 testTarget 声明(四个 Task 若缺则追加同一份)

```swift
.testTarget(
    name: "NotchReminderTests",
    dependencies: ["NotchReminder", "ReminderCore"],
    path: "Tests/NotchReminderTests"
),
```

含 `ReminderCore` 显式依赖(Task 7 的 `SettingsStoreTests` `import ReminderCore` 需要)+ 显式 `path`。**先落地的 Task 建立这一份;后续 Task 一律「检查存在即跳过」,不重复声明、不用别的形状。**

### C5. CC 插件名 = `notchreminder`(无连字符,全链路一致)

`plugin.json` 的 `name`、`marketplace.json` 的 marketplace `name` 与 `plugins[].name`、`install.sh`/`uninstall.sh` 的 `claude plugin install notchreminder@notchreminder`、README——**全部用 `notchreminder`**。`install <plugin>@<marketplace>` 要求 plugin 自身 name 与 marketplace plugin name 一致,若写成 `notch-reminder` 会导致 install 找不到插件而失败。(spec §4 架构图里的 `notch-reminder` 以本契约为准更正为 `notchreminder`。)

### C6. DynamicNotchKit 1.1.0 @MainActor 归属(据 1.1.0 源码核实)

- `DynamicNotchInfo` / `DynamicNotch` 的 **class 声明与 `init` 均非 @MainActor**,可在任意上下文同步构造。
- 仅 `expand(on:)` / `compact()` / `hide()` 因定义在 `@MainActor public protocol DynamicNotchControllable` 上而被 MainActor 隔离,且均 `async`。
- 因此承载 `await expand/hide` 的方法需在 MainActor 上下文(本计划把 `NotchPresenter` 整类标 `@MainActor`,安全)。
- 顶层 `main.swift` 里 `call to main actor-isolated initializer` 的报错来自**顶层 `@MainActor AppDelegate()` 的构造**(需 `MainActor.assumeIsolated`,本机已实测坐实),**与 `DynamicNotchInfo.init` 无关**。

---

## File Structure

汇总所有 Task 的 filesTouched(单一 root 布局,spec §6 的 `app/` 子目录示意以此为准更正):

```
NotchReminder/                                  # ~/NotchReminder (repo root)
├── Package.swift                               # SPM 清单: ReminderCore(库) + NotchReminder(可执行) + NotchReminderTests(测试)
├── .gitignore                                  # 忽略 .build/ 与 .notchreminder/(已存在)
├── install.sh                                  # [T8] 幂等安装: build release → 装 CC 插件 → 写+bootstrap LaunchAgent
├── uninstall.sh                                # [T8] 幂等卸载: bootout+删 plist → 卸插件 → 移 marketplace
├── README.md                                   # [T8] 交付文档: 架构/构建/装插件/自启/阈值表/权限/卸载
├── Sources/
│   ├── ReminderCore/                           # 纯逻辑, 可 swift test, 不 import AppKit
│   │   ├── Version.swift                        # [T1] reminderCoreVersion 占位源
│   │   ├── Models.swift                         # [T2] Sample/ReminderConfig/ReminderState/Reminder public 定义
│   │   └── ReminderEngine.swift                # [T2,T4] advance 纯函数 + isNight/clockString
│   └── NotchReminder/                          # 菜单栏 App (AppKit + SwiftUI + DynamicNotchKit)
│       ├── main.swift                          # [T1,T3,T7] accessory 入口: NSApplication + AppDelegate + AppController 启动
│       ├── NotchPresenter.swift                # [T1,T5] 唯一渲染入口 present(_:onAction:) + 强/轻样式 + auto-hide
│       ├── StrongReminderView.swift            # [T5] 强样式 SwiftUI 视图(标题+起身5分钟/知道了按钮)
│       ├── DoNotDisturb.swift                  # [T5] muteFor/isMuted + isFullscreenActive(CGWindowList 近似)
│       ├── ActivityMonitor.swift               # [T3] 系统 idle 只读采样(CGEventSource, 零权限)
│       ├── AppController.swift                 # [T3 owner; T5/T6/T7 Modify] 采样循环 + route/pending + shared/config/state/命令面
│       ├── CCSignalReader.swift                # [T6] 读并解析 ~/.notchreminder/cc.json(容错 nil)
│       ├── SettingsStore.swift                 # [T7] UserDefaults 持久化 config 阈值+开关+标量偏好
│       ├── SettingsWindow.swift                # [T7] SwiftUI 设置窗 + NSWindow 宿主 controller(改动即存)
│       ├── MenuBar.swift                       # [T7] 完整菜单栏 MenuBarController(状态行+动作+开关+设置)
│       ├── LaunchAgent.swift                   # [T7] plist 生成 + bootstrap/bootout 开机自启
│       └── FirstRun.swift                      # [T7] 首启一屏引导 + CC 插件一键命令
├── Tests/
│   ├── ReminderCoreTests/
│   │   ├── ReminderCoreTests.swift             # [T1] 版本占位测试(防空 testTarget)
│   │   └── ReminderEngineTests.swift           # [T2,T4] 引擎 12 用例(sit/water/eye/night/rest/CC/muted/顺序)
│   └── NotchReminderTests/
│       ├── AppControllerTests.swift            # [T3] 采样注入测试(连续活跃产 .sit / rest 清零)
│       ├── DoNotDisturbTests.swift             # [T5] muteFor/isMuted 时间口径
│       ├── AppControllerReplayTests.swift      # [T5] pending 全屏挂起 / flushPending 重放
│       ├── CCSignalReaderTests.swift           # [T6] cc.json 解析(有效/inactive/缺失/损坏/缺字段)
│       └── SettingsStoreTests.swift            # [T7] config↔UserDefaults round-trip
├── cc-plugin/                                  # Claude Code 传感器插件(name=notchreminder)
│   ├── .claude-plugin/
│   │   ├── plugin.json                         # [T6] 插件清单(name=notchreminder)
│   │   └── marketplace.json                    # [T8] 本地单插件 marketplace(name=notchreminder)
│   └── hooks/
│       ├── hooks.json                          # [T6] 4 hook 声明(wrapper 格式)
│       ├── touch_activity.py                   # [T6] 唯一逻辑: 写 cc.json(原子写)
│       └── test_touch_activity.py              # [T6] Python unittest(标准库)
└── docs/
    ├── 2026-07-07-notch-reminder-design.md     # 设计 spec
    └── plans/
        └── 2026-07-07-notch-reminder-implementation.md   # 本文件
```

> **收尾清理(review minor):** 磁盘上遗留一个空的 `app/` 目录(spec §6 早先草图),root 布局已取代它。Task 1 Step 1.1 或 Task 8 收尾时执行 `rmdir /Users/chunhaixu/NotchReminder/app`(空目录,安全)。

---

## Task 1: SPM 骨架 + 菜单栏空壳 + 刘海测试卡

> 目标: 建立可 `swift build` / `swift run` / `swift test` 的最小工程。产出一个菜单栏
> accessory App(无 Dock 图标), 菜单里有「测试提醒 / 退出」, 点「测试提醒」用 DynamicNotchKit
> 在刘海弹一张信息卡片(3 秒自动收起)。纯逻辑 library `ReminderCore` 本 Task 仅放一个 Version.swift
> 占位源文件(让 target 有源可编译), Models / ReminderEngine 由 Task 2 补齐。
>
> **本 Task 是接线 / UI Task, 不是纯逻辑 TDD**: `ReminderEngine.advance` 尚不存在(Task 2 才写),
> 故本 Task 用「写代码 → `swift build` → 手动验证 → commit」推进; testTarget 只放一个校验
> `reminderCoreVersion` 的占位测试, 保证 `swift test` 能编译通过(空 testTarget 在 SPM 会构建失败)。
>
> **工程布局采用仓库根**(与 Task 2 / Task 4 一致): `Package.swift` 在 `/Users/chunhaixu/NotchReminder/`
> 根目录, 全程用 `swift build`(cwd = 仓库根) 或 `--package-path /Users/chunhaixu/NotchReminder`。
> release 产物落在 `/Users/chunhaixu/NotchReminder/.build/release/NotchReminder`。
> (设计文档 §6 的 `app/` 子目录示意与本 Task 的实际根布局不同, 以本 Task 为准; Task 2/4 的
> `--package-path /Users/chunhaixu/NotchReminder` 已锁定根布局。磁盘上遗留的空 `app/` 目录在 Step 1.1 清掉。)
>
> **NotchPresenter 从本 Task 起即 `public final class` + `public init()`**(见 CONTRACT §C2)。Task 1 只用它的
> `showTest()` 临时演示;Task 5 会用 `present(_:onAction:)` 取代 `showTest()` 并保留 public 可访问性。让 Task 3/5/6/7
> 全程引用同一可访问性,不出现中间态 internal→public 的漂移。

#### Files

- **Create** `/Users/chunhaixu/NotchReminder/Package.swift` — swift-tools-version:5.9, platforms `.macOS(.v13)`, 依赖 DynamicNotchKit from 1.1.0, 三 target: library `ReminderCore` / executable `NotchReminder`(依赖 `ReminderCore` + `.product(name:"DynamicNotchKit")`) / testTarget `ReminderCoreTests`(依赖 `ReminderCore`)。
- **Create** `/Users/chunhaixu/NotchReminder/Sources/ReminderCore/Version.swift` — `public let reminderCoreVersion = "0.1.0"`(占位源文件, Task 2 加 Models/Engine)。
- **Create** `/Users/chunhaixu/NotchReminder/Sources/NotchReminder/NotchPresenter.swift` — `public final class NotchPresenter { public init(); @MainActor func showTest() }`, 用 `DynamicNotchInfo(icon:title:description:)` + `await info.expand()` / `hide()`。
- **Create** `/Users/chunhaixu/NotchReminder/Sources/NotchReminder/main.swift` — `NSApplication.shared` + `.accessory` + `AppDelegate` 挂 `NSStatusItem`(菜单: 测试提醒 / 分隔 / 退出) + `app.run()`。
- **Create** `/Users/chunhaixu/NotchReminder/Tests/ReminderCoreTests/ReminderCoreTests.swift` — 占位测试, 校验 `reminderCoreVersion == "0.1.0"`, 让 testTarget 非空可编译。Task 2 会新增 `ReminderEngineTests.swift` 与之并存。

#### Interfaces

**Produces**(本 Task 定义, 下游可依赖):
```swift
// ReminderCore(library)
public let reminderCoreVersion: String   // = "0.1.0"

// NotchReminder(executable) — public 供跨 target 引用一致(见 CONTRACT §C2)
public final class NotchPresenter {
    public init()
    @MainActor func showTest()            // 弹一张 DynamicNotchInfo 卡片, 3s 后自动收起(临时演示; Task 5 用 present 取代)
}
```

**Consumes**(第三方, 已在本机实测坐实 API 形态; @MainActor 归属见 CONTRACT §C6):
```swift
import DynamicNotchKit   // 1.1.0, swift-tools 6.0, macOS 13+
// DynamicNotchInfo 的 init 非 @MainActor(可任意上下文构造); 仅 expand/compact/hide 经
// DynamicNotchControllable 协议为 @MainActor async。承载 await expand/hide 的方法需在 MainActor 上下文。
DynamicNotchInfo(
    icon: DynamicNotchInfo.Label?,        // 传 .init(systemName:color:), 不是 Image/String
    title: LocalizedStringKey,            // 字面量可直接传
    description: LocalizedStringKey? = nil // 字面量可直接传
)
func expand(on: NSScreen = NSScreen.screens[0]) async   // @MainActor, async
func hide() async                                        // @MainActor, async
```

> ⚠️ 本 Task 不消费 `ReminderEngine` / `Sample` / `ReminderConfig` / `ReminderState` / `Reminder`
> (那些在 Task 2 定义)。App 侧真正接入引擎的采样循环在 Task 3。

#### Steps

- [ ] **Step 1.1 — 清理遗留空目录 + 写 `Package.swift`(根目录, 三 target)。** 先删磁盘上遗留的空 `app/` 目录(root 布局已取代它):

  ```bash
  rmdir /Users/chunhaixu/NotchReminder/app 2>/dev/null || true
  ```

  新建 `/Users/chunhaixu/NotchReminder/Package.swift`, 内容为下面**完整可编译**代码:

  ```swift
  // swift-tools-version:5.9
  import PackageDescription

  let package = Package(
      name: "NotchReminder",
      platforms: [
          .macOS(.v13)
      ],
      dependencies: [
          .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0")
      ],
      targets: [
          .target(
              name: "ReminderCore",
              path: "Sources/ReminderCore"
          ),
          .executableTarget(
              name: "NotchReminder",
              dependencies: [
                  "ReminderCore",
                  .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
              ],
              path: "Sources/NotchReminder"
          ),
          .testTarget(
              name: "ReminderCoreTests",
              dependencies: ["ReminderCore"],
              path: "Tests/ReminderCoreTests"
          )
      ]
  )
  ```

  > 注: `NotchReminderTests` test target 由 Task 3(最先需要它的 Task)按 CONTRACT §C4 追加,本 Task 只建 `ReminderCoreTests`。

- [ ] **Step 1.2 — 写 `Sources/ReminderCore/Version.swift`(库占位源)。** 新建 `/Users/chunhaixu/NotchReminder/Sources/ReminderCore/Version.swift`:

  ```swift
  import Foundation

  /// ReminderCore 版本号。占位源文件, 让 library target 在 Task 2 加入 Models/Engine 前即可编译。
  public let reminderCoreVersion = "0.1.0"
  ```

- [ ] **Step 1.3 — 写 `Sources/NotchReminder/NotchPresenter.swift`(刘海封装)。** 新建 `/Users/chunhaixu/NotchReminder/Sources/NotchReminder/NotchPresenter.swift`。**可访问性: `public final class` + `public init()`**(CONTRACT §C2,让跨 target 验证/Task 5 覆盖前后一致)。`showTest()` 内部要 `await expand/hide`(经 DynamicNotchControllable 协议的 @MainActor async 方法),故标 `@MainActor`。内容:

  ```swift
  import AppKit
  import DynamicNotchKit

  /// 封装 DynamicNotchKit 的最小刘海浮层入口。
  /// DynamicNotchInfo.init 本身非 @MainActor(可任意上下文构造); 仅 expand/hide 经
  /// DynamicNotchControllable 协议为 @MainActor async, 故 showTest() 标 @MainActor 以承载 await。
  /// Task 5 会用 present(_:onAction:) 取代 showTest(), 并保留 public 可访问性。
  public final class NotchPresenter {
      public init() {}

      /// 弹一张测试信息卡片(展开 → 停留 3s → 自动收起)。DynamicNotchKit 无内建 auto-hide,
      /// 手动 expand() + Task.sleep + hide()。
      @MainActor
      func showTest() {
          let info = DynamicNotchInfo(
              icon: .init(systemName: "checkmark.seal", color: .green),   // DynamicNotchInfo.Label?
              title: "测试提醒",                                            // LocalizedStringKey
              description: "刘海浮层测试卡片 · NotchReminder"                // LocalizedStringKey?
          )
          Task { @MainActor in
              await info.expand()                       // async; 内部含 ~0.4s 展开动画后返回
              try? await Task.sleep(for: .seconds(3))   // 额外停留 3s
              await info.hide()                          // 淡出并销毁窗口
          }
      }
  }
  ```

- [ ] **Step 1.4 — 写 `Sources/NotchReminder/main.swift`(菜单栏 accessory 入口)。** 新建 `/Users/chunhaixu/NotchReminder/Sources/NotchReminder/main.swift`。**注意**: `AppDelegate` 标 `@MainActor`(delegate 回调本就在主线程), 因此顶层构造它要用 `MainActor.assumeIsolated { AppDelegate() }`——`main.swift` 顶层是 nonisolated 上下文, 直接 `AppDelegate()` 在当前 Swift 工具链下会报 actor 隔离错(此报错来自顶层 AppDelegate 构造, 与 DynamicNotchInfo.init 无关, 见 CONTRACT §C6)。内容:

  ```swift
  import AppKit

  /// 菜单栏 accessory App 委托: 挂一个 NSStatusItem, 菜单含「测试提醒 / 退出」。
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
      private var statusItem: NSStatusItem!
      private let presenter = NotchPresenter()

      func applicationDidFinishLaunching(_ notification: Notification) {
          statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
          if let button = statusItem.button {
              button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "NotchReminder")
          }
          let menu = NSMenu()
          let testItem = NSMenuItem(title: "测试提醒", action: #selector(fireTest), keyEquivalent: "")
          testItem.target = self
          menu.addItem(testItem)
          menu.addItem(.separator())
          let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
          menu.addItem(quitItem)
          statusItem.menu = menu
      }

      /// 菜单「测试提醒」回调: 弹刘海测试卡片。选择器在主线程触发, 与 @MainActor 一致。
      @objc private func fireTest() {
          presenter.showTest()
      }
  }

  let app = NSApplication.shared
  // 顶层是 nonisolated 上下文, AppDelegate 是 @MainActor 类型, 用 assumeIsolated 在主 actor 上构造。
  let delegate = MainActor.assumeIsolated { AppDelegate() }
  app.delegate = delegate
  app.setActivationPolicy(.accessory)   // 菜单栏 accessory: 无 Dock 图标、无主菜单
  app.run()
  ```

- [ ] **Step 1.5 — 写 `Tests/ReminderCoreTests/ReminderCoreTests.swift`(占位测试, 防空 testTarget)。** 新建 `/Users/chunhaixu/NotchReminder/Tests/ReminderCoreTests/ReminderCoreTests.swift`。SPM 里空的 testTarget 会构建失败, 故先放一个最小测试; Task 2 会在同目录新增 `ReminderEngineTests.swift`, 二者并存。内容:

  ```swift
  import XCTest
  @testable import ReminderCore

  final class ReminderCoreTests: XCTestCase {
      func testVersionPresent() {
          XCTAssertEqual(reminderCoreVersion, "0.1.0")
      }
  }
  ```

- [ ] **Step 1.6 — `swift build` 确认整包编译通过。** 在仓库根执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -15
  ```

  预期 **PASS**(首次会先 fetch/resolve DynamicNotchKit 1.1.0), 尾部形如:

  ```
  Computed https://github.com/MrKai77/DynamicNotchKit at 1.1.0
  Building for debugging...
  [x/y] Compiling ReminderCore Version.swift
  [x/y] Compiling DynamicNotchKit DynamicNotch.swift
  [x/y] Compiling NotchReminder NotchPresenter.swift
  [x/y] Linking NotchReminder
  Build complete!
  ```

  若报 `error: call to main actor-isolated initializer ... in a synchronous nonisolated context`, 该报错来自顶层 `AppDelegate()` 漏了 `MainActor.assumeIsolated`(见 CONTRACT §C6, 与 DynamicNotchInfo.init 无关)—— 回 Step 1.4 对照。

- [ ] **Step 1.7 — `swift test` 确认 testTarget 可编译通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -6
  ```

  预期 **PASS**: `Executed 1 test, with 0 failures`(占位 `testVersionPresent` 通过, 证明 testTarget 非空可编译, 为 Task 2 铺好路)。

- [ ] **Step 1.8 — `swift run` + 手动验证菜单栏与刘海卡片。** 在**图形登录会话**(非纯 SSH)里执行:

  ```bash
  swift run --package-path /Users/chunhaixu/NotchReminder NotchReminder
  ```

  手动验证(逐条对照):
  1. 命令启动后**不返回**(App 进入 `app.run()` 事件循环), Dock **不出现**图标(`.accessory` 生效)。
  2. 屏幕**右上角菜单栏**出现一个沙漏(hourglass)图标。
  3. 点该图标 → 弹出菜单, 含两行:「测试提醒」/(分隔)/「退出」。
  4. 点「测试提醒」→ **刘海周围弹出一张卡片**(绿色 checkmark.seal 图标 + 标题「测试提醒」+ 描述「刘海浮层测试卡片 · NotchReminder」), 约 3 秒后自动收起。
  5. 点「退出」→ App 退出, 终端命令返回。

  > 若第 4 步无卡片但菜单/图标正常, 见文末「Fallback 注记」。
  > 验证完毕后在终端 `Ctrl-C` 或点菜单「退出」结束进程。

- [ ] **Step 1.9 — commit。** 执行:

  ```bash
  \
  git add Package.swift Sources/ReminderCore/Version.swift Sources/NotchReminder/main.swift Sources/NotchReminder/NotchPresenter.swift Tests/ReminderCoreTests/ReminderCoreTests.swift && \
  git commit -m "Task 1: SPM skeleton + menu-bar accessory shell + notch test card

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 5 个文件纳入版本(`.build/` 已被 `.gitignore` 忽略, 不会误入)。

#### Fallback 注记(裸可执行无法显示刘海时改 .app bundle)

以上 `swift run` 产出的是**裸 Mach-O 可执行**(非 `.app` bundle)。据 DynamicNotchKit 源码, 其内部依赖 AppKit GUI 栈(`NSPanel` / `NSHostingView` / `NSScreen` / `NSApplication.didChangeScreenParametersNotification` / `NSHapticFeedbackManager`)。本 Task 已用 `.accessory` + `app.run()` 建立了 `NSApplication` 事件循环, 通常足以让 `NSStatusItem` 与刘海浮层正常显示。但若在实机上出现「菜单栏图标正常、点『测试提醒』刘海无反应」或 `NSScreen.screens[0]` 越界崩溃, 说明需要正规 `.app` bundle 承载。**最小改造步骤(不在本 Task 展开代码, 留待需要时执行)**:

1. 在仓库根建 `NotchReminder.app/Contents/`, 放 `MacOS/NotchReminder`(= `swift build -c release` 产物拷入) 与 `Info.plist`。
2. `Info.plist` 关键键: `CFBundleExecutable=NotchReminder`、`CFBundleIdentifier=com.notchreminder.app`、`CFBundlePackageType=APPL`、`LSUIElement=true`(去 Dock 图标, 替代运行时 `.accessory`)、`LSMinimumSystemVersion=13.0`。
3. `open NotchReminder.app` 启动; 刘海浮层与菜单栏依赖已连接 WindowServer 的 GUI 会话, bundle 形态下 `NSScreen.screens` 时序更稳。
4. 若后续要申请通知 / 辅助功能等需 TCC 授权的能力, 或走开机自启, 都以 `.app` bundle(带稳定 bundle id + 代码签名) 为前提 —— 裸可执行的 TCC 授权按可执行路径记账、换路径即失效。

> 说明(feasibility 标签): 「裸可执行能否显示刘海浮层」标 `待实机坐实`。已坐实的是: SPM 三 target 工程 `swift build -c release` / `swift test` / `swift run` 全通过, DynamicNotchKit 1.1.0 依赖解析成功, 上述 `NotchPresenter` / `AppDelegate` 代码在本机 Swift 6.3.3 工具链下编译链接通过(见 Step 1.6/1.7 预期输出)。未坐实的是 Step 1.8 实机点击后刘海卡片的实际显示 —— 由执行者在图形会话手动确认; 若不显示按上文改 `.app` bundle。

---

## Task 2: ReminderCore 模型与引擎(active/rest/sit + CC 补活跃)

> 前置: Task 1 已建好 SPM 工程, `Sources/ReminderCore/` 与 `Tests/ReminderCoreTests/` 目录存在,
> `swift build` / `swift test` 可跑通(空 target)。本 Task 建立纯逻辑状态机的**模型 + 引擎骨架**,
> 只实现 dt / active / rest / sit 触发 / CC 补活跃这几条口径。water / eye / night 三分支留给 Task 4。
>
> ReminderEngine.advance 是**纯函数**(无副作用, 不 import AppKit), 必须先测后写。
> 本 Task 定义的 `Sample`/`ReminderConfig`/`ReminderState`/`Reminder`/`advance` 即 CONTRACT §C1,下游逐字对齐。

#### Files

- `Sources/ReminderCore/Models.swift` — 本 Task 新建, 完整 public 定义(Sample / ReminderConfig / ReminderState / Reminder)。
- `Sources/ReminderCore/ReminderEngine.swift` — 本 Task 新建, 含 `advance` 的 dt/active/rest/sit/CC 部分 + `isNight`/`clockString`(供 Task 4 复用, 本 Task 先落地不调 night 分支)。
- `Tests/ReminderCoreTests/ReminderEngineTests.swift` — 本 Task 新建, 覆盖: 首采样 dt=0 不累加 / 连续 active 累加到 sit 阈值触发 / snooze 内不重复 / rest 清零 sit·eye / water 暂停于 rest / CC 补活跃使无键鼠也 active。

#### Interfaces (本 Task 定义, Task 4 复用, 下游必须保持一致; = CONTRACT §C1)

```swift
public struct Sample: Equatable {
    public var now: Date
    public var idleSeconds: Double
    public var ccActive: Bool
    public var ccLastEvent: Date?
    public var project: String?
}

public struct ReminderConfig: Equatable {
    public var sitThreshold: TimeInterval       // 50min
    public var waterThreshold: TimeInterval     // 60min
    public var eyeThreshold: TimeInterval        // 30min
    public var activeIdleCeiling: TimeInterval   // 60s
    public var restThreshold: TimeInterval       // 5min
    public var ccGrace: TimeInterval             // 90s
    public var sitSnooze: TimeInterval           // 15min
    public var nightRepeat: TimeInterval         // 30min
    public var sitEnabled: Bool
    public var waterEnabled: Bool
    public var eyeEnabled: Bool
    public var nightEnabled: Bool
    public var mutedUntil: Date?
}

public struct ReminderState: Equatable {
    public var sitAccum: TimeInterval
    public var waterAccum: TimeInterval
    public var eyeAccum: TimeInterval
    public var lastSample: Date?
    public var lastSitAlert: Date?
    public var lastNightAlert: Date?
}

public enum Reminder: Equatable {
    case sit(minutes: Int, project: String?)
    case water
    case eye
    case night(clock: String)
}

// 纯函数
public static func advance(_ state: ReminderState, config: ReminderConfig, sample: Sample) -> (ReminderState, [Reminder])
```

#### Steps

- [ ] **Step 2.1 — 写 Models.swift(完整 public 定义)。** 新建 `Sources/ReminderCore/Models.swift`, 内容为下面**完整可编译**代码(全部字段带默认值构造器, 便于测试构造):

  ```swift
  import Foundation

  /// 一次采样输入。纯数据, 无副作用。
  public struct Sample: Equatable {
      public var now: Date
      public var idleSeconds: Double
      public var ccActive: Bool
      public var ccLastEvent: Date?
      public var project: String?

      public init(
          now: Date,
          idleSeconds: Double,
          ccActive: Bool = false,
          ccLastEvent: Date? = nil,
          project: String? = nil
      ) {
          self.now = now
          self.idleSeconds = idleSeconds
          self.ccActive = ccActive
          self.ccLastEvent = ccLastEvent
          self.project = project
      }
  }

  /// 引擎配置: 四类阈值 + 四个开关 + 判定阈值 + 免打扰窗口。时间字段单位秒。默认值取 spec §5.3/§5.4。
  public struct ReminderConfig: Equatable {
      public var sitThreshold: TimeInterval
      public var waterThreshold: TimeInterval
      public var eyeThreshold: TimeInterval
      public var activeIdleCeiling: TimeInterval
      public var restThreshold: TimeInterval
      public var ccGrace: TimeInterval
      public var sitSnooze: TimeInterval
      public var nightRepeat: TimeInterval
      public var sitEnabled: Bool
      public var waterEnabled: Bool
      public var eyeEnabled: Bool
      public var nightEnabled: Bool
      public var mutedUntil: Date?

      public init(
          sitThreshold: TimeInterval = 50 * 60,
          waterThreshold: TimeInterval = 60 * 60,
          eyeThreshold: TimeInterval = 30 * 60,
          activeIdleCeiling: TimeInterval = 60,
          restThreshold: TimeInterval = 5 * 60,
          ccGrace: TimeInterval = 90,
          sitSnooze: TimeInterval = 15 * 60,
          nightRepeat: TimeInterval = 30 * 60,
          sitEnabled: Bool = true,
          waterEnabled: Bool = true,
          eyeEnabled: Bool = true,
          nightEnabled: Bool = true,
          mutedUntil: Date? = nil
      ) {
          self.sitThreshold = sitThreshold
          self.waterThreshold = waterThreshold
          self.eyeThreshold = eyeThreshold
          self.activeIdleCeiling = activeIdleCeiling
          self.restThreshold = restThreshold
          self.ccGrace = ccGrace
          self.sitSnooze = sitSnooze
          self.nightRepeat = nightRepeat
          self.sitEnabled = sitEnabled
          self.waterEnabled = waterEnabled
          self.eyeEnabled = eyeEnabled
          self.nightEnabled = nightEnabled
          self.mutedUntil = mutedUntil
      }
  }

  /// 引擎累积状态。由 advance 输入并返回更新后的副本(值语义)。
  public struct ReminderState: Equatable {
      public var sitAccum: TimeInterval
      public var waterAccum: TimeInterval
      public var eyeAccum: TimeInterval
      public var lastSample: Date?
      public var lastSitAlert: Date?
      public var lastNightAlert: Date?

      public init(
          sitAccum: TimeInterval = 0,
          waterAccum: TimeInterval = 0,
          eyeAccum: TimeInterval = 0,
          lastSample: Date? = nil,
          lastSitAlert: Date? = nil,
          lastNightAlert: Date? = nil
      ) {
          self.sitAccum = sitAccum
          self.waterAccum = waterAccum
          self.eyeAccum = eyeAccum
          self.lastSample = lastSample
          self.lastSitAlert = lastSitAlert
          self.lastNightAlert = lastNightAlert
      }
  }

  /// 一次 advance 可产出的提醒。Equatable 便于单测断言。
  public enum Reminder: Equatable {
      case sit(minutes: Int, project: String?)
      case water
      case eye
      case night(clock: String)
  }
  ```

- [ ] **Step 2.2 — 写失败测试(active/rest/sit/CC 六条)。** 新建 `Tests/ReminderCoreTests/ReminderEngineTests.swift`, 内容为下面**完整**代码。此时 `ReminderEngine` 尚不存在, 编译失败即预期 FAIL。

  ```swift
  import XCTest
  @testable import ReminderCore

  final class ReminderEngineTests: XCTestCase {

      // 固定基准时间: 2026-07-07 14:00:00(非熬夜窗口)。
      private var base: Date {
          var comps = DateComponents()
          comps.year = 2026; comps.month = 7; comps.day = 7
          comps.hour = 14; comps.minute = 0; comps.second = 0
          return Calendar.current.date(from: comps)!
      }

      func testFirstSampleDtZeroNoAccum() {
          let cfg = ReminderConfig()
          let s = ReminderState()
          let sample = Sample(now: base, idleSeconds: 0)  // 首采样, 无 lastSample
          let (out, reminders) = ReminderEngine.advance(s, config: cfg, sample: sample)
          XCTAssertEqual(out.sitAccum, 0)
          XCTAssertEqual(out.eyeAccum, 0)
          XCTAssertEqual(out.waterAccum, 0)
          XCTAssertEqual(out.lastSample, base)
          XCTAssertTrue(reminders.isEmpty)
      }

      func testContinuousActiveAccumulatesToSitThresholdAndFires() {
          let cfg = ReminderConfig()  // sit 50min
          var s = ReminderState()
          var t = base
          var last: [Reminder] = []
          (s, _) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0))
          var fired = false
          for _ in 0..<(50 * 6 + 1) {  // 50min * 6 次/min + 1
              t = t.addingTimeInterval(10)
              (s, last) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0, project: "SoulApp"))
              if last.contains(where: { if case .sit = $0 { return true } else { return false } }) {
                  fired = true
                  break
              }
          }
          XCTAssertTrue(fired)
          XCTAssertTrue(s.sitAccum >= cfg.sitThreshold)  // 不清零
          if case let .sit(minutes, project)? = last.first(where: { if case .sit = $0 { return true } else { return false } }) {
              XCTAssertEqual(minutes, 50)
              XCTAssertEqual(project, "SoulApp")
          } else {
              XCTFail("expected .sit")
          }
      }

      func testSitSnoozeNoRepeatWithinWindow() {
          let cfg = ReminderConfig()  // sit 50min, snooze 15min
          // 已越过阈值、刚在 base 报过一次。以 10s 步长采样避免触发 dormant(dt>restThreshold)清零。
          var s = ReminderState(sitAccum: cfg.sitThreshold + 60, lastSample: base, lastSitAlert: base)
          var t = base
          var firedInSnooze = false
          for _ in 0..<(10 * 6) {  // 推进 10min(< 15min snooze)
              t = t.addingTimeInterval(10)
              var r: [Reminder]
              (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0))
              if r.contains(where: { if case .sit = $0 { return true } else { return false } }) { firedInSnooze = true }
          }
          XCTAssertFalse(firedInSnooze)  // snooze 窗口内不重复
          var firedAfter = false
          for _ in 0..<(6 * 6) {  // 再推进 6min(累计 16min > 15min snooze)
              t = t.addingTimeInterval(10)
              var r: [Reminder]
              (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0))
              if r.contains(where: { if case .sit = $0 { return true } else { return false } }) { firedAfter = true }
          }
          XCTAssertTrue(firedAfter)
      }

      func testRestClearsSitAndEyeButPausesWater() {
          let cfg = ReminderConfig()
          var s = ReminderState(sitAccum: 1000, waterAccum: 1200, eyeAccum: 800, lastSample: base)
          let t = base.addingTimeInterval(30)  // dt=30(< restThreshold), 不走 dormant
          let sample = Sample(now: t, idleSeconds: cfg.restThreshold + 1)  // idle 达 rest 且无 CC
          (s, _) = ReminderEngine.advance(s, config: cfg, sample: sample)
          XCTAssertEqual(s.sitAccum, 0)
          XCTAssertEqual(s.eyeAccum, 0)
          XCTAssertEqual(s.waterAccum, 1200)  // water 暂停, 不加不清
      }

      func testCCGraceKeepsActiveWithoutInput() {
          let cfg = ReminderConfig()
          var s = ReminderState(lastSample: base)
          let t = base.addingTimeInterval(30)
          let sample = Sample(
              now: t,
              idleSeconds: cfg.restThreshold + 100,  // 无键鼠
              ccActive: true,
              ccLastEvent: t.addingTimeInterval(-30),  // 30s < 90s grace
              project: "SoulApp"
          )
          (s, _) = ReminderEngine.advance(s, config: cfg, sample: sample)
          XCTAssertEqual(s.sitAccum, 30)  // 累加 dt=30, 未清零 → 证明判为 active 而非 rest
          XCTAssertEqual(s.eyeAccum, 30)
          XCTAssertEqual(s.waterAccum, 30)
      }
  }
  ```

- [ ] **Step 2.3 — 运行确认失败。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -20
  ```

  预期 **FAIL**: 编译错误 `error: cannot find 'ReminderEngine' in scope`(引擎尚未创建)。

- [ ] **Step 2.4 — 写最小实现(引擎 dt/active/rest/sit + CC + isNight/clockString)。** 新建 `Sources/ReminderCore/ReminderEngine.swift`。本 Task 版本**不含 water/eye/night 触发分支**(留 Task 4), 但 `isNight`/`clockString` 先落地。内容:

  ```swift
  import Foundation

  /// 纯逻辑状态机。无副作用、不依赖 AppKit, 可 `swift test`。
  public enum ReminderEngine {

      /// 墙钟是否处于「熬夜」窗口: hour >= 23 或 hour < 2(即 23:00–01:59)。
      public static func isNight(_ now: Date, calendar: Calendar = .current) -> Bool {
          let hour = calendar.component(.hour, from: now)
          return hour >= 23 || hour < 2
      }

      /// 把时间格式化为 "HH:mm"(24 小时制, 本地时区)。
      public static func clockString(_ now: Date, calendar: Calendar = .current) -> String {
          let comps = calendar.dateComponents([.hour, .minute], from: now)
          let hour = comps.hour ?? 0
          let minute = comps.minute ?? 0
          return String(format: "%02d:%02d", hour, minute)
      }

      /// 纯函数: 喂入当前状态 + 配置 + 一次采样, 返回更新后状态与本次要产出的提醒列表。
      /// 本 Task 只实现 dt / active / rest / sit / CC 口径; water/eye/night 分支在 Task 4 补齐。
      public static func advance(
          _ state: ReminderState,
          config: ReminderConfig,
          sample: Sample
      ) -> (ReminderState, [Reminder]) {
          var newState = state
          let now = sample.now

          // ---- 1) dt ----
          var dt: TimeInterval
          if let last = state.lastSample {
              dt = now.timeIntervalSince(last)
          } else {
              dt = 0
          }
          if dt < 0 { dt = 0 }
          let dormant = dt > config.restThreshold  // 长时间未采样(休眠) → 按真休息

          // ---- 2) active / rest 判定 ----
          let byInput = sample.idleSeconds < config.activeIdleCeiling
          let byCC: Bool = {
              guard sample.ccActive, let ccLast = sample.ccLastEvent else { return false }
              return now.timeIntervalSince(ccLast) < config.ccGrace
          }()
          let active = byInput || byCC
          let rest = (sample.idleSeconds >= config.restThreshold && !byCC) || dormant

          // ---- 3) 计时器推进 ----
          if rest {
              newState.sitAccum = 0
              newState.eyeAccum = 0
              // water: 暂停累加, 不加不清
          } else if active {
              newState.sitAccum += dt
              newState.eyeAccum += dt
              newState.waterAccum += dt
          }
          // 灰区: 三累加均不变

          newState.lastSample = now

          // ---- 4) 触发判断(本 Task 仅 sit) ----
          var reminders: [Reminder] = []

          // sit
          if config.sitEnabled && newState.sitAccum >= config.sitThreshold {
              let snoozeOK: Bool = {
                  guard let lastAlert = newState.lastSitAlert else { return true }
                  return now.timeIntervalSince(lastAlert) >= config.sitSnooze
              }()
              if snoozeOK {
                  reminders.append(.sit(minutes: Int(newState.sitAccum / 60), project: sample.project))
                  newState.lastSitAlert = now  // 不清 sitAccum
              }
          }

          // ---- 5) muted 抑制产出(计时已照常推进) ----
          if let mutedUntil = config.mutedUntil, now < mutedUntil {
              return (newState, [])
          }

          return (newState, reminders)
      }
  }
  ```

- [ ] **Step 2.5 — 运行确认通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter ReminderEngineTests 2>&1 | tail -8
  ```

  预期 **PASS**: `Executed 5 tests, with 0 failures`(Test 2.2 中 5 个用例全绿)。全量 `swift test`(不加 filter)应为 `Executed 6 tests`(ReminderCore 占位 1 + Engine 5)。

- [ ] **Step 2.6 — commit。** 执行:

  ```bash
  \
  git add Sources/ReminderCore/Models.swift Sources/ReminderCore/ReminderEngine.swift Tests/ReminderCoreTests/ReminderEngineTests.swift && \
  git commit -m "Task 2: ReminderCore models + engine (active/rest/sit + CC grace)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 3 个文件纳入版本。

---

## Task 3: ActivityMonitor(idle 采样) + AppController(单一 owner) + 久坐端到端

> 前置: Task 1 已建好 SPM 工程(repo 根 `Package.swift`, 两个 target: library `ReminderCore` + executable `NotchReminder`),
> `Sources/NotchReminder/` 下已有 `NotchPresenter.swift`(`public final class` + `public init()`, 至少有 `showTest()`)与 `main.swift`(入口:
> `NSApplication.shared.setActivationPolicy(.accessory)` + `AppDelegate` + `app.run()`), 菜单栏"测试提醒"点一下能弹刘海卡片;
> Task 2 已把 `ReminderCore` 的 `advance` 纯函数 + 首批单测跑绿。
>
> **本 Task 是 AppController 的唯一 owner(CONTRACT §C3): 一次性建立完整表面。** Task 5/6/7 只做增量 Modify,不重复 Create/覆盖。
> 本 Task 把**纯引擎接到真实系统信号**, 打通久坐提醒端到端:
> ① 新增 `ActivityMonitor.currentIdleSeconds()`(系统 idle 只读采样, 零权限);
> ② 新增 `AppController`(CONTRACT §C3 的三面: 采样面完整实现 + 路由面 route/flushPending/pending/onSitSnooze + 命令只读面 shared/config/state/applyConfig/manualRest/muteFor);
> ③ 给 `NotchPresenter` 加**唯一对外方法 `present(_:onAction:)`**(CONTRACT §C2; 本 Task 四类都走 DynamicNotchInfo 占位, Task 5 把 sit/night 升级为强样式);
> ④ `main.swift` 里实例化 `AppController`(赋给 `AppController.shared`)、接 `onSitSnooze = manualRest`、并启动 Timer。
>
> **FullscreenProbe 的默认值本 Task 用 `{ false }`(永不全屏 → 总是 present)**, 因为 `DoNotDisturb.isFullscreenActive` 在 Task 5 才创建。Task 5 Modify 时把默认值改成 `DoNotDisturb.isFullscreenActive`。这样 Task 3 自包含可编译, Task 5 再补真探针。
>
> `AppController` 会引用 AppKit, **不放进 ReminderCore**, 保持 library 纯逻辑可 `swift test`。
> CC 字段(`ccActive`/`ccLastEvent`/`project`)本 Task 全传 `false`/`nil`/`nil`, 留 Task 6 接入 `~/.notchreminder/cc.json`。
>
> 测试策略: 引擎行为已在 Task 2/4 单测覆盖, 本 Task 主体是**接线**。给一个**轻量注入测试**(`AppController` 允许注入 `idleProvider` 与 `clock`, 断言"连续活跃累加到临时阈值会产出 `.sit`" / "idle 超 restThreshold 会把 sitAccum 清零"), 再给一套**手动端到端验证步骤**。

#### Files

- `Sources/NotchReminder/ActivityMonitor.swift` — **本 Task 新建**。`enum ActivityMonitor { static func currentIdleSeconds() -> Double }`, 用已核实的 `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)`(只读 idle, 已本机实测零权限、无 TCC 弹窗)。
- `Sources/NotchReminder/AppController.swift` — **本 Task 新建(唯一 owner)**。`@MainActor public final class AppController`, CONTRACT §C3 完整三面。
- `Sources/NotchReminder/NotchPresenter.swift` — **本 Task 修改**(Task 1 已建)。加**唯一对外方法 `present(_ r: Reminder, onAction: ((SitAction)->Void)?)`** + `public enum SitAction`, 四类都走 DynamicNotchInfo 占位(Task 5 升级 sit/night 为强样式)。保留 Task 1 的 `showTest()`(Task 5 会随文件重写取代)。
- `Sources/NotchReminder/main.swift` — **本 Task 修改**(Task 1 已建)。在 `applicationDidFinishLaunching` 里实例化 `AppController`、赋 `AppController.shared`、接 `onSitSnooze`、`start()`; 保留 Task 1 的 `NSStatusItem` 骨架。
- `Package.swift` — **本 Task 修改**。按 CONTRACT §C4 追加 `NotchReminderTests` test target(Task 1 未加, 本 Task 首次建立这一份)。
- `Tests/NotchReminderTests/AppControllerTests.swift` — **本 Task 新建**。`@testable import NotchReminder`, 注入 idle/clock, 断言连续活跃产 `.sit` / idle≥rest 清零。

#### Interfaces

**Consumes(来自 ReminderCore, CONTRACT §C1, 逐字对齐, 不得改动):**

```swift
public static func advance(_ state: ReminderState, config: ReminderConfig, sample: Sample) -> (ReminderState, [Reminder])
public struct Sample: Equatable { public init(now: Date, idleSeconds: Double, ccActive: Bool = false, ccLastEvent: Date? = nil, project: String? = nil) }
public struct ReminderConfig: Equatable { /* 见 Task 2 Models.swift */ }
public struct ReminderState: Equatable { public init(sitAccum: TimeInterval = 0, ...) }
public enum Reminder: Equatable { case sit(minutes: Int, project: String?); case water; case eye; case night(clock: String) }
```

**Produces(本 Task 定义; = CONTRACT §C2/§C3):**

```swift
enum ActivityMonitor {
    /// 系统全局空闲秒数(自最后一次任意键鼠/触控板输入)。只读被动查询, 零权限。
    static func currentIdleSeconds() -> Double
}

public enum SitAction: Equatable { case snooze; case dismiss }
public typealias FullscreenProbe = () -> Bool

@MainActor
public final class NotchPresenter {
    // Task 1 已给 public init(); 本 Task 加 present(_:onAction:)(唯一对外渲染入口)
    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?)
}

@MainActor
public final class AppController {              // CONTRACT §C3 完整三面
    public static var shared: AppController!    // App 启动时赋值(main.swift)
    public init(presenter: NotchPresenter,
                config: ReminderConfig = ReminderConfig(),
                idleProvider: @escaping () -> Double = ActivityMonitor.currentIdleSeconds,
                clock: @escaping () -> Date = { Date() },
                dnd: @escaping FullscreenProbe = { false })   // Task 5 改默认为 DoNotDisturb.isFullscreenActive
    public func start(interval: TimeInterval = 10)
    @discardableResult public func tick() -> [Reminder]
    public func route(_ reminders: [Reminder])
    public func flushPending()
    public var onSitSnooze: (() -> Void)?
    public private(set) var pending: [Reminder]
    public var config: ReminderConfig { get }
    public var state: ReminderState { get }
    public func applyConfig(_ config: ReminderConfig)
    public func manualRest()
    public func muteFor(_ seconds: TimeInterval)
}
```

> `AppController.shared` 用 `static var shared: AppController!`(可为 nil 直到 App 启动赋值)。Task 7 的 MenuBar/SettingsWindow 在 App 运行期访问, 此时已非 nil。单测直接用 `init` 构造实例、不碰 `shared`。

#### Steps

- [ ] **Step 3.1 — 按 CONTRACT §C4 追加 `NotchReminderTests` test target。** 先读现状:

  ```bash
  cat /Users/chunhaixu/NotchReminder/Package.swift
  ```

  确认存在 `.executableTarget(name: "NotchReminder", ...)`。若**已有** `.testTarget(name: "NotchReminderTests", ...)` 则跳过;若**没有**, 在 `targets:` 数组末尾追加 CONTRACT §C4 那一份(含 `ReminderCore` 显式依赖 + path):

  ```swift
          .testTarget(
              name: "NotchReminderTests",
              dependencies: ["NotchReminder", "ReminderCore"],
              path: "Tests/NotchReminderTests"
          ),
  ```

  验证包结构可解析:

  ```bash
  swift package --package-path /Users/chunhaixu/NotchReminder describe 2>&1 | grep -E "NotchReminder|ReminderCore|Type:" | head -20
  ```

  预期能看到 executable target `NotchReminder`、library `ReminderCore`, 以及 test target `NotchReminderTests`。

- [ ] **Step 3.2 — 写 `ActivityMonitor.swift`(系统 idle 只读采样)。** 新建 `Sources/NotchReminder/ActivityMonitor.swift`, 内容为下面**完整可编译**代码。签名严格按已核实的 `CGEventSource.secondsSinceLastEventType`(本机 macOS 26.5 实测返回真实 idle 值、无任何 TCC 权限弹窗; 实测 82.17s):

  ```swift
  import CoreGraphics

  /// 系统级活跃度采样。只读, 不监听/不记录输入内容, 因此无需辅助功能或输入监测权限。
  enum ActivityMonitor {

      /// 系统全局空闲秒数: 距上次任意键鼠/触控板输入过去的秒数。
      ///
      /// 用 `CGEventSource.secondsSinceLastEventType(_:eventType:)`(被动查询, 非事件监听),
      /// 已在本机 macOS 26.5 实测: 裸可执行直接返回真实 idle 值, 全程无 TCC 权限弹窗。
      /// - stateID 用 `.hidSystemState`(对应 C 常量 kCGEventSourceStateHIDSystemState)。
      /// - eventType 表达"任意输入": `kCGAnyInputEventType` 在 Swift 未桥接为符号, 用 `CGEventType(rawValue: ~0)!`
      ///   构造(~0 即全 1 位, 底层 C 值 0xFFFFFFFF)。
      /// 返回 `CFTimeInterval`(== `Double`), 单位秒。
      static func currentIdleSeconds() -> Double {
          let anyInput = CGEventType(rawValue: ~0)!
          return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
      }
  }
  ```

- [ ] **Step 3.3 — 给 `NotchPresenter` 加唯一对外方法 `present(_:onAction:)` + `SitAction`。** 打开 `Sources/NotchReminder/NotchPresenter.swift`, 在**文件末尾**追加下面代码。**不删 Task 1 的 `showTest()`**(Task 5 会随文件重写取代)。本 Task 四类都走 `DynamicNotchInfo` 占位强样式(带图标标题描述, 停留数秒后自动收), Task 5 再把 sit/night 升级为带按钮的强样式、water/eye 改轻样式。`SitAction` 在此定义(CONTRACT §C2), 本占位版 `onAction` 暂不触发(Task 5 的强样式按钮才回调):

  ```swift
  import DynamicNotchKit
  import ReminderCore

  /// 强样式浮层「起身5分钟」/「知道了」两个按钮对应的动作(CONTRACT §C2)。
  public enum SitAction: Equatable {
      case snooze   // 起身5分钟: 记真休息意图(由 AppController 清 sit 计时)
      case dismiss  // 知道了: 仅收起
  }

  extension NotchPresenter {

      /// 唯一对外渲染入口。本 Task(阶段1)四类都做成 DynamicNotchInfo 占位卡片(停留数秒自动收),
      /// onAction 暂不触发; Task 5 把 sit/night 升级为带按钮的强样式(回调 onAction)、water/eye 改轻样式。
      /// 展开/收起走 DynamicNotchKit 的 @MainActor async API(经 DynamicNotchControllable 协议)。
      public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
          let info: DynamicNotchInfo
          switch r {
          case let .sit(minutes, project):
              let suffix = project.map { " · \($0) 项目" } ?? ""
              info = DynamicNotchInfo(
                  icon: .init(systemName: "figure.walk", color: .orange),
                  title: "该起身了",
                  description: "连续 \(minutes) 分钟\(suffix) / 起来走两步"
              )
          case .water:
              info = DynamicNotchInfo(
                  icon: .init(systemName: "drop.fill", color: .blue),
                  title: "喝口水",
                  description: "累计工作到点了 / 补个水"
              )
          case .eye:
              info = DynamicNotchInfo(
                  icon: .init(systemName: "eye.fill", color: .green),
                  title: "护眼远眺",
                  description: "看看 6 米外的东西 20 秒"
              )
          case let .night(clock):
              info = DynamicNotchInfo(
                  icon: .init(systemName: "moon.stars.fill", color: .purple),
                  title: "\(clock) 了",
                  description: "明天的你会感谢现在睡觉的你"
              )
          }
          Task { @MainActor in
              await info.expand()                       // 内部已含 ~0.4s 动画等待
              try? await Task.sleep(for: .seconds(4))   // 额外停留 4s
              await info.hide()
          }
      }
  }
  ```

  > 注: `DynamicNotchInfo.Label` 的 `.init(systemName:color:)` 与 `title`/`description` 为 `LocalizedStringKey`, 均据已核实源码(tag 1.1.0)。`Reminder`/`SitAction` 供 `AppController` 与 Task 5 复用。若 Task 1 的 `NotchPresenter.swift` 已 `import DynamicNotchKit`, 追加的 `import` 重复无害。

- [ ] **Step 3.4 — 写 `AppController.swift`(CONTRACT §C3 完整三面)。** 新建 `Sources/NotchReminder/AppController.swift`, 内容为下面**完整可编译**代码。`@MainActor` 保证 Timer 回调与 `NotchPresenter`(@MainActor)都在主 actor; `idleProvider`/`clock`/`dnd` 可注入供测试。**tick() 流程: 先 flushPending()(免打扰结束自动补放)→ 采样 → advance → route(_:)**(不直接 present)。route 全屏则入 pending、否则 present。`manualRest()` 与 `onSitSnooze` 走同一清零语义(CONTRACT §C3):

  ```swift
  import Foundation
  import ReminderCore

  /// 判定「当前是否全屏」的探针。Task 3 默认 { false }(永不全屏), Task 5 Modify 改默认为 DoNotDisturb.isFullscreenActive; 单测可注入假探针。
  public typealias FullscreenProbe = () -> Bool

  /// 采样调度器 + 提醒落地编排层(CONTRACT §C3 单一 owner)。
  /// 每 interval 秒: flushPending → 读 idle → 构造 Sample → ReminderEngine.advance → route。
  /// CC 字段(ccActive/ccLastEvent/project)本阶段固定 false/nil/nil, 留 Task 6 接 ~/.notchreminder/cc.json。
  @MainActor
  public final class AppController {

      /// App 启动时(main.swift)赋值; 供 Task 7 的 MenuBar/SettingsWindow 访问。单测不碰它。
      public static var shared: AppController!

      private let presenter: NotchPresenter
      private var _config: ReminderConfig
      private var _state = ReminderState()
      private let idleProvider: () -> Double
      private let clock: () -> Date
      private let isFullscreen: FullscreenProbe
      private var timer: Timer?

      /// 全屏期间被挡下的提醒, 按到达顺序排队, 免打扰结束后补放。
      public private(set) var pending: [Reminder] = []

      /// 强样式 snooze / 菜单「起身了」回调。App 启动时接为 manualRest(见 main.swift)。
      public var onSitSnooze: (() -> Void)?

      public init(
          presenter: NotchPresenter,
          config: ReminderConfig = ReminderConfig(),
          idleProvider: @escaping () -> Double = ActivityMonitor.currentIdleSeconds,
          clock: @escaping () -> Date = { Date() },
          dnd: @escaping FullscreenProbe = { false }   // Task 5 改为 DoNotDisturb.isFullscreenActive
      ) {
          self.presenter = presenter
          self._config = config
          self.idleProvider = idleProvider
          self.clock = clock
          self.isFullscreen = dnd
      }

      // MARK: - 只读面(CONTRACT §C3c)

      public var config: ReminderConfig { _config }
      public var state: ReminderState { _state }

      // MARK: - 采样面(CONTRACT §C3a)

      /// 启动采样: 立即跑一次, 之后每 interval 秒一次(默认 10s, spec §5.3)。
      public func start(interval: TimeInterval = 10) {
          tick()
          let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
              Task { @MainActor in self?.tick() }
          }
          timer = t
      }

      /// 采样一次并推进引擎。先 flushPending(免打扰结束补放), 再采样→advance→route。返回本次 [Reminder] 供测试断言。
      @discardableResult
      public func tick() -> [Reminder] {
          flushPending()
          let sample = Sample(
              now: clock(),
              idleSeconds: idleProvider(),
              ccActive: false,
              ccLastEvent: nil,
              project: nil
          )
          let (newState, reminders) = ReminderEngine.advance(_state, config: _config, sample: sample)
          _state = newState
          route(reminders)
          return reminders
      }

      // MARK: - 路由面(CONTRACT §C3b)

      /// advance 产出的提醒逐条路由: 全屏 → 记 pending; 否则立即 present。
      public func route(_ reminders: [Reminder]) {
          for r in reminders {
              if isFullscreen() {
                  pending.append(r)
              } else {
                  show(r)
              }
          }
      }

      /// 免打扰结束后补放 pending。全屏仍在则整体继续挂起(不丢)。
      public func flushPending() {
          guard !pending.isEmpty else { return }
          guard !isFullscreen() else { return }
          let queued = pending
          pending.removeAll()
          for r in queued { show(r) }
      }

      private func show(_ r: Reminder) {
          presenter.present(r) { [weak self] action in
              if action == .snooze { self?.onSitSnooze?() }
          }
      }

      // MARK: - 命令面(CONTRACT §C3c)

      /// 替换配置并立即生效(采样循环下一拍即用新值)。
      public func applyConfig(_ config: ReminderConfig) {
          _config = config
      }

      /// 手动「我起身了」/ 强样式 snooze: 置 sitAccum=0、lastSitAlert=nil(与 onSitSnooze 同一实现)。
      public func manualRest() {
          _state.sitAccum = 0
          _state.lastSitAlert = nil
      }

      /// 专注静音: config.mutedUntil = now+seconds 并生效。
      public func muteFor(_ seconds: TimeInterval) {
          var cfg = _config
          cfg.mutedUntil = clock().addingTimeInterval(seconds)
          applyConfig(cfg)
      }
  }
  ```

- [ ] **Step 3.5 — 在 `main.swift` 里实例化 `AppController`、赋 shared、接 onSitSnooze、start。** 打开 `Sources/NotchReminder/main.swift`。在 Task 1 的 `AppDelegate.applicationDidFinishLaunching(_:)` 里(建完 `NSStatusItem` 之后), 新增接线。给 `AppDelegate` 加两个 `private` 属性并在 launching 里赋值。**只新增, 不删 Task 1 已有逻辑。**

  在 `AppDelegate` 类体内(与已有 `statusItem` 属性并列)新增:

  ```swift
      private var presenter = NotchPresenter()
      private var controller: AppController!
  ```

  在 `applicationDidFinishLaunching(_:)` 方法体**末尾**新增:

  ```swift
          let c = AppController(presenter: presenter)
          c.onSitSnooze = { [weak c] in c?.manualRest() }   // snooze 与「我起身了」同一清零语义(CONTRACT §C3)
          AppController.shared = c                            // 供 Task 7 菜单/设置窗访问
          controller = c
          c.start()
  ```

  > 注: `AppController` 与 `NotchPresenter` 均 `@MainActor`, 而 `applicationDidFinishLaunching` 在主 actor 上下文调用, 直接构造无隔离问题。Task 7 会在此启动路径再插三行接线(持久化 config + MenuBarController + FirstRunGuide), 不动本处采样接线。

- [ ] **Step 3.6 — `swift build` 确认接线编译通过。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -25
  ```

  预期 **PASS**: `Build complete!`(无 error)。首次会拉取 DynamicNotchKit 依赖, 耗时略长。若报 `NotchPresenter` 无 `present` / 构造器不匹配, 回 Step 3.3/3.5 对齐。

- [ ] **Step 3.7 — 写注入测试(不等真实时间)。** 新建 `Tests/NotchReminderTests/AppControllerTests.swift`, 内容为下面**完整**代码。用注入的 `idleProvider`/`clock` 直接调 `tick()` 断言, 不依赖真实 10s Timer、不依赖真实 idle:

  ```swift
  import XCTest
  @testable import NotchReminder
  import ReminderCore

  @MainActor
  final class AppControllerTests: XCTestCase {

      // 固定基准时间: 2026-07-07 14:00:00(非熬夜窗口)。
      private var base: Date {
          var comps = DateComponents()
          comps.year = 2026; comps.month = 7; comps.day = 7
          comps.hour = 14; comps.minute = 0; comps.second = 0
          return Calendar.current.date(from: comps)!
      }

      /// idle 恒 0(一直活跃) + clock 每 tick +10s, 临时 sitThreshold=60s → 累加过阈值应产出 .sit。
      func testContinuousActiveFiresSit() {
          var cfg = ReminderConfig()
          cfg.sitThreshold = 60          // 临时阈值 60s, 避免等 50min
          var fakeNow = base
          let controller = AppController(
              presenter: NotchPresenter(),
              config: cfg,
              idleProvider: { 0 },        // 一直有输入 → active
              clock: { fakeNow }
          )
          var fired = false
          _ = controller.tick()          // 第 1 次 tick: 首采样 dt=0 不累加
          for _ in 0..<10 {              // 推进 100s(> 60s 阈值)
              fakeNow = fakeNow.addingTimeInterval(10)
              let reminders = controller.tick()
              if reminders.contains(where: { if case .sit = $0 { return true } else { return false } }) {
                  fired = true
                  break
              }
          }
          XCTAssertTrue(fired, "连续活跃越过 sitThreshold 应产出 .sit")
      }

      /// 先累积一段, 再喂一个 idle ≥ restThreshold 的样本(真休息)→ sitAccum 归零, 不再产 .sit。
      func testRestResetsSit() {
          var cfg = ReminderConfig()
          cfg.sitThreshold = 60
          var fakeNow = base
          var idle: Double = 0
          let controller = AppController(
              presenter: NotchPresenter(),
              config: cfg,
              idleProvider: { idle },
              clock: { fakeNow }
          )
          _ = controller.tick()           // 首采样
          for _ in 0..<4 {                // 累积 40s(< 60s)
              fakeNow = fakeNow.addingTimeInterval(10)
              _ = controller.tick()
          }
          idle = cfg.restThreshold + 1    // 一次真休息: dt=10(< restThreshold 不触发 dormant)→ sit 清零
          fakeNow = fakeNow.addingTimeInterval(10)
          _ = controller.tick()
          idle = 0                        // 恢复活跃再推进 40s: 刚清零, 累计 40s < 60s → 不应产 .sit
          var firedAfterRest = false
          for _ in 0..<4 {
              fakeNow = fakeNow.addingTimeInterval(10)
              let reminders = controller.tick()
              if reminders.contains(where: { if case .sit = $0 { return true } else { return false } }) {
                  firedAfterRest = true
              }
          }
          XCTAssertFalse(firedAfterRest, "真休息清零后 40s 未达阈值, 不应产 .sit")
      }
  }
  ```

  > 注: 测试只调 `tick()`(返回 `[Reminder]`), `present(_:onAction:)` 里的 `expand()` 在 `Task { @MainActor in ... }` 里异步派发, 测试同步断言 `tick()` 返回值即结束, 不等待浮层动画, 不影响单测稳定性。默认 `dnd: { false }` → route 不入 pending、直接 present, 不干扰断言。

- [ ] **Step 3.8 — 运行注入测试确认通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter AppControllerTests 2>&1 | tail -12
  ```

  预期 **PASS**: `Executed 2 tests, with 0 failures`。全量回归(不加 filter)本阶段应为 `Executed 8 tests`(ReminderCore 占位 1 + Engine 5 + AppController 2)。

  > 说明: 全量 test 计数随 Task 累加变化, 各 Task 的 PASS 判据以 `--filter <本 Task 的 TestCase>` 为准(避免脆弱的全量总数断言)。累计总表见文末 Self-Review。

- [ ] **Step 3.9 — 手动端到端验证(临时把 sitThreshold 调 60s, 真实弹刘海)。** 为了不等 50 分钟, 临时改一行阈值再跑 App, 观察真弹卡片与真清零。

  1. **临时改阈值**: 打开 `Sources/NotchReminder/main.swift`, 把 Step 3.5 里那行

     ```swift
             let c = AppController(presenter: presenter)
     ```

     临时改成(仅本次验证用):

     ```swift
             var debugCfg = ReminderConfig()
             debugCfg.sitThreshold = 60          // 临时: 60s 就弹久坐, 便于验证
             debugCfg.restThreshold = 300        // 保持 5min 真休息
             let c = AppController(presenter: presenter, config: debugCfg)
     ```

  2. **构建并前台运行**:

     ```bash
     swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -3
     /Users/chunhaixu/NotchReminder/.build/debug/NotchReminder
     ```

  3. **验证 A — 连续活跃 60s 弹久坐**: App 启动后, **持续动键盘/鼠标/触控板约 70 秒**(别停手超过 5s)。由于每 10s 采样一次、sitThreshold=60s, 累计 ≥ 60s 时应看到**刘海弹出一张"该起身了"卡片**(橙色 figure.walk 图标 + "连续 N 分钟 / 起来走两步"), 约 4s 后自动收起。**✅ 验证点: 卡片真的从刘海弹出。**

  4. **验证 B — 离开 > 5min 回来计数归零**: 卡片弹过后, **完全离开键鼠 6 分钟**(idle 会超过 restThreshold=300s → 引擎把 sitAccum 清零)。6 分钟后**回来重新连续动键鼠**: 应重新从 0 开始累加, 需**再连续活跃 ~60s** 才会**再次弹**久坐卡片。**✅ 验证点: 归零生效——回来后不是立刻弹, 而是要重新攒够 60s。**

  5. **停止 App**: `Ctrl-C` 退出。

  6. **还原阈值**: 把 Step 3.9.1 临时加的三行 `debugCfg` 改回 Step 3.5 的原始接线:

     ```swift
             let c = AppController(presenter: presenter)
     ```

     (保留 Step 3.5 的 `onSitSnooze` / `AppController.shared` / `start()` 三行不变。)确认还原后仍能编译:

     ```bash
     swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -3
     ```

     预期 `Build complete!`, 且 `main.swift` 里不再残留 `debugCfg`。

  > 说明: 验证 A/B 是"数据驱动久坐"的核心行为坐实(spec §5.3)。若验证 A 刘海不弹但注入测试(Step 3.8)已绿, 问题定位在**展示层**(Task 1 的 `NotchPresenter`/DynamicNotchKit 宿主环境), 而非采样/引擎链路。

- [ ] **Step 3.10 — commit。** 确认 `main.swift` 已还原(无 `debugCfg` 残留)后执行:

  ```bash
  \
  git add Package.swift \
          Sources/NotchReminder/ActivityMonitor.swift \
          Sources/NotchReminder/AppController.swift \
          Sources/NotchReminder/NotchPresenter.swift \
          Sources/NotchReminder/main.swift \
          Tests/NotchReminderTests/AppControllerTests.swift && \
  git commit -m "Task 3: ActivityMonitor idle sampling + AppController (sole owner) + sit end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit。`git status --short` 干净(临时 debugCfg 已还原)。

---

## Task 4: 引擎扩展 —— 喝水/护眼/熬夜触发

> 前置: Task 2 已落地 `Sources/ReminderCore/Models.swift` 与 `ReminderEngine.swift`(含 dt/active/rest/sit
> 口径 + `isNight`/`clockString`), `swift test` 5 个引擎用例全绿。本 Task 在**同一个 advance 纯函数**里
> 补上 water / eye / night 三个触发分支, 并把它们排在 sit 之后、muted 抑制之前, 形成
> `[sit, water, eye, night]` 的固定产出顺序。
>
> advance 仍是纯函数(无副作用, 不 import AppKit)。先写失败测试 → 补实现 → 通过 → commit。
>
> **熬夜「阈值」的范围决定(解决 review minor):** 熬夜类唯一用户可调的「阈值」是 `nightRepeat`(重复间隔, Task 7 设置窗暴露)。
> 而触发窗口边界 `墙钟≥23:00(含 00:00–01:59)` 由 `isNight` 硬编码(`hour>=23 || hour<2`), **本版有意不暴露给用户改**——
> 它是固定的时钟规则(非时长), 故 spec §5.4「每类可调阈值」对熬夜类 = 调 `nightRepeat` 重复节奏。这是有意的范围收窄, 非缺口。

#### Files

- `Sources/ReminderCore/ReminderEngine.swift` — 本 Task 修改: 在 sit 分支后追加 water/eye/night 三分支(见 Step 4.4 最终完整版 advance)。`isNight`/`clockString` 已在 Task 2 落地, 本 Task 直接调用, 不重复定义。
- `Tests/ReminderCoreTests/ReminderEngineTests.swift` — 本 Task 追加 7 个测试方法(water 触发清零 / eye 触发清零 / night 墙钟触发 / night 重复间隔 / night 非 active 不触发 / muted 抑制 / 多提醒同序), 不改动 Task 2 已有方法。

#### Interfaces (沿用 CONTRACT §C1, 不新增类型)

签名不变:

```swift
public static func advance(_ state: ReminderState, config: ReminderConfig, sample: Sample) -> (ReminderState, [Reminder])
```

复用字段: `ReminderConfig.{waterThreshold, eyeThreshold, nightRepeat, waterEnabled, eyeEnabled, nightEnabled, mutedUntil}`、`ReminderState.{waterAccum, eyeAccum, lastNightAlert}`、`Reminder.{water, eye, night(clock:)}`。均在 Task 2 的 Models.swift 中已定义。

#### Steps

- [ ] **Step 4.1 — 追加失败测试(water/eye/night/muted/多提醒同序)。** 在 `Tests/ReminderCoreTests/ReminderEngineTests.swift` 的 `final class ReminderEngineTests` 内, 在末尾 `}` 之前追加下面的 `nightBase` 计算属性与 7 个方法(完整代码, 与 Task 2 已有方法并存):

  ```swift
      // 熬夜基准: 2026-07-07 00:47:00(isNight 命中)。
      private var nightBase: Date {
          var comps = DateComponents()
          comps.year = 2026; comps.month = 7; comps.day = 7
          comps.hour = 0; comps.minute = 47; comps.second = 0
          return Calendar.current.date(from: comps)!
      }

      func testWaterFiresAndResets() {
          let cfg = ReminderConfig()  // water 60min
          var s = ReminderState(waterAccum: cfg.waterThreshold - 5, lastSample: base)
          let t = base.addingTimeInterval(10)  // dt=10 → 越过阈值
          var r: [Reminder]
          (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0))
          XCTAssertTrue(r.contains(.water))
          XCTAssertEqual(s.waterAccum, 0)
      }

      func testEyeFiresAndResets() {
          let cfg = ReminderConfig()  // eye 30min
          var s = ReminderState(eyeAccum: cfg.eyeThreshold - 5, lastSample: base)
          let t = base.addingTimeInterval(10)
          var r: [Reminder]
          (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0))
          XCTAssertTrue(r.contains(.eye))
          XCTAssertEqual(s.eyeAccum, 0)
      }

      func testNightFiresWhenActiveAndClockInWindow() {
          let cfg = ReminderConfig()
          var s = ReminderState(lastSample: nightBase.addingTimeInterval(-10))
          var r: [Reminder]
          (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: nightBase, idleSeconds: 0))
          XCTAssertTrue(r.contains(.night(clock: "00:47")))
          XCTAssertEqual(s.lastNightAlert, nightBase)
      }

      func testNightRepeatIntervalSuppressesThenFires() {
          let cfg = ReminderConfig()  // nightRepeat 30min
          var s = ReminderState(lastSample: nightBase, lastNightAlert: nightBase)
          var r: [Reminder]
          let t1 = nightBase.addingTimeInterval(10 * 60)  // 10min(< 30min)不重复
          (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t1, idleSeconds: 0))
          XCTAssertFalse(r.contains { if case .night = $0 { return true } else { return false } })
          let t2 = t1.addingTimeInterval(25 * 60)  // 累计 35min(> 30min)应重复
          (_, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t2, idleSeconds: 0))
          XCTAssertTrue(r.contains { if case .night = $0 { return true } else { return false } })
      }

      func testNightNoFireWhenNotActive() {
          let cfg = ReminderConfig()
          let s = ReminderState(lastSample: nightBase.addingTimeInterval(-10))
          // idle 超 restThreshold、无 CC → rest(非 active)→ 不产 night
          let (_, r) = ReminderEngine.advance(
              s, config: cfg,
              sample: Sample(now: nightBase, idleSeconds: cfg.restThreshold + 1)
          )
          XCTAssertFalse(r.contains { if case .night = $0 { return true } else { return false } })
      }

      func testMutedSuppressesRemindersButKeepsTiming() {
          var cfg = ReminderConfig()
          cfg.mutedUntil = base.addingTimeInterval(3600)  // 1h 后才解除
          var s = ReminderState(waterAccum: cfg.waterThreshold - 5, eyeAccum: cfg.eyeThreshold - 5, lastSample: base)
          let t = base.addingTimeInterval(10)
          var r: [Reminder]
          (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0))
          XCTAssertTrue(r.isEmpty)  // muted → 不产出
          XCTAssertEqual(s.waterAccum, 0)  // 但 water 已触发清零(计时照常)
          XCTAssertEqual(s.eyeAccum, 0)
      }

      func testMultipleRemindersInOrder() {
          var cfg = ReminderConfig()
          cfg.sitEnabled = true; cfg.waterEnabled = true; cfg.eyeEnabled = true; cfg.nightEnabled = true
          var s = ReminderState(
              sitAccum: cfg.sitThreshold - 5,
              waterAccum: cfg.waterThreshold - 5,
              eyeAccum: cfg.eyeThreshold - 5,
              lastSample: nightBase.addingTimeInterval(-10)
          )
          let t = nightBase  // isNight 命中, active
          var r: [Reminder]
          (s, r) = ReminderEngine.advance(s, config: cfg, sample: Sample(now: t, idleSeconds: 0, project: "P"))
          XCTAssertEqual(r.count, 4)  // 顺序: sit, water, eye, night
          if case .sit = r[0] {} else { XCTFail("r[0] should be .sit") }
          XCTAssertEqual(r[1], .water)
          XCTAssertEqual(r[2], .eye)
          if case .night = r[3] {} else { XCTFail("r[3] should be .night") }
      }
  ```

- [ ] **Step 4.2 — 运行确认失败。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter ReminderEngineTests 2>&1 | tail -20
  ```

  预期 **FAIL**: 至少 `testWaterFiresAndResets` / `testEyeFiresAndResets` / `testNightFiresWhenActiveAndClockInWindow` / `testMultipleRemindersInOrder` 断言失败(Task 2 的 advance 只产 sit)。典型报错: `XCTAssertTrue failed`; 多提醒用例 `XCTAssertEqual(r.count, 4)` 得到 1。

- [ ] **Step 4.3 — 补实现: 在 advance 的 sit 分支后追加 water/eye/night 三分支。** 打开 `Sources/ReminderCore/ReminderEngine.swift`, 找到 Task 2 里 sit 分支结尾(`newState.lastSitAlert = now` 那个 `if` 块的闭合 `}`)与 muted 抑制块之间, 插入 water / eye / night 三分支。改完后整个 `advance` 应与 Step 4.4 的最终完整版**逐字一致**。

- [ ] **Step 4.4 — 最终完整版 `ReminderEngine.swift`(逐字替换整份文件)。** 为避免手工插桩出错, 直接用下面这份**完整可编译**的最终版覆盖 `Sources/ReminderCore/ReminderEngine.swift`:

  ```swift
  import Foundation

  /// 纯逻辑状态机。无副作用、不依赖 AppKit, 可 `swift test`。
  public enum ReminderEngine {

      /// 墙钟是否处于「熬夜」窗口: hour >= 23 或 hour < 2(即 23:00–01:59)。窗口边界固定, 不暴露给用户调(见 Task 4 范围说明)。
      public static func isNight(_ now: Date, calendar: Calendar = .current) -> Bool {
          let hour = calendar.component(.hour, from: now)
          return hour >= 23 || hour < 2
      }

      /// 把时间格式化为 "HH:mm"(24 小时制, 本地时区)。
      public static func clockString(_ now: Date, calendar: Calendar = .current) -> String {
          let comps = calendar.dateComponents([.hour, .minute], from: now)
          let hour = comps.hour ?? 0
          let minute = comps.minute ?? 0
          return String(format: "%02d:%02d", hour, minute)
      }

      /// 纯函数: 喂入当前状态 + 配置 + 一次采样, 返回更新后状态与本次要产出的提醒列表。
      ///
      /// 计时口径(spec §5.3):
      /// - dt = lastSample==nil ? 0 : now - lastSample; dt<0 视为 0; dt>restThreshold 视为休眠(按真休息处理)。
      /// - byInput = idleSeconds < activeIdleCeiling
      /// - byCC = ccActive && ccLastEvent!=nil && (now-ccLastEvent) < ccGrace
      /// - active = byInput || byCC
      /// - rest = (idleSeconds>=restThreshold && !byCC) || dt>restThreshold
      /// - rest: sitAccum=0、eyeAccum=0, water 暂停(不加不清)。
      /// - active(非 rest): 三累加 += dt。
      /// - 灰区(既非 active 也非 rest): 三累加不变。
      ///
      /// 触发(muted 时计时照常但不产出任何 Reminder, 见 §5.4), 按 sit,water,eye,night 顺序 append。
      public static func advance(
          _ state: ReminderState,
          config: ReminderConfig,
          sample: Sample
      ) -> (ReminderState, [Reminder]) {
          var newState = state
          let now = sample.now

          // ---- 1) dt ----
          var dt: TimeInterval
          if let last = state.lastSample {
              dt = now.timeIntervalSince(last)
          } else {
              dt = 0
          }
          if dt < 0 { dt = 0 }
          let dormant = dt > config.restThreshold  // 长时间未采样(休眠) → 按真休息

          // ---- 2) active / rest 判定 ----
          let byInput = sample.idleSeconds < config.activeIdleCeiling
          let byCC: Bool = {
              guard sample.ccActive, let ccLast = sample.ccLastEvent else { return false }
              return now.timeIntervalSince(ccLast) < config.ccGrace
          }()
          let active = byInput || byCC
          let rest = (sample.idleSeconds >= config.restThreshold && !byCC) || dormant

          // ---- 3) 计时器推进 ----
          if rest {
              newState.sitAccum = 0
              newState.eyeAccum = 0
              // water: 暂停累加, 不加不清
          } else if active {
              newState.sitAccum += dt
              newState.eyeAccum += dt
              newState.waterAccum += dt
          }
          // 灰区: 三累加均不变

          newState.lastSample = now

          // ---- 4) 触发判断(顺序: sit, water, eye, night) ----
          var reminders: [Reminder] = []

          // sit
          if config.sitEnabled && newState.sitAccum >= config.sitThreshold {
              let snoozeOK: Bool = {
                  guard let lastAlert = newState.lastSitAlert else { return true }
                  return now.timeIntervalSince(lastAlert) >= config.sitSnooze
              }()
              if snoozeOK {
                  reminders.append(.sit(minutes: Int(newState.sitAccum / 60), project: sample.project))
                  newState.lastSitAlert = now  // 不清 sitAccum
              }
          }

          // water
          if config.waterEnabled && newState.waterAccum >= config.waterThreshold {
              reminders.append(.water)
              newState.waterAccum = 0
          }

          // eye
          if config.eyeEnabled && newState.eyeAccum >= config.eyeThreshold {
              reminders.append(.eye)
              newState.eyeAccum = 0
          }

          // night
          if config.nightEnabled && active && isNight(now) {
              let repeatOK: Bool = {
                  guard let lastAlert = newState.lastNightAlert else { return true }
                  return now.timeIntervalSince(lastAlert) >= config.nightRepeat
              }()
              if repeatOK {
                  reminders.append(.night(clock: clockString(now)))
                  newState.lastNightAlert = now
              }
          }

          // ---- 5) muted 抑制产出(计时已照常推进) ----
          if let mutedUntil = config.mutedUntil, now < mutedUntil {
              return (newState, [])
          }

          return (newState, reminders)
      }
  }
  ```

- [ ] **Step 4.5 — 运行确认通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter ReminderEngineTests 2>&1 | tail -8
  ```

  预期 **PASS**: `Executed 12 tests, with 0 failures`(Task 2 的 5 个 + 本 Task 追加的 7 个)。

- [ ] **Step 4.6 — commit。** 执行:

  ```bash
  \
  git add Sources/ReminderCore/ReminderEngine.swift Tests/ReminderCoreTests/ReminderEngineTests.swift && \
  git commit -m "Task 4: engine water/eye/night triggers + muted suppression

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 2 个文件纳入版本。

---

## Task 5: NotchPresenter 强/轻样式 + auto-hide + 免打扰探针接线

> 前置: Task 2 + Task 4 已落地 `Sources/ReminderCore/`(`Reminder` 枚举 + `advance` 纯函数, 12 个 XCTest 全绿)。
> Task 3 已落地 `NotchPresenter`(`public final class`, 已有占位 `present(_:onAction:)` + `SitAction`)、
> `AppController`(CONTRACT §C3 完整三面, 含 `route`/`flushPending`/`pending`/`onSitSnooze` 与注入的 `FullscreenProbe`,
> 默认 `dnd: { false }`)、`Package.swift` 已含 `NotchReminderTests` test target(CONTRACT §C4)。
>
> 本 Task 把四类 `Reminder` 的**渲染样式升级**并**补上真全屏探针**:
> - **强样式**(`sit` / `night`): 自定义 SwiftUI 视图(带「起身5分钟」/「知道了」按钮 + 回调), 用 `DynamicNotch { ... }` 便捷初始化器展示。
> - **轻样式**(`water` / `eye`): `DynamicNotchInfo(...).expand()`, 停留 ~4s 后 `hide()`(库无内建 auto-hide)。
> - **免打扰探针**: `DoNotDisturb.muteFor/isMuted`(纯时间, 可单测)+ `isFullscreenActive()`(CGWindowList 近似)。摄像头占用检测**本版不做**(spec §8 `待验证`, 标 v2, 属 YAGNI)。
> - **AppController 接线(Modify, 非 Create)**: 把 Task 3 里 `AppController.init` 的 `dnd` 默认值从 `{ false }` 改成 `DoNotDisturb.isFullscreenActive`。route/pending/flushPending 逻辑 Task 3 已实现, 本 Task **不重写 AppController**, 只改这一个默认值 + 把 `present(_:onAction:)` 升级为真强/轻样式。
>
> **本 Task 明确不重复 Create `AppController.swift`**(CONTRACT §C3: Task 3 是唯一 owner)。`NotchPresenter.swift` 本 Task **整份重写**(用真强/轻样式取代 Task 1/3 的占位 `showTest`/`present`), 保持 `public final class NotchPresenter` + `public init()` + `present(_:onAction:)` 签名不变(CONTRACT §C2)。
>
> 每步「写代码 → `swift build` → 手动验证 → commit」, 严格按已核实的 DynamicNotchKit 1.1.0 API。

#### Files

**Create**

- `Sources/NotchReminder/StrongReminderView.swift` — 强样式自定义 SwiftUI 视图(标题 + 两个按钮)。
- `Sources/NotchReminder/DoNotDisturb.swift` — 静音入口(`muteFor` / `isMuted`)+ `isFullscreenActive()`(CGWindowList 近似)。
- `Tests/NotchReminderTests/DoNotDisturbTests.swift` — `DoNotDisturb.muteFor`/`isMuted` 时间口径单测。
- `Tests/NotchReminderTests/AppControllerReplayTests.swift` — pending 重放逻辑单测(注入假 `FullscreenProbe`)。

**Modify**

- `Sources/NotchReminder/NotchPresenter.swift` — **整份重写**: `present(_:onAction:)` 升级为真强/轻样式(强样式用 `DynamicNotch { StrongReminderView(...) }`)。签名/可访问性不变(CONTRACT §C2)。Task 1 的 `showTest()` 被本次重写取代(不再需要)。
- `Sources/NotchReminder/AppController.swift`(Task 3 产) — **仅改 `init` 的 `dnd` 默认值**为 `DoNotDisturb.isFullscreenActive`。不动 route/flushPending/pending/tick 逻辑。
- `Package.swift` — 确认 `NotchReminderTests` test target 已存在(Task 3 按 CONTRACT §C4 已加), 若缺才补同一份;通常本步跳过。

#### Interfaces

**Consumes**(来自 CONTRACT §C1/§C3, 逐字对齐, 不得改动):

```swift
public enum Reminder: Equatable { case sit(minutes: Int, project: String?); case water; case eye; case night(clock: String) }
public enum SitAction: Equatable { case snooze; case dismiss }            // Task 3 已定义(CONTRACT §C2)
public typealias FullscreenProbe = () -> Bool                              // Task 3 已定义(CONTRACT §C3)
@MainActor public final class AppController { /* route/flushPending/pending/onSitSnooze 已由 Task 3 实现 */ }
```

**Consumes**(来自 DynamicNotchKit 1.1.0, 已核实源码; @MainActor 归属见 CONTRACT §C6):

```swift
// 便捷初始化器: 仅 expanded, 尾随闭包无实参标签
DynamicNotch { <SwiftUI View> }
// Info 卡片: icon 是 DynamicNotchInfo.Label? 类型(非 Image/String), title 是 LocalizedStringKey
DynamicNotchInfo(icon: DynamicNotchInfo.Label?, title: LocalizedStringKey, description: LocalizedStringKey? = nil)
DynamicNotchInfo.Label(systemName: String, color: Color)
// 展开/收起(均 async, 经 DynamicNotchControllable 协议 @MainActor; 无 toggle()/无 show(); init 非 @MainActor)
func expand(on screen: NSScreen = NSScreen.screens[0]) async
func hide() async
```

**Produces**(本 Task 定义, 下游 Task 6/7 复用):

```swift
public enum DoNotDisturb {
    /// 从 now 起静音 seconds 秒, 返回应写入 ReminderConfig.mutedUntil 的时间。
    public static func muteFor(_ seconds: TimeInterval, now: Date = Date()) -> Date
    /// mutedUntil 是否仍在生效(now < mutedUntil)。
    public static func isMuted(_ mutedUntil: Date?, now: Date = Date()) -> Bool
    /// best-effort: 当前是否有 App 处于全屏(演示/看片/会议)。CGWindowList 近似。
    public static func isFullscreenActive() -> Bool
}
```

> `NotchPresenter.present(_:onAction:)` 与 `AppController.route/flushPending/onSitSnooze/pending` 的签名保持 CONTRACT §C2/§C3 不变——本 Task 只改实现, 不改接口。

#### Steps

- [ ] **Step 5.1 — 整份重写 `NotchPresenter.swift`(强/轻样式 + present 分发)。** 用下面完整可编译代码**覆盖** `Sources/NotchReminder/NotchPresenter.swift`(取代 Task 1 的 `showTest()` 与 Task 3 的占位 `present`)。要点: `present` 按 `Reminder` 分四支; 强样式(sit/night)用 `DynamicNotch { StrongReminderView(...) }`, 文案用 `Text(verbatim:)` 承载运行时插值; 轻样式(water/eye)用 `DynamicNotchInfo` + `.expand()` 后 `Task.sleep(autoHideSeconds)` 再 `hide()`。`SitAction` 已在 Task 3 定义于本文件(CONTRACT §C2), 重写时**保留 `SitAction` 定义**:

  ```swift
  import SwiftUI
  import DynamicNotchKit
  import ReminderCore

  /// 强样式浮层上「起身5分钟」/「知道了」两个按钮对应的动作(CONTRACT §C2)。
  public enum SitAction: Equatable {
      case snooze   // 起身5分钟: 记真休息意图(由 AppController 清 sit 计时)
      case dismiss  // 知道了: 仅收起
  }

  /// 封装 DynamicNotchKit 的强/轻样式渲染。整类 @MainActor: 库的展开/收起方法均 @MainActor 隔离(经协议)。
  @MainActor
  public final class NotchPresenter {
      /// 轻样式停留时长(秒)。expand() 自身另含 ~0.4s 动画等待, 此为额外停留。
      private let autoHideSeconds: TimeInterval = 4

      /// 当前强样式浮层实例。持有引用以便按钮回调里 hide, 以及被下一条强提醒替换时先收起旧的。
      private var strongNotch: DynamicNotch<StrongReminderView, EmptyView, EmptyView>?

      public init() {}

      /// 唯一对外渲染入口(CONTRACT §C2)。把一条 Reminder 映射到刘海浮层。
      public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
          switch r {
          case let .sit(minutes, project):
              presentStrong(
                  title: sitTitle(minutes: minutes, project: project),
                  subtitle: "起来走两步, 眼睛也歇歇",
                  showSnooze: true,
                  onAction: onAction
              )
          case let .night(clock):
              presentStrong(
                  title: "\(clock) 了",
                  subtitle: "明天的你会感谢现在睡觉的你",
                  showSnooze: false,
                  onAction: onAction
              )
          case .water:
              presentLight(systemName: "drop.fill", color: .blue, title: "喝口水", description: "补个水, 顺手站一下")
          case .eye:
              presentLight(systemName: "eye.fill", color: .green, title: "远眺 20 秒", description: "看向 6 米外, 放松睫状肌")
          }
      }

      // MARK: - 强样式

      private func presentStrong(
          title: String,
          subtitle: String,
          showSnooze: Bool,
          onAction: ((SitAction) -> Void)?
      ) {
          // 先收起上一条强提醒(若有), 避免叠放。
          if let old = strongNotch {
              Task { @MainActor in await old.hide() }
          }
          let notch = DynamicNotch {
              StrongReminderView(
                  title: title,
                  subtitle: subtitle,
                  showSnooze: showSnooze,
                  onSnooze: { [weak self] in
                      onAction?(.snooze)
                      self?.dismissStrong()
                  },
                  onDismiss: { [weak self] in
                      onAction?(.dismiss)
                      self?.dismissStrong()
                  }
              )
          }
          strongNotch = notch
          Task { @MainActor in await notch.expand() }
      }

      private func dismissStrong() {
          guard let notch = strongNotch else { return }
          strongNotch = nil
          Task { @MainActor in await notch.hide() }
      }

      // MARK: - 轻样式

      private func presentLight(systemName: String, color: Color, title: LocalizedStringKey, description: LocalizedStringKey) {
          let info = DynamicNotchInfo(
              icon: .init(systemName: systemName, color: color),
              title: title,
              description: description
          )
          Task { @MainActor in
              await info.expand()                                   // 内含 ~0.4s 动画
              try? await Task.sleep(for: .seconds(autoHideSeconds)) // 额外停留
              await info.hide()
          }
      }

      // MARK: - 文案

      private func sitTitle(minutes: Int, project: String?) -> String {
          if let p = project, !p.isEmpty {
              return "连续 \(minutes) 分钟了 · \(p) 项目"
          }
          return "连续 \(minutes) 分钟了"
      }
  }
  ```

- [ ] **Step 5.2 — 写 `StrongReminderView.swift`(强样式自定义视图 + 按钮回调)。** 新建 `Sources/NotchReminder/StrongReminderView.swift`。用 `Text(verbatim:)` 显示运行时插值文案; `showSnooze` 为 false 时(熬夜)只显示「知道了」。

  ```swift
  import SwiftUI

  /// 强样式浮层内容: 标题 + 副标题 + 一到两个按钮。
  /// 用 Text(verbatim:) 承载运行时插值文案, 避免 LocalizedStringKey 本地化查表。
  struct StrongReminderView: View {
      let title: String
      let subtitle: String
      let showSnooze: Bool
      let onSnooze: () -> Void
      let onDismiss: () -> Void

      var body: some View {
          VStack(alignment: .leading, spacing: 8) {
              Text(verbatim: title)
                  .font(.headline)
                  .foregroundStyle(.primary)
              Text(verbatim: subtitle)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              HStack(spacing: 10) {
                  if showSnooze {
                      Button(action: onSnooze) {
                          Text(verbatim: "起身5分钟")
                      }
                      .buttonStyle(.borderedProminent)
                  }
                  Button(action: onDismiss) {
                      Text(verbatim: "知道了")
                  }
                  .buttonStyle(.bordered)
              }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .frame(maxWidth: 360)
      }
  }
  ```

- [ ] **Step 5.3 — 写 `DoNotDisturb.swift`(静音入口 + 全屏近似检测)。** 新建 `Sources/NotchReminder/DoNotDisturb.swift`。`muteFor`/`isMuted` 是纯时间计算(可单测); `isFullscreenActive()` 用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 近似。给出完整代码:

  ```swift
  import Foundation
  import CoreGraphics
  import AppKit

  public enum DoNotDisturb {

      // MARK: - 手动静音(可靠部分; 写入 ReminderConfig.mutedUntil, 供 Task 7 菜单栏调用)

      /// 从 now 起静音 seconds 秒, 返回应写入 ReminderConfig.mutedUntil 的时间点。
      public static func muteFor(_ seconds: TimeInterval, now: Date = Date()) -> Date {
          return now.addingTimeInterval(seconds)
      }

      /// mutedUntil 是否仍在生效: 非 nil 且 now < mutedUntil。
      public static func isMuted(_ mutedUntil: Date?, now: Date = Date()) -> Bool {
          guard let until = mutedUntil else { return false }
          return now < until
      }

      // MARK: - 全屏近似(best-effort; spec §5.4 免打扰。摄像头占用检测本版不做, 见 §8/§9 v2)

      /// 当前是否有 App 处于全屏(演示 / 看片 / 会议)。CGWindowList 近似, 非精确。
      /// 判据: 存在一个普通层级(kCGWindowLayer==0)、有归属进程、且 bounds 完整覆盖某块屏 frame 的窗口。
      /// 全屏 App 会占满整屏并遮住菜单栏, 其窗口 bounds ≈ 该屏 CGDisplayBounds。
      public static func isFullscreenActive() -> Bool {
          let option: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
          guard let infoList = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
              return false
          }
          // 收集所有屏的 CGDisplayBounds(全局坐标, 原点左上)。
          let screenFrames: [CGRect] = NSScreen.screens.compactMap { screen in
              guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                  return nil
              }
              return CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
          }
          guard !screenFrames.isEmpty else { return false }

          for info in infoList {
              // 只看普通层(全屏 App 内容窗口在 layer 0; 菜单栏/Dock 等在非 0 层)。
              let layer = (info[kCGWindowLayer as String] as? Int) ?? Int.min
              guard layer == 0 else { continue }
              // 必须有归属进程(排除系统装饰窗口)。
              guard (info[kCGWindowOwnerPID as String] as? Int) != nil else { continue }
              guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                    let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                  continue
              }
              // 该窗口是否覆盖了某整块屏(允许 1pt 误差)。
              for frame in screenFrames where coversFullScreen(window: rect, screen: frame) {
                  return true
              }
          }
          return false
      }

      /// 窗口是否近似覆盖整块屏(原点重合、宽高不小于屏)。
      private static func coversFullScreen(window: CGRect, screen: CGRect) -> Bool {
          let tol: CGFloat = 1
          return abs(window.origin.x - screen.origin.x) <= tol
              && abs(window.origin.y - screen.origin.y) <= tol
              && window.width >= screen.width - tol
              && window.height >= screen.height - tol
      }
  }
  ```

- [ ] **Step 5.4 — Modify `AppController.swift`: 把 `dnd` 默认值切到真探针。** 打开 `Sources/NotchReminder/AppController.swift`(Task 3 产)。**只改一处**: `init` 里 `dnd` 参数的默认值:

  从(Task 3):
  ```swift
          dnd: @escaping FullscreenProbe = { false }   // Task 5 改为 DoNotDisturb.isFullscreenActive
  ```
  改为:
  ```swift
          dnd: @escaping FullscreenProbe = DoNotDisturb.isFullscreenActive
  ```

  **不动** route / flushPending / pending / tick / onSitSnooze——它们 Task 3 已按 CONTRACT §C3 实现(全屏 → pending;每次 tick 开头 flushPending 自动补放;snooze→onSitSnooze→manualRest)。本 Task 至此让运行期 App 真正接上全屏探针: tick() 里 route 用真 `DoNotDisturb.isFullscreenActive`, 全屏期间提醒进 pending, 退出全屏后下一拍 tick 的 flushPending 自动补放(spec §5.4 auto-resume 在真运行 App 里生效, 见 Step 5.11 验证)。

- [ ] **Step 5.5 — 确认 `Package.swift` 已有 test target(CONTRACT §C4)。** Task 3 应已按 §C4 追加 `NotchReminderTests`(含 `ReminderCore` 依赖 + path)。执行核对:

  ```bash
  grep -A3 'NotchReminderTests' /Users/chunhaixu/NotchReminder/Package.swift
  ```

  预期看到 `dependencies: ["NotchReminder", "ReminderCore"]` + `path: "Tests/NotchReminderTests"`。若缺, 按 CONTRACT §C4 补同一份(不用别的形状)。

- [ ] **Step 5.6 — 写 `DoNotDisturbTests.swift`(muteFor/isMuted 口径单测)。** 新建 `Tests/NotchReminderTests/DoNotDisturbTests.swift`。只测纯时间函数(`isFullscreenActive` 依赖真窗口列表, 靠 Step 5.11 手动验证)。

  ```swift
  import XCTest
  @testable import NotchReminder

  final class DoNotDisturbTests: XCTestCase {
      private let base = Date(timeIntervalSince1970: 1_800_000_000)

      func testMuteForReturnsFutureDeadline() {
          let until = DoNotDisturb.muteFor(3600, now: base)
          XCTAssertEqual(until, base.addingTimeInterval(3600))
      }

      func testIsMutedTrueBeforeDeadline() {
          let until = base.addingTimeInterval(3600)
          XCTAssertTrue(DoNotDisturb.isMuted(until, now: base))
          XCTAssertTrue(DoNotDisturb.isMuted(until, now: base.addingTimeInterval(3599)))
      }

      func testIsMutedFalseAtOrAfterDeadline() {
          let until = base.addingTimeInterval(3600)
          XCTAssertFalse(DoNotDisturb.isMuted(until, now: until))            // now == until 不算静音
          XCTAssertFalse(DoNotDisturb.isMuted(until, now: base.addingTimeInterval(3601)))
      }

      func testIsMutedFalseWhenNil() {
          XCTAssertFalse(DoNotDisturb.isMuted(nil, now: base))
      }
  }
  ```

- [ ] **Step 5.7 — 写 `AppControllerReplayTests.swift`(pending 重放单测)。** 新建 `Tests/NotchReminderTests/AppControllerReplayTests.swift`。注入受控 `FullscreenProbe`, 断言全屏时 route 入 pending、非全屏时不入; flushPending 在非全屏时清空、全屏时保留。因 `AppController` / `NotchPresenter` 是 `@MainActor`, 测试方法标 `@MainActor`。**用 Task 3 的 `init(presenter:dnd:)`(其余参数用默认)构造。**

  ```swift
  import XCTest
  @testable import NotchReminder
  import ReminderCore

  @MainActor
  final class AppControllerReplayTests: XCTestCase {

      func testFullscreenRoutesToPending() {
          let controller = AppController(presenter: NotchPresenter(), dnd: { true })
          controller.route([.water, .eye])
          XCTAssertEqual(controller.pending, [.water, .eye])
      }

      func testNonFullscreenDoesNotQueue() {
          let controller = AppController(presenter: NotchPresenter(), dnd: { false })
          controller.route([.water])
          XCTAssertTrue(controller.pending.isEmpty)
      }

      func testFlushPendingClearsWhenNotFullscreen() {
          var fullscreen = true
          let controller = AppController(presenter: NotchPresenter(), dnd: { fullscreen })
          controller.route([.water, .eye])   // 全屏 → 入队
          XCTAssertEqual(controller.pending.count, 2)
          fullscreen = false
          controller.flushPending()           // 结束 → 补放并清空
          XCTAssertTrue(controller.pending.isEmpty)
      }

      func testFlushPendingKeepsWhenStillFullscreen() {
          let controller = AppController(presenter: NotchPresenter(), dnd: { true })
          controller.route([.water])          // 全屏 → 入队
          controller.flushPending()           // 仍全屏 → 保留
          XCTAssertEqual(controller.pending, [.water])
      }
  }
  ```

  > 注: `AppController(presenter:dnd:)` 用 Task 3 定义的 `init`(`config`/`idleProvider`/`clock` 取默认值, 只显式传 `presenter` 与 `dnd`)。构造不碰 `AppController.shared`(它只在真 App 启动时赋值)。

- [ ] **Step 5.8 — 解析依赖并构建, 确认编译通过。** 先让 SPM 拉取 DynamicNotchKit(若尚未), 再 build:

  ```bash
  swift package --package-path /Users/chunhaixu/NotchReminder resolve 2>&1 | tail -10
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -20
  ```

  预期 **PASS**: `swift build` 以 `Build complete!` 结束, 无 `no such module` / 无 `value of type 'DynamicNotch...' has no member 'toggle'`。

  > 排错锚点(据核实的 API 常见误用): 若报 `cannot find 'toggle'`/`'show'` → 只能用 `expand`/`hide`; 若报 icon 类型不符 → `icon:` 必须 `.init(systemName:color:)` 而非传 String/Image; 若报 `expand` 需 `await`/actor 隔离 → 确认调用点在 `Task { @MainActor in ... }` 内。

- [ ] **Step 5.9 — 运行确认单测通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter DoNotDisturbTests 2>&1 | tail -6
  swift test --package-path /Users/chunhaixu/NotchReminder --filter AppControllerReplayTests 2>&1 | tail -6
  ```

  预期 **PASS**: `DoNotDisturbTests` 4 个 + `AppControllerReplayTests` 4 个全绿(各自 `Executed 4 tests, with 0 failures`)。全量回归本阶段累计 20 个用例(累计总表见文末 Self-Review)。

- [ ] **Step 5.10 — (可选) 全量回归。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -8
  ```

  预期本阶段全量 `Executed 20 tests, with 0 failures`(ReminderCore 占位 1 + Engine 12 + AppController 2 + DoNotDisturb 4 + Replay 4 = 23? 见下)。

  > **计数口径(解决 review major):** 各 Task 的硬 PASS 判据一律用 `--filter <本 Task TestCase>`, 不依赖脆弱的全量总数。全量总数会随 Task 累加, 权威累计表见文末 Self-Review 的「测试累计表」。本阶段全量 = 占位 1 + Engine 12 + AppControllerTests 2 + DoNotDisturbTests 4 + AppControllerReplayTests 4 = 23。

- [ ] **Step 5.11 — 手动验证: 全屏静默 + 轻样式 4s 自动收 + 强样式按钮生效。** 单测无法覆盖真刘海浮层与 CGWindowList, 需在真机跑一个临时验证入口。**首选用 SPM 原生 `swift run` 跑临时 main**(比手工 swiftc 链接稳):

  1. **临时把验证入口拷成 `Sources/NotchReminder/main.swift.bak` 之外的临时 main**。因正式 `main.swift` 已是 App 入口, 用**临时改名法**避免冲突:

     ```bash
     # 备份正式入口, 用临时验证 main 顶替
     cp /Users/chunhaixu/NotchReminder/Sources/NotchReminder/main.swift /tmp/main.swift.real
     cat > /Users/chunhaixu/NotchReminder/Sources/NotchReminder/main.swift <<'SWIFT'
     import AppKit
     import ReminderCore

     let app = NSApplication.shared
     app.setActivationPolicy(.accessory)

     let d = MainActor.assumeIsolated { () -> NotchPresenter in NotchPresenter() }
     Task { @MainActor in
         let presenter = d
         print("isFullscreenActive =", DoNotDisturb.isFullscreenActive())      // (a) 全屏探针自检
         print("present water @", Date())
         presenter.present(.water, onAction: nil)                              // (b) 轻样式 ~4s 自动收
         try? await Task.sleep(for: .seconds(6))
         print("present sit @", Date())
         presenter.present(.sit(minutes: 92, project: "SoulApp")) { action in  // (c) 强样式带按钮, 不自动收
             print("sit action =", action)
         }
         // (d) 全屏静默: 构造注入 true 探针的 controller, 断言 pending
         let c = AppController(presenter: presenter, dnd: { true })
         c.route([.water])
         print("pending(while fullscreen) =", c.pending)                       // 期望 [ReminderCore.Reminder.water]
     }
     app.run()
     SWIFT
     ```

  2. **前台运行**(直接看刘海 + Ctrl-C 退出):

     ```bash
     swift run --package-path /Users/chunhaixu/NotchReminder NotchReminder
     ```

  3. **逐项肉眼核对**(在有物理刘海的本机屏幕上观察):
     - ☑ 运行后刘海处**弹出 water 轻样式卡片**(水滴图标 + 「喝口水」), 约 **4 秒后自动收起**(叠加库内 ~0.4s 动画, 实测 4–4.5s 属正常)。
     - ☑ 再过约 6 秒**弹出 sit 强样式卡片**, 含「连续 92 分钟了 · SoulApp 项目」标题 + **「起身5分钟」「知道了」两个按钮**, 且**不自动收起**(等点击)。
     - ☑ 点「起身5分钟」→ 终端打印 `sit action = snooze` 且卡片收起; 重跑点「知道了」→ 打印 `sit action = dismiss` 且卡片收起。
     - ☑ 终端打印 `pending(while fullscreen) = [ReminderCore.Reminder.water]`(注入 true 探针 → route 入 pending、无浮层弹出), 证明全屏静默逻辑成立。
     - ☑ **真运行 auto-resume 验证(spec §5.4)**: 用正式入口(下一步还原后)跑 App, 把某 App 切全屏, 观察全屏期间提醒不弹、退出全屏后下一拍(≤10s)自动补放——因 tick() 开头 flushPending 已接线。

  4. **还原正式入口**(务必):

     ```bash
     cp /tmp/main.swift.real /Users/chunhaixu/NotchReminder/Sources/NotchReminder/main.swift
     rm -f /tmp/main.swift.real
     grep -q 'AppController.shared = c' /Users/chunhaixu/NotchReminder/Sources/NotchReminder/main.swift && echo "OK: 正式 main.swift 已还原" || echo "WARN: main.swift 还原异常, 手动检查"
     swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -3
     ```

     预期打印 `OK: 正式 main.swift 已还原` + `Build complete!`。

  > 若本机无法进入全屏或无物理刘海屏可观察, 至少完成 (b)(c) 的浮层与按钮验证 + 终端打印自检; 全屏静默/auto-resume 在 CI/远程环境标记「需真机复验」不阻塞 commit。
  > 说明(避坑): **不首选 `swiftc` 手工链接 `.build/release` 产物**——executableTarget 产出可执行文件而非 `.a`/`.dylib`, `-lNotchReminder` 极易报 `library not found`/`no such module`。故上面直接用 `swift run` 顶替临时 main。

- [ ] **Step 5.12 — commit。** 确认正式 `main.swift` 已还原后执行:

  ```bash
  \
  git add Package.swift \
          Sources/NotchReminder/NotchPresenter.swift \
          Sources/NotchReminder/StrongReminderView.swift \
          Sources/NotchReminder/DoNotDisturb.swift \
          Sources/NotchReminder/AppController.swift \
          Tests/NotchReminderTests/DoNotDisturbTests.swift \
          Tests/NotchReminderTests/AppControllerReplayTests.swift && \
  git commit -m "Task 5: NotchPresenter strong/light styles + auto-hide + do-not-disturb probe

- strong style (sit/night): custom SwiftUI view with snooze/dismiss buttons via DynamicNotch { }
- light style (water/eye): DynamicNotchInfo expand + Task.sleep 4s + hide (no built-in auto-hide)
- DoNotDisturb: manual mute (muteFor/isMuted) + isFullscreenActive() CGWindowList approximation
- AppController: switch dnd default to real fullscreen probe (route/pending/flushPending from Task 3)
- camera-occupancy detection intentionally deferred to v2 (spec section 8)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 7 个文件纳入版本(临时验证 main 已还原, 不在其中)。

#### 备注(feasibility 标签, 逐条据核实事实)

- **auto-hide**(`已验证`): DynamicNotchKit 1.1.0 **无内建定时收起 API**, `expand()/hide()` 均 async + `@MainActor`(经协议)。轻样式用 `expand()` → `Task.sleep(4s)` → `hide()`, `expand()` 自身另含 ~0.4s 动画等待。
- **强样式 API**(`已验证`): 用便捷初始化器 `DynamicNotch { StrongReminderView(...) }`(尾随闭包无实参标签, 泛型自动约束两个 compact 为 `EmptyView` → 类型 `DynamicNotch<StrongReminderView, EmptyView, EmptyView>`)。**无 `toggle()`/`show()`**, 只能 `expand`/`hide`。运行时插值文案用 `Text(verbatim:)`。
- **DynamicNotchInfo.icon**(`已验证`): 类型是 `DynamicNotchInfo.Label?`, 必须 `.init(systemName:color:)` 构造。`title`/`description` 是 `LocalizedStringKey`(水/眼文案为静态字面量, 安全)。**init 非 @MainActor**(见 CONTRACT §C6), 但 `NotchPresenter` 整类 @MainActor 承载 await expand/hide, 安全。
- **全屏检测**(`待真机复验`): `isFullscreenActive()` 是 CGWindowList **近似**(某普通层窗口 bounds 覆盖整屏), 留 1pt 容差。真机需按 Step 5.11(3) 复验一次。
- **auto-resume**(`已接线, 待真机复验`): tick() 开头调 flushPending(Task 3 已实现), 全屏退出后下一拍自动补放。真运行验证见 Step 5.11(3) 最后一条。
- **摄像头占用检测**(`v2 · 不做`): spec §8 标 `待验证`、§9 YAGNI。本版**明确不做**——范围决策, 非占位。全屏检测已覆盖演示/看片/全屏会议主要场景。

---

## Task 6: CC 插件(传感器) + CCSignalReader + 接入采样

> 前置: Task 1 已建好 SPM 工程(根 `Package.swift`, 库 target `ReminderCore` + 可执行 target
> `NotchReminder`); Task 2/4 已落地 `ReminderCore` 的 `Sample`/`ReminderConfig`/`ReminderState`/
> `Reminder` 与纯函数 `advance`(引擎 12 用例全绿); Task 3 已落地
> `Sources/NotchReminder/AppController.swift`(菜单栏 accessory App + 每 ~10s 采样循环 `tick()`, 循环里
> 用系统 idle 秒数构造 `Sample` 调 `ReminderEngine.advance`——CONTRACT §C3 owner);
> `Package.swift` 已含 `NotchReminderTests` test target(CONTRACT §C4)。
>
> 本 Task 做三件事:
> 1. **CC 插件(纯传感器)** — 4 个 hook(SessionStart / UserPromptSubmit / Stop / SessionEnd)都调一个
>    Python 脚本, 把活跃信号原子写进 `~/.notchreminder/cc.json`(spec §5.2 契约)。
> 2. **CCSignalReader** — App 侧读并解析 `cc.json`, 容错缺失/损坏返回 `nil`(可注入路径便于单测)。
> 3. **接入采样(Modify AppController)** — 在 `AppController.tick()` 构造 `Sample` 处填入 `CCSignalReader.read()` 的
>    `ccActive` / `ccLastEvent` / `project`。**只改 tick() 里 Sample 构造这一处**, 不动 Task 3 的采样循环/route/pending。
>
> **插件名 = `notchreminder`(CONTRACT §C5, 无连字符)**, 与 Task 8 的 marketplace/install 全链路一致。
> Python 脚本与 CCSignalReader 都是纯逻辑, 先写失败测试再补实现(TDD)。

#### Files

Create:
- `cc-plugin/.claude-plugin/plugin.json` — 插件清单(`name` = `notchreminder`, CONTRACT §C5)。
- `cc-plugin/hooks/hooks.json` — 声明 4 个 hook, 均调 `touch_activity.py`(wrapper 格式 `{"hooks":{...}}`)。
- `cc-plugin/hooks/touch_activity.py` — 唯一逻辑: 读 stdin JSON → 更新 `~/.notchreminder/cc.json`(原子写)。
- `cc-plugin/hooks/test_touch_activity.py` — Python 单测(`unittest`, 标准库), 喂假 stdin JSON, 断言 `cc.json` 内容及 `cc_active` 随 `SessionStart`/`SessionEnd` 翻转。
- `Sources/NotchReminder/CCSignalReader.swift` — `struct CCSignal` + `struct CCSignalReader.read() -> CCSignal?`(可注入路径)。
- `Tests/NotchReminderTests/CCSignalReaderTests.swift` — Swift 解析测试(喂样例 json / 缺失 / 损坏)。

Modify:
- `Package.swift` — 确认 `NotchReminderTests` test target 已存在(CONTRACT §C4, Task 3 已加);缺才补同一份。
- `Sources/NotchReminder/AppController.swift` — 在 `tick()` 构造 `Sample` 的那一处填入 CC 三字段(Task 3 产物, 本 Task 只改这一处)。

#### Interfaces

Consumes(上游契约, 必须逐字对齐, 不得改动):
- `ReminderCore.Sample`(CONTRACT §C1):
  ```swift
  public struct Sample: Equatable {
      public var now: Date; public var idleSeconds: Double
      public var ccActive: Bool          // ← 本 Task 填 CCSignal.ccActive
      public var ccLastEvent: Date?      // ← 本 Task 填 CCSignal.lastEvent
      public var project: String?        // ← 本 Task 填 CCSignal.project
      public init(now: Date, idleSeconds: Double, ccActive: Bool = false,
                  ccLastEvent: Date? = nil, project: String? = nil)
  }
  ```
- `NotchReminder.AppController`(Task 3, CONTRACT §C3): `@MainActor public final class`, `tick()` 内构造 `Sample(now:idleSeconds:)` 调 `advance`(Task 3 owner)。本 Task 只在该构造点追加 CC 三实参, 不改采样节奏/route/pending。**tick() 由 Task 3 保证存在——本 Task 依赖它未被任何 Task 抹掉(CONTRACT §C3 已把 Task 5/7 定为 Modify, tick 恒在)。**

Produces(本 Task 定义, 下游可用):
- 状态文件契约 `~/.notchreminder/cc.json`(spec §5.2), 字段:
  ```json
  { "cc_active": true, "project": "SoulApp",
    "session_start": "2026-07-07T14:02:11+08:00",
    "last_event": "2026-07-07T15:34:50+08:00" }
  ```
  ISO8601 带本地时区偏移(本机 `+08:00`); `project` = hook 传入 `cwd` 的末段目录名。
- Swift 侧读取器:
  ```swift
  public struct CCSignal: Equatable {
      public var ccActive: Bool
      public var project: String?
      public var lastEvent: Date?
  }
  public struct CCSignalReader {
      public init(path: URL = FileManager.default.homeDirectoryForCurrentUser
                      .appendingPathComponent(".notchreminder/cc.json"))
      public func read() -> CCSignal?   // 缺失/损坏 → nil
  }
  ```

#### Steps

- [ ] **Step 6.1 — 建插件目录 + 写 `plugin.json`(name=`notchreminder`)。** 执行建目录:

  ```bash
  mkdir -p /Users/chunhaixu/NotchReminder/cc-plugin/.claude-plugin \
           /Users/chunhaixu/NotchReminder/cc-plugin/hooks
  ```

  新建 `cc-plugin/.claude-plugin/plugin.json`, 内容(**`name` 必须为 `notchreminder`, 与 Task 8 marketplace/install 全链路一致, CONTRACT §C5**):

  ```json
  {
    "name": "notchreminder",
    "description": "Sensor-only plugin: writes CC activity + project name to ~/.notchreminder/cc.json for the NotchReminder menu-bar app.",
    "version": "1.0.0",
    "author": { "name": "chunhaixu", "email": "chunhaiyoung@foxmail.com" }
  }
  ```

  > ⚠️ 名字必须精确为 `notchreminder`(无连字符)。Task 8 的 `install.sh` 用 `claude plugin install notchreminder@notchreminder`, 要求 plugin.json 的 `name` = `notchreminder`; 若写成 `notch-reminder`, install 找不到该插件而失败(CONTRACT §C5)。

- [ ] **Step 6.2 — 写 `hooks.json`(wrapper 格式, 4 事件同脚本)。** 新建 `cc-plugin/hooks/hooks.json`。必须用插件 wrapper 格式 `{"hooks":{...}}`; `command` 用 `${CLAUDE_PLUGIN_ROOT}` 拼绝对路径。内容:

  ```json
  {
    "hooks": {
      "SessionStart": [
        { "matcher": "*", "hooks": [
          { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/touch_activity.py\"" }
        ] }
      ],
      "UserPromptSubmit": [
        { "matcher": "*", "hooks": [
          { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/touch_activity.py\"" }
        ] }
      ],
      "Stop": [
        { "matcher": "*", "hooks": [
          { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/touch_activity.py\"" }
        ] }
      ],
      "SessionEnd": [
        { "matcher": "*", "hooks": [
          { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/touch_activity.py\"" }
        ] }
      ]
    }
  }
  ```

- [ ] **Step 6.3 — 写 Python 失败测试 `test_touch_activity.py`(先测后写)。** 新建 `cc-plugin/hooks/test_touch_activity.py`。测试把脚本作为子进程运行, 用环境变量 `NOTCHREMINDER_STATE_FILE` 指定一个临时 `cc.json`, 喂各事件的假 stdin JSON, 断言写出的字段与 `cc_active` 翻转。内容(完整可运行, 仅标准库):

  ```python
  import json
  import os
  import subprocess
  import sys
  import tempfile
  import unittest

  SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "touch_activity.py")


  def run_hook(state_file, payload):
      """把 payload 作为 stdin 喂给 touch_activity.py, 返回解析后的 cc.json(dict)。"""
      env = dict(os.environ)
      env["NOTCHREMINDER_STATE_FILE"] = state_file
      proc = subprocess.run(
          [sys.executable, SCRIPT],
          input=json.dumps(payload),
          text=True,
          capture_output=True,
          env=env,
      )
      assert proc.returncode == 0, f"hook exited {proc.returncode}: {proc.stderr}"
      with open(state_file) as f:
          return json.load(f)


  class TouchActivityTests(unittest.TestCase):
      def setUp(self):
          self.tmp = tempfile.TemporaryDirectory()
          self.state_file = os.path.join(self.tmp.name, "cc.json")

      def tearDown(self):
          self.tmp.cleanup()

      def test_session_start_sets_active_and_project_and_start(self):
          data = run_hook(self.state_file, {
              "hook_event_name": "SessionStart",
              "cwd": "/Users/chunhaixu/SoulApp",
              "session_id": "s1",
          })
          self.assertTrue(data["cc_active"])
          self.assertEqual(data["project"], "SoulApp")
          self.assertIn("session_start", data)
          self.assertIn("last_event", data)
          # ISO8601 带时区偏移(以 + 或 - 结尾的偏移段)
          self.assertRegex(data["session_start"], r"T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$")

      def test_user_prompt_submit_updates_last_event_and_project(self):
          run_hook(self.state_file, {
              "hook_event_name": "SessionStart",
              "cwd": "/Users/chunhaixu/SoulApp",
              "session_id": "s1",
          })
          data = run_hook(self.state_file, {
              "hook_event_name": "UserPromptSubmit",
              "cwd": "/Users/chunhaixu/NotchReminder",
              "session_id": "s1",
          })
          self.assertTrue(data["cc_active"])
          self.assertEqual(data["project"], "NotchReminder")  # project 跟随最新 cwd

      def test_stop_keeps_active_and_bumps_last_event(self):
          run_hook(self.state_file, {
              "hook_event_name": "SessionStart",
              "cwd": "/Users/chunhaixu/SoulApp",
              "session_id": "s1",
          })
          data = run_hook(self.state_file, {
              "hook_event_name": "Stop",
              "cwd": "/Users/chunhaixu/SoulApp",
              "session_id": "s1",
          })
          self.assertTrue(data["cc_active"])
          self.assertIn("last_event", data)

      def test_session_end_flips_active_false(self):
          run_hook(self.state_file, {
              "hook_event_name": "SessionStart",
              "cwd": "/Users/chunhaixu/SoulApp",
              "session_id": "s1",
          })
          data = run_hook(self.state_file, {
              "hook_event_name": "SessionEnd",
              "cwd": "/Users/chunhaixu/SoulApp",
              "session_id": "s1",
          })
          self.assertFalse(data["cc_active"])

      def test_empty_stdin_does_not_crash(self):
          env = dict(os.environ)
          env["NOTCHREMINDER_STATE_FILE"] = self.state_file
          proc = subprocess.run(
              [sys.executable, SCRIPT],
              input="",
              text=True,
              capture_output=True,
              env=env,
          )
          self.assertEqual(proc.returncode, 0, proc.stderr)


  if __name__ == "__main__":
      unittest.main()
  ```

- [ ] **Step 6.4 — 运行确认失败。** 脚本尚未创建, 测试应失败:

  ```bash
  python3 -m unittest discover -s /Users/chunhaixu/NotchReminder/cc-plugin/hooks -p 'test_*.py' 2>&1 | tail -20
  ```

  预期 **FAIL**: 每个用例在 `run_hook` 内 `subprocess.run` 返回非 0(因 `touch_activity.py` 不存在), `assert proc.returncode == 0` 触发 `AssertionError`; 汇总类似 `FAILED (errors=4, failures=1)` 或全 errors。

- [ ] **Step 6.5 — 写实现 `touch_activity.py`。** 新建 `cc-plugin/hooks/touch_activity.py`。要点: 读 stdin JSON(容错空/坏 → 空 dict); 依 `hook_event_name` 更新状态; `project` = `basename(cwd.rstrip('/'))`; 时间用 `datetime.now().astimezone().isoformat(timespec="seconds")`(本机产出 `+08:00`); 原子写; 状态文件路径优先取 env `NOTCHREMINDER_STATE_FILE`; 任何异常吞掉并 `exit(0)`。内容(完整可运行):

  ```python
  #!/usr/bin/env python3
  """CC 传感器 hook: 把活跃信号写进 ~/.notchreminder/cc.json(spec §5.2)。

  4 个 hook 事件都调本脚本:
    SessionStart     -> cc_active=true, session_start=now, last_event=now, project=cwd 末段
    UserPromptSubmit -> last_event=now, project=cwd 末段(cc_active 保持 true)
    Stop             -> last_event=now(活跃心跳; cc_active 保持 true)
    SessionEnd       -> cc_active=false, last_event=now

  纯传感器: 不做任何计时/判断/弹窗。失败静默(exit 0), 不阻断 CC。
  """
  import json
  import os
  import sys
  from datetime import datetime


  def state_path():
      override = os.environ.get("NOTCHREMINDER_STATE_FILE")
      if override:
          return override
      return os.path.join(os.path.expanduser("~/.notchreminder"), "cc.json")


  def now_iso():
      # 本地时区带偏移, 如 2026-07-07T15:34:50+08:00
      return datetime.now().astimezone().isoformat(timespec="seconds")


  def load_state(path):
      try:
          with open(path) as f:
              st = json.load(f)
          return st if isinstance(st, dict) else {}
      except Exception:
          return {}


  def atomic_write(path, obj):
      d = os.path.dirname(path)
      os.makedirs(d, exist_ok=True)
      tmp = path + ".tmp"
      with open(tmp, "w") as f:
          json.dump(obj, f)
      os.replace(tmp, path)


  def main():
      try:
          raw = sys.stdin.read()
          data = json.loads(raw) if raw.strip() else {}
      except Exception:
          data = {}
      if not isinstance(data, dict):
          data = {}

      event = data.get("hook_event_name", "")
      cwd = data.get("cwd", "") or ""
      project = os.path.basename(cwd.rstrip("/")) if cwd else None

      path = state_path()
      st = load_state(path)
      ts = now_iso()

      if event == "SessionStart":
          st["cc_active"] = True
          st["session_start"] = ts
          st["last_event"] = ts
          if project:
              st["project"] = project
      elif event == "UserPromptSubmit":
          st["cc_active"] = True
          st["last_event"] = ts
          if project:
              st["project"] = project
      elif event == "Stop":
          st["cc_active"] = True
          st["last_event"] = ts
      elif event == "SessionEnd":
          st["cc_active"] = False
          st["last_event"] = ts
      else:
          # 未知事件: 仅记一次心跳, 不改 cc_active。
          st["last_event"] = ts

      atomic_write(path, st)


  if __name__ == "__main__":
      try:
          main()
      except Exception:
          # 传感器失败不该阻断 CC。
          pass
      sys.exit(0)
  ```

- [ ] **Step 6.6 — 运行确认通过。** 执行:

  ```bash
  python3 -m unittest discover -s /Users/chunhaixu/NotchReminder/cc-plugin/hooks -p 'test_*.py' 2>&1 | tail -8
  ```

  预期 **PASS**: `Ran 5 tests` + `OK`。

- [ ] **Step 6.7 — commit(CC 插件 + Python 测试)。** 执行:

  ```bash
  \
  git add cc-plugin/.claude-plugin/plugin.json \
          cc-plugin/hooks/hooks.json \
          cc-plugin/hooks/touch_activity.py \
          cc-plugin/hooks/test_touch_activity.py && \
  git commit -m "Task 6: CC sensor plugin (name=notchreminder) writes cc.json (4 hooks + python tests)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 4 个文件纳入版本。

- [ ] **Step 6.8 — 确认 `Package.swift` 已有 `NotchReminderTests`(CONTRACT §C4)。** Task 3 应已按 §C4 追加。执行核对:

  ```bash
  grep -A3 'NotchReminderTests' /Users/chunhaixu/NotchReminder/Package.swift
  ```

  预期看到 `dependencies: ["NotchReminder", "ReminderCore"]` + `path: "Tests/NotchReminderTests"`。若缺(Task 3 未加), 按 CONTRACT §C4 补同一份。

- [ ] **Step 6.9 — 写 Swift 失败测试 `CCSignalReaderTests.swift`(先测后写)。** 新建 `Tests/NotchReminderTests/CCSignalReaderTests.swift`。内容(完整可编译):

  ```swift
  import XCTest
  @testable import NotchReminder

  final class CCSignalReaderTests: XCTestCase {

      private func tempURL() -> URL {
          FileManager.default.temporaryDirectory
              .appendingPathComponent("cc-\(UUID().uuidString).json")
      }

      private func write(_ json: String, to url: URL) {
          try! json.data(using: .utf8)!.write(to: url)
      }

      func testParsesValidJSON() {
          let url = tempURL()
          write("""
          {
            "cc_active": true,
            "project": "SoulApp",
            "session_start": "2026-07-07T14:02:11+08:00",
            "last_event": "2026-07-07T15:34:50+08:00"
          }
          """, to: url)
          defer { try? FileManager.default.removeItem(at: url) }

          let signal = CCSignalReader(path: url).read()
          XCTAssertNotNil(signal)
          XCTAssertEqual(signal?.ccActive, true)
          XCTAssertEqual(signal?.project, "SoulApp")
          // last_event 应解析为具体时刻(2026-07-07T15:34:50+08:00)
          let expected = ISO8601DateFormatter().date(from: "2026-07-07T15:34:50+08:00")
          XCTAssertEqual(signal?.lastEvent, expected)
      }

      func testInactiveJSON() {
          let url = tempURL()
          write("""
          { "cc_active": false, "project": "SoulApp",
            "session_start": "2026-07-07T14:02:11+08:00",
            "last_event": "2026-07-07T15:34:50+08:00" }
          """, to: url)
          defer { try? FileManager.default.removeItem(at: url) }

          let signal = CCSignalReader(path: url).read()
          XCTAssertEqual(signal?.ccActive, false)
      }

      func testMissingFileReturnsNil() {
          let url = tempURL()  // 从未写入
          XCTAssertNil(CCSignalReader(path: url).read())
      }

      func testCorruptJSONReturnsNil() {
          let url = tempURL()
          write("{ not json at all ", to: url)
          defer { try? FileManager.default.removeItem(at: url) }
          XCTAssertNil(CCSignalReader(path: url).read())
      }

      func testMissingOptionalFieldsTolerated() {
          let url = tempURL()
          write("""
          { "cc_active": true }
          """, to: url)
          defer { try? FileManager.default.removeItem(at: url) }

          let signal = CCSignalReader(path: url).read()
          XCTAssertEqual(signal?.ccActive, true)
          XCTAssertNil(signal?.project)
          XCTAssertNil(signal?.lastEvent)
      }
  }
  ```

- [ ] **Step 6.10 — 运行确认失败。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter CCSignalReaderTests 2>&1 | tail -20
  ```

  预期 **FAIL**: 编译错误 `error: cannot find 'CCSignalReader' in scope`(以及 `cannot find 'CCSignal'`)。

- [ ] **Step 6.11 — 写实现 `CCSignalReader.swift`。** 新建 `Sources/NotchReminder/CCSignalReader.swift`。用 `Codable` 解析 `cc.json`(snake_case 字段用 `CodingKeys` 映射); 时间用 `ISO8601DateFormatter`(默认支持 `+08:00`); 文件缺失/读失败/JSON 坏 → 返回 `nil`。内容(完整可编译):

  ```swift
  import Foundation

  /// 从 ~/.notchreminder/cc.json 读出的 CC 活跃信号(App 侧消费)。
  public struct CCSignal: Equatable {
      public var ccActive: Bool
      public var project: String?
      public var lastEvent: Date?

      public init(ccActive: Bool, project: String? = nil, lastEvent: Date? = nil) {
          self.ccActive = ccActive
          self.project = project
          self.lastEvent = lastEvent
      }
  }

  /// 读并解析 CC 状态文件。缺失/损坏一律容错返回 nil, 绝不抛。
  public struct CCSignalReader {
      private let path: URL

      public init(
          path: URL = FileManager.default.homeDirectoryForCurrentUser
              .appendingPathComponent(".notchreminder/cc.json")
      ) {
          self.path = path
      }

      /// cc.json 的磁盘表示。session_start 本读取器不用, 故不声明。
      private struct Payload: Decodable {
          let ccActive: Bool
          let project: String?
          let lastEvent: String?

          enum CodingKeys: String, CodingKey {
              case ccActive = "cc_active"
              case project
              case lastEvent = "last_event"
          }
      }

      /// 读并解析。任何失败(文件缺失/读失败/JSON 损坏)返回 nil。
      public func read() -> CCSignal? {
          guard let data = try? Data(contentsOf: path) else { return nil }
          guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
          let iso = ISO8601DateFormatter()
          let lastEvent = payload.lastEvent.flatMap { iso.date(from: $0) }
          return CCSignal(ccActive: payload.ccActive, project: payload.project, lastEvent: lastEvent)
      }
  }
  ```

- [ ] **Step 6.12 — 运行确认通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter CCSignalReaderTests 2>&1 | tail -8
  ```

  预期 **PASS**: `Executed 5 tests, with 0 failures`。

  > 全量回归见文末 Self-Review「测试累计表」(本阶段累计不再逐 Task 硬断固定总数, 避免脆弱; 判据以本 filter 的 5 个为准)。

- [ ] **Step 6.13 — commit(Package.swift + CCSignalReader + 测试)。** 执行:

  ```bash
  \
  git add Package.swift \
          Sources/NotchReminder/CCSignalReader.swift \
          Tests/NotchReminderTests/CCSignalReaderTests.swift && \
  git commit -m "Task 6: CCSignalReader parses cc.json (tolerant, injectable path)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit(若 Package.swift 未改则 2 个文件)。

- [ ] **Step 6.14 — Modify: 在 `AppController.tick()` 构造 `Sample` 处填入 CC 三字段。** 打开 `Sources/NotchReminder/AppController.swift`(Task 3 产, CONTRACT §C3 owner)。找到 `tick()` 里构造 `Sample` 的那段(Task 3 形如 `let sample = Sample(now: clock(), idleSeconds: idleProvider(), ccActive: false, ccLastEvent: nil, project: nil)`), 在**它之前**读一次 CC 信号, 并把三字段接进去。**只改这一处**, 不动 flushPending/route/pending/循环节奏。

  在 `AppController` 里加一个只读一次的属性(与其它存储属性并列):

  ```swift
      private let ccReader = CCSignalReader()
  ```

  把 tick() 里构造 `Sample` 的那段改成:

  ```swift
          let cc = ccReader.read()
          let sample = Sample(
              now: clock(),
              idleSeconds: idleProvider(),
              ccActive: cc?.ccActive ?? false,
              ccLastEvent: cc?.lastEvent,
              project: cc?.project
          )
  ```

  > 说明: `advance` 内部 `byCC` 已要求 `ccActive && ccLastEvent != nil && now-ccLastEvent < ccGrace`, 故这里把 `cc == nil`/字段缺失安全降级为 `false`/`nil` 即可。`project` 直接透传, 供 `.sit(minutes:project:)` 文案使用。`CCSignalReader` 与 `AppController` 同属 `NotchReminder` target, 无需额外 import。

- [ ] **Step 6.15 — 编译确认。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -15
  ```

  预期 **成功**: 无报错。若出现 `cannot find 'Sample'`, 检查 `AppController.swift` 是否已 `import ReminderCore`(Task 3 应已 import)。

- [ ] **Step 6.16 — 手动验证 A: 真跑一个 CC 会话看 `cc.json` 更新。** 执行:

  ```bash
  # 用 --plugin-dir 本地加载(无需 marketplace); 在项目目录内起一个 CC 会话
  rm -f ~/.notchreminder/cc.json
  claude --plugin-dir ./cc-plugin -p "hello" ; echo "---- exit ----"
  cat ~/.notchreminder/cc.json
  ```

  预期(具体可核对):
  - 文件存在, 是合法 JSON。
  - `-p "hello"` 一次性会话依次触发 `SessionStart`→`UserPromptSubmit`→`Stop`→`SessionEnd`, 故最终 `cc_active` 为 `false`。
  - `project` 为 `NotchReminder`(cwd 末段)。
  - `session_start` 与 `last_event` 均为形如 `2026-07-07T…+08:00` 的字符串, 且 `last_event >= session_start`。
  - 若想看 `cc_active=true` 的中间态: 另开一个**交互式**会话不退出, 另开终端 `cat ~/.notchreminder/cc.json`, 应见 `"cc_active": true`、`project": "NotchReminder"`。

- [ ] **Step 6.17 — 手动验证 B: 盯 CC 不动键鼠不被判休息 + 提醒带项目名(判据以既有单测为准)。** 本条口径已被既有单测坐实:
  - `testCCGraceKeepsActiveWithoutInput`(Task 2): idle 超 rest 但 CC 补活跃 → sitAccum 继续累加不清零。
  - `testContinuousActiveAccumulatesToSitThresholdAndFires`(Task 2): `.sit(minutes:50, project:"SoulApp")` 带项目名。

  故本条以「6.16 cc.json 有 project 字段 + 6.15 编译通过 + Task 2 两条单测绿」三者共同判定通过, 无需再跑裸 swiftc 直连(易因 SPM 内部模块布局报 `library not found`)。若确需现场跑一次端到端断言, 用临时 XCTest 方法跑 `swift test`(可跑完即删), 不用 swiftc 手工链接。

- [ ] **Step 6.18 — commit(AppController 接线)。** 执行:

  ```bash
  \
  git add Sources/NotchReminder/AppController.swift && \
  git commit -m "Task 6: wire CCSignalReader into AppController.tick() Sample construction

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 1 个文件纳入版本。

#### 落地注意(据 verify 坐实, 非猜测)

- **插件名 `notchreminder`**(CONTRACT §C5): plugin.json 的 `name`、Task 8 的 marketplace `name`/`plugins[].name`、install 命令 `notchreminder@notchreminder` 三处必须完全一致。
- **hooks.json 必须 wrapper 格式** `{"hooks":{...}}`(插件格式), 不是 settings.json 顶层事件格式。
- **`command` 用 `${CLAUDE_PLUGIN_ROOT}`** 拼绝对路径; 相对路径会因 hook 执行时 CWD=用户工程而找不到脚本。含空格路径用 `\"…\"` 包裹。
- **`plugin.json` 只在 `.claude-plugin/` 下**; `hooks/` 在插件根(不是 `.claude-plugin/hooks/`)。
- **hooks 非热加载**: 改了 `hooks.json` 需重启 CC / `/reload-plugins`; 首次用 `--plugin-dir ./cc-plugin` 本地加载即可。
- **`project` 取 stdin 的 `cwd` 末段**, 不是 `CLAUDE_PROJECT_DIR` 环境变量。
- **ISO8601 带 `+08:00` 偏移**: Python `datetime.now().astimezone().isoformat(timespec="seconds")` 本机产出 `+08:00`; Swift `ISO8601DateFormatter` 默认能解析。
- **原子写**: 先写 `cc.json.tmp` 再 `os.replace`, 避免读到半截 JSON。
- **`.notchreminder/` 已在 `.gitignore`**, `cc.json` 不会被误提交。
- **CCSignalReader 只降级不抛**: 文件缺失/JSON 坏一律 `nil`; App 层 `cc?.ccActive ?? false` 安全降级, 与解耦设计一致。

---

## Task 7: 设置持久化 + 设置窗 + 完整菜单栏 + 开机自启 + 首启引导

> 前置: Task 1 已建好 SPM 工程(`Package.swift` 含 library `ReminderCore` + executableTarget `NotchReminder`,
> 后者以 `Sources/NotchReminder/main.swift` 命令式入口起菜单栏)。Task 2/4 已落地 `ReminderCore`, 引擎 12 用例全绿。
> **Task 3 已落地运行期 `AppController`(CONTRACT §C3 owner): 采样循环 + 持有 config/state + `static var shared` +
> `config`/`state` 只读属性 + `applyConfig`/`manualRest`/`muteFor` 命令面全部已实现。** 本 Task 只 Modify AppController 启动路径插三行接线,
> 不再需要「对齐 Task 3 命名」——那五个成员 Task 3 已按契约提供。Task 5/6 已把 NotchPresenter/DoNotDisturb/CCSignalReader 落地。
> `Package.swift` 已含 `NotchReminderTests` test target(CONTRACT §C4, 含 `ReminderCore` 显式依赖——本 Task 的 `SettingsStoreTests` `import ReminderCore` 依赖它)。
>
> 本 Task 做「常驻与可配置」这一层, 五块:
> 1. `SettingsStore` — 用 `UserDefaults` 持久化 `ReminderConfig` 的阈值 + 四开关(可注入 suite, 给 round-trip 单测)。
> 2. `SettingsWindow` — SwiftUI 设置窗(阈值 Slider + Toggle + 开机自启 Toggle + 样式偏好), 改动即存。
> 3. 完整菜单栏 — 替换 Task 3 的占位: 只读状态行 + 手动重置/静音 + 四开关 + 设置 + 退出, 弹出前刷新。
> 4. `LaunchAgent` — 生成 `~/Library/LaunchAgents/com.notchreminder.agent.plist`, `enable()`/`disable()` 走现代 `launchctl bootstrap/bootout`。
> 5. 首启引导 — 首次运行弹一屏说明 + 提示装 CC 插件并打印一键命令。
>
> 只有 `SettingsStore` 是可纯逻辑单测的(config↔UserDefaults round-trip); 其余为菜单/窗口/plist 接线, 走「写代码 → `swift build` → 手动验证」路线。

---

#### Files

**Create**
- `Sources/NotchReminder/SettingsStore.swift` — `UserDefaults` 持久化 `ReminderConfig`(阈值 + 四开关 + 开机自启标志 + 样式偏好 + 首启标记); 可注入 `UserDefaults`; `load()` / `save(_:)` / `makeConfig()`。
- `Sources/NotchReminder/SettingsWindow.swift` — SwiftUI 设置窗 + 一个持有它的 `SettingsWindowController`(NSWindow 宿主)。
- `Sources/NotchReminder/MenuBar.swift` — `MenuBarController`: 构建/刷新完整 `NSMenu`, 作 `NSMenuDelegate` 在弹出前刷新状态行, 各菜单项 action。
- `Sources/NotchReminder/LaunchAgent.swift` — `LaunchAgent` enum: `isEnabled` / `enable()` / `disable()` / `plistContents()`。
- `Sources/NotchReminder/FirstRun.swift` — `FirstRunGuide`: `presentIfNeeded(store:)` 首启一屏说明 + CC 插件一键命令。
- `Tests/NotchReminderTests/SettingsStoreTests.swift` — `SettingsStore` round-trip 单测(注入 `UserDefaults(suiteName:)`)。

**Modify**
- `Package.swift` — 确认 `NotchReminderTests`(依赖 `NotchReminder` + `ReminderCore` + path)已存在(CONTRACT §C4, Task 3 已加);缺才补。
- `Sources/NotchReminder/AppController.swift`(Task 3 产) — 启动时(在 main.swift 的 launching 里)`store.load()` 应用到 `config`、装 `MenuBarController`、`FirstRunGuide.presentIfNeeded`。**仅这几处接线, 不动 Task 3 采样循环/route/pending。**

---

#### Interfaces

**Consumes(本 Task 依赖, 由上游提供; 引用签名必须与 CONTRACT 一致)**

来自 `ReminderCore`(CONTRACT §C1, Task 2/4 已定义):
```swift
public struct ReminderConfig: Equatable {
    public var sitThreshold: TimeInterval; public var waterThreshold: TimeInterval; public var eyeThreshold: TimeInterval
    public var activeIdleCeiling: TimeInterval; public var restThreshold: TimeInterval; public var ccGrace: TimeInterval
    public var sitSnooze: TimeInterval; public var nightRepeat: TimeInterval
    public var sitEnabled: Bool; public var waterEnabled: Bool; public var eyeEnabled: Bool; public var nightEnabled: Bool
    public var mutedUntil: Date?
    public init(...)  // 见 Task 2 Models.swift 全默认值
}
```

来自 `AppController`(Task 3 已按 CONTRACT §C3 提供 —— 本 Task 直接调用, 不需改 Task 3):
```swift
@MainActor public final class AppController {
    static var shared: AppController!          // App 启动时已赋值(main.swift Step 3.5)
    var config: ReminderConfig { get }
    var state: ReminderState { get }
    func applyConfig(_ config: ReminderConfig) // 替换配置并下一拍生效
    func manualRest()                          // 置 sitAccum=0、lastSitAlert=nil
    func muteFor(_ seconds: TimeInterval)      // config.mutedUntil = now+seconds 并 applyConfig
}
```
> 这五个成员 Task 3 已实现(CONTRACT §C3c),本 Task 只调用。`applyConfig` 内部不持久化——本 Task 在每个调用点先 `store.save(cfg)` 再 `AppController.shared.applyConfig(cfg)`(见各 action)。

**Produces(本 Task 定义, 下游/接线方可用)**

```swift
final class SettingsStore {
    init(defaults: UserDefaults = .standard)
    func load() -> ReminderConfig                 // 无存值时回落 ReminderConfig() 默认
    func save(_ config: ReminderConfig)            // 持久化阈值 + 四开关
    func makeConfig() -> ReminderConfig            // = load()
    var launchAtLogin: Bool { get set }
    var strongStyleStaysLonger: Bool { get set }
    var hasCompletedFirstRun: Bool { get set }
}
enum LaunchAgent {
    static var plistPath: String { get }
    static var isEnabled: Bool { get }
    static func plistContents(execPath: String) -> String
    @discardableResult static func enable() -> Bool
    @discardableResult static func disable() -> Bool
}
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    init(statusItem: NSStatusItem, store: SettingsStore)
    func attach()
}
@MainActor final class SettingsWindowController {
    init(store: SettingsStore); func show()
}
enum FirstRunGuide {
    @MainActor static func presentIfNeeded(store: SettingsStore)
}
```

---

#### Steps

##### A. SettingsStore(先测后写 —— 唯一纯逻辑单测块)

- [ ] **Step 7.1 — 确认 `Package.swift` 的 `NotchReminderTests`(CONTRACT §C4)。** Task 3 应已按 §C4 追加(含 `ReminderCore` 显式依赖 + path)。执行核对:

  ```bash
  grep -A3 'NotchReminderTests' /Users/chunhaixu/NotchReminder/Package.swift
  ```

  预期看到 `dependencies: ["NotchReminder", "ReminderCore"]` + `path: "Tests/NotchReminderTests"`。**必须含 `ReminderCore`**(本 Task 的 `SettingsStoreTests` `import ReminderCore`)。若缺, 按 CONTRACT §C4 补同一份。

- [ ] **Step 7.2 — 写失败测试(SettingsStore round-trip, 5 条)。** 新建 `Tests/NotchReminderTests/SettingsStoreTests.swift`, 内容为下面**完整**代码。每个用例用独立 suiteName 并在 `tearDown` 清掉。

  ```swift
  import XCTest
  @testable import NotchReminder
  import ReminderCore

  final class SettingsStoreTests: XCTestCase {

      private var suiteName: String!
      private var defaults: UserDefaults!

      override func setUp() {
          super.setUp()
          suiteName = "com.notchreminder.tests.\(UUID().uuidString)"
          defaults = UserDefaults(suiteName: suiteName)!
      }

      override func tearDown() {
          defaults.removePersistentDomain(forName: suiteName)
          defaults = nil
          suiteName = nil
          super.tearDown()
      }

      func testLoadWithoutStoredReturnsDefaults() {
          let store = SettingsStore(defaults: defaults)
          let cfg = store.load()
          XCTAssertEqual(cfg, ReminderConfig())  // 无存值 → 引擎默认
      }

      func testSaveThenLoadRoundTripsThresholds() {
          let store = SettingsStore(defaults: defaults)
          var cfg = ReminderConfig()
          cfg.sitThreshold = 40 * 60
          cfg.waterThreshold = 45 * 60
          cfg.eyeThreshold = 20 * 60
          cfg.nightRepeat = 20 * 60   // 熬夜也算一类阈值(重复间隔), 一并持久化
          store.save(cfg)

          let reloaded = SettingsStore(defaults: defaults).load()
          XCTAssertEqual(reloaded.sitThreshold, 40 * 60)
          XCTAssertEqual(reloaded.waterThreshold, 45 * 60)
          XCTAssertEqual(reloaded.eyeThreshold, 20 * 60)
          XCTAssertEqual(reloaded.nightRepeat, 20 * 60)
      }

      func testSaveThenLoadRoundTripsToggles() {
          let store = SettingsStore(defaults: defaults)
          var cfg = ReminderConfig()
          cfg.sitEnabled = false
          cfg.waterEnabled = true
          cfg.eyeEnabled = false
          cfg.nightEnabled = false
          store.save(cfg)

          let reloaded = SettingsStore(defaults: defaults).load()
          XCTAssertFalse(reloaded.sitEnabled)
          XCTAssertTrue(reloaded.waterEnabled)
          XCTAssertFalse(reloaded.eyeEnabled)
          XCTAssertFalse(reloaded.nightEnabled)
      }

      func testMakeConfigEqualsLoad() {
          let store = SettingsStore(defaults: defaults)
          var cfg = ReminderConfig()
          cfg.sitThreshold = 55 * 60
          cfg.eyeEnabled = false
          store.save(cfg)
          XCTAssertEqual(store.makeConfig(), store.load())
      }

      func testScalarPrefsRoundTrip() {
          var store = SettingsStore(defaults: defaults)
          XCTAssertFalse(store.hasCompletedFirstRun)      // 默认未完成首启
          XCTAssertFalse(store.launchAtLogin)             // 默认不自启
          XCTAssertFalse(store.strongStyleStaysLonger)    // 默认样式偏好 false

          store.hasCompletedFirstRun = true
          store.launchAtLogin = true
          store.strongStyleStaysLonger = true

          let reloaded = SettingsStore(defaults: defaults)
          XCTAssertTrue(reloaded.hasCompletedFirstRun)
          XCTAssertTrue(reloaded.launchAtLogin)
          XCTAssertTrue(reloaded.strongStyleStaysLonger)
      }
  }
  ```

- [ ] **Step 7.3 — 运行确认失败。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter SettingsStoreTests 2>&1 | tail -20
  ```

  预期 **FAIL**: 编译错误 `error: cannot find 'SettingsStore' in scope`。

- [ ] **Step 7.4 — 写最小实现 `SettingsStore.swift`。** 新建 `Sources/NotchReminder/SettingsStore.swift`, 内容为下面**完整可编译**代码。持久化只覆盖「阈值 + 四开关」+ 三个标量偏好。`mutedUntil` 是运行期临时态, **不**持久化。`load()` 用 `defaults.object(forKey:) != nil` 判断有无存值, 缺失时回落 `ReminderConfig()` 默认。

  ```swift
  import Foundation
  import ReminderCore

  /// 用 UserDefaults 持久化用户可配置项:
  /// - ReminderConfig 的四类阈值(含熬夜重复间隔)+ 四个开关。
  /// - 三个标量偏好: 开机自启意图 / 样式偏好 / 首启完成标记。
  ///
  /// 注: mutedUntil 是运行期临时静音态, 不持久化(重启不应保留静音)。
  /// activeIdleCeiling / restThreshold / ccGrace / sitSnooze 属引擎内部判定阈值,
  /// 本版设置窗不暴露给用户改, 故也不持久化(load 时回落默认值)。
  final class SettingsStore {

      private let defaults: UserDefaults

      init(defaults: UserDefaults = .standard) {
          self.defaults = defaults
      }

      private enum Key {
          static let sitThreshold = "sitThreshold"
          static let waterThreshold = "waterThreshold"
          static let eyeThreshold = "eyeThreshold"
          static let nightRepeat = "nightRepeat"
          static let sitEnabled = "sitEnabled"
          static let waterEnabled = "waterEnabled"
          static let eyeEnabled = "eyeEnabled"
          static let nightEnabled = "nightEnabled"
          static let launchAtLogin = "launchAtLogin"
          static let strongStyleStaysLonger = "strongStyleStaysLonger"
          static let hasCompletedFirstRun = "hasCompletedFirstRun"
      }

      // MARK: - Config round-trip

      /// 读出持久化的 ReminderConfig。任一键缺失 → 该字段回落 ReminderConfig() 默认。
      func load() -> ReminderConfig {
          let d = ReminderConfig()  // 默认值来源
          var cfg = ReminderConfig()

          cfg.sitThreshold   = double(Key.sitThreshold,   fallback: d.sitThreshold)
          cfg.waterThreshold = double(Key.waterThreshold, fallback: d.waterThreshold)
          cfg.eyeThreshold   = double(Key.eyeThreshold,   fallback: d.eyeThreshold)
          cfg.nightRepeat    = double(Key.nightRepeat,    fallback: d.nightRepeat)

          cfg.sitEnabled   = bool(Key.sitEnabled,   fallback: d.sitEnabled)
          cfg.waterEnabled = bool(Key.waterEnabled, fallback: d.waterEnabled)
          cfg.eyeEnabled   = bool(Key.eyeEnabled,   fallback: d.eyeEnabled)
          cfg.nightEnabled = bool(Key.nightEnabled, fallback: d.nightEnabled)

          // 未暴露的引擎阈值保持默认; mutedUntil 不持久化 → 始终 nil。
          return cfg
      }

      /// 持久化 ReminderConfig 的可配置部分。
      func save(_ config: ReminderConfig) {
          defaults.set(config.sitThreshold,   forKey: Key.sitThreshold)
          defaults.set(config.waterThreshold, forKey: Key.waterThreshold)
          defaults.set(config.eyeThreshold,   forKey: Key.eyeThreshold)
          defaults.set(config.nightRepeat,    forKey: Key.nightRepeat)
          defaults.set(config.sitEnabled,   forKey: Key.sitEnabled)
          defaults.set(config.waterEnabled, forKey: Key.waterEnabled)
          defaults.set(config.eyeEnabled,   forKey: Key.eyeEnabled)
          defaults.set(config.nightEnabled, forKey: Key.nightEnabled)
      }

      /// 语义别名: 供 AppController 启动时取初始 config。
      func makeConfig() -> ReminderConfig { load() }

      // MARK: - Scalar prefs

      var launchAtLogin: Bool {
          get { defaults.bool(forKey: Key.launchAtLogin) }
          set { defaults.set(newValue, forKey: Key.launchAtLogin) }
      }

      var strongStyleStaysLonger: Bool {
          get { defaults.bool(forKey: Key.strongStyleStaysLonger) }
          set { defaults.set(newValue, forKey: Key.strongStyleStaysLonger) }
      }

      var hasCompletedFirstRun: Bool {
          get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
          set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
      }

      // MARK: - Helpers

      private func double(_ key: String, fallback: TimeInterval) -> TimeInterval {
          defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
      }

      private func bool(_ key: String, fallback: Bool) -> Bool {
          defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
      }
  }
  ```

- [ ] **Step 7.5 — 运行确认通过。** 执行:

  ```bash
  swift test --package-path /Users/chunhaixu/NotchReminder --filter SettingsStoreTests 2>&1 | tail -8
  ```

  预期 **PASS**: `Executed 5 tests, with 0 failures`。

- [ ] **Step 7.6 — commit(SettingsStore)。** 执行:

  ```bash
  \
  git add Package.swift Sources/NotchReminder/SettingsStore.swift Tests/NotchReminderTests/SettingsStoreTests.swift && \
  git commit -m "Task 7: SettingsStore UserDefaults persistence + round-trip tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit(若 Package.swift 未改则 2 个文件)。

##### B. LaunchAgent(开机自启 plist 生成 + bootstrap/bootout)

- [ ] **Step 7.7 — 写 `LaunchAgent.swift`。** 新建 `Sources/NotchReminder/LaunchAgent.swift`, 内容为下面**完整可编译**代码。plist 采用裸二进制 + LaunchAgent 路线; 加载/卸载用 `launchctl bootstrap gui/$(id -u)` / `bootout`。`execPath` 默认取 `Bundle.main.executablePath`。

  ```swift
  import Foundation

  /// 生成并管理 ~/Library/LaunchAgents/com.notchreminder.agent.plist,
  /// 用现代 launchctl bootstrap/bootout(gui/UID 图形域)装/卸开机自启。
  ///
  /// 路线: 裸 SPM 二进制 + LaunchAgent(非 SMAppService)。菜单栏 App 必须用
  /// LaunchAgent(跑在登录用户 Aqua 图形会话, 才能画状态栏图标), 不能用 LaunchDaemon。
  enum LaunchAgent {

      static let label = "com.notchreminder.agent"

      /// plist 落地路径: ~/Library/LaunchAgents/com.notchreminder.agent.plist
      static var plistPath: String {
          (NSHomeDirectory() as NSString)
              .appendingPathComponent("Library/LaunchAgents/\(label).plist")
      }

      /// 当前登录用户的图形域, e.g. "gui/501"。
      private static var guiDomain: String { "gui/\(getuid())" }

      /// 当前运行的可执行绝对路径(自启应指向"当前这个二进制")。回落到 release 产物路径。
      static var currentExecPath: String {
          Bundle.main.executablePath
              ?? "/Users/chunhaixu/NotchReminder/.build/release/NotchReminder"
      }

      /// 是否已装: plist 文件存在 且 launchctl print 命中该 label。
      static var isEnabled: Bool {
          guard FileManager.default.fileExists(atPath: plistPath) else { return false }
          let rc = runLaunchctl(["print", "\(guiDomain)/\(label)"]).status
          return rc == 0
      }

      /// 生成 plist 文本(execPath 为可执行绝对路径)。
      static func plistContents(execPath: String) -> String {
          """
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
              <key>Label</key>
              <string>\(label)</string>
              <key>ProgramArguments</key>
              <array>
                  <string>\(execPath)</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
              <key>KeepAlive</key>
              <dict>
                  <key>Crashed</key>
                  <true/>
              </dict>
              <key>ProcessType</key>
              <string>Interactive</string>
              <key>LimitLoadToSessionType</key>
              <string>Aqua</string>
          </dict>
          </plist>
          """
      }

      /// 写 plist 并 bootstrap 到图形域。成功返回 true。
      @discardableResult
      static func enable() -> Bool {
          let dir = (plistPath as NSString).deletingLastPathComponent
          do {
              try FileManager.default.createDirectory(
                  atPath: dir, withIntermediateDirectories: true)
              try plistContents(execPath: currentExecPath)
                  .write(toFile: plistPath, atomically: true, encoding: .utf8)
          } catch {
              NSLog("[LaunchAgent] write plist failed: \(error)")
              return false
          }
          // 已加载则先 bootout, 避免 "service already bootstrapped" 报错。
          _ = runLaunchctl(["bootout", guiDomain, plistPath])
          let r = runLaunchctl(["bootstrap", guiDomain, plistPath])
          if r.status != 0 {
              NSLog("[LaunchAgent] bootstrap failed rc=\(r.status): \(r.output)")
          }
          return r.status == 0
      }

      /// bootout 并删 plist。成功(或本就未装)返回 true。
      @discardableResult
      static func disable() -> Bool {
          _ = runLaunchctl(["bootout", guiDomain, plistPath])
          try? FileManager.default.removeItem(atPath: plistPath)
          return !FileManager.default.fileExists(atPath: plistPath)
      }

      // MARK: - launchctl runner

      private static func runLaunchctl(_ args: [String]) -> (status: Int32, output: String) {
          let p = Process()
          p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
          p.arguments = args
          let pipe = Pipe()
          p.standardOutput = pipe
          p.standardError = pipe
          do {
              try p.run()
              p.waitUntilExit()
              let data = pipe.fileHandleForReading.readDataToEndOfFile()
              return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
          } catch {
              return (-1, "\(error)")
          }
      }
  }
  ```

- [ ] **Step 7.8 — `swift build` 确认编译通过。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -15
  ```

  预期: `Build complete!`。

- [ ] **Step 7.9 — 手动验证 plist 文本正确。** 用一次性脚本确认 `plistContents` 产出的 XML 合法(`plutil -lint`)。执行:

  ```bash
  cat > /tmp/nr_plist_check.swift <<'SWIFT'
  let label = "com.notchreminder.agent"
  let execPath = "/Users/chunhaixu/NotchReminder/.build/release/NotchReminder"
  let s = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>Label</key>
      <string>\(label)</string>
      <key>ProgramArguments</key>
      <array>
          <string>\(execPath)</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
          <key>Crashed</key>
          <true/>
      </dict>
      <key>ProcessType</key>
      <string>Interactive</string>
      <key>LimitLoadToSessionType</key>
      <string>Aqua</string>
  </dict>
  </plist>
  """
  try! s.write(toFile: "/tmp/nr_test.plist", atomically: true, encoding: .utf8)
  print("written")
  SWIFT
  swift /tmp/nr_plist_check.swift && plutil -lint /tmp/nr_test.plist
  ```

  预期: 打印 `written` 且 `/tmp/nr_test.plist: OK`。清理: `rm -f /tmp/nr_test.plist /tmp/nr_plist_check.swift`。

- [ ] **Step 7.10 — commit(LaunchAgent)。** 执行:

  ```bash
  \
  git add Sources/NotchReminder/LaunchAgent.swift && \
  git commit -m "Task 7: LaunchAgent plist generation + bootstrap/bootout enable/disable

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit。

##### C. 设置窗(SwiftUI, 改动即存)

- [ ] **Step 7.11 — 写 `SettingsWindow.swift`。** 新建 `Sources/NotchReminder/SettingsWindow.swift`, 内容为下面**完整可编译**代码。任一改动即 `store.save` + `AppController.shared.applyConfig` + (自启 Toggle) `LaunchAgent.enable/disable`。阈值展示为分钟。

  ```swift
  import SwiftUI
  import AppKit
  import ReminderCore

  /// 设置窗内容: 四类阈值 Slider(分钟) + 四开关 + 开机自启 + 样式偏好。改动即存即生效。
  struct SettingsView: View {

      let store: SettingsStore

      // 阈值(分钟, 双向绑定回写秒到 config)
      @State private var sitMin: Double
      @State private var waterMin: Double
      @State private var eyeMin: Double
      @State private var nightRepeatMin: Double
      // 四开关
      @State private var sitEnabled: Bool
      @State private var waterEnabled: Bool
      @State private var eyeEnabled: Bool
      @State private var nightEnabled: Bool
      // 偏好
      @State private var launchAtLogin: Bool
      @State private var strongStyleStaysLonger: Bool

      init(store: SettingsStore) {
          self.store = store
          let cfg = store.load()
          _sitMin = State(initialValue: cfg.sitThreshold / 60)
          _waterMin = State(initialValue: cfg.waterThreshold / 60)
          _eyeMin = State(initialValue: cfg.eyeThreshold / 60)
          _nightRepeatMin = State(initialValue: cfg.nightRepeat / 60)
          _sitEnabled = State(initialValue: cfg.sitEnabled)
          _waterEnabled = State(initialValue: cfg.waterEnabled)
          _eyeEnabled = State(initialValue: cfg.eyeEnabled)
          _nightEnabled = State(initialValue: cfg.nightEnabled)
          _launchAtLogin = State(initialValue: store.launchAtLogin)
          _strongStyleStaysLonger = State(initialValue: store.strongStyleStaysLonger)
      }

      var body: some View {
          Form {
              Section("提醒阈值") {
                  sliderRow(title: "🧍 久坐起身", value: $sitMin, range: 10...120, unit: "分钟")
                  sliderRow(title: "💧 喝水", value: $waterMin, range: 15...120, unit: "分钟")
                  sliderRow(title: "👀 护眼远眺", value: $eyeMin, range: 10...90, unit: "分钟")
                  sliderRow(title: "🌙 熬夜重复间隔", value: $nightRepeatMin, range: 10...60, unit: "分钟")
              }
              Section("开关") {
                  Toggle("久坐起身", isOn: $sitEnabled).onChange(of: sitEnabled) { _, _ in persist() }
                  Toggle("喝水", isOn: $waterEnabled).onChange(of: waterEnabled) { _, _ in persist() }
                  Toggle("护眼远眺", isOn: $eyeEnabled).onChange(of: eyeEnabled) { _, _ in persist() }
                  Toggle("熬夜劝退", isOn: $nightEnabled).onChange(of: nightEnabled) { _, _ in persist() }
              }
              Section("通用") {
                  Toggle("开机自启", isOn: $launchAtLogin)
                      .onChange(of: launchAtLogin) { _, on in
                          store.launchAtLogin = on
                          if on { LaunchAgent.enable() } else { LaunchAgent.disable() }
                      }
                  Toggle("强样式提醒停留更久", isOn: $strongStyleStaysLonger)
                      .onChange(of: strongStyleStaysLonger) { _, on in
                          store.strongStyleStaysLonger = on
                      }
              }
          }
          .formStyle(.grouped)
          .frame(width: 380, height: 420)
      }

      @ViewBuilder
      private func sliderRow(title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, unit: String) -> some View {
          VStack(alignment: .leading, spacing: 4) {
              HStack {
                  Text(title)
                  Spacer()
                  Text("\(Int(value.wrappedValue)) \(unit)").foregroundStyle(.secondary)
              }
              Slider(value: value, in: range, step: 5)
                  .onChange(of: value.wrappedValue) { _, _ in persist() }
          }
      }

      /// 把当前 UI 值组装成 ReminderConfig(保留未暴露的引擎阈值默认)并存 + 生效。
      private func persist() {
          var cfg = store.load()  // 拿到当前(含未暴露字段)
          cfg.sitThreshold = sitMin * 60
          cfg.waterThreshold = waterMin * 60
          cfg.eyeThreshold = eyeMin * 60
          cfg.nightRepeat = nightRepeatMin * 60
          cfg.sitEnabled = sitEnabled
          cfg.waterEnabled = waterEnabled
          cfg.eyeEnabled = eyeEnabled
          cfg.nightEnabled = nightEnabled
          store.save(cfg)
          AppController.shared.applyConfig(cfg)
      }
  }

  /// 宿主 SwiftUI 设置窗的 NSWindow 控制器。单实例复用, 再次点"设置…"只前置已有窗。
  @MainActor
  final class SettingsWindowController {

      private let store: SettingsStore
      private var window: NSWindow?

      init(store: SettingsStore) {
          self.store = store
      }

      func show() {
          if let w = window {
              w.makeKeyAndOrderFront(nil)
              NSApp.activate(ignoringOtherApps: true)
              return
          }
          let hosting = NSHostingView(rootView: SettingsView(store: store))
          let w = NSWindow(
              contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
              styleMask: [.titled, .closable],
              backing: .buffered,
              defer: false)
          w.title = "NotchReminder 设置"
          w.contentView = hosting
          w.isReleasedWhenClosed = false
          w.center()
          window = w
          w.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
      }
  }
  ```

- [ ] **Step 7.12 — `swift build` 确认编译通过。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -15
  ```

  预期: `Build complete!`。若报 `onChange(of:)` 弃用/签名错误, 确认使用 macOS 14+ 两参 closure 形式 `{ _, newValue in }`(本机 macOS 26.5 支持); 若工程平台钉 `.macOS(.v13)` 触发旧签名告警, 忽略告警不影响 build。

- [ ] **Step 7.13 — commit(SettingsWindow)。** 执行:

  ```bash
  \
  git add Sources/NotchReminder/SettingsWindow.swift && \
  git commit -m "Task 7: SwiftUI settings window (thresholds/toggles/launch-at-login, save-on-change)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit。

##### D. 完整菜单栏(替换 Task 3 占位)

- [ ] **Step 7.14 — 写 `MenuBar.swift`。** 新建 `Sources/NotchReminder/MenuBar.swift`, 内容为下面**完整可编译**代码。`MenuBarController` 作 `NSMenuDelegate`, 在 `menuNeedsUpdate` 里重建菜单。状态行文案从 `AppController.shared.state`/`config` 计算。「我起身了」调 `AppController.shared.manualRest`(与强样式 snooze 同一清零语义, CONTRACT §C3);「专注 1 小时」调 `AppController.shared.muteFor(3600)`。project 名从 `~/.notchreminder/cc.json` 读。

  ```swift
  import AppKit
  import Foundation
  import ReminderCore

  /// 构建并刷新完整菜单栏菜单。作为 NSMenuDelegate, 每次弹出前(menuNeedsUpdate)重建,
  /// 保证只读状态行反映最新 state。
  @MainActor
  final class MenuBarController: NSObject, NSMenuDelegate {

      private let statusItem: NSStatusItem
      private let store: SettingsStore
      private let menu = NSMenu()
      private lazy var settingsWC = SettingsWindowController(store: store)

      init(statusItem: NSStatusItem, store: SettingsStore) {
          self.statusItem = statusItem
          self.store = store
          super.init()
      }

      /// 挂菜单到 statusItem 并设 delegate。
      func attach() {
          menu.delegate = self
          statusItem.menu = menu
          if let button = statusItem.button {
              button.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "NotchReminder")
          }
          rebuild()
      }

      // MARK: - NSMenuDelegate

      func menuNeedsUpdate(_ menu: NSMenu) {
          rebuild()
      }

      // MARK: - Build

      private func rebuild() {
          menu.removeAllItems()

          let config = AppController.shared.config
          let state = AppController.shared.state
          let project = currentProject()

          // 只读状态行 1: 连续工作 Nmin · <project>
          let workedMin = Int(state.sitAccum / 60)
          let line1 = "连续工作 \(workedMin)min · \(project)"
          menu.addItem(disabledItem(line1))

          // 只读状态行 2: 下次久坐 Nmin 后
          let remainSec = max(0, config.sitThreshold - state.sitAccum)
          let remainMin = Int(ceil(remainSec / 60))
          let line2: String
          if !config.sitEnabled {
              line2 = "久坐提醒已关闭"
          } else if let muted = config.mutedUntil, Date() < muted {
              line2 = "专注中 · 提醒已静音"
          } else {
              line2 = "下次久坐提醒：\(remainMin)min 后"
          }
          menu.addItem(disabledItem(line2))

          menu.addItem(.separator())

          // 手动动作
          addItem("☕️ 我起身了", #selector(didTapManualRest))
          addItem("🔕 专注 1 小时", #selector(didTapFocusOneHour))

          menu.addItem(.separator())

          // 四开关(勾选态绑定 config)
          addToggle("久坐起身", on: config.sitEnabled, #selector(didToggleSit))
          addToggle("喝水", on: config.waterEnabled, #selector(didToggleWater))
          addToggle("护眼远眺", on: config.eyeEnabled, #selector(didToggleEye))
          addToggle("熬夜劝退", on: config.nightEnabled, #selector(didToggleNight))

          menu.addItem(.separator())

          addItem("⚙️ 设置…", #selector(didTapSettings))
          addItem("退出", #selector(didTapQuit))
      }

      // MARK: - Item helpers

      private func disabledItem(_ title: String) -> NSMenuItem {
          let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
          item.isEnabled = false
          return item
      }

      private func addItem(_ title: String, _ action: Selector) {
          let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
          item.target = self
          menu.addItem(item)
      }

      private func addToggle(_ title: String, on: Bool, _ action: Selector) {
          let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
          item.target = self
          item.state = on ? .on : .off
          menu.addItem(item)
      }

      // MARK: - Actions

      @objc private func didTapManualRest() {
          AppController.shared.manualRest()
      }

      @objc private func didTapFocusOneHour() {
          AppController.shared.muteFor(3600)
      }

      @objc private func didToggleSit()   { toggle { $0.sitEnabled.toggle() } }
      @objc private func didToggleWater() { toggle { $0.waterEnabled.toggle() } }
      @objc private func didToggleEye()   { toggle { $0.eyeEnabled.toggle() } }
      @objc private func didToggleNight() { toggle { $0.nightEnabled.toggle() } }

      @objc private func didTapSettings() {
          settingsWC.show()
      }

      @objc private func didTapQuit() {
          NSApp.terminate(nil)
      }

      /// 翻转某开关: 取当前 config → 变更 → 存 → 生效。
      private func toggle(_ mutate: (inout ReminderConfig) -> Void) {
          var cfg = AppController.shared.config
          mutate(&cfg)
          store.save(cfg)
          AppController.shared.applyConfig(cfg)
      }

      // MARK: - cc.json project

      /// 从 ~/.notchreminder/cc.json 读 project(CONTRACT §5.2)。缺失/未激活显示 "—"。
      private func currentProject() -> String {
          let path = (NSHomeDirectory() as NSString)
              .appendingPathComponent(".notchreminder/cc.json")
          guard
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = obj["cc_active"] as? Bool, active,
              let project = obj["project"] as? String, !project.isEmpty
          else {
              return "—"
          }
          return project
      }
  }
  ```

- [ ] **Step 7.15 — `swift build` 确认编译通过。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -15
  ```

  预期: `Build complete!`。`AppController.shared.config`/`state`/`applyConfig`/`manualRest`/`muteFor` 均由 Task 3 按 CONTRACT §C3 提供, 直接可用。

- [ ] **Step 7.16 — commit(MenuBar)。** 执行:

  ```bash
  \
  git add Sources/NotchReminder/MenuBar.swift && \
  git commit -m "Task 7: full menu bar (status lines + manual rest/mute + toggles + settings/quit)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit。

##### E. 首启引导

- [ ] **Step 7.17 — 写 `FirstRun.swift`。** 新建 `Sources/NotchReminder/FirstRun.swift`, 内容为下面**完整可编译**代码。首次运行(`store.hasCompletedFirstRun == false`)弹 `NSAlert` 说明面板 + 打印 CC 插件一键命令。

  ```swift
  import AppKit

  /// 首启一屏引导: 说明计时口径 + 打印 CC 插件一键安装命令。仅首次运行弹一次。
  enum FirstRunGuide {

      /// CC 插件一键安装命令(与 Task 8 install.sh 一致)。
      static let ccInstallCommand =
          "bash /Users/chunhaixu/NotchReminder/install.sh"

      @MainActor
      static func presentIfNeeded(store: SettingsStore) {
          guard !store.hasCompletedFirstRun else { return }

          print("""
          [NotchReminder] 首次运行。要让提醒带上「正在跑哪个 CC 项目」, 请安装 CC 插件:
              \(ccInstallCommand)
          idle 计时只读系统空闲时长(CGEventSourceSecondsSinceLastEventType), 无需辅助功能权限。
          """)

          let alert = NSAlert()
          alert.messageText = "欢迎使用 NotchReminder"
          alert.informativeText = """
          它会盯住你的连续活跃时长, 在刘海周围弹久坐 / 喝水 / 护眼 / 熬夜提醒。

          · 计时基于系统空闲时长(只读), 无需辅助功能权限。
          · 想让提醒带上当前 Claude Code 项目名, 可装 CC 插件:
            \(ccInstallCommand)
          · 阈值、开关、开机自启都能在菜单栏「⚙️ 设置…」里调。
          """
          alert.addButton(withTitle: "知道了")
          alert.alertStyle = .informational
          NSApp.activate(ignoringOtherApps: true)
          alert.runModal()

          store.hasCompletedFirstRun = true
      }
  }
  ```

- [ ] **Step 7.18 — `swift build` 确认编译通过。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -15
  ```

  预期: `Build complete!`。

##### F. 接线进 AppController 启动路径(main.swift) + 端到端手动验证

- [ ] **Step 7.19 — 在 `main.swift` 的 AppController 启动路径插入接线。** 打开 `Sources/NotchReminder/main.swift`(Task 3 的 `AppDelegate.applicationDidFinishLaunching` 里已建 `NSStatusItem` + `AppController.shared`)。做且仅做下面的**最小**接线, 不触碰采样循环。因 Task 3 已提供 `config`/`state`/`applyConfig`/`manualRest`/`muteFor`(CONTRACT §C3), **本 Task 不需改 Task 3 任何方法名**。

  在 `AppDelegate` 类型体内的属性区加:
  ```swift
      private let settingsStore = SettingsStore()
      private var menuBarController: MenuBarController?
  ```

  在 `applicationDidFinishLaunching(_:)` 里, **把 Step 3.5 的 AppController 构造改为从持久化取初始 config**, 并在其后接完整菜单 + 首启引导。即把 Step 3.5 的:
  ```swift
          let c = AppController(presenter: presenter)
          c.onSitSnooze = { [weak c] in c?.manualRest() }
          AppController.shared = c
          controller = c
          c.start()
  ```
  改成:
  ```swift
          let c = AppController(presenter: presenter, config: settingsStore.load())  // 初始 config 来自持久化
          c.onSitSnooze = { [weak c] in c?.manualRest() }
          AppController.shared = c
          controller = c
          // Task 7: 完整菜单 + 首启引导(替换 Task 1 的占位菜单)
          let mbc = MenuBarController(statusItem: statusItem, store: settingsStore)
          mbc.attach()
          menuBarController = mbc
          FirstRunGuide.presentIfNeeded(store: settingsStore)
          c.start()
  ```

  其中 `statusItem` / `presenter` / `controller` 为 Task 1/3 已有的属性。**删掉 Task 1 里对 `statusItem.menu` 的占位赋值那一行**(由 `mbc.attach()` 接管)——这是「移除本次改动造成的 orphan」范畴, 仅删被 MenuBarController 取代的那一行菜单赋值, 不动其它。

  > 注: Task 1 的 `AppDelegate` 里若还有 `private let presenter = NotchPresenter()` 与 fireTest/testItem 占位菜单, 保留 presenter(AppController 要用), 删占位菜单赋值即可。若 fireTest 选择器已无引用, 一并删该 orphan 方法与 testItem(仅限 Task 1 占位菜单相关)。

- [ ] **Step 7.20 — 全量 build + 全量 test。** 执行:

  ```bash
  swift build --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -8 && \
  swift test --package-path /Users/chunhaixu/NotchReminder --filter SettingsStoreTests 2>&1 | tail -6
  ```

  预期: `Build complete!` 且 `SettingsStoreTests` `Executed 5 tests, with 0 failures`。全量 `swift test`(不加 filter)本阶段累计 = 占位 1 + Engine 12 + AppControllerTests 2 + DoNotDisturb 4 + Replay 4 + CCSignalReader 5 + SettingsStore 5 = **33**(权威累计表见文末 Self-Review)。

- [ ] **Step 7.21 — 手动验证: 阈值改动即时生效 + 重启保留。** 步骤:

  1. 前台跑 App: `swift run --package-path /Users/chunhaixu/NotchReminder NotchReminder`(菜单栏出现 clock 图标; 首次运行会弹欢迎 Alert, 点"知道了")。
  2. 点菜单栏图标 → 「⚙️ 设置…」→ 把「久坐起身」滑块从 50 拖到 30 分钟。
  3. 确认已落盘:
     ```bash
     defaults read NotchReminder sitThreshold 2>/dev/null || \
     defaults find sitThreshold 2>&1 | grep -A1 sitThreshold | head -4
     ```
     预期: 打印出 `1800`(30min = 1800s)。
  4. `Ctrl-C` 停掉 App, 再次 `swift run ... NotchReminder`, 打开设置窗 → 「久坐起身」应仍显示 **30 分钟**。

- [ ] **Step 7.22 — 手动验证: 菜单动作 + 只读状态行。** 步骤:

  1. App 前台运行中, 点菜单栏图标: 顶部应显示「连续工作 Nmin · —」(无 CC 时 project 为「—」)与「下次久坐提醒：Nmin 后」。
  2. 点「☕️ 我起身了」→ 再次打开菜单, 「连续工作」应回到接近 0min(`manualRest` 清了 sitAccum)。
  3. 点「🔕 专注 1 小时」→ 再次打开菜单, 状态行第二行应变为「专注中 · 提醒已静音」。
  4. 点「久坐起身」开关 → 关闭后再开菜单该项应无勾, 且状态行第二行显示「久坐提醒已关闭」; 再点一次重新勾上。

- [ ] **Step 7.23 — 手动验证: 开机自启 enable → `launchctl print` 可见。** 步骤:

  1. 先构建 release 二进制(自启 plist 指向它):
     ```bash
     swift build -c release --package-path /Users/chunhaixu/NotchReminder && \
     ls -l /Users/chunhaixu/NotchReminder/.build/release/NotchReminder
     ```
  2. App 前台运行, 打开设置窗 → 打开「开机自启」Toggle。
  3. 确认 plist 已写且已 bootstrap:
     ```bash
     ls -l ~/Library/LaunchAgents/com.notchreminder.agent.plist && \
     launchctl print gui/$(id -u)/com.notchreminder.agent 2>&1 | head -6
     ```
     预期: plist 存在; `launchctl print` 打印出该 service 详情(state = running / waiting)。
  4. 关掉「开机自启」Toggle → 确认已卸:
     ```bash
     launchctl print gui/$(id -u)/com.notchreminder.agent 2>&1 | head -2 ; \
     ls ~/Library/LaunchAgents/com.notchreminder.agent.plist 2>&1
     ```
     预期: `Could not find service ...` 且 plist 文件已被删。

- [ ] **Step 7.24 — 手动验证: 重启/重登后自起(等价链路)。** 步骤:

  1. 重新打开「开机自启」Toggle 装上 plist。
  2. 手动触发一次(等价于登录后 launchd 拉起):
     ```bash
     launchctl kickstart -k gui/$(id -u)/com.notchreminder.agent && \
     sleep 1 && \
     launchctl print gui/$(id -u)/com.notchreminder.agent 2>&1 | grep -E "state|pid" | head -3
     ```
     预期: 输出含 `state = running` 与一个 `pid = <非0>`。
  3. 真机完整验证(可选): 注销再登录或重启后, 菜单栏应自动出现 clock 图标(`RunAtLoad=true` + `LimitLoadToSessionType=Aqua`)。
  4. 收尾: 关掉「开机自启」Toggle 卸载(见 Step 7.23.4)。

- [ ] **Step 7.25 — commit(FirstRun + main.swift 接线)。** 执行:

  ```bash
  \
  git add Sources/NotchReminder/FirstRun.swift Sources/NotchReminder/main.swift && \
  git commit -m "Task 7: first-run guide + wire SettingsStore/MenuBar/first-run into startup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit(新建 FirstRun.swift + 修改 main.swift)。

---

#### 验证清单(Task 完成判据)

- [ ] `swift test --filter SettingsStoreTests` 全绿: `Executed 5 tests, with 0 failures`。
- [ ] 改久坐阈值 50→30min 后, `defaults` 里 `sitThreshold=1800`; 重启 App 设置窗仍显示 30min(即时生效 + 重启保留)。
- [ ] 菜单栏状态行随 state 刷新;「我起身了」清久坐、「专注 1 小时」进静音、四开关勾选态与 config 一致。
- [ ] 开机自启 Toggle 打开后 `launchctl print gui/$(id -u)/com.notchreminder.agent` 命中(running); 关闭后 `Could not find service` 且 plist 已删。
- [ ] `launchctl kickstart` 能把它作为「登录自起」拉起并显示菜单栏图标。
- [ ] 首次运行弹欢迎 Alert 并打印 CC 插件一键命令; `hasCompletedFirstRun` 置真后不再弹。

#### 依赖与风险备注(feasibility 标签)

- **`@testable import NotchReminder` 对 executableTarget 生效** — `已验证`(本机 Swift 6.3.3)。
- **裸二进制 + LaunchAgent 能画菜单栏图标** — `已验证机制`(NSStatusItem 不要求 bundle)。`待真机坐实`: 完整注销/重启后自动出图标(Step 7.24.3, kickstart 等价链路已验证)。
- **idle API 零权限** — `已验证`(`CGEventSourceSecondsSinceLastEventType` 只读, 本机实测无 TCC 弹窗)。
- **`AppController` 五成员** — `已由 Task 3 提供`(CONTRACT §C3c): 本 Task 直接调用 `config`/`state`/`applyConfig`/`manualRest`/`muteFor`, 无需改 Task 3。
- **`onChange(of:)` 两参 closure** — `已验证可用`(macOS 14+; 本机 26.5)。工程钉 `.macOS(.v13)` 仅告警不阻断 build。
- **熬夜阈值范围** — 熬夜可调项 = `nightRepeat`(重复间隔); 23:00 窗口边界固定不暴露(见 Task 4 说明), 故设置窗只有「熬夜重复间隔」滑块无「熬夜起始时刻」滑块, 是有意范围收窄。

---

## Task 8: README + 安装/卸载脚本 + 收尾

> 前置: Task 1 已建好**单一 root `Package.swift`**(library `ReminderCore` + executableTarget `NotchReminder`,
> 依赖 `DynamicNotchKit` from 1.1.0), `swift build -c release` 产出裸二进制
> `/Users/chunhaixu/NotchReminder/.build/release/NotchReminder`; Task 2/4 的 `ReminderCore` 引擎 `swift test` 全绿;
> Task 3/5/6/7 已落地 App 层(`Sources/NotchReminder/*.swift`)与 CC 插件(`cc-plugin/.claude-plugin/plugin.json`——
> **`name` = `notchreminder`, CONTRACT §C5**、`cc-plugin/hooks/hooks.json`、`cc-plugin/hooks/touch_activity.py`),
> 状态文件契约 `~/.notchreminder/cc.json`。
>
> 本 Task 是**收尾交付**: 写 `README.md`、`install.sh`、`uninstall.sh`、`marketplace.json`, 最后一次 commit。
> 脚本按「写脚本 → 语法/构建校验 → 手动验证 → commit」推进, 不做 TDD。
> 所有命令、路径、CLI 子命令均已在本机(macOS 26.5 / Swift 6.3.3 / claude 2.1.170, uid=501, `$HOME`=/Users/chunhaixu)坐实。
> **插件名全链路统一 `notchreminder`(无连字符, CONTRACT §C5)**: plugin.json name = marketplace name = plugins[].name = install 目标 @ 两段。

#### Files

- `/Users/chunhaixu/NotchReminder/README.md` — **Create**。项目简介、架构图、构建/运行、装 CC 插件、开机自启、四类提醒与阈值表、权限说明、卸载。
- `/Users/chunhaixu/NotchReminder/cc-plugin/.claude-plugin/marketplace.json` — **Create**。本地单插件 marketplace 清单; marketplace `name` = plugin `name` = `notchreminder`(与 `plugin.json` 一致, CONTRACT §C5)。
- `/Users/chunhaixu/NotchReminder/install.sh` — **Create**。`swift build -c release` → `mkdir ~/.notchreminder` → 加 marketplace + 装/启用 CC 插件 → 写 + `bootstrap` LaunchAgent → 打印验证提示。幂等、`set -euo pipefail`。
- `/Users/chunhaixu/NotchReminder/uninstall.sh` — **Create**。`bootout` agent + 删 plist + 卸插件 + 移除 marketplace + 可选删 `~/.notchreminder`。

#### Interfaces

**Consumes(前序 Task 已产出的具体路径/契约, 本 Task 不新增类型):**

```
# 构建产物(Task 1 root Package.swift → swift build -c release)
/Users/chunhaixu/NotchReminder/Package.swift
/Users/chunhaixu/NotchReminder/.build/release/NotchReminder          # 裸 arm64 可执行, 菜单栏 accessory App

# ReminderCore 纯逻辑真源(Task 2/4, 本 Task 只在 README 里描述)
/Users/chunhaixu/NotchReminder/Sources/ReminderCore/Models.swift
/Users/chunhaixu/NotchReminder/Sources/ReminderCore/ReminderEngine.swift
#   ReminderEngine.advance(_ state:config:sample:) -> (ReminderState, [Reminder])
#   Reminder = .sit(minutes:project:) | .water | .eye | .night(clock:)

# CC 插件(Task 6)
/Users/chunhaixu/NotchReminder/cc-plugin/.claude-plugin/plugin.json   # { "name": "notchreminder", ... }  (CONTRACT §C5)
/Users/chunhaixu/NotchReminder/cc-plugin/hooks/hooks.json
/Users/chunhaixu/NotchReminder/cc-plugin/hooks/touch_activity.py

# 运行时状态契约(spec §5.2)
~/.notchreminder/cc.json         # { cc_active, project, session_start, last_event }
```

**Produces(交付物, 无对下游的代码接口):**

```
/Users/chunhaixu/NotchReminder/README.md
/Users/chunhaixu/NotchReminder/cc-plugin/.claude-plugin/marketplace.json   # marketplace "notchreminder" → plugin "notchreminder"
/Users/chunhaixu/NotchReminder/install.sh    # 幂等安装脚本
/Users/chunhaixu/NotchReminder/uninstall.sh  # 幂等卸载脚本
~/Library/LaunchAgents/com.notchreminder.agent.plist   # 由 install.sh 生成(不入库)
```

阈值/口径以 `ReminderCore.ReminderConfig` 默认值为唯一真源, README 表格逐字对齐:
`sit=50min / water=60min / eye=30min / night≥23:00(含 00:00–01:59) / rest=idle≥5min / active=idle<60s / ccGrace=90s / sitSnooze=15min / nightRepeat=30min`。

---

#### Steps

- [ ] **Step 8.1 — 写 `cc-plugin/.claude-plugin/marketplace.json`(本地单插件 marketplace 清单)。** install.sh 用 `claude plugin marketplace add <dir>` 加载, 该命令要求目标目录含 `.claude-plugin/marketplace.json`。新建该文件, 内容(plugin `name` 与 `cc-plugin/.claude-plugin/plugin.json` 的 `notchreminder` 一致, CONTRACT §C5):

  ```json
  {
    "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
    "name": "notchreminder",
    "owner": {
      "name": "chunhaixu",
      "email": "chunhaiyoung@foxmail.com"
    },
    "metadata": {
      "description": "NotchReminder 健康提醒工具的 CC 传感器插件本地 marketplace",
      "version": "1.0.0"
    },
    "plugins": [
      {
        "name": "notchreminder",
        "source": "./",
        "description": "把 Claude Code 活跃信号写入 ~/.notchreminder/cc.json, 给 NotchReminder App 的久坐/熬夜提醒补活跃与项目名",
        "version": "1.0.0",
        "author": {
          "name": "chunhaixu",
          "email": "chunhaiyoung@foxmail.com"
        },
        "keywords": ["health", "notch", "reminder", "hooks"],
        "category": "workflow"
      }
    ]
  }
  ```

- [ ] **Step 8.2 — 校验 marketplace 清单可被 CC 识别。** 执行:

  ```bash
  claude plugin validate /Users/chunhaixu/NotchReminder/cc-plugin 2>&1 | tail -20
  ```

  预期 **PASS**: 输出中包含插件 `notchreminder` 且无 error(退出码 0)。若报 `no plugin.json` / `missing marketplace.json`, 说明 Task 6 的 `plugin.json` 或本 Step 的 `marketplace.json` 路径不对(二者都必须在 `cc-plugin/.claude-plugin/` 下)。

- [ ] **Step 8.3 — 写 `install.sh`(幂等安装脚本)。** 新建 `/Users/chunhaixu/NotchReminder/install.sh`, 内容为下面**完整可运行**脚本(uid 用 `id -u` 动态取; 每步失败即 `set -e` 退出; marketplace/plugin/agent 三处均先清后加):

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  # NotchReminder 一键安装: 构建二进制 → 装 CC 插件 → 装开机自启 LaunchAgent。
  # 幂等: 可重复运行。所有路径按本仓库固定位置写死。

  REPO="/Users/chunhaixu/NotchReminder"
  BIN="$REPO/.build/release/NotchReminder"
  PLUGIN_DIR="$REPO/cc-plugin"
  STATE_DIR="$HOME/.notchreminder"
  PLIST_SRC_LABEL="com.notchreminder.agent"
  PLIST="$HOME/Library/LaunchAgents/$PLIST_SRC_LABEL.plist"
  UID_NUM="$(id -u)"

  echo "==> [1/5] 构建 release 二进制"
  swift build -c release --package-path "$REPO"
  if [ ! -x "$BIN" ]; then
    echo "错误: 构建后未找到可执行 $BIN" >&2
    exit 1
  fi
  echo "    产物: $BIN"

  echo "==> [2/5] 准备状态目录 $STATE_DIR"
  mkdir -p "$STATE_DIR"

  echo "==> [3/5] 安装 CC 插件(本地 marketplace: notchreminder)"
  # 先移除同名 marketplace 再加, 保证可重复运行(未安装时忽略报错)
  claude plugin marketplace remove notchreminder >/dev/null 2>&1 || true
  claude plugin marketplace add "$PLUGIN_DIR"
  # 装并启用插件(user scope); 已安装则 install 幂等, 再显式 enable 兜底
  claude plugin install notchreminder@notchreminder --scope user || true
  claude plugin enable notchreminder@notchreminder --scope user || true
  echo "    CC 插件 notchreminder@notchreminder 已安装启用(重启 claude 会话后 hooks 生效)"

  echo "==> [4/5] 安装开机自启 LaunchAgent"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST_EOF
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>Label</key>
      <string>$PLIST_SRC_LABEL</string>

      <key>ProgramArguments</key>
      <array>
          <string>$BIN</string>
      </array>

      <key>RunAtLoad</key>
      <true/>

      <key>KeepAlive</key>
      <dict>
          <key>Crashed</key>
          <true/>
      </dict>

      <key>ProcessType</key>
      <string>Interactive</string>

      <key>LimitLoadToSessionType</key>
      <string>Aqua</string>

      <key>StandardOutPath</key>
      <string>$STATE_DIR/agent.out.log</string>
      <key>StandardErrorPath</key>
      <string>$STATE_DIR/agent.err.log</string>
  </dict>
  </plist>
  PLIST_EOF

  # 改 plist 后必须先 bootout 再 bootstrap 才生效(未加载时忽略报错)
  launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$PLIST"
  launchctl kickstart -k "gui/$UID_NUM/$PLIST_SRC_LABEL"

  echo "==> [5/5] 完成"
  echo ""
  echo "验证:"
  echo "  1) 菜单栏应出现 NotchReminder 图标(时钟)。若无, 看日志:"
  echo "       cat $STATE_DIR/agent.err.log"
  echo "  2) 查看 agent 运行状态:"
  echo "       launchctl print gui/$UID_NUM/$PLIST_SRC_LABEL | head -20"
  echo "  3) 重启 claude 会话后, 发起一轮对话, 应写出状态文件:"
  echo "       cat $STATE_DIR/cc.json"
  echo "  4) 卸载: $REPO/uninstall.sh"
  ```

  说明(不写进脚本, 供实施者理解):
  - heredoc `PLIST_EOF` 不加引号, 故 `$PLIST_SRC_LABEL` / `$BIN` / `$STATE_DIR` 在写入时展开为真实值。plist 各行前导缩进随 heredoc 原样写入, XML 允许前导空白, 不影响 `plutil` 解析。
  - `KeepAlive={Crashed:true}`: 仅崩溃时自愈, 从菜单正常「退出」不会被 launchd 立即拉起。
  - `bootstrap gui/$(id -u)`: 现代 launchd 加载语义; 菜单栏 App 必须走 LaunchAgent(GUI 会话)而非 LaunchDaemon。

- [ ] **Step 8.4 — 写 `uninstall.sh`(幂等卸载脚本)。** 新建 `/Users/chunhaixu/NotchReminder/uninstall.sh`, 内容:

  ```bash
  #!/usr/bin/env bash
  set -uo pipefail

  # NotchReminder 卸载: 停 + 删 LaunchAgent → 卸 CC 插件 + 移除 marketplace。
  # 幂等: 各步未安装时忽略报错。默认保留 ~/.notchreminder(状态/日志); 传 --purge 一并删除。

  PLIST_SRC_LABEL="com.notchreminder.agent"
  PLIST="$HOME/Library/LaunchAgents/$PLIST_SRC_LABEL.plist"
  STATE_DIR="$HOME/.notchreminder"
  UID_NUM="$(id -u)"
  PURGE=0
  [ "${1:-}" = "--purge" ] && PURGE=1

  echo "==> [1/3] 停止并移除 LaunchAgent"
  launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "    已 bootout 并删除 $PLIST"

  echo "==> [2/3] 卸载 CC 插件与本地 marketplace"
  claude plugin uninstall notchreminder@notchreminder --scope user >/dev/null 2>&1 || true
  claude plugin marketplace remove notchreminder >/dev/null 2>&1 || true
  echo "    CC 插件 notchreminder 已移除(重启 claude 会话后 hooks 失效)"

  echo "==> [3/3] 状态目录"
  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$STATE_DIR"
    echo "    已删除 $STATE_DIR(--purge)"
  else
    echo "    保留 $STATE_DIR(如需一并删除, 重跑: $0 --purge)"
  fi

  echo "==> 卸载完成。二进制在 .build/ 内, git clean -xdf 可清理构建产物。"
  ```

- [ ] **Step 8.5 — 写 `README.md`。** 新建 `/Users/chunhaixu/NotchReminder/README.md`, 内容为下面**完整**文档(阈值表逐字对齐 `ReminderConfig` 默认值; 架构图取 spec §4 但插件名更正为 `notchreminder`; 权限段据本机实测的 idle API 零权限结论):

  ````markdown
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

  依赖: macOS 13+(本机 macOS 26.5 / Apple M5)、Swift 6+。App 依赖 [`DynamicNotchKit`](https://github.com/MrKai77/DynamicNotchKit)(MIT, SPM 自动拉取)。

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
  claude plugin marketplace add /Users/chunhaixu/NotchReminder/cc-plugin
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
  ````

- [ ] **Step 8.6 — 语法/构建自检(不实际装 agent)。** 依次执行, 逐条核对预期:

  ```bash
  # 1) 两个脚本 bash 语法无误(-n 只解析不执行)
  bash -n /Users/chunhaixu/NotchReminder/install.sh   && echo "install.sh OK"
  bash -n /Users/chunhaixu/NotchReminder/uninstall.sh && echo "uninstall.sh OK"

  # 2) 赋可执行位
  chmod +x /Users/chunhaixu/NotchReminder/install.sh /Users/chunhaixu/NotchReminder/uninstall.sh

  # 3) marketplace.json 是合法 JSON
  python3 -c "import json; json.load(open('/Users/chunhaixu/NotchReminder/cc-plugin/.claude-plugin/marketplace.json')); print('marketplace.json JSON OK')"

  # 4) release 二进制能构建出来
  swift build -c release --package-path /Users/chunhaixu/NotchReminder 2>&1 | tail -5
  ls -l /Users/chunhaixu/NotchReminder/.build/release/NotchReminder
  ```

  预期: 前三条分别打印 `install.sh OK` / `uninstall.sh OK` / `marketplace.json JSON OK`; 第 4 条 `swift build` 成功、`ls` 列出可执行文件(权限带 `x`)。

- [ ] **Step 8.7 — 端到端手动验证(实跑 install.sh, 可撤销)。** 执行安装并逐条核对:

  ```bash
  /Users/chunhaixu/NotchReminder/install.sh
  ```

  预期与手动核对:
  1. 脚本打印 `[1/5]`…`[5/5]` 五段, 最后输出「验证」提示块, 退出码 0。
  2. **菜单栏出现 NotchReminder 时钟图标**(accessory App, 无 Dock 图标)。
  3. agent 已注册:
     ```bash
     launchctl print gui/$(id -u)/com.notchreminder.agent | head -20
     ```
     预期含 `state = running` 且 `program = /Users/chunhaixu/NotchReminder/.build/release/NotchReminder`。
  4. CC 插件已装:
     ```bash
     claude plugin list 2>&1 | grep -i notchreminder
     ```
     预期列出 `notchreminder`(启用态)。
  5. 重启一个 claude 会话、发一轮对话后:
     ```bash
     cat ~/.notchreminder/cc.json
     ```
     预期是含 `cc_active` / `project` / `last_event` 字段的 JSON。
  6. **回滚验证卸载幂等**:
     ```bash
     /Users/chunhaixu/NotchReminder/uninstall.sh
     launchctl print gui/$(id -u)/com.notchreminder.agent 2>&1 | tail -1   # 预期: Could not find service
     ls ~/Library/LaunchAgents/com.notchreminder.agent.plist 2>&1          # 预期: No such file
     ```
     菜单栏图标应消失。`~/.notchreminder`(状态/日志)默认保留。

  > 说明: 若第 2 步图标未出现, `cat ~/.notchreminder/agent.err.log` 看崩溃原因(常见: `NSScreen.screens` 时序 / 二进制路径写错)。此为交付前必过的人工闸门。

- [ ] **Step 8.8 — commit(收尾)。** 执行:

  ```bash
  \
  git add README.md install.sh uninstall.sh cc-plugin/.claude-plugin/marketplace.json && \
  git commit -m "Task 8: README + install/uninstall scripts + local CC marketplace (notchreminder)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  预期: 一条 commit, 4 个文件纳入版本(README.md、install.sh、uninstall.sh、marketplace.json)。`~/Library/LaunchAgents/*.plist` 由脚本运行时生成, **不入库**; `.build/` 已被 `.gitignore` 忽略。

---

## Self-Review

### Spec 覆盖表(spec 各节 → Task)

| spec 节 | 内容 | 落地 Task |
|---|---|---|
| §1 背景与目标 / §2 画像 / §3 决策 | 设计依据(无代码产物) | 全篇设计前提, README §简介引用 |
| §4 架构总览 | 两部件 + cc.json 握手 + idle 主计时 | 架构落在 Task 3(采样)+ Task 5(浮层)+ Task 6(CC 插件); README(T8)画图(插件名更正为 notchreminder) |
| §5.1 CC 插件(纯传感器) | 4 hook → touch_activity.py 写 cc.json | **Task 6**(plugin.json/hooks.json/touch_activity.py + Python 测试) |
| §5.2 数据契约 cc.json | cc_active/project/session_start/last_event | **Task 6**(写: touch_activity.py; 读: CCSignalReader) |
| §5.3 计时引擎(idle 状态机) | dt/active/rest/CC 补活跃 + 四计时器 | **Task 2**(dt/active/rest/sit/CC)+ **Task 4**(water/eye/night)+ **Task 3**(ActivityMonitor 真采样接线) |
| §5.4 四类提醒 + 分级打扰 + 免打扰 | sit/water/eye/night 阈值 + 强/轻样式 + 全屏静默+补放 + 专注静音 | 逻辑: **Task 2/4**(阈值触发+muted); 样式: **Task 5**(强/轻); 全屏静默+auto-resume: **Task 3**(route/pending/flushPending in tick)+**Task 5**(真探针); 专注静音: **Task 7**(muteFor) |
| §5.5 菜单栏与交互 | 状态行/我起身了/专注1h/四开关/设置窗/首启引导/强样式 snooze | **Task 7**(SettingsStore/SettingsWindow/MenuBar/FirstRun)+ **Task 5**(强样式 snooze 按钮) |
| §6 目录结构 | 工程布局 | **Task 1**(root 布局, 更正 §6 的 app/ 草图)+ File Structure 段 |
| §7 分阶段交付 | 阶段 0–4 | 0→T1 / 1→T2+T3 / 2→T4+T5 / 3→T6 / 4→T7+T8 |
| §8 待验证/风险 | idle 权限 / auto-hide / 全屏检测 / 插件分发 | idle 零权限已坐实(T3); auto-hide 用 expand+sleep+hide(T5); 全屏 CGWindowList 近似(T5, 待真机复验); 插件分发 marketplace(T8) |
| §9 非目标(YAGNI) | 仪表盘/周报/通用刘海功能/云同步 | 全不做; 摄像头占用检测明确留 v2(T5 备注) |

### 占位符扫描结论

`placeholderClean = true`。全文通读无 TODO / TBD / FIXME / 「略」/「如上」/「添加适当错误处理」/「此处省略」/「写测试(无代码)」等占位。每个 Step 均给出完整可编译/可运行代码块或明确的 shell 命令 + 预期输出。文中出现的 `待验证 / 待真机复验 / 待实机坐实 / v2·不做` 是 feasibility 标签(明确标注的未坐实项与范围决策), 非代码占位。

> 扫描命令(实施者可自查):
> `grep -nE 'TODO|TBD|FIXME|XXX|待补|占位符|省略|如上所述' docs/plans/2026-07-07-notch-reminder-implementation.md` 应只命中本段自身对这些词的引用, 无实际占位。

### 类型/接口一致性结论

`typeConsistency = pass`(review 三处 blocker + 相关 major/minor 已在 Shared CONTRACT 段统一并贯穿各 Task):

- **AppController 单一契约(原 blocker)**: CONTRACT §C3 冻结唯一形状; **Task 3 是唯一 owner(Create 完整三面)**, Task 5(改 dnd 默认)、Task 6(改 tick 里 Sample 构造)、Task 7(启动路径接线)全部标 **Modify**, 不再各写各的。`static var shared` / `config` / `state` / `applyConfig` / `manualRest` / `muteFor` / `route` / `flushPending` / `pending` / `onSitSnooze` / `tick` / `start` 全集在 Task 3 一次落地。
- **NotchPresenter 唯一入口(原 blocker)**: CONTRACT §C2 定 `present(_:onAction:)` 为唯一对外方法, **删除 `show(_:)`**; Task 1 起即 `public final class` + `public init()`; Task 5 整份重写升级样式, 签名不变。AppController 全程用 `present`(经 route→show)。
- **插件名一致(原 blocker)**: CONTRACT §C5 定 `notchreminder`(无连字符); Task 6 plugin.json、Task 8 marketplace.json/install.sh/uninstall.sh/README 全用同名; `install notchreminder@notchreminder` 成立。
- **testTarget 唯一声明(原 major)**: CONTRACT §C4 定 `dependencies: ["NotchReminder", "ReminderCore"], path: "Tests/NotchReminderTests"`; Task 3 首建, Task 5/6/7 一律「检查存在即跳过」。
- **manualRest / onSitSnooze 统一语义(原 minor)**: CONTRACT §C3 定二者都 `sitAccum=0; lastSitAlert=nil`; App 启动接 `onSitSnooze = { manualRest() }`(Task 3 main.swift)。
- **DynamicNotchKit @MainActor 归属(原 minor)**: CONTRACT §C6 更正为「init 非 @MainActor, 仅 expand/compact/hide 经协议 @MainActor」; main.swift 报错归因于顶层 AppDelegate 构造(assumeIsolated), 非 DynamicNotchInfo.init。
- **auto-resume 接线(原 blocker)**: tick() 开头调 flushPending(Task 3 实现), 真运行 App 里全屏退出后下一拍自动补放; Step 5.11(3) 加了真运行验证。
- **NotchPresenter 可访问性中间态(原 minor)**: Task 1 起即 public, 无 internal→public 漂移。
- **熬夜阈值范围(原 minor)**: Task 4 + Task 7 显式记「可调项=nightRepeat, 23:00 边界固定不暴露」。
- ReminderCore 层(Sample/ReminderConfig/ReminderState/Reminder/advance/isNight/clockString)与 CONTRACT §C1 逐字一致, 无漂移。

### 测试累计表(线性 T1→T8 应用, 各 Task 硬判据用 `--filter <本 Task TestCase>`)

| 完成到 | 新增 TestCase(用例数) | 全量 `swift test` 累计 |
|---|---|---|
| T1 | ReminderCoreTests 占位(1) | 1 |
| T2 | ReminderEngineTests +5 | 6 |
| T3 | AppControllerTests(2) | 8 |
| T4 | ReminderEngineTests +7 | 15 |
| T5 | DoNotDisturbTests(4) + AppControllerReplayTests(4) | 23 |
| T6 | CCSignalReaderTests(5) | 28 |
| T7 | SettingsStoreTests(5) | 33 |
| T8 | (交付脚本, 无新增 XCTest) | 33 |

> 各 Task 的 PASS 判据一律用 `--filter <本 Task 的 TestCase>`(如 `--filter CCSignalReaderTests` → `Executed 5 tests`), **不依赖脆弱的全量总数**。全量总数以本表为准; 若某 Task 想跑全量, 对照本表列对应累计值。此表解决了 review 指出的「T6/T7 各自写 17、忽略彼此测试」的矛盾。

### 仍存的 unresolved(feasibility 标签, 非计划缺陷)

以下均为**明确标注、待真机/实机坐实**的项, 已在对应 Task 就地标签, 不阻断实施(在图形会话由执行者人工确认):

- **裸可执行显示刘海浮层**(T1 Step 1.8 / T5 Step 5.11): `待实机坐实`。SPM 三 target build/test/run 已坐实; 实机点击后刘海卡片实际显示未坐实, 不显示则按 T1 Fallback 改 `.app` bundle。
- **全屏检测 + auto-resume 真机行为**(T5 Step 5.11(3)): `待真机复验`。CGWindowList 近似 + tick flushPending 已接线, 需真全屏 App 复验一次。
- **注销/重启后 LaunchAgent 自起**(T7 Step 7.24.3): `待真机坐实`。`launchctl kickstart` 等价链路已验证, 完整重登/重启由执行者可选复验。
- **摄像头占用检测**: `v2 · 明确不做`(T5 备注)。范围决策(YAGNI), 全屏检测已覆盖演示/会议/看片主要场景。

（无未修复的 blocker/major——review 的 3 个 blocker + 相关 major/minor 均已在 CONTRACT 段统一并落到各 Task。）
