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
