import SwiftUI
import ReminderCore

/// 宠物状态机。纯状态持有(mood / act / isAwake / isPetting), 不含动画/定时——
/// 动画由 SwiftUI 视图按 @Published 状态自行驱动; 演出后的收起定时由 NotchPresenter 管(expand/compact 所在层)。
/// 整类 @MainActor: 被 NotchPresenter(主 actor) 与视图共享。
@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var mood: PetMood = .fresh
    @Published public private(set) var act: PetAct?
    @Published public private(set) var isAwake: Bool = true
    @Published public private(set) var isPetting: Bool = false
    /// 宠物是否显示的唯一真相源。长存 notch 的 compact/expanded 闭包捕获 vm,
    /// 改此值即触发视图重绘(即便闭包是在 attachPet 时建的一次性视图树)。
    @Published public private(set) var showsPet: Bool = true

    // MARK: - 外观(设计稿:宠物形象/配色/大小/侧位/动画强度)。全部默认 = 现状。
    /// 形象: "blob" | "cat" | "droplet" | "sprout"。
    @Published public private(set) var character: String = "blob"
    /// 配色主题名。"sky"(默认)= 跟随心情, 其余为固定色。
    @Published public private(set) var colorTheme: String = "sky"
    /// 大小缩放 0.8...1.3。
    @Published public private(set) var sizeScale: CGFloat = 1.0
    /// 刘海侧位置: "left" | "right"。
    @Published public private(set) var side: String = "left"
    /// 动画强度 0...1(默认 0.6)。
    @Published public private(set) var animationIntensity: CGFloat = 0.6

    /// 当前主题的固定色; "sky" → nil 表示跟随心情(现状默认)。视图 colorOverride 用它。
    public var themeColor: Color? { Self.themeColor(colorTheme) }

    /// 主题名 → 固定色。"sky" 返回 nil(跟随心情)。设计稿色板(≥5 色)。
    public static func themeColor(_ name: String) -> Color? {
        switch name {
        case "rose":     return Color(red: 0.98, green: 0.60, blue: 0.66)
        case "mint":     return Color(red: 0.55, green: 0.86, blue: 0.72)
        case "lavender": return Color(red: 0.72, green: 0.66, blue: 0.92)
        case "amber":    return Color(red: 0.98, green: 0.78, blue: 0.42)
        case "graphite": return Color(red: 0.62, green: 0.66, blue: 0.72)
        default:         return nil  // sky: 跟随心情
        }
    }

    public init() {}

    public func setShowsPet(_ on: Bool) { showsPet = on }

    /// 设置窗实时刷新宠物外观。任一参数改动即触发 compact/expanded 重绘。
    public func setAppearance(character: String, colorTheme: String,
                              sizeScale: CGFloat, side: String, animationIntensity: CGFloat) {
        self.character = character
        self.colorTheme = colorTheme
        self.sizeScale = sizeScale
        self.side = side
        self.animationIntensity = animationIntensity
    }

    public func setMood(_ m: PetMood) { mood = m }
    public func playAct(_ a: PetAct) { act = a }
    public func clearAct() { act = nil }
    public func sleep() { isAwake = false }
    public func wake() { isAwake = true }
    public func pet() { isPetting = true }
    public func clearPet() { isPetting = false }
}
