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

    public init() {}

    public func setMood(_ m: PetMood) { mood = m }
    public func playAct(_ a: PetAct) { act = a }
    public func clearAct() { act = nil }
    public func sleep() { isAwake = false }
    public func wake() { isAwake = true }
    public func pet() { isPetting = true }
    public func clearPet() { isPetting = false }
}
