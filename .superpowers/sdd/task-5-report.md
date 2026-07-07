# Task 5 Report: NotchPresenter 强/轻样式 + auto-hide + 免打扰探针接线

## 实现内容

### 文件变动

**Create**
- `Sources/NotchReminder/StrongReminderView.swift` — 强样式 SwiftUI 视图(VStack: 标题 + 副标题 + 1–2 个按钮; `showSnooze=false` 时熬夜只显示「知道了」; `Text(verbatim:)` 承载运行时插值文案)
- `Sources/NotchReminder/DoNotDisturb.swift` — 静音入口 `muteFor`/`isMuted`(纯时间计算, 可单测) + `isFullscreenActive()`(CGWindowList 近似, layer==0 + 覆盖整屏 + 有归属进程, 允许 1pt 容差)
- `Tests/NotchReminderTests/DoNotDisturbTests.swift` — 4 个单测: muteFor 返回正确截止时间 / isMuted 在截止前为 true / 截止时及之后为 false / nil 时为 false
- `Tests/NotchReminderTests/AppControllerReplayTests.swift` — 4 个单测: 全屏 route → pending / 非全屏不入队 / flushPending 非全屏清空并补放 / flushPending 仍全屏保留

**Modify**
- `Sources/NotchReminder/NotchPresenter.swift` — 整份重写: 移除占位 `showTest()` 和 Task 3 的 `DynamicNotchInfo` 全覆盖; 分四支:
  - sit/night → `DynamicNotch { StrongReminderView(...) }` + `expand()` (强样式, 不自动收, 按钮触发 onAction 后 `dismissStrong()`)
  - water/eye → `DynamicNotchInfo.expand()` + `Task.sleep(4s)` + `hide()` (轻样式, 4s 后自动收)
  - 持有 `strongNotch` 引用, 新强提醒到来时先 `hide()` 旧的
  - 保留 `SitAction` 枚举 (CONTRACT §C2) + `public final class NotchPresenter` + `public init()` + `present(_:onAction:)` 签名
- `Sources/NotchReminder/AppController.swift` — 仅改一处: `dnd` 参数默认值从 `{ false }` 改为 `DoNotDisturb.isFullscreenActive`; 其余 route/flushPending/pending/tick/onSitSnooze 不动 (CONTRACT §C3)
- `Sources/NotchReminder/main.swift` — `fireTest()` 从已删除的 `showTest()` 改为 `presenter.present(.water, onAction: nil)` (轻样式测试; 符合意图)

---

## TDD 证据

### RED 阶段
在实现代码落地之前，`DoNotDisturbTests` 和 `AppControllerReplayTests` 的逻辑依赖 `DoNotDisturb` enum 和正确的 `AppController.route/flushPending`。由于 `DoNotDisturb.swift` 尚未创建时编译直接失败，这构成 RED 状态（代码先写测试、build 报 `cannot find type 'DoNotDisturb'`）。

### GREEN 阶段

```
swift test --filter DoNotDisturbTests
→ Executed 4 tests, with 0 failures (0 unexpected) in 0.001 seconds

swift test --filter AppControllerReplayTests
→ Executed 4 tests, with 0 failures (0 unexpected) in 0.003 seconds

swift test (全量)
→ Executed 23 tests, with 0 failures (0 unexpected) in 0.048 seconds
```

计数口径: 占位 1 + Engine 12 + AppControllerTests 2 + DoNotDisturbTests 4 + AppControllerReplayTests 4 = 23 ✓

---

## Self-Review

| 检查项 | 结论 |
|---|---|
| CONTRACT §C2 (NotchPresenter 签名) | ✓ 保留 `public enum SitAction`, `@MainActor public final class NotchPresenter`, `public init()`, `present(_:onAction:)` |
| CONTRACT §C3 (AppController 单一 owner, 不重写) | ✓ 仅改一行 `dnd` 默认值, 其余逻辑不动 |
| DynamicNotch API 正确使用 | ✓ 便捷 init `DynamicNotch { ... }` (CompactLeading/Trailing = EmptyView); `expand()` / `hide()` 均在 `Task { @MainActor in }` 内 await; 无 `toggle()`/`show()` |
| DynamicNotchInfo.icon 类型 | ✓ `.init(systemName:color:)` 构造 `DynamicNotchInfo.Label?` |
| auto-hide 实现 | ✓ `expand()` → `Task.sleep(.seconds(4))` → `hide()`; 库无内建 auto-hide |
| DoNotDisturb public 可见性 | ✓ enum + 三个 static func 均 `public`; 用作 AppController.init default 参数值 |
| 摄像头占用检测 | ✓ 明确不做 (spec §8 v2, YAGNI); 注释标注 |
| main.swift showTest() 清理 | ✓ 已替换为 `present(.water, onAction: nil)` |
| swift build | ✓ Build complete! |
| swift test (全量) | ✓ 23 tests, 0 failures |

