import Foundation

/// 情景预设: 一键套用整套阈值与样式(设计稿「情景模式」)。纯数据, 可单测。
public enum ScenarioPreset: String, CaseIterable, Codable {
    case focus      // 专注: 仅久坐 + 护眼, 轻样式, 静音
    case relax      // 摸鱼: 全开, 强样式, 高频
    case eyeCare    // 护眼强化: 护眼 20min
    case custom     // 自定义: 不覆盖用户手调值

    public var displayName: String {
        switch self {
        case .focus: return "专注"
        case .relax: return "摸鱼"
        case .eyeCare: return "护眼强化"
        case .custom: return "自定情景"
        }
    }

    /// SF Symbol 名(设计稿图标的原生等价)。
    public var systemImage: String {
        switch self {
        case .focus: return "target"
        case .relax: return "fish"
        case .eyeCare: return "eye"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// 把预设套用到一个基准 config 上, 返回新 config。custom 原样返回。
    public func apply(to base: ReminderConfig) -> ReminderConfig {
        var c = base
        switch self {
        case .focus:
            c.sitEnabled = true;  c.eyeEnabled = true
            c.waterEnabled = false; c.nightEnabled = false
            c.sitStyle = .light; c.eyeStyle = .light
        case .relax:
            c.sitEnabled = true; c.waterEnabled = true; c.eyeEnabled = true; c.nightEnabled = true
            c.sitStyle = .strong; c.nightStyle = .strong
            c.sitThreshold = 40 * 60; c.waterThreshold = 45 * 60
        case .eyeCare:
            c.eyeEnabled = true; c.eyeThreshold = 20 * 60; c.eyeStyle = .light
        case .custom:
            break
        }
        return c
    }
}
