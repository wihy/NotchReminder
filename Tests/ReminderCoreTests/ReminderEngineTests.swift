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
}
