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

    func testNewConfigFieldsRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        var cfg = ReminderConfig()
        cfg.sitStyle = .light
        cfg.waterStyle = .strong
        cfg.eyeStyle = .strong
        cfg.nightStyle = .light
        cfg.waterSnooze = 10 * 60
        cfg.eyeSnooze = 5 * 60
        cfg.dndStartMinute = 22 * 60 + 30
        cfg.dndEndMinute = 7 * 60
        cfg.sitTitleTemplate = "坐了 {minutes} 分钟"
        cfg.waterSubtitleTemplate = "喝水吧 {clock}"
        cfg.nightTitleTemplate = "{clock} 该睡了"
        store.save(cfg)

        let r = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(r.sitStyle, .light)
        XCTAssertEqual(r.waterStyle, .strong)
        XCTAssertEqual(r.eyeStyle, .strong)
        XCTAssertEqual(r.nightStyle, .light)
        XCTAssertEqual(r.waterSnooze, 10 * 60)
        XCTAssertEqual(r.eyeSnooze, 5 * 60)
        XCTAssertEqual(r.dndStartMinute, 22 * 60 + 30)
        XCTAssertEqual(r.dndEndMinute, 7 * 60)
        XCTAssertEqual(r.sitTitleTemplate, "坐了 {minutes} 分钟")
        XCTAssertEqual(r.waterSubtitleTemplate, "喝水吧 {clock}")
        XCTAssertEqual(r.nightTitleTemplate, "{clock} 该睡了")
        // 未设置的模板保持 nil(= 内置默认)
        XCTAssertNil(r.eyeTitleTemplate)
    }

    func testDNDNilRoundTripsAsDisabled() {
        let store = SettingsStore(defaults: defaults)
        var cfg = ReminderConfig()
        cfg.dndStartMinute = 60
        cfg.dndEndMinute = 120
        store.save(cfg)
        XCTAssertEqual(SettingsStore(defaults: defaults).load().dndStartMinute, 60)
        // 关闭勿扰: 存回 nil 应清除, load 得 nil。
        cfg.dndStartMinute = nil
        cfg.dndEndMinute = nil
        store.save(cfg)
        XCTAssertNil(SettingsStore(defaults: defaults).load().dndStartMinute)
        XCTAssertNil(SettingsStore(defaults: defaults).load().dndEndMinute)
    }

    func testAppearancePrefsRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        // 默认值
        XCTAssertEqual(store.scenario, .custom)
        XCTAssertTrue(store.soundEnabled)
        XCTAssertFalse(store.breathingLight)
        XCTAssertEqual(store.cardDwellSeconds, 4)
        XCTAssertEqual(store.cardPosition, "notch")
        XCTAssertEqual(store.petColorTheme, "sky")
        XCTAssertEqual(store.petSizeScale, 1.0)
        XCTAssertEqual(store.petSide, "left")
        XCTAssertEqual(store.petAnimationIntensity, 0.6, accuracy: 0.0001)

        store.scenario = .relax
        store.soundEnabled = false
        store.soundName = "Submarine"
        store.breathingLight = true
        store.cardDwellSeconds = 7
        store.cardPosition = "topRight"
        store.petColorTheme = "rose"
        store.petSizeScale = 1.2
        store.petSide = "right"
        store.petAnimationIntensity = 0.9

        let r = SettingsStore(defaults: defaults)
        XCTAssertEqual(r.scenario, .relax)
        XCTAssertFalse(r.soundEnabled)
        XCTAssertEqual(r.soundName, "Submarine")
        XCTAssertTrue(r.breathingLight)
        XCTAssertEqual(r.cardDwellSeconds, 7)
        XCTAssertEqual(r.cardPosition, "topRight")
        XCTAssertEqual(r.petColorTheme, "rose")
        XCTAssertEqual(r.petSizeScale, 1.2)
        XCTAssertEqual(r.petSide, "right")
        XCTAssertEqual(r.petAnimationIntensity, 0.9, accuracy: 0.0001)
    }

    func testPetPrefsRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        // petEnabled 默认 true(首次无存值); petPauseOnBattery 默认 false; petCharacter 默认 "blob"
        XCTAssertTrue(store.petEnabled)
        XCTAssertFalse(store.petPauseOnBattery)
        XCTAssertEqual(store.petCharacter, "blob")

        store.petEnabled = false
        store.petPauseOnBattery = true
        store.petCharacter = "cat"

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.petEnabled)
        XCTAssertTrue(reloaded.petPauseOnBattery)
        XCTAssertEqual(reloaded.petCharacter, "cat")
    }
}
