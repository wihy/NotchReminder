# NotchReminder 宠物特效 设计方案

> 给已上线的 NotchReminder 增加「刘海常驻宠物 + 提醒时演出」特效。基于现有引擎状态零成本驱动宠物心情。
>
> 日期：2026-07-08 · 状态：设计已确认，待转实施规划 · 前置：NotchReminder v1 已 merged 到 main（33 XCTest + 5 Python）

---

## 1. 背景与目标

NotchReminder v1 已上线（菜单栏 App + CC 传感器 + 久坐/喝水/护眼/熬夜提醒，刘海卡片渲染已真机验证）。用户希望刘海「更有陪伴感」：平时有一只小宠物常驻刘海旁，提醒时宠物加演对应动作。本设计在不破坏现有提醒链路、且不显著增加耗电的前提下实现该特效。

### 1.1 关键事实（已验证）

- **DynamicNotchKit 支持 compact 常驻**：`DynamicNotch<Expanded, CompactLeading, CompactTrailing>` 有三态——`expand()`（完整下拉卡）、`compact()`（刘海收起时在两侧常驻显示，像 iPhone 灵动岛）、`hide()`（完全消失）。v1 只用了 expand/hide，**compact 能力未用**——宠物正好住进 compact。
- **状态数据现成**：引擎 `ReminderEngine.advance` 每 tick 已算出 `sitAccum / isNight / mutedUntil / 刚 rest` 等。宠物心情可据此零成本映射，无需新增采样。
- **现有渲染是每条提醒新建临时 notch**（`presentLight`/`presentStrong`）。宠物要常驻 → 必须改为「一个长存的 DynamicNotch」。

### 1.2 用户决策（已逐项确认）

| 决策项 | 选择 |
|---|---|
| 宠物平时在不在 | **常驻(compact) + 提醒时加演(expand)**，三态机 idle→compact→expand |
| 动画方式 | **SwiftUI 手绘小生物**（Path/Shape + 属性动画），零美术素材零依赖、CPU 低、可做表情 |
| 宠物多"活" | **心情 + 分类演出**：平时心情随状态变，每类提醒有专属动作 |
| 形象 | **团子(blob)**，squash-and-stretch 最适合做情绪 |
| 集成方案 | **A：单个长存 DynamicNotch**（compactLeading=宠物 / expanded=提醒卡含宠物），观察共享 PetViewModel |

## 2. 架构总览

```
tick: idle → advance → [Reminder]
   ├─ petMood(state,config,now) ──▶ vm.mood ──▶ PetCompactView (常驻·随心情 idle 动画)
   └─ route(r) ──▶ present(r):
                    vm.playAct(actFor r) + expand()
                    ──▶ PetExpandedView(宠物演出 + 文案 + [sit/night 带按钮])
                    水/护眼: 停留后 compact()  ·  久坐/熬夜: 按钮后 compact()
                    （收尾是 compact 不是 hide —— 宠物不消失）
```

**核心：一个长存的 DynamicNotch 绑定共享 PetViewModel。** 平时 `compact()` 显示宠物，提醒时 `expand()` 加演，演完回 `compact()`。`petMood` 是纯函数（进 ReminderCore，与 `advance` 同级，可单测），把引擎现有状态映射成心情，推给 vm。

**解耦**：宠物是渲染层增强；引擎 `ReminderCore` 不变（只新增一个纯函数 `petMood`）。提醒触发逻辑、CC 信号、计时口径全部复用 v1，零改动。

## 3. 组件设计

### 3.1 心情引擎（纯函数，进 ReminderCore）

**新文件 `Sources/ReminderCore/PetMood.swift`**：

```swift
public enum PetMood: Equatable {
    case fresh       // 刚开工 / 刚真休息过(sitAccum 低 / 刚 rest) → 挺立亮眼轻弹跳
    case calm        // 正常工作(sitAccum 中等) → 缓慢呼吸 + 偶尔眨眼
    case tired       // 连续 ≥50min(=sitThreshold) → 眼下垂呼吸变慢微塌
    case exhausted   // 连续 ≥90min → 塌成一摊 + 冒汗滴
    case sleepy      // 深夜 ≥23:00 且活跃 → 半眯眼偶打哈欠 Zzz
    case dozing      // 静音中(mutedUntil 在未来) / 长时间无活动 → 闭眼睡飘 Zzz
}

/// 纯函数: 把引擎现有状态映射成宠物心情。无副作用, 可单测。
public func petMood(state: ReminderState, config: ReminderConfig, now: Date) -> PetMood
```

**映射规则（优先级从高到低，首个命中即返回）**：
1. `now < config.mutedUntil` → `.dozing`（静音/专注 → 宠物睡觉）
2. `isNight(now)` → `.sleepy`（夜里 → 困，不论是否在动）
3. `sitAccum >= 90*60` → `.exhausted`
4. `sitAccum >= sitThreshold(50min)` → `.tired`
5. `sitAccum < 10*60` → `.fresh`（刚开工/刚休息过的低水位）
6. 否则 → `.calm`

