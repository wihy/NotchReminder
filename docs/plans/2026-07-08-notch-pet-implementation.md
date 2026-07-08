# NotchReminder 宠物特效 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给已上线的 NotchReminder 增加刘海常驻的 SwiftUI 手绘团子宠物,平时按工作状态变心情、提醒时演对应动作,不破坏 v1 提醒链路与现有测试。

**Architecture:** 新增纯函数 `petMood` 进 ReminderCore(可单测);app 层加 `PetViewModel`(@MainActor ObservableObject)+ `PetView`(手绘团子)。`NotchPresenter` 从「每条提醒新建临时 notch」重构为「一个长存 `DynamicNotch`(compactLeading=宠物 / expanded=提醒卡含宠物)」,平时 `compact()` 常驻、提醒时 `expand()`、演完回 `compact()`。`AppController.tick` 接一行 `petMood→presenter.setPetMood`。`petEnabled=false` 用同一套视图的 `showsPet` 开关降级,不维护双路径。

**Tech Stack:** Swift / SwiftPM / SwiftUI(Path/Shape 手绘 + 属性动画)/ DynamicNotchKit 1.1.0(compact+expand 三态)/ AppKit(NSWorkspace 灭屏通知)。无新依赖。

## Global Constraints

逐条 verbatim(下游所有 Task 遵循,摘自 spec §1.2 + 既有 v1 约束):

- 部署目标 macOS 14+(v1 已批准;Package.swift `.macOS(.v14)` 不动)。
- Swift Package Manager;纯逻辑进 library `ReminderCore`(可 `swift test`),app 视图进 executable `NotchReminder`。**不新增 SPM 依赖;不改 Package.swift**(Pet 文件放 `Sources/NotchReminder/Pet/` 子目录,SPM 自动递归)。
- `ReminderEngine.advance` 及其全部既有测试**不改动**(33 XCTest 保持绿)。本计划只**新增** `PetMood.swift` + 测试,重构 `NotchPresenter`,其余 app 文件做最小 Modify。
- 宠物心情由引擎现有状态零成本映射;`petMood` 是纯函数(无副作用、不 import AppKit),必须先测后写。
- 耗电约束:平时低频 idle 动画(呼吸 ~3-4s autoreverse + 偶尔眨眼);灭屏/锁屏 `vm.sleep()` 停动画;全屏时 `hide()` 连宠物一起隐。
- 默认值:`petEnabled=true`、`petPauseOnBattery=false`、`petCharacter="blob"`(v1 仅团子)。
- `Reminder` 四 case 与 `ReminderConfig`/`ReminderState` 字段名逐字与 v1 一致(见 `Sources/ReminderCore/Models.swift`)。

---

## File Structure

```
NotchReminder/  (仓库根, ~/NotchReminder)
├── Sources/ReminderCore/
│   └── PetMood.swift                      # [T1] 新 enum PetMood + petMood() 纯函数
├── Sources/NotchReminder/Pet/
│   ├── PetViewModel.swift                 # [T2] 新 @MainActor ObservableObject(mood/act/isAwake/isPetting)
│   ├── PetAct.swift                       # [T3] 新 enum PetAct + actFor(_:)
│   ├── PetView.swift                      # [T3] 新 PetShape + PetCompactView + PetExpandedView(showsPet)
│   └── ScreenPowerObserver.swift          # [T4] 新 灭屏/唤醒 → vm.sleep/wake
├── Sources/NotchReminder/
│   ├── NotchPresenter.swift               # [T4 改] 长存 DynamicNotch·compact↔expand·petEnabled 降级
│   ├── AppController.swift                # [T4 改一处] tick 末尾 presenter.setPetMood(petMood(...))
│   ├── SettingsStore.swift                # [T5 改] +petEnabled/petPauseOnBattery/petCharacter
│   ├── SettingsWindow.swift               # [T5 改] +宠物分组(总开关+电源静止+形象占位)
│   └── StrongReminderView.swift           # [T3 删] 按钮逻辑并入 PetExpandedView
├── Tests/ReminderCoreTests/
│   └── PetMoodTests.swift                 # [T1] 新 ~6 例
└── Tests/NotchReminderTests/
    ├── PetViewModelTests.swift            # [T2] 新 setMood/playAct/clearAct/sleep/wake/pet
    └── SettingsStoreTests.swift           # [T5 改] +3 字段 round-trip
```

> 提醒卡统一为 `PetExpandedView`(`showsPet:Bool`)后,`StrongReminderView` 删除。`NotchPresenter` 对外 `present(_:onAction:)` 签名与 `presentCount` 测试钩子不变,AppController 调用点几乎不动。

---

## Task 1: PetMood 纯函数 + 测试(spec P1)

> 把引擎现有状态映射成宠物心情。纯函数、进 ReminderCore、TDD。不碰任何既有文件(仅新增)。

**Files:**
- Create: `Sources/ReminderCore/PetMood.swift`
- Create: `Tests/ReminderCoreTests/PetMoodTests.swift`

**Interfaces:**
- Consumes: `ReminderState`(字段 `sitAccum`)、`ReminderConfig`(字段 `sitThreshold`/`mutedUntil`)、`ReminderEngine.isNight(_:calendar:)`(均来自 v1 `Sources/ReminderCore/`)。
- Produces: `enum PetMood { fresh, calm, tired, exhausted, sleepy, dozing }` + `func petMood(state: ReminderState, config: ReminderConfig, now: Date) -> PetMood`(均 `public`)。下游 Task 4 消费。

- [ ] **Step 1.1 — 写失败测试 `PetMoodTests.swift`。** 新建 `Tests/ReminderCoreTests/PetMoodTests.swift`:

