import Foundation

/// 一次采样输入。纯数据, 无副作用。
public struct Sample: Equatable {
    public var now: Date
    public var idleSeconds: Double
    public var ccActive: Bool
    public var ccLastEvent: Date?
    public var project: String?

    public init(
        now: Date,
        idleSeconds: Double,
        ccActive: Bool = false,
        ccLastEvent: Date? = nil,
        project: String? = nil
    ) {
        self.now = now
        self.idleSeconds = idleSeconds
        self.ccActive = ccActive
        self.ccLastEvent = ccLastEvent
        self.project = project
    }
}

/// 每类提醒的展示样式。默认与现有硬编码一致(sit/night 强、water/eye 轻)。
public enum ReminderStyle: String, Equatable, CaseIterable, Codable {
    case strong   // 带按钮, 等用户操作
    case light    // 一闪即收, 无按钮
}

/// 引擎配置: 四类阈值 + 四个开关 + 判定阈值 + 免打扰窗口 + 每类样式/静默/文案模板。
/// 时间字段单位秒。默认值取 spec §5.3/§5.4; 设计稿新增字段一律带默认值 = 现状。
public struct ReminderConfig: Equatable {
    public var sitThreshold: TimeInterval
    public var waterThreshold: TimeInterval
    public var eyeThreshold: TimeInterval
    public var activeIdleCeiling: TimeInterval
    public var restThreshold: TimeInterval
    public var ccGrace: TimeInterval
    public var sitSnooze: TimeInterval
    public var nightRepeat: TimeInterval
    public var sitEnabled: Bool
    public var waterEnabled: Bool
    public var eyeEnabled: Bool
    public var nightEnabled: Bool
    public var mutedUntil: Date?

    // 每类样式(默认与现有硬编码一致)
    public var sitStyle: ReminderStyle
    public var waterStyle: ReminderStyle
    public var eyeStyle: ReminderStyle
    public var nightStyle: ReminderStyle

    // 每类静默(现仅 sit 有 sitSnooze; 补 water/eye 独立静默, 默认 0 = 不额外静默)
    public var waterSnooze: TimeInterval
    public var eyeSnooze: TimeInterval

    // 定时勿扰(本地时区当天分钟数 0...1439; nil = 不启用)。窗口内 advance 不产出提醒但计时照常。
    public var dndStartMinute: Int?
    public var dndEndMinute: Int?

    // 自定义文案模板(nil = presenter 用内置默认)。支持占位 {minutes}{project}{clock}
    public var sitTitleTemplate: String?
    public var sitSubtitleTemplate: String?
    public var waterTitleTemplate: String?
    public var waterSubtitleTemplate: String?
    public var eyeTitleTemplate: String?
    public var eyeSubtitleTemplate: String?
    public var nightTitleTemplate: String?
    public var nightSubtitleTemplate: String?

    public init(
        sitThreshold: TimeInterval = 50 * 60,
        waterThreshold: TimeInterval = 60 * 60,
        eyeThreshold: TimeInterval = 30 * 60,
        activeIdleCeiling: TimeInterval = 60,
        restThreshold: TimeInterval = 5 * 60,
        ccGrace: TimeInterval = 90,
        sitSnooze: TimeInterval = 15 * 60,
        nightRepeat: TimeInterval = 30 * 60,
        sitEnabled: Bool = true,
        waterEnabled: Bool = true,
        eyeEnabled: Bool = true,
        nightEnabled: Bool = true,
        mutedUntil: Date? = nil,
        sitStyle: ReminderStyle = .strong,
        waterStyle: ReminderStyle = .light,
        eyeStyle: ReminderStyle = .light,
        nightStyle: ReminderStyle = .strong,
        waterSnooze: TimeInterval = 0,
        eyeSnooze: TimeInterval = 0,
        dndStartMinute: Int? = nil,
        dndEndMinute: Int? = nil,
        sitTitleTemplate: String? = nil,
        sitSubtitleTemplate: String? = nil,
        waterTitleTemplate: String? = nil,
        waterSubtitleTemplate: String? = nil,
        eyeTitleTemplate: String? = nil,
        eyeSubtitleTemplate: String? = nil,
        nightTitleTemplate: String? = nil,
        nightSubtitleTemplate: String? = nil
    ) {
        self.sitThreshold = sitThreshold
        self.waterThreshold = waterThreshold
        self.eyeThreshold = eyeThreshold
        self.activeIdleCeiling = activeIdleCeiling
        self.restThreshold = restThreshold
        self.ccGrace = ccGrace
        self.sitSnooze = sitSnooze
        self.nightRepeat = nightRepeat
        self.sitEnabled = sitEnabled
        self.waterEnabled = waterEnabled
        self.eyeEnabled = eyeEnabled
        self.nightEnabled = nightEnabled
        self.mutedUntil = mutedUntil
        self.sitStyle = sitStyle
        self.waterStyle = waterStyle
        self.eyeStyle = eyeStyle
        self.nightStyle = nightStyle
        self.waterSnooze = waterSnooze
        self.eyeSnooze = eyeSnooze
        self.dndStartMinute = dndStartMinute
        self.dndEndMinute = dndEndMinute
        self.sitTitleTemplate = sitTitleTemplate
        self.sitSubtitleTemplate = sitSubtitleTemplate
        self.waterTitleTemplate = waterTitleTemplate
        self.waterSubtitleTemplate = waterSubtitleTemplate
        self.eyeTitleTemplate = eyeTitleTemplate
        self.eyeSubtitleTemplate = eyeSubtitleTemplate
        self.nightTitleTemplate = nightTitleTemplate
        self.nightSubtitleTemplate = nightSubtitleTemplate
    }
}

/// 引擎累积状态。由 advance 输入并返回更新后的副本(值语义)。
public struct ReminderState: Equatable {
    public var sitAccum: TimeInterval
    public var waterAccum: TimeInterval
    public var eyeAccum: TimeInterval
    public var lastSample: Date?
    public var lastSitAlert: Date?
    public var lastNightAlert: Date?
    /// water/eye 上次触发时刻(用于「忽略后静默」snooze gate; 默认 nil)。
    public var lastWaterAlert: Date?
    public var lastEyeAlert: Date?

    public init(
        sitAccum: TimeInterval = 0,
        waterAccum: TimeInterval = 0,
        eyeAccum: TimeInterval = 0,
        lastSample: Date? = nil,
        lastSitAlert: Date? = nil,
        lastNightAlert: Date? = nil,
        lastWaterAlert: Date? = nil,
        lastEyeAlert: Date? = nil
    ) {
        self.sitAccum = sitAccum
        self.waterAccum = waterAccum
        self.eyeAccum = eyeAccum
        self.lastSample = lastSample
        self.lastSitAlert = lastSitAlert
        self.lastNightAlert = lastNightAlert
        self.lastWaterAlert = lastWaterAlert
        self.lastEyeAlert = lastEyeAlert
    }
}

/// 一次 advance 可产出的提醒。Equatable 便于单测断言。
public enum Reminder: Equatable {
    case sit(minutes: Int, project: String?)
    case water
    case eye
    case night(clock: String)
}
