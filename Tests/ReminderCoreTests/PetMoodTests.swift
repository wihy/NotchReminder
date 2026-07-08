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