```swift
import XCTest
@testable import ReminderCore

final class PetMoodTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private var baseComponents: DateComponents {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 8; c.hour = 14; c.minute = 0; c.second = 0
        return c
    }
    private var noon: Date { cal.date(from: baseComponents)! }
    private func night(hour: Int) -> Date {
        var c = baseComponents; c.hour = hour; return cal.date(from: c)!
    }

    private func state(sitAccum: TimeInterval) -> ReminderState {
        ReminderState(sitAccum: sitAccum)
    }

    // 1) 静音(mutedUntil 在未来) → dozing, 优先级最高
    func testMutedIsDozing() {
        let cfg = ReminderConfig(mutedUntil: noon.addingTimeInterval(60))
        XCTAssertEqual(petMood(state: state(sitAccum: 0), config: cfg, now: noon), .dozing)
    }

    // 2) 夜里(23:00) → sleepy(不论 sitAccum)
    func testNightIsSleepy() {
        let cfg = ReminderConfig()
        XCTAssertEqual(petMood(state: state(sitAccum: 0), config: cfg, now: night(hour: 23)), .sleepy)
        XCTAssertEqual(petMood(state: state(sitAccum: 6000), config: cfg, now: night(hour: 0)), .sleepy)
    }

    // 3) 连续 ≥90min → exhausted
    func testExhausted() {
        let cfg = ReminderConfig()
        XCTAssertEqual(petMood(state: state(sitAccum: 90 * 60), config: cfg, now: noon), .exhausted)
    }

    // 4) 连续 ≥sitThreshold(50min) 但 <90min → tired
    func testTired() {
        let cfg = ReminderConfig()
        XCTAssertEqual(petMood(state: state(sitAccum: 50 * 60), config: cfg, now: noon), .tired)
        XCTAssertEqual(petMood(state: state(sitAccum: 70 * 60), config: cfg, now: noon), .tired)
    }

    // 5) sitAccum <10min → fresh
    func testFresh() {
        let cfg = ReminderConfig()
        XCTAssertEqual(petMood(state: state(sitAccum: 0), config: cfg, now: noon), .fresh)
        XCTAssertEqual(petMood(state: state(sitAccum: 9 * 60), config: cfg, now: noon), .fresh)
    }

    // 6) 中等 → calm
    func testCalm() {
        let cfg = ReminderConfig()
        XCTAssertEqual(petMood(state: state(sitAccum: 30 * 60), config: cfg, now: noon), .calm)
    }

    // 7) 优先级: muted 高于 night
    func testMutedBeatsNight() {
        let cfg = ReminderConfig(mutedUntil: night(hour: 23).addingTimeInterval(60))
        XCTAssertEqual(petMood(state: state(sitAccum: 0), config: cfg, now: night(hour: 23)), .dozing)
    }
}
```

- [ ] **Step 1.2 — 运行确认失败(RED)。** Run:
```bash
cd ~/NotchReminder && swift test --filter PetMoodTests
```
Expected: FAIL, `cannot find 'petMood' in scope` / `cannot find type 'PetMood'`。

- [ ] **Step 1.3 — 实现 `PetMood.swift`。** 新建 `Sources/ReminderCore/PetMood.swift`:

```swift
import Foundation

/// 宠物心情。由引擎现有状态经 petMood() 纯函数映射(spec §3.1)。
public enum PetMood: Equatable {
    case fresh       // 刚开工 / 刚真休息过(sitAccum 低)
    case calm        // 正常工作
    case tired       // 连续 ≥ sitThreshold(50min)
    case exhausted   // 连续 ≥ 90min
    case sleepy      // 夜里(23:00–01:59)
    case dozing      // 静音/专注中
}

/// 把引擎现有状态映射成宠物心情。纯函数: 无副作用、不依赖 AppKit、确定、可单测。
/// 优先级(首个命中即返回, spec §3.1):
/// 1) now < mutedUntil → .dozing
/// 2) isNight(now)     → .sleepy
/// 3) sitAccum ≥ 90*60 → .exhausted
/// 4) sitAccum ≥ sitThreshold → .tired
/// 5) sitAccum < 10*60 → .fresh
/// 6) else             → .calm
public func petMood(state: ReminderState, config: ReminderConfig, now: Date) -> PetMood {
    if let mutedUntil = config.mutedUntil, now < mutedUntil {
        return .dozing
    }
    if ReminderEngine.isNight(now) {
        return .sleepy
    }
    if state.sitAccum >= 90 * 60 {
        return .exhausted
    }
    if state.sitAccum >= config.sitThreshold {
        return .tired
    }
    if state.sitAccum < 10 * 60 {
        return .fresh
    }
    return .calm
}
```

- [ ] **Step 1.4 — 运行确认通过(GREEN)。** Run:
```bash
cd ~/NotchReminder && swift test --filter PetMoodTests
```
Expected: PASS, `Executed 7 tests, with 0 failures`。再跑全量 `swift test`, Expected `Executed 40 tests, with 0 failures`(33 + PetMood 7)。

- [ ] **Step 1.5 — Commit。**
```bash
cd ~/NotchReminder && git add Sources/ReminderCore/PetMood.swift Tests/ReminderCoreTests/PetMoodTests.swift && git commit -m "feat(pet): PetMood 纯函数 + 测试(引擎状态→6 心情)"
```

---

## Task 2: PetAct + PetViewModel + 测试(spec P2 逻辑基础)

> 提醒→演出动作的映射 + 宠物状态机(纯状态持有,不含动画)。@MainActor ObservableObject,可单测。

**Files:**
- Create: `Sources/NotchReminder/Pet/PetAct.swift`
- Create: `Sources/NotchReminder/Pet/PetViewModel.swift`
- Create: `Tests/NotchReminderTests/PetViewModelTests.swift`

**Interfaces:**
- Consumes: `Reminder`(v1, 四 case)。
- Produces: `enum PetAct { drink, lookAway, stretch, yawn }` + `func actFor(_ r: Reminder) -> PetAct`; `PetViewModel`(字段 `mood`/`act`/`isAwake`/`isPetting` + 方法 `setMood`/`playAct`/`clearAct`/`sleep`/`wake`/`pet`/`clearPet`,均 internal 可见供 `@testable` 测试 + 同 target 视图用)。下游 Task 3 视图、Task 4 presenter 消费。

