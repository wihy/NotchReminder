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