> 注：`isNight` 复用 `ReminderEngine` 已有的同名函数（hour>=23 || hour<2）。纯函数只用 `state`/`config`/`now`，无副作用、确定、可单测。

### 3.2 演出映射（app 层）

**新文件 `Sources/NotchReminder/Pet/PetAct.swift`**：

```swift
public enum PetAct: Equatable { case drink, lookAway, stretch, yawn }

/// Reminder → PetAct 平凡映射。
public func actFor(_ r: Reminder) -> PetAct {
    switch r {
    case .water:        return .drink
    case .eye:          return .lookAway
    case .sit:          return .stretch
    case .night:        return .yawn
    }
}
```

### 3.3 PetViewModel（app, @MainActor, ObservableObject）

**新文件 `Sources/NotchReminder/Pet/PetViewModel.swift`**：

```swift
@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var mood: PetMood = .fresh
    @Published public private(set) var act: PetAct?          // 非 nil = 正在演出
    @Published public private(set) var isAwake: Bool = true  // 灭屏/锁屏 → false
    @Published public private(set) var isPetting: Bool = false // rua 反应中

    public func setMood(_ m: PetMood)
    public func playAct(_ a: PetAct)        // 设 act, ~4s 后自动清(act 回 nil, 触发回 compact)
    public func pet()                       // rua: isPetting=true, ~1.5s 后 false
    public func sleep(); public func wake() // 灭屏/唤醒
}
```

`playAct` 的自动清除驱动「水/护眼停留后回 compact」——act 清零即收起 expanded。

### 3.4 PetView（SwiftUI 手绘团子）

**新文件 `Sources/NotchReminder/Pet/PetView.swift`**：

- `PetShape`：用 `Path` 画的圆团子主体 + 两眼 + 可选嘴形/Zzz/汗滴。squash-and-stretch 用 `.scaleEffect` autoreverse。
- `PetCompactView`：刘海旁的小团子（~24pt），按 `mood`/`act`/`isPetting` 选姿态 + idle 动画（呼吸/眨眼）。绑 `PetViewModel`。
- `PetExpandedView`：提醒卡。布局 = 大团子(演出对应 act) + 文案 + [sit/night 多两个按钮]。**取代 v1 的 `StrongReminderView`**（按钮逻辑/回调 `onAction(.snooze/.dismiss)` 原样搬入）。水/护眼无按钮。

**6 心情静态姿态**（手绘参数化）：fresh=挺立亮眼、calm=平缓、tired=微塌下垂、exhausted=塌一摊+汗、sleepy=半眯+Zzz、dozing=闭眼睡+Zzz。
**4 演出**：drink=捧杯、lookAway=眼偏一侧、stretch=起身伸懒腰、yawn=打哈欠揉眼。

### 3.5 灭屏/电源观察

**新文件 `Sources/NotchReminder/Pet/ScreenPowerObserver.swift`**：
- `NSWorkspace` 通知：`screensDidSleepNotification` / `screensDidWakeNotification` / `com.apple.screenIsLocked` / `.screenIsUnlocked` → `vm.sleep()/wake()`。屏不亮时团子 `dozing`、动画停（省电）。
- `IOPSNotificationCreateRunLoopSource`（电源变化）→ 仅当 `petPauseOnBattery=true` 时, 电池态 `sleep()`、接电源 `wake()`。

### 3.6 NotchPresenter 改造（核心重构）

v1 是「每条提醒新建临时 notch + expand/hide」。改为：
- 启动时建**一个长存** `DynamicNotch<PetExpandedView, PetCompactView, EmptyView>`，绑定共享 `PetViewModel`。
- 启动后 `compact()` → 宠物常驻刘海旁。
- `present(r)`：`vm.playAct(actFor r)` + `expand()`。
  - 水/护眼：`playAct` 的 ~4s 自动清除触发回 `compact()`（act→nil 监听）。
  - 久坐/熬夜：按钮回调 → `onAction(.snooze/.dismiss)` + 回 `compact()`。
- 全屏时（复用 `isFullscreenActive`）：`hide()`（连宠物一起隐）；退出全屏 → `compact()` 恢复。
- **`petEnabled=false`**：**同一条代码路径，不维护双套渲染**。`PetCompactView`/`PetExpandedView` 接受 `showsPet: Bool`：关时 `compactLeading` 不显示宠物（notch 平时 `hide()`，与 v1 一致），提醒时 `PetExpandedView` 以 `showsPet=false` 渲染（纯文案 + sit/night 按钮，行为等同 v1）。即「宠物」整体是一个可关的渲染叠加层，开关只控 `showsPet`，不改架构。

### 3.7 AppController 改动（一处）

`tick()` 内 advance 后：算 `petMood(state,config,now)` → `presenter.petVM.setMood(...)`。仅此一行接线。

### 3.8 设置（接现有 SettingsStore/Window）