- [ ] **Step 2.1 — 写失败测试 `PetViewModelTests.swift`。** 新建 `Tests/NotchReminderTests/PetViewModelTests.swift`:

```swift
import XCTest
@testable import NotchReminder
import ReminderCore

@MainActor
final class PetViewModelTests: XCTestCase {

    func testSetMood() {
        let vm = PetViewModel()
        vm.setMood(.tired)
        XCTAssertEqual(vm.mood, .tired)
        vm.setMood(.dozing)
        XCTAssertEqual(vm.mood, .dozing)
    }

    func testPlayActAndClear() {
        let vm = PetViewModel()
        vm.playAct(.drink)
        XCTAssertEqual(vm.act, .drink)
        vm.clearAct()
        XCTAssertNil(vm.act)
    }

    func testSleepWake() {
        let vm = PetViewModel()
        XCTAssertTrue(vm.isAwake)
        vm.sleep()
        XCTAssertFalse(vm.isAwake)
        vm.wake()
        XCTAssertTrue(vm.isAwake)
    }

    func testPetAndClear() {
        let vm = PetViewModel()
        XCTAssertFalse(vm.isPetting)
        vm.pet()
        XCTAssertTrue(vm.isPetting)
        vm.clearPet()
        XCTAssertFalse(vm.isPetting)
    }

    func testActForMapping() {
        XCTAssertEqual(actFor(.water), .drink)
        XCTAssertEqual(actFor(.eye), .lookAway)
        XCTAssertEqual(actFor(.sit(minutes: 50, project: nil)), .stretch)
        XCTAssertEqual(actFor(.night(clock: "23:30")), .yawn)
    }
}
```

- [ ] **Step 2.2 — 运行确认失败(RED)。** Run:
```bash
cd ~/NotchReminder && swift test --filter PetViewModelTests
```
Expected: FAIL, `cannot find 'PetViewModel' in scope` / `cannot find 'actFor'`。

- [ ] **Step 2.3 — 实现 `PetAct.swift`。** 新建目录与文件 `Sources/NotchReminder/Pet/PetAct.swift`:
```bash
mkdir -p ~/NotchReminder/Sources/NotchReminder/Pet
```
```swift
import ReminderCore

/// 提醒触发时宠物的演出动作。
public enum PetAct: Equatable {
    case drink      // 喝水
    case lookAway   // 护眼远眺
    case stretch    // 久坐伸懒腰
    case yawn       // 熬夜打哈欠
}

/// Reminder → PetAct 平凡映射。
public func actFor(_ r: Reminder) -> PetAct {
    switch r {
    case .water:  return .drink
    case .eye:    return .lookAway
    case .sit:    return .stretch
    case .night:  return .yawn
    }
}
```

- [ ] **Step 2.4 — 实现 `PetViewModel.swift`。** 新建 `Sources/NotchReminder/Pet/PetViewModel.swift`:

```swift
import SwiftUI
import ReminderCore

/// 宠物状态机。纯状态持有(mood / act / isAwake / isPetting), 不含动画/定时——
/// 动画由 SwiftUI 视图按 @Published 状态自行驱动; 演出后的收起定时由 NotchPresenter 管(expand/compact 所在层)。
/// 整类 @MainActor: 被 NotchPresenter(主 actor) 与视图共享。
@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var mood: PetMood = .fresh
    @Published public private(set) var act: PetAct?
    @Published public private(set) var isAwake: Bool = true
    @Published public private(set) var isPetting: Bool = false

    public init() {}

    public func setMood(_ m: PetMood) { mood = m }
    public func playAct(_ a: PetAct) { act = a }
    public func clearAct() { act = nil }
    public func sleep() { isAwake = false }
    public func wake() { isAwake = true }
    public func pet() { isPetting = true }
    public func clearPet() { isPetting = false }
}
```

- [ ] **Step 2.5 — 运行确认通过(GREEN)。** Run:
```bash
cd ~/NotchReminder && swift test --filter PetViewModelTests
```
Expected: PASS, `Executed 5 tests, with 0 failures`。全量 `swift test` → `Executed 45 tests, with 0 failures`(40 + 5)。

- [ ] **Step 2.6 — Commit。**
```bash
cd ~/NotchReminder && git add Sources/NotchReminder/Pet Tests/NotchReminderTests/PetViewModelTests.swift && git commit -m "feat(pet): PetAct + PetViewModel 状态机 + 测试"
```

---

## Task 3: PetView 手绘团子 + 删除 StrongReminderView(spec P2 视觉)

> SwiftUI Path 画团子,6 心情静态姿态 + 4 演出;`PetExpandedView` 吸收旧 `StrongReminderView` 的按钮逻辑(`showsPet` 控是否画宠物)。视觉任务——`swift run` 真机看,无单测。

**Files:**
- Create: `Sources/NotchReminder/Pet/PetView.swift`
- Delete: `Sources/NotchReminder/StrongReminderView.swift`
- (Modify 铺垫) `Sources/NotchReminder/NotchPresenter.swift` 本 Task **不改**(Task 4 才重构);本 Task 仅让 `PetExpandedView` 就绪并删旧文件。**注意**:删 `StrongReminderView.swift` 后 `NotchPresenter` 仍引用它 → 会编译失败。故本 Task 的 Step 3.4 给 `NotchPresenter` 打一个**临时桥接**:把对 `StrongReminderView` 的引用改为 `PetExpandedView(showsPet: true, ...)` 调用,使 build 不破,但仍是「每条提醒新建临时 notch」(Task 4 再改长存)。这样每个 Task 都绿。

**Interfaces:**
- Consumes: `PetMood`(T1)、`PetAct` + `PetViewModel`(T2)、`SitAction`(v1 NotchPresenter 现有 `public enum`)。
- Produces: `PetCompactView`(刘海旁小团子,绑 vm)、`PetExpandedView`(提醒卡:团子演出 + 文案 + 可选按钮,绑 vm + onSnooze/onDismiss)。下游 Task 4 presenter 构造 DynamicNotch 时用。

