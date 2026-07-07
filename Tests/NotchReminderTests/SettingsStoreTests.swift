import XCTest
@testable import NotchReminder
import ReminderCore

final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.notchreminder.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadWithoutStoredReturnsDefaults() {
        let store = SettingsStore(defaults: defaults)
        let cfg = store.load()
        XCTAssertEqual(cfg, ReminderConfig())  // 无存值 → 引擎默认
    }

    func testSaveThenLoadRoundTripsThresholds() {
        let store = SettingsStore(defaults: defaults)
        var cfg = ReminderConfig()
        cfg.sitThreshold = 40 * 60
        cfg.waterThreshold = 45 * 60
        cfg.eyeThreshold = 20 * 60
        cfg.nightRepeat = 20 * 60   // 熬夜也算一类阈值(重复间隔), 一并持久化
        store.save(cfg)

        let reloaded = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.sitThreshold, 40 * 60)
        XCTAssertEqual(reloaded.waterThreshold, 45 * 60)
        XCTAssertEqual(reloaded.eyeThreshold, 20 * 60)
        XCTAssertEqual(reloaded.nightRepeat, 20 * 60)
    }

    func testSaveThenLoadRoundTripsToggles() {
        let store = SettingsStore(defaults: defaults)
        var cfg = ReminderConfig()
        cfg.sitEnabled = false
        cfg.waterEnabled = true
        cfg.eyeEnabled = false
        cfg.nightEnabled = false
        store.save(cfg)

        let reloaded = SettingsStore(defaults: defaults).load()
        XCTAssertFalse(reloaded.sitEnabled)
        XCTAssertTrue(reloaded.waterEnabled)
        XCTAssertFalse(reloaded.eyeEnabled)
        XCTAssertFalse(reloaded.nightEnabled)
    }

    func testMakeConfigEqualsLoad() {
        let store = SettingsStore(defaults: defaults)
        var cfg = ReminderConfig()
        cfg.sitThreshold = 55 * 60
        cfg.eyeEnabled = false
        store.save(cfg)
        XCTAssertEqual(store.makeConfig(), store.load())
    }

    func testScalarPrefsRoundTrip() {
        var store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.hasCompletedFirstRun)      // 默认未完成首启
        XCTAssertFalse(store.launchAtLogin)             // 默认不自启
        XCTAssertFalse(store.strongStyleStaysLonger)    // 默认样式偏好 false

        store.hasCompletedFirstRun = true
        store.launchAtLogin = true
        store.strongStyleStaysLonger = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedFirstRun)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertTrue(reloaded.strongStyleStaysLonger)
    }
}
