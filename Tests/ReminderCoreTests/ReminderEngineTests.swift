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