- [ ] **Step 3.1 — 实现 `PetView.swift`。** 新建 `Sources/NotchReminder/Pet/PetView.swift`:

```swift
import SwiftUI
import ReminderCore

// MARK: - 团子主体 Shape

/// 手绘团子: 一个带轻微变形的圆(用 Path 近似 squircle), 颜色按心情。
/// 视觉为 v1 草图, 可后续精修; 关键是 mood/act/isPetting 参数化能驱动姿态。
struct BlobShape: Shape {
    var squash: CGFloat  // 1.0=正圆, <1 压扁(累), >1 拉长(精神/伸懒腰)
    func path(in rect: CGRect) -> Path {
        let w = rect.width * squash
        let h = rect.height / squash
        let r = CGRect(x: rect.midX - w/2, y: rect.midY - h/2, width: w, height: h)
        return Path(ellipseIn: r)
    }
}

// MARK: - 单只团子(共享姿态逻辑)

/// 按 mood/act/isPetting 选颜色 + squash + 眼/嘴装饰。compact 与 expanded 复用。
struct PetBlob: View {
    let mood: PetMood
    let act: PetAct?
    let isAwake: Bool
    let isPetting: Bool
    var size: CGFloat = 40

    private var color: Color {
        switch mood {
        case .fresh:     return Color(red: 0.55, green: 0.85, blue: 0.95)
        case .calm:      return Color(red: 0.60, green: 0.80, blue: 0.90)
        case .tired:     return Color(red: 0.70, green: 0.75, blue: 0.85)
        case .exhausted: return Color(red: 0.78, green: 0.72, blue: 0.82)
        case .sleepy:    return Color(red: 0.66, green: 0.62, blue: 0.82)
        case .dozing:    return Color(red: 0.72, green: 0.70, blue: 0.80)
        }
    }
    private var squash: CGFloat {
        if isPetting { return 1.12 }                       // rua: 弹起
        if act == .stretch { return 1.15 }                 // 伸懒腰: 拉长
        switch mood {
        case .exhausted: return 0.72                       // 塌一摊
        case .tired:     return 0.85
        case .fresh:     return 1.05
        default:         return 0.95
        }
    }
    /// 眼开合度(0=闭眼, 1=全开)。
    private var eyeOpen: CGFloat {
        if !isAwake { return 0 }                           // 睡着闭眼
        if mood == .sleepy { return 0.35 }                 // 半眯
        if mood == .tired || mood == .exhausted { return 0.6 }
        return 1
    }

    var body: some View {
        ZStack {
            BlobShape(squash: squash)
                .fill(color)
                .frame(width: size, height: size)
            // 两眼
            HStack(spacing: size * 0.18) {
                eye(open: eyeOpen)
                eye(open: eyeOpen)
            }
            .offset(y: -size * 0.08)
            // 嘴/装饰
            if act == .yawn || mood == .sleepy {
                Circle().fill(Color.black.opacity(0.55)).frame(width: size*0.10, height: size*0.10)
                    .offset(y: size * 0.12)
            }
            if mood == .exhausted {
                Text(verbatim: "💦").font(.system(size: size*0.28)).offset(x: size*0.32, y: -size*0.28)
            }
            if !isAwake || mood == .dozing {
                Text(verbatim: "z").font(.system(size: size*0.30, weight: .bold))
                    .offset(x: size*0.30, y: -size*0.34)
            }
        }
        .frame(width: size*1.4, height: size*1.4)
    }

    private func eye(open: CGFloat) -> some View {
        Capsule().fill(Color.black.opacity(0.8))
            .frame(width: size*0.07, height: size*0.12 * max(0.05, open))
    }
}

// MARK: - compact(刘海旁)

/// 刘海旁的小团子。绑 vm, 平时呼吸 + 偶尔眨眼(由 act/isPetting 覆盖)。showsPet=false → EmptyView。
struct PetCompactView: View {
    @ObservedObject var vm: PetViewModel
    var showsPet: Bool

    // 呼吸: 缓慢 scale autoreverse(~3.5s)。只在 awake 时动。
    @State private var breathe = false

    var body: some View {
        Group {
            if showsPet {
                PetBlob(mood: vm.mood, act: vm.act, isAwake: vm.isAwake, isPetting: vm.isPetting, size: 22)
                    .scaleEffect(vm.isAwake && vm.act == nil ? (breathe ? 1.05 : 0.95) : 1)
                    .animation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true), value: breathe)
                    .onAppear {
                        if vm.isAwake { breathe.toggle() }
                    }
                    .onChange(of: vm.isAwake) { _, awake in if awake { breathe.toggle() } }
            } else {
                EmptyView()
            }
        }
    }
}

// MARK: - expanded(提醒卡)

/// 提醒卡: 大团子(演出) + 文案 + [sit/night 带按钮]。取代旧 StrongReminderView。
/// 文案/按钮由外部 presenter 经 onSnooze/onDismiss 传入(与旧 StrongReminderView 同契约)。
struct PetExpandedView: View {
    @ObservedObject var vm: PetViewModel
    var showsPet: Bool
    let title: String
    let subtitle: String
    let showSnooze: Bool              // sit=true / night=false / water,eye 不会进 expanded 走带按钮路径
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if showsPet {
                PetBlob(mood: vm.mood, act: vm.act, isAwake: vm.isAwake, isPetting: false, size: 46)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.headline).foregroundStyle(.primary)
                Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary)
                if showSnooze {
                    HStack(spacing: 10) {
                        Button(action: onSnooze) { Text(verbatim: "起身5分钟") }.buttonStyle(.borderedProminent)
                        Button(action: onDismiss) { Text(verbatim: "知道了") }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 360)
    }
}
```

- [ ] **Step 3.2 — 编译检查。** Run:
```bash
cd ~/NotchReminder && swift build
```
Expected: Build complete(PetView 自洽,还没人引用)。

- [ ] **Step 3.3 — 删旧 `StrongReminderView.swift`。** Run:
```bash
rm ~/NotchReminder/Sources/NotchReminder/StrongReminderView.swift
```