---

## 关注点 (manual-visual, 无法程序化验证)

1. **强样式视觉效果**: `DynamicNotch { StrongReminderView(...) }` 展开后，刘海区域是否正常渲染标题 + 两个按钮，需真机(有物理刘海的 Mac)肉眼确认。
2. **轻样式 auto-hide 时间**: `expand()` (~0.4s 动画) + `Task.sleep(4s)` + `hide()` 总约 4–4.5s，实测可能因系统调度有轻微偏差，属正常范围。
3. **全屏静默 auto-resume 真运行**: `tick()` 开头 `flushPending()` 已接线 (Task 3 实现)，全屏退出后 ≤10s 补放。CGWindowList 近似的准确性需真机复验，特别是 Mission Control / 分屏场景。
4. **`isFullscreenActive()` 边界**: 菜单栏全屏 App 在 layer 0 + 覆盖整屏的逻辑对 macOS 标准全屏有效；对 Stage Manager 或某些第三方窗口管理器的行为属「待真机复验」。
5. **`strongNotch` 持有引用**: `DynamicNotch` 是 `final class`，`[weak self]` 防循环引用已加；旧强提醒收起时 `Task { await old.hide() }` 是 fire-and-forget，若 App 退出时窗口已消失不影响正确性。

---

## Commit

- SHA: `e4e0c5e`
- Subject: `Task 5: NotchPresenter strong/light styles + auto-hide + do-not-disturb probe`
- 7 files changed, 247 insertions(+), 48 deletions(-)

---

## Fix (review round 1)

### Fix 1 — Serialize strong-style notch hide→expand
**File:** `Sources/NotchReminder/NotchPresenter.swift`, `presentStrong()` (~line 48–75)

Before: `hide()` was fire-and-forget in a detached Task; `expand()` launched in a separate Task immediately after — the two animations overlapped.

After: capture `old = strongNotch` before reassignment, then run hide→expand in ONE serialized `@MainActor` Task:
```swift
let old = strongNotch
let notch = DynamicNotch { StrongReminderView(...) }
strongNotch = notch
Task { @MainActor in
    if let old { await old.hide() }
    await notch.expand()
}
```
The `[weak self]` captures in the view closure are unchanged. Light-style (water/eye) path untouched.

### Fix 2 — Assert re-present actually happens in replay test
**Files:**
- `Sources/NotchReminder/NotchPresenter.swift` — added `private(set) var presentCount = 0` (internal, not public) and `presentCount += 1` at the top of `present(_:onAction:)` before any DynamicNotchKit call.
- `Tests/NotchReminderTests/AppControllerReplayTests.swift`, `testFlushPendingClearsWhenNotFullscreen` — extracted `presenter` as a named local, then after `flushPending()` added: `XCTAssertEqual(presenter.presentCount, 2, "flushPending should re-present all queued reminders")`. The original `pending.isEmpty` assertion is retained.

### Fix 3 — Strict-concurrency-safe NSScreen access
**File:** `Sources/NotchReminder/DoNotDisturb.swift`, `isFullscreenActive()` (~line 31–36)

`NSScreen.screens` is `@MainActor`-isolated AppKit state accessed from a non-isolated `public static func`. The function signature is kept as `() -> Bool` (NOT `@MainActor`) because it is used as `AppController.init`'s `dnd` default — annotating it `@MainActor` would change the closure type and break the build.

The `NSScreen.screens.compactMap { ... }` block is wrapped in `MainActor.assumeIsolated { ... }` with a comment explaining this is safe because `isFullscreenActive()` is always called from `tick()` on the main actor at runtime.

**Fix 3 applied successfully — build and tests remain green.**

### Build & Test Results

```
swift build
→ Build complete! (1.27s)

swift test
→ Test Suite 'All tests' passed at 2026-07-07 22:12:29.202.
→ Executed 23 tests, with 0 failures (0 unexpected) in 0.050 seconds
```

Covering tests confirmed green:
- `AppControllerReplayTests`: 4 tests, 0 failures (including strengthened `testFlushPendingClearsWhenNotFullscreen` with `presentCount` assertion)
- `DoNotDisturbTests`: 4 tests, 0 failures
- Full suite: 23 tests, 0 failures
