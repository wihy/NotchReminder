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
            clock: { fakeNow },
            ccProvider: { nil }         // 隔离: 不读真实 cc.json
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
            clock: { fakeNow },
            ccProvider: { nil }         // 隔离: 不读真实 cc.json
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