- [ ] **Step 3.4 — 临时桥接 `NotchPresenter`, 让 build 不破。** 打开 `Sources/NotchReminder/NotchPresenter.swift`, 把 `presentStrong(...)` 内对 `StrongReminderView(...)` 的构造替换为 `PetExpandedView(...)`。**仅这一处构造改**,其余(每条提醒新建临时 notch、expand/hide)保持不变,Task 4 再重构为长存 notch。

定位 `presentStrong` 方法体内(当前约 60-74 行)的:
```swift
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
```
替换为(用长存 vm;此处先给 presenter 加一个 `private let petVM = PetViewModel()` 字段供临时用,Task 4 复用):
```swift
let notch = DynamicNotch {
    PetExpandedView(
        vm: self.petVM,
        showsPet: true,
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
```
并在 `NotchPresenter` 类顶部字段区(现有 `strongNotch`/`presentCount` 旁)新增:
```swift
let petVM = PetViewModel()   // Task 3 临时用于 PetExpandedView; Task 4 升级为长存 notch 的共享 vm
```
> 注意:`DynamicNotch<PetExpandedView,...>` 的泛型从 `<StrongReminderView, EmptyView, EmptyView>` 变成 `<PetExpandedView, EmptyView, EmptyView>`,同步改 `strongNotch` 字段类型声明。

- [ ] **Step 3.5 — 编译 + 全量测试。** Run:
```bash
cd ~/NotchReminder && swift build && swift test
```
Expected: Build complete; `Executed 45 tests, with 0 failures`(PetView 无单测,但既有测试不被破坏;`presentCount` 钩子仍在)。

- [ ] **Step 3.6 — 手动视觉验证(可选, 本机图形会话)。** Run `swift run NotchReminder`,触发一次久坐提醒(临时把 sitThreshold 调小或等),确认提醒卡里出现团子 + 文案 + 按钮。无头环境跳过,记为 concern。

- [ ] **Step 3.7 — Commit。**
```bash
cd ~/NotchReminder && git add -A && git commit -m "feat(pet): PetView 手绘团子(compact/expanded) + 删除 StrongReminderView"
```

---

## Task 4: 长存 DynamicNotch + compact↔expand + ScreenPowerObserver + AppController 接线(spec P3+P4)

> 核心集成: presenter 从「每条提醒新建临时 notch」重构为「启动建一个长存 notch(compactLeading=宠物)」,平时 compact、提醒 expand、演完 compact;AppController tick 推心情;灭屏睡/唤醒。`petEnabled=false` 用 `showsPet` 降级(notch hide 而非 compact)。

**Files:**
- Create: `Sources/NotchReminder/Pet/ScreenPowerObserver.swift`
- Modify: `Sources/NotchReminder/NotchPresenter.swift`(重构)
- Modify: `Sources/NotchReminder/AppController.swift`(tick 末尾一行 + 读 petEnabled 设置)
- Modify: `Sources/NotchReminder/main.swift`(启动时 presenter.attachPet() / 推初始 petEnabled)

**Interfaces:**
- Consumes: `PetCompactView`/`PetExpandedView`(T3)、`PetViewModel`/`PetAct`/`actFor`(T2)、`PetMood`/`petMood`(T1)、`ReminderEngine.compact/expand/hide`(DynamicNotchKit)。
- Produces: `NotchPresenter` 新公开方法 `setPetMood(_:)`、`setPetEnabled(Bool)`、`attachPet()`;`ScreenPowerObserver`(internal)。下游 Task 5 设置 + AppController 消费。

- [ ] **Step 4.1 — 实现 `ScreenPowerObserver.swift`。** 新建 `Sources/NotchReminder/Pet/ScreenPowerObserver.swift`:

```swift
import AppKit

/// 监听系统灭屏/唤醒, 推动 PetViewModel.sleep()/wake()(spec §3.5 耗电控制)。
/// 用 NSWorkspace 共享通知中心: screensDidSleep/Wake 覆盖「屏不亮」场景。
final class ScreenPowerObserver {
    private let vm: PetViewModel
    private var tokens: [NSObjectProtocol] = []

    init(vm: PetViewModel) { self.vm = vm }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                     object: nil, queue: .main) { [weak vm] _ in
            MainActor.assumeIsolated { vm?.sleep() }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                     object: nil, queue: .main) { [weak vm] _ in
            MainActor.assumeIsolated { vm?.wake() }
        })
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
    }
}
```

- [ ] **Step 4.2 — 重构 `NotchPresenter.swift`。** 整份替换为下面的长存 notch 版本(保留 `presentCount` 测试钩子与 `present(_:onAction:)` 签名;`SitAction` 不变):

