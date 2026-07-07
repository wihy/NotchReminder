import AppKit
import DynamicNotchKit
import ReminderCore

/// 强样式浮层「起身5分钟」/「知道了」两个按钮对应的动作(CONTRACT §C2)。
public enum SitAction: Equatable {
    case snooze   // 起身5分钟: 记真休息意图(由 AppController 清 sit 计时)
    case dismiss  // 知道了: 仅收起
}

/// 封装 DynamicNotchKit 的最小刘海浮层入口。
/// DynamicNotchInfo.init 本身非 @MainActor(可任意上下文构造); 仅 expand/hide 经
/// DynamicNotchControllable 协议为 @MainActor async, 故 showTest() 标 @MainActor 以承载 await。
/// Task 5 会用 present(_:onAction:) 取代 showTest(), 并保留 public 可访问性。
@MainActor public final class NotchPresenter {
    public init() {}

    /// 唯一对外渲染入口。本 Task(阶段1)四类都做成 DynamicNotchInfo 占位卡片(停留数秒自动收),
    /// onAction 暂不触发; Task 5 把 sit/night 升级为带按钮的强样式(回调 onAction)、water/eye 改轻样式。
    @MainActor
    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
        let info: DynamicNotchInfo
        switch r {
        case let .sit(minutes, project):
            let suffix = project.map { " · \($0) 项目" } ?? ""
            info = DynamicNotchInfo(
                icon: .init(systemName: "figure.walk", color: .orange),
                title: "该起身了",
                description: "连续 \(minutes) 分钟\(suffix) / 起来走两步"
            )
        case .water:
            info = DynamicNotchInfo(
                icon: .init(systemName: "drop.fill", color: .blue),
                title: "喝口水",
                description: "累计工作到点了 / 补个水"
            )
        case .eye:
            info = DynamicNotchInfo(
                icon: .init(systemName: "eye.fill", color: .green),
                title: "护眼远眺",
                description: "看看 6 米外的东西 20 秒"
            )
        case let .night(clock):
            info = DynamicNotchInfo(
                icon: .init(systemName: "moon.stars.fill", color: .purple),
                title: "\(clock) 了",
                description: "明天的你会感谢现在睡觉的你"
            )
        }
        Task { @MainActor in
            await info.expand()                       // 内部已含 ~0.4s 动画等待
            try? await Task.sleep(for: .seconds(4))   // 额外停留 4s
            await info.hide()
        }
    }

    /// 弹一张测试信息卡片(展开 → 停留 3s → 自动收起)。DynamicNotchKit 无内建 auto-hide,
    /// 手动 expand() + Task.sleep + hide()。
    @MainActor
    func showTest() {
        let info = DynamicNotchInfo(
            icon: .init(systemName: "checkmark.seal", color: .green),   // DynamicNotchInfo.Label?
            title: "测试提醒",                                            // LocalizedStringKey
            description: "刘海浮层测试卡片 · NotchReminder"                // LocalizedStringKey?
        )
        Task { @MainActor in
            await info.expand()                       // async; 内部含 ~0.4s 展开动画后返回
            try? await Task.sleep(for: .seconds(3))   // 额外停留 3s
            await info.hide()                          // 淡出并销毁窗口
        }
    }
}
