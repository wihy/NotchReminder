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

    /// 宠物开关(临时: Task 5 正式分组持久化, 此属性可被替换/收编)。
    var petEnabled: Bool {
        get { defaults.object(forKey: "petEnabled") == nil ? true : defaults.bool(forKey: "petEnabled") }
        set { defaults.set(newValue, forKey: "petEnabled") }
    }

    // MARK: - Helpers

    private func double(_ key: String, fallback: TimeInterval) -> TimeInterval {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