```swift
import SwiftUI
import DynamicNotchKit
import ReminderCore

public enum SitAction: Equatable {
    case snooze
    case dismiss
}

@MainActor
public final class NotchPresenter {
    private let autoHideSeconds: TimeInterval = 4
    private(set) var presentCount = 0

    /// 长存 notch: compactLeading=宠物, expanded=提醒卡(PetExpandedView)。启动后建一次。
    private var notch: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>?
    private let petVM = PetViewModel()
    private var powerObserver: ScreenPowerObserver?
    private var petEnabled: Bool = true

    public init() {}

    // MARK: - 启动接线(由 AppDelegate 调)

    /// 建长存 notch + 注册灭屏观察; showPet 据当前 petEnabled。
    public func attachPet() {
        let vm = petVM
        let n = DynamicNotch(
            expanded: { PetExpandedView(
                vm: vm, showsPet: self.petEnabled,
                title: "", subtitle: "", showSnooze: false,
                onSnooze: {}, onDismiss: {}) },
            compactLeading: { PetCompactView(vm: vm, showsPet: self.petEnabled) }
        )
        notch = n
        powerObserver = ScreenPowerObserver(vm: petVM)
        powerObserver?.start()
        Task { @MainActor in
            if petEnabled { await n.compact() } else { await n.hide() }
        }
    }

    public func setPetEnabled(_ on: Bool) {
        petEnabled = on
        Task { @MainActor in
            guard let n = notch else { return }
            if on { await n.compact() } else { await n.hide() }
        }
    }

    public func setPetMood(_ m: PetMood) { petVM.setMood(m) }

    // MARK: - 提醒入口(签名与 v1 一致, AppController 调用点不变)

    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
        presentCount += 1
        guard let n = notch else { return }
        petVM.playAct(actFor(r))
        switch r {
        case let .sit(minutes, project):
            expandStrong(title: sitTitle(minutes: minutes, project: project),
                         subtitle: "起来走两步, 眼睛也歇歇",
                         showSnooze: true, onAction: onAction, n: n)
        case let .night(clock):
            expandStrong(title: "\(clock) 了",
                         subtitle: "明天的你会感谢现在睡觉的你",
                         showSnooze: false, onAction: onAction, n: n)
        case .water, .eye:
            // 轻样式: expand → 停留 → clearAct → 回 compact(宠物不消失)
            Task { @MainActor in
                await n.expand()
                try? await Task.sleep(for: .seconds(autoHideSeconds))
                petVM.clearAct()
                if petEnabled { await n.compact() } else { await n.hide() }
            }
        }
    }

    private func expandStrong(title: String, subtitle: String, showSnooze: Bool,
                              onAction: ((SitAction) -> Void)?,
                              n: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>) {
        // expanded 内容在 expand 时由 DynamicNotch 重建闭包生成; 闭包捕获的 title/subtitle 是旧的,
        // 故此处用一次性强展开: 临时把按钮文案/动作经 vm 不行 → 改为 rebuild。
        // 简化: 强提醒也走「expand 当前 expanded 视图」, 文案通过一个临时 holder 注入。
        // 见下方 StrongPayload holder。
        StrongPayload.shared.set(title: title, subtitle: subtitle, showSnooze: showSnooze,
                                 onSnooze: { onAction?(.snooze); self.afterStrong(n: n) },
                                 onDismiss: { onAction?(.dismiss); self.afterStrong(n: n) })
        Task { @MainActor in await n.expand() }
    }

    private func afterStrong(n: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>) {
        petVM.clearAct()
        Task { @MainActor in
            if petEnabled { await n.compact() } else { await n.hide() }
        }
    }

    private func sitTitle(minutes: Int, project: String?) -> String {
        if let p = project, !p.isEmpty { return "连续 \(minutes) 分钟了 · \(p) 项目" }
        return "连续 \(minutes) 分钟了"
    }
}

/// 强提醒的一次性文案/动作 holder: 让长存 notch 的 expanded 闭包能读到「本次」的 title/subtitle。
/// 简单可行; 不持久化。Task 4 自洽即可, 不对外暴露。
fileprivate final class StrongPayload {
    static let shared = StrongPayload()
    var title = ""; var subtitle = ""; var showSnooze = false
    var onSnooze: () -> Void = {}
    var onDismiss: () -> Void = {}
    @MainActor
    func set(title: String, subtitle: String, showSnooze: Bool,
             onSnooze: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.showSnooze = showSnooze
        self.onSnooze = onSnooze; self.onDismiss = onDismiss
    }
}
```

> 因为长存 notch 的 expanded 闭包在 `attachPet` 时就定死了 view, 而 sit/night 的 title/subtitle 是运行时来的, 故用 `StrongPayload.shared` holder 把本次文案塞进去。需让 `attachPet` 里 expanded 闭包**读 StrongPayload** 而非空串。修正:`attachPet` 的 expanded 闭包改为:
```swift
expanded: { PetExpandedView(
    vm: vm, showsPet: self.petEnabled,
    title: StrongPayload.shared.title,
    subtitle: StrongPayload.shared.subtitle,
    showSnooze: StrongPayload.shared.showSnooze,
    onSnooze: StrongPayload.shared.onSnooze,
    onDismiss: StrongPayload.shared.onSnooze == nil ? {} : StrongPayload.shared.onDismiss) }
```
把上面 `attachPet` 内 expanded 闭包按此替换(用 StrongPayload)。`PetExpandedView` 是 `@ObservedObject vm` 的视图——为让 title/subtitle 变化也触发重绘, 给 `StrongPayload` 加 `@Published` 风格通知最稳:改 `StrongPayload` 为 `ObservableObject` 并在 `PetExpandedView` 额外 `@ObservedObject var payload = StrongPayload.shared`。**实施者按此收敛**:让 `PetExpandedView` 多一个 `@ObservedObject var payload: StrongPayload` 参数, expanded 闭包传入 `StrongPayload.shared`, 视图内 title/subtitle/showSnooze/onSnooze/onDismiss 读自 payload。`present`/`expandStrong` 只 `payload.set(...)` + `await n.expand()`。

> 注: 这一步有「设计收敛」自由度, 实施时按上述 ObservableObject payload 方案把 `PetExpandedView` 与 `attachPet`/`expandStrong` 串通, 保证 sit/night 文案正确显示且点击按钮生效。水/护眼路径(无按钮)不变。

- [ ] **Step 4.3 — 编译。** Run:
```bash
cd ~/NotchReminder && swift build
```
Expected: Build complete。若 ObservableObject payload 收敛后有编译错, 修正至通过(典型: PetExpandedView 参数顺序 / DynamicNotch 泛型)。

- [ ] **Step 4.4 — 改 `AppController.swift` tick。** 打开 `Sources/NotchReminder/AppController.swift`, 在 `tick()` 的 `route(reminders)` **之前**插一行推宠物心情。当前 tick 末尾是:
```swift
        let (newState, reminders) = ReminderEngine.advance(_state, config: _config, sample: sample)
        _state = newState
        route(reminders)
        return reminders
```
改为:
```swift
        let (newState, reminders) = ReminderEngine.advance(_state, config: _config, sample: sample)
        _state = newState
        presenter.setPetMood(petMood(state: _state, config: _config, now: sample.now))
        route(reminders)
        return reminders
```
(`petMood` 来自 ReminderCore, AppController 已 `import ReminderCore`, 无需新 import。)

