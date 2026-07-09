import Foundation
import ReminderCore

/// 用 UserDefaults 持久化用户可配置项:
/// - ReminderConfig 的四类阈值(含熬夜重复间隔)+ 四个开关。
/// - 三个标量偏好: 开机自启意图 / 样式偏好 / 首启完成标记。
///
/// 注: mutedUntil 是运行期临时静音态, 不持久化(重启不应保留静音)。
/// activeIdleCeiling / restThreshold / ccGrace / sitSnooze 属引擎内部判定阈值,
/// 本版设置窗不暴露给用户改, 故也不持久化(load 时回落默认值)。
final class SettingsStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let sitThreshold = "sitThreshold"
        static let waterThreshold = "waterThreshold"
        static let eyeThreshold = "eyeThreshold"
        static let nightRepeat = "nightRepeat"
        static let sitEnabled = "sitEnabled"
        static let waterEnabled = "waterEnabled"
        static let eyeEnabled = "eyeEnabled"
        static let nightEnabled = "nightEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let strongStyleStaysLonger = "strongStyleStaysLonger"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let petEnabled = "petEnabled"
        static let petPauseOnBattery = "petPauseOnBattery"
        static let petCharacter = "petCharacter"
        // 每类样式 / 静默 / 定时勿扰 / 文案模板(设计稿新增, 随 config 持久化)
        static let sitStyle = "sitStyle"
        static let waterStyle = "waterStyle"
        static let eyeStyle = "eyeStyle"
        static let nightStyle = "nightStyle"
        static let waterSnooze = "waterSnooze"
        static let eyeSnooze = "eyeSnooze"
        static let dndStartMinute = "dndStartMinute"
        static let dndEndMinute = "dndEndMinute"
        static let sitTitleTemplate = "sitTitleTemplate"
        static let sitSubtitleTemplate = "sitSubtitleTemplate"
        static let waterTitleTemplate = "waterTitleTemplate"
        static let waterSubtitleTemplate = "waterSubtitleTemplate"
        static let eyeTitleTemplate = "eyeTitleTemplate"
        static let eyeSubtitleTemplate = "eyeSubtitleTemplate"
        static let nightTitleTemplate = "nightTitleTemplate"
        static let nightSubtitleTemplate = "nightSubtitleTemplate"
        // 应用层展示 pref(不进 ReminderConfig)
        static let scenario = "scenario"
        static let soundEnabled = "soundEnabled"
        static let soundName = "soundName"
        static let breathingLight = "breathingLight"
        static let cardDwellSeconds = "cardDwellSeconds"
        static let cardPosition = "cardPosition"
        static let petColorTheme = "petColorTheme"
        static let petSizeScale = "petSizeScale"
        static let petSide = "petSide"
        static let petAnimationIntensity = "petAnimationIntensity"
        static let fullscreenSilence = "fullscreenSilence"
        static let castingSilence = "castingSilence"
        static let sitSound = "sitSound"
        static let waterSound = "waterSound"
        static let eyeSound = "eyeSound"
        static let nightSound = "nightSound"
    }

    // MARK: - Config round-trip

    /// 读出持久化的 ReminderConfig。任一键缺失 → 该字段回落 ReminderConfig() 默认。
    func load() -> ReminderConfig {
        let d = ReminderConfig()  // 默认值来源
        var cfg = ReminderConfig()

        cfg.sitThreshold   = double(Key.sitThreshold,   fallback: d.sitThreshold)
        cfg.waterThreshold = double(Key.waterThreshold, fallback: d.waterThreshold)
        cfg.eyeThreshold   = double(Key.eyeThreshold,   fallback: d.eyeThreshold)
        cfg.nightRepeat    = double(Key.nightRepeat,    fallback: d.nightRepeat)

        cfg.sitEnabled   = bool(Key.sitEnabled,   fallback: d.sitEnabled)
        cfg.waterEnabled = bool(Key.waterEnabled, fallback: d.waterEnabled)
        cfg.eyeEnabled   = bool(Key.eyeEnabled,   fallback: d.eyeEnabled)
        cfg.nightEnabled = bool(Key.nightEnabled, fallback: d.nightEnabled)

        // 每类样式(缺失 → 默认)
        cfg.sitStyle   = style(Key.sitStyle,   fallback: d.sitStyle)
        cfg.waterStyle = style(Key.waterStyle, fallback: d.waterStyle)
        cfg.eyeStyle   = style(Key.eyeStyle,   fallback: d.eyeStyle)
        cfg.nightStyle = style(Key.nightStyle, fallback: d.nightStyle)

        // 每类静默
        cfg.waterSnooze = double(Key.waterSnooze, fallback: d.waterSnooze)
        cfg.eyeSnooze   = double(Key.eyeSnooze,   fallback: d.eyeSnooze)

        // 定时勿扰(缺失 → nil)
        cfg.dndStartMinute = optionalInt(Key.dndStartMinute)
        cfg.dndEndMinute   = optionalInt(Key.dndEndMinute)

        // 文案模板(缺失 → nil = 内置默认)
        cfg.sitTitleTemplate      = optionalString(Key.sitTitleTemplate)
        cfg.sitSubtitleTemplate   = optionalString(Key.sitSubtitleTemplate)
        cfg.waterTitleTemplate    = optionalString(Key.waterTitleTemplate)
        cfg.waterSubtitleTemplate = optionalString(Key.waterSubtitleTemplate)
        cfg.eyeTitleTemplate      = optionalString(Key.eyeTitleTemplate)
        cfg.eyeSubtitleTemplate   = optionalString(Key.eyeSubtitleTemplate)
        cfg.nightTitleTemplate    = optionalString(Key.nightTitleTemplate)
        cfg.nightSubtitleTemplate = optionalString(Key.nightSubtitleTemplate)

        // 未暴露的引擎阈值保持默认; mutedUntil 不持久化 → 始终 nil。
        return cfg
    }

    /// 持久化 ReminderConfig 的可配置部分。
    func save(_ config: ReminderConfig) {
        defaults.set(config.sitThreshold,   forKey: Key.sitThreshold)
        defaults.set(config.waterThreshold, forKey: Key.waterThreshold)
        defaults.set(config.eyeThreshold,   forKey: Key.eyeThreshold)
        defaults.set(config.nightRepeat,    forKey: Key.nightRepeat)
        defaults.set(config.sitEnabled,   forKey: Key.sitEnabled)
        defaults.set(config.waterEnabled, forKey: Key.waterEnabled)
        defaults.set(config.eyeEnabled,   forKey: Key.eyeEnabled)
        defaults.set(config.nightEnabled, forKey: Key.nightEnabled)

        defaults.set(config.sitStyle.rawValue,   forKey: Key.sitStyle)
        defaults.set(config.waterStyle.rawValue, forKey: Key.waterStyle)
        defaults.set(config.eyeStyle.rawValue,   forKey: Key.eyeStyle)
        defaults.set(config.nightStyle.rawValue, forKey: Key.nightStyle)

        defaults.set(config.waterSnooze, forKey: Key.waterSnooze)
        defaults.set(config.eyeSnooze,   forKey: Key.eyeSnooze)

        setOptionalInt(config.dndStartMinute, forKey: Key.dndStartMinute)
        setOptionalInt(config.dndEndMinute,   forKey: Key.dndEndMinute)

        setOptionalString(config.sitTitleTemplate,      forKey: Key.sitTitleTemplate)
        setOptionalString(config.sitSubtitleTemplate,   forKey: Key.sitSubtitleTemplate)
        setOptionalString(config.waterTitleTemplate,    forKey: Key.waterTitleTemplate)
        setOptionalString(config.waterSubtitleTemplate, forKey: Key.waterSubtitleTemplate)
        setOptionalString(config.eyeTitleTemplate,      forKey: Key.eyeTitleTemplate)
        setOptionalString(config.eyeSubtitleTemplate,   forKey: Key.eyeSubtitleTemplate)
        setOptionalString(config.nightTitleTemplate,    forKey: Key.nightTitleTemplate)
        setOptionalString(config.nightSubtitleTemplate, forKey: Key.nightSubtitleTemplate)
    }

    /// 语义别名: 供 AppController 启动时取初始 config。
    func makeConfig() -> ReminderConfig { load() }

    // MARK: - Scalar prefs

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var strongStyleStaysLonger: Bool {
        get { defaults.bool(forKey: Key.strongStyleStaysLonger) }
        set { defaults.set(newValue, forKey: Key.strongStyleStaysLonger) }
    }

    var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
    }

    /// 宠物总开关(默认 true: 首次无存值视为开启)。
    var petEnabled: Bool {
        get { defaults.object(forKey: Key.petEnabled) == nil ? true : defaults.bool(forKey: Key.petEnabled) }
        set { defaults.set(newValue, forKey: Key.petEnabled) }
    }

    /// 电池模式静止(省电): v1 启动时读一次决定是否常驻, 重启生效。
    var petPauseOnBattery: Bool {
        get { defaults.bool(forKey: Key.petPauseOnBattery) }
        set { defaults.set(newValue, forKey: Key.petPauseOnBattery) }
    }

    /// 宠物形象。设计稿扩为可写: "blob" | "cat" | "droplet" | "sprout"。默认 "blob"。
    var petCharacter: String {
        get { defaults.string(forKey: Key.petCharacter) ?? "blob" }
        set { defaults.set(newValue, forKey: Key.petCharacter) }
    }

    // MARK: - Scenario / 提醒方式 / 宠物外观 pref(不进 ReminderConfig)

    /// 当前情景预设(默认 .custom = 不覆盖用户手调值)。
    var scenario: ScenarioPreset {
        get { ScenarioPreset(rawValue: defaults.string(forKey: Key.scenario) ?? "") ?? .custom }
        set { defaults.set(newValue.rawValue, forKey: Key.scenario) }
    }

    /// 提示音开关(默认 true)。
    var soundEnabled: Bool {
        get { bool(Key.soundEnabled, fallback: true) }
        set { defaults.set(newValue, forKey: Key.soundEnabled) }
    }

    /// 提示音名(NSSound 系统音名, 默认 "Ping")。
    var soundName: String {
        get { defaults.string(forKey: Key.soundName) ?? "Ping" }
        set { defaults.set(newValue, forKey: Key.soundName) }
    }

    /// 呼吸灯边框(默认 false)。
    var breathingLight: Bool {
        get { defaults.bool(forKey: Key.breathingLight) }
        set { defaults.set(newValue, forKey: Key.breathingLight) }
    }

    /// 卡片停留时长秒(默认 4, 接管 presenter 的 autoHideSeconds)。
    var cardDwellSeconds: Double {
        get { double(Key.cardDwellSeconds, fallback: 4) }
        set { defaults.set(newValue, forKey: Key.cardDwellSeconds) }
    }

    /// 卡片位置: "notch" | "topRight"(默认 "notch")。
    var cardPosition: String {
        get { defaults.string(forKey: Key.cardPosition) ?? "notch" }
        set { defaults.set(newValue, forKey: Key.cardPosition) }
    }

    /// 宠物配色主题名(默认 "sky")。
    var petColorTheme: String {
        get { defaults.string(forKey: Key.petColorTheme) ?? "sky" }
        set { defaults.set(newValue, forKey: Key.petColorTheme) }
    }

    /// 宠物大小缩放 0.8...1.3(默认 1.0)。
    var petSizeScale: Double {
        get { double(Key.petSizeScale, fallback: 1.0) }
        set { defaults.set(newValue, forKey: Key.petSizeScale) }
    }

    /// 宠物刘海侧位置: "left" | "right"(默认 "left")。
    var petSide: String {
        get { defaults.string(forKey: Key.petSide) ?? "left" }
        set { defaults.set(newValue, forKey: Key.petSide) }
    }

    /// 宠物动画强度 0...1(默认 0.6)。
    var petAnimationIntensity: Double {
        get { double(Key.petAnimationIntensity, fallback: 0.6) }
        set { defaults.set(newValue, forKey: Key.petAnimationIntensity) }
    }

    /// 全屏应用静默(默认 true = 现状: 全屏时不弹提醒, 结束后补放)。
    var fullscreenSilence: Bool {
        get { bool(Key.fullscreenSilence, fallback: true) }
        set { defaults.set(newValue, forKey: Key.fullscreenSilence) }
    }

    /// 投屏/镜像静默(默认 false)。用 CGDisplayIsInMirrorSet 检测屏幕镜像/投屏。
    var castingSilence: Bool {
        get { defaults.bool(forKey: Key.castingSilence) }
        set { defaults.set(newValue, forKey: Key.castingSilence) }
    }

    /// 每类提示音(NSSound 系统音名, 默认 "Ping")。总开关是 soundEnabled。
    var sitSound: String {
        get { defaults.string(forKey: Key.sitSound) ?? "Ping" }
        set { defaults.set(newValue, forKey: Key.sitSound) }
    }
    var waterSound: String {
        get { defaults.string(forKey: Key.waterSound) ?? "Ping" }
        set { defaults.set(newValue, forKey: Key.waterSound) }
    }
    var eyeSound: String {
        get { defaults.string(forKey: Key.eyeSound) ?? "Ping" }
        set { defaults.set(newValue, forKey: Key.eyeSound) }
    }
    var nightSound: String {
        get { defaults.string(forKey: Key.nightSound) ?? "Ping" }
        set { defaults.set(newValue, forKey: Key.nightSound) }
    }

    // MARK: - Helpers

    private func double(_ key: String, fallback: TimeInterval) -> TimeInterval {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func style(_ key: String, fallback: ReminderStyle) -> ReminderStyle {
        guard let raw = defaults.string(forKey: key) else { return fallback }
        return ReminderStyle(rawValue: raw) ?? fallback
    }

    /// 缺键 → nil(用于定时勿扰起止分钟数)。
    private func optionalInt(_ key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    private func setOptionalInt(_ value: Int?, forKey key: String) {
        if let v = value { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// 缺键 → nil(用于自定义文案模板, nil = presenter 用内置默认)。
    private func optionalString(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let v = value { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
