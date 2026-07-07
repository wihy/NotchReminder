import XCTest
@testable import ReminderCore

final class ReminderCoreTests: XCTestCase {
    func testVersionPresent() {
        XCTAssertEqual(reminderCoreVersion, "0.1.0")
    }
}