- [ ] **Step 4.5 — 改 `main.swift` 启动接线。** 打开 `Sources/NotchReminder/main.swift`, 在 `AppDelegate.applicationDidFinishLaunching` 里 `c.start()` **之前**加:
```swift
        presenter.attachPet()
        presenter.setPetEnabled(settingsStore.petEnabled)
```
(`settingsStore.petEnabled` 在 Task 5 加; 本 Task 先在 SettingsStore 里加一个临时 `var petEnabled: Bool = true` computed/存储属性让 main.swift 编译过, Task 5 再接持久化。)

- [ ] **Step 4.6 — SettingsStore 临时加 `petEnabled`(Task 5 正式持久化)。** 打开 `Sources/NotchReminder/SettingsStore.swift`, 在 `Scalar prefs` 区加临时:
```swift
    var petEnabled: Bool {
        get { defaults.object(forKey: "petEnabled") == nil ? true : defaults.bool(forKey: "petEnabled") }
        set { defaults.set(newValue, forKey: "petEnabled") }
    }
```

- [ ] **Step 4.7 — 编译 + 全量测试。** Run:
```bash
cd ~/NotchReminder && swift build && swift test
```
Expected: Build complete; `Executed 45 tests, with 0 failures`(AppControllerTests 的「连续活跃产 .sit」断言仍成立——presentCount 仍递增;replay 测试仍成立)。

- [ ] **Step 4.8 — 手动视觉验证(本机图形会话)。** Run `swift run NotchReminder`:① 启动后刘海旁应出现团子并呼吸;② 把 sitThreshold 调小触发久坐 → 卡片展开带团子伸懒腰 + 按钮,点按钮回 compact;③ 合盖/灭屏片刻 → 团子闭眼,亮屏恢复。无头环境跳过,记 concern。

- [ ] **Step 4.9 — Commit。**
```bash
cd ~/NotchReminder && git add -A && git commit -m "feat(pet): 长存 DynamicNotch(compact↔expand) + ScreenPowerObserver + AppController 推心情"
```

---

## Task 5: 设置(3 字段持久化 + 设置窗宠物分组) + 收尾(spec P5)

> 把 petEnabled 正式持久化 + 加 petPauseOnBattery/petCharacter 字段 + 设置窗加「宠物」分组 + petPauseOnBattery 接电源观察 + petEnabled 开关接 presenter.setPetEnabled。收尾全量验证。

**Files:**
- Modify: `Sources/NotchReminder/SettingsStore.swift`(正式 +2 字段,petEnabled 已临时存在,补 round-trip)
- Modify: `Tests/NotchReminderTests/SettingsStoreTests.swift`(+3 字段 round-trip)
- Modify: `Sources/NotchReminder/SettingsWindow.swift`(+「宠物」分组: 总开关 + 电源静止 + 形象占位只读)
- Modify: `Sources/NotchReminder/AppController.swift`(读 petPauseOnBattery, 接电源变化 → presenter; **或**简化:电源观察放 NotchPresenter.attachPet 内据 settingsStore 读一次,v1 不监听运行时切换)。

**Interfaces:**
- Consumes: T4 的 `presenter.setPetEnabled`。
- Produces: 3 个持久化设置项 + UI。

- [ ] **Step 5.1 — 写失败测试(SettingsStore +3 字段 round-trip)。** 打开 `Tests/NotchReminderTests/SettingsStoreTests.swift`, 参照既有 round-trip 用例加 3 个断言(`petEnabled=false`、`petPauseOnBattery=true`、`petCharacter="blob"` 存后读出一致)。用注入 `UserDefaults(suiteName: UUID().uuidString)`。先确认 RED: Run `swift test --filter SettingsStoreTests` → FAIL(`petPauseOnBattery`/`petCharacter` 未定义)。

- [ ] **Step 5.2 — SettingsStore 正式加字段。** 打开 `Sources/NotchReminder/SettingsStore.swift`, 在 Key enum 加 `petEnabled`/`petPauseOnBattery`/`petCharacter`;在 Scalar prefs 区:
```swift
    var petEnabled: Bool {
        get { defaults.object(forKey: Key.petEnabled) == nil ? true : defaults.bool(forKey: Key.petEnabled) }
        set { defaults.set(newValue, forKey: Key.petEnabled) }
    }
    var petPauseOnBattery: Bool {
        get { defaults.bool(forKey: Key.petPauseOnBattery) }
        set { defaults.set(newValue, forKey: Key.petPauseOnBattery) }
    }
    var petCharacter: String {
        get { (defaults.string(forKey: Key.petCharacter) ?? "blob") }
        set { defaults.set(newValue, forKey: Key.petCharacter) }
    }
```
(替换 Task 4 临时加的 `petEnabled`, 用 Key 常量。)

- [ ] **Step 5.3 — 运行 SettingsStoreTests GREEN。** Run:
```bash
cd ~/NotchReminder && swift test --filter SettingsStoreTests
```
Expected: PASS(原 5 + 新 3 = 8,或按既有结构合并)。

- [ ] **Step 5.4 — SettingsWindow 加「宠物」分组。** 打开 `Sources/NotchReminder/SettingsWindow.swift`, 在 `SettingsView` 加 3 个 `@State`(petEnabled/petPauseOnBattery/petCharacter,init 从 store 读),并在 `body` 的 Form 里「通用」分组**之前**加:
```swift
            Section("宠物") {
                Toggle("启用刘海宠物", isOn: $petEnabled).onChange(of: petEnabled) { _, on in
                    store.petEnabled = on
                    AppController.shared.presenterSetPetEnabled(on)
                }
                Toggle("电池模式静止(省电)", isOn: $petPauseOnBattery).onChange(of: petPauseOnBattery) { _, on in
                    store.petPauseOnBattery = on
                }
                HStack {
                    Text("形象"); Spacer()
                    Text(verbatim: store.petCharacter).foregroundStyle(.secondary)  // v1 仅 blob, 占位只读
                }
            }
```
并在 `persist()` 之外(宠物开关即时生效, 不走 persist 的 ReminderConfig 路径)。

