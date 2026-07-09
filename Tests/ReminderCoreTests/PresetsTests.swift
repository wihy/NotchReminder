import XCTest
@testable import ReminderCore

final class PresetsTests: XCTestCase {

    func testFocusPresetOnlySitAndEyeLight() {
        let c = ScenarioPreset.focus.apply(to: ReminderConfig())
        XCTAssertTrue(c.sitEnabled)
        XCTAssertTrue(c.eyeEnabled)
        XCTAssertFalse(c.waterEnabled)
        XCTAssertFalse(c.nightEnabled)
        XCTAssertEqual(c.sitStyle, .light)
        XCTAssertEqual(c.eyeStyle, .light)
    }

    func testRelaxPresetAllOnStrongHighFrequency() {
        let c = ScenarioPreset.relax.apply(to: ReminderConfig())
        XCTAssertTrue(c.sitEnabled)
        XCTAssertTrue(c.waterEnabled)
        XCTAssertTrue(c.eyeEnabled)
        XCTAssertTrue(c.nightEnabled)
        XCTAssertEqual(c.sitStyle, .strong)
        XCTAssertEqual(c.nightStyle, .strong)
        XCTAssertEqual(c.sitThreshold, 40 * 60)
        XCTAssertEqual(c.waterThreshold, 45 * 60)
    }

    func testEyeCarePresetTightensEye() {
        let c = ScenarioPreset.eyeCare.apply(to: ReminderConfig())
        XCTAssertTrue(c.eyeEnabled)
        XCTAssertEqual(c.eyeThreshold, 20 * 60)
        XCTAssertEqual(c.eyeStyle, .light)
    }

    func testCustomPresetReturnsBaseUnchanged() {
        var base = ReminderConfig()
        base.sitThreshold = 33 * 60
        base.waterEnabled = false
        base.nightStyle = .light
        XCTAssertEqual(ScenarioPreset.custom.apply(to: base), base)
    }

    func testDisplayNamesAndSystemImages() {
        XCTAssertEqual(ScenarioPreset.focus.displayName, "专注")
        XCTAssertEqual(ScenarioPreset.relax.displayName, "摸鱼")
        XCTAssertEqual(ScenarioPreset.eyeCare.displayName, "护眼强化")
        XCTAssertEqual(ScenarioPreset.custom.displayName, "自定情景")
        XCTAssertEqual(ScenarioPreset.focus.systemImage, "target")
        XCTAssertEqual(ScenarioPreset.custom.systemImage, "slider.horizontal.3")
    }
}