新增 3 字段：`petEnabled:Bool(默认 true)` / `petPauseOnBattery:Bool(默认 false)` / `petCharacter:String(预留, v1 仅 "blob")`。SettingsWindow 加一个「宠物」分组（总开关 + 电源静止 + 形象占位）。

## 4. 耗电控制（用户对功耗敏感，重点）

- **低频 idle**：团子平时只「缓慢呼吸」（scale autoreverse ~3–4s）+「偶尔眨眼」（每几秒瞬时），非高 FPS 连播。
- **灭屏/锁屏暂停**：`ScreenPowerObserver` → `vm.sleep()`，屏不亮时近乎零动画。
- **纯电量可选静止**：`petPauseOnBattery`（默认关）。
- `dozing` 心情本身近乎零动画。
- 全屏时 `hide()` 完全不渲染。

> 这些是设计约束，实际 CPU/电量影响为 `待真机坐实`（用 Instruments / 活动监视器看常驻态 CPU 是否接近 0）。

## 5. 交互

- **点常驻团子 → rua 彩蛋**：`vm.pet()` → 弹跳/眯眼 ~1.5s。
  - ⚠️ `待验证`：DynamicNotchKit 的 compact 内容能否接收点击（库有 hover 行为配置）。若不接收，**降级为 hover 反应**（鼠标移上去团子眯眼），不强求点击。
- 提醒展开态点团子无特殊；按钮照旧（sit/night 的 snooze/dismiss）。
- **YAGNI**：不做喂养/成长/饱食度（那是另一个 Tamagotchi 应用）。

## 6. 文件结构

```
Sources/ReminderCore/
└── PetMood.swift                    # 新: enum PetMood + petMood() 纯函数
Sources/NotchReminder/Pet/
├── PetViewModel.swift               # 新: @MainActor ObservableObject
├── PetView.swift                    # 新: PetShape + PetCompactView + PetExpandedView
├── PetAct.swift                     # 新: enum PetAct + actFor()
└── ScreenPowerObserver.swift        # 新: 灭屏/锁屏/电源 → vm.sleep/wake
Sources/NotchReminder/
├── NotchPresenter.swift             # 改: 长存 DynamicNotch + compact↔expand + fallback
├── AppController.swift              # 改一处: tick 算 petMood 推 vm
├── SettingsStore.swift              # 改: +petEnabled/petPauseOnBattery/petCharacter
├── SettingsWindow.swift             # 改: +宠物分组控件
└── StrongReminderView.swift         # 删除(并入 PetExpandedView)
Tests/ReminderCoreTests/PetMoodTests.swift          # 新: ~6 例
Tests/NotchReminderTests/PetViewModelTests.swift    # 新: playAct 定时清除/sleep-wake/setMood/pet
Tests/NotchReminderTests/SettingsStoreTests.swift   # 改: +3 字段 round-trip
```

## 7. 分阶段交付（每阶段可验证）

| 阶段 | 内容 | ✅ 验证 |
|---|---|---|
| **P1** 心情引擎 | PetMood + petMood + 测试 | PetMoodTests 绿: 各状态→正确心情 |
| **P2** 团子静态 | PetView 画团子 + 6 心情静态姿态 | swift run 看团子按心情变样 |
| **P3** 常驻+idle | 持久 compact + 呼吸/眨眼 + 灭屏暂停 | 团子常驻会呼吸、灭屏停 |
| **P4** 提醒演出 | PetExpandedView + 4 演出 + expand↔compact + 按钮 | 触发提醒→演对应动作→回常驻 |
| **P5** 设置+交互+边界 | 3 设置 + rua点击/hover + 全屏隐 + fallback | 开关/点击/全屏隐生效 |

心情逻辑(P1)纯函数 TDD；视觉(P2–P5)靠 `swift run` 真机看。

## 8. 待验证 / 风险项

| 项 | 标签 | 说明 |
|---|---|---|
| DynamicNotchKit compact 内容能否点击 | `待验证` | 不行则 hover 降级(§5) |
| 常驻 compact 的实际 CPU/耗电 | `待真机坐实` | Instruments/活动监视器看常驻态 CPU≈0 |
| 长存 notch 与 v1 临时 notch 共存 | `已规避` | 全改长存, 不并存(避免抢刘海) |
| petEnabled=false 行为 | `设计内` | 单路径 + showsPet 开关(§3.6), 不维护双套渲染 |

## 9. 非目标（YAGNI）

- 宠物喂养/成长/饱食度/多宠物养成（Tamagotchi 类）。
- 多形象库（v1 仅团子，petCharacter 字段预留）。
- 宠物音效。

---

## 附：与 v1 的关系

- **不改动** `ReminderCore` 的 `ReminderEngine.advance` 及其全部测试（33 XCTest 保持绿）。仅**新增** `PetMood.swift` + 测试。
- **重构** `NotchPresenter`（核心改动，但 `present(_:onAction:)` 对外签名不变，AppController 调用点几乎不动）。
- `StrongReminderView` 删除（按钮逻辑并入 `PetExpandedView`）。