- [ ] **Step 5.5 — AppController 暴露 presenter.setPetEnabled 桥。** 打开 `Sources/NotchReminder/AppController.swift`, 加一个转发方法(供 SettingsView 调, 不暴露 presenter 私有性):
```swift
    public func presenterSetPetEnabled(_ on: Bool) {
        presenter.setPetEnabled(on)
    }
```

- [ ] **Step 5.6 — petPauseOnBattery 接电源(v1 简化:启动时读一次)。** 在 `NotchPresenter.attachPet()` 里, 若 `petPauseOnBattery && 当前是电池` → 直接 `hide()` 而非 compact。判定电源:
```swift
private var isOnBattery: Bool {
    let ps = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(ps).takeRetainedValue() as Array
    if let desc = list.first as? [String: Any] {
        return (desc[kIOPSPowerSourceStateKey] as? String) != kIOPSACPowerValue
    }
    return false
}
```
注:v1 不监听运行时电源切换(简化), 仅启动时据设置决定是否常驻;记为 minor。SettingsWindow 改 petPauseOnBattery 需重启或下次 attach 生效——在分组控件下加一行说明文字「(重启生效)」。

- [ ] **Step 5.7 — 编译 + 全量测试。** Run:
```bash
cd ~/NotchReminder && swift build -c release && swift test
```
Expected: Build complete(release); `Executed 48 tests, with 0 failures`(45 + SettingsStore 新增 3)。

- [ ] **Step 5.8 — 手动收尾验证(本机图形会话)。** Run release 二进制 `~/NotchReminder/.build/release/NotchReminder`:① 设置窗「宠物」分组可开关;② 关闭后刘海无团子、提醒卡无团子(showsPet=false);③ 开启后团子常驻 + 提醒演出。无头环境跳过,记 concern。

- [ ] **Step 5.9 — Commit。**
```bash
cd ~/NotchReminder && git add -A && git commit -m "feat(pet): 设置(3 字段持久化 + 宠物分组 UI) + petEnabled/pauseOnBattery 接线"
```

---

## Self-Review

### Spec 覆盖(spec 各节 → Task)

| spec 节 | 内容 | 落地 Task |
|---|---|---|
| §2 架构(长存 notch + petMood 纯函数) | T1(petMood) + T4(长存 notch) |
| §3.1 心情引擎 | **T1** PetMood + petMood + 6 心情规则 + 测试 |
| §3.2 演出映射 | **T2** PetAct + actFor |
| §3.3 PetViewModel | **T2** + 测试 |
| §3.4 PetView(团子 + compact + expanded + showsPet) | **T3** + 删 StrongReminderView |
| §3.5 灭屏/电源观察 | **T4** ScreenPowerObserver(灭屏); **T5** 电源(petPauseOnBattery, 简化启动时读一次) |
| §3.6 NotchPresenter 重构 + fallback | **T4** 长存 notch + showsPet 降级 |
| §3.7 AppController 接线 | **T4** tick 末尾 setPetMood |
| §3.8 设置 3 字段 | **T5** SettingsStore + SettingsWindow |
| §4 耗电(低频 idle/灭屏/电源/全屏隐) | T3(呼吸 autoreverse ~3.5s) + T4(ScreenPowerObserver + 全屏 hide) + T5(petPauseOnBattery) |
| §5 交互(rua + hover 降级) | **T3** PetCompactView 点 → vm.pet()(点击;若 DynamicNotchKit compact 不收点击则运行时观察降级 hover,记 concern) |
| §6 文件结构 | 全 Task 合计 |
| §7 分阶段 P1-P5 | T1=P1 / T2=P2 逻辑 / T3=P2 视觉 / T4=P3+P4 / T5=P5 |

### 占位符扫描
无 TODO/TBD/「类似上文」。「实施者按 ObservableObject payload 方案收敛」(T4 Step 4.2 注)是**明确的实现收敛指引**(给了方向 + 关键约束), 不是占位——但因其含设计自由度, 标注为实施时需编译验证的收敛点, reviewer 会重点看 sit/night 文案是否正确显示。

### 类型一致性
- `PetMood` 六 case 在 T1 定义, T3 PetBlob/T4 setPetMood 消费, 逐字一致。
- `PetAct` 四 case 在 T2 定义, T3 PetBlob(`act == .stretch`)、T4 present(`actFor(r)`)消费, 一致。
- `PetViewModel` 字段 mood/act/isAwake/isPetting 在 T2 定义, T3 视图、T4 presenter 消费, 一致。
- `present(_:onAction:)` 签名 + `presentCount` 与 v1 一致(AppControllerTests/AppControllerReplayTests 不破)。
- `petMood(state:config:now:)` 签名 T1 定义, T4 tick 消费, 一致。

### 测试累计表(线性 T1→T5)

| 完成到 | 新增 | 全量 swift test |
|---|---|---|
| T1 | PetMoodTests(7) | 40 |
| T2 | PetViewModelTests(5) | 45 |
| T3 | (视觉, 无单测) | 45 |
| T4 | (集成, 既有测试不破) | 45 |
| T5 | SettingsStoreTests +3 | 48 |

各 Task 硬判据用 `--filter <本 Task TestCase>`。

### 仍存 unresolved(非计划缺陷)
- DynamicNotchKit compact 内容能否接收点击(T3 Step 3.6 / T4 4.8 真机验证): 不行则 rua 降级 hover。
- 长存 notch expanded 闭包定死 vs sit/night 运行时文案 → 用 StrongPayload(ObservableObject)收敛(T4 Step 4.2 注): 编译+视觉验证文案正确。
- 常驻 compact 实际 CPU/耗电(T4 4.8): Instruments 真机看常驻态 CPU≈0。
- petPauseOnBattery 仅启动时读一次(T5 Step 5.6): v1 简化, 重启生效。
