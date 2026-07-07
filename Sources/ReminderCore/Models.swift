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

/// 引擎配置: 四类阈值 + 四个开关 + 判定阈值 + 免打扰窗口。时间字段单位秒。默认值取 spec §5.3/§5.4。
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
        mutedUntil: Date? = nil
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

    public init(
        sitAccum: TimeInterval = 0,
        waterAccum: TimeInterval = 0,
        eyeAccum: TimeInterval = 0,
        lastSample: Date? = nil,
        lastSitAlert: Date? = nil,
        lastNightAlert: Date? = nil
    ) {
        self.sitAccum = sitAccum
        self.waterAccum = waterAccum
        self.eyeAccum = eyeAccum
        self.lastSample = lastSample
        self.lastSitAlert = lastSitAlert
        self.lastNightAlert = lastNightAlert
    }
}

/// 一次 advance 可产出的提醒。Equatable 便于单测断言。
public enum Reminder: Equatable {
    case sit(minutes: Int, project: String?)
    case water
    case eye
    case night(clock: String)
}
