import SwiftUI
import DynamicNotchKit
import ReminderCore

/// 强样式浮层上「起身5分钟」/「知道了」两个按钮对应的动作(CONTRACT §C2)。
public enum SitAction: Equatable {
    case snooze   // 起身5分钟: 记真休息意图(由 AppController 清 sit 计时)
    case dismiss  // 知道了: 仅收起
}

/// 封装 DynamicNotchKit 的强/轻样式渲染。整类 @MainActor: 库的展开/收起方法均 @MainActor 隔离(经协议)。
@MainActor
public final class NotchPresenter {
    /// 轻样式停留时长(秒)。expand() 自身另含 ~0.4s 动画等待, 此为额外停留。
    private let autoHideSeconds: TimeInterval = 4

    /// 当前强样式浮层实例。持有引用以便按钮回调里 hide, 以及被下一条强提醒替换时先收起旧的。
    private var strongNotch: DynamicNotch<StrongReminderView, EmptyView, EmptyView>?

    /// 测试钩: present(_:onAction:) 被调用的累计次数(含无头测试环境)。内部可见, 供 @testable 测试断言。
    private(set) var presentCount = 0

    public init() {}

    /// 唯一对外渲染入口(CONTRACT §C2)。把一条 Reminder 映射到刘海浮层。
    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
        presentCount += 1
        switch r {
        case let .sit(minutes, project):
            presentStrong(
                title: sitTitle(minutes: minutes, project: project),
                subtitle: "起来走两步, 眼睛也歇歇",
                showSnooze: true,
                onAction: onAction
            )
        case let .night(clock):
            presentStrong(
                title: "\(clock) 了",
                subtitle: "明天的你会感谢现在睡觉的你",
                showSnooze: false,
                onAction: onAction
            )
        case .water:
            presentLight(systemName: "drop.fill", color: .blue, title: "喝口水", description: "补个水, 顺手站一下")
        case .eye:
            presentLight(systemName: "eye.fill", color: .green, title: "远眺 20 秒", description: "看向 6 米外, 放松睫状肌")
        }
    }

    // MARK: - 强样式

    private func presentStrong(
        title: String,
        subtitle: String,
        showSnooze: Bool,
        onAction: ((SitAction) -> Void)?
    ) {
        // 先收起上一条强提醒(若有), 避免叠放。序列化 hide→expand, 防止两个动画重叠。
        let old = strongNotch
        let notch = DynamicNotch {
            StrongReminderView(
                title: title,
                subtitle: subtitle,
                showSnooze: showSnooze,
                onSnooze: { [weak self] in
                    onAction?(.snooze)
                    self?.dismissStrong()
                },
                onDismiss: { [weak self] in
                    onAction?(.dismiss)
                    self?.dismissStrong()
                }
            )
        }
        strongNotch = notch
        Task { @MainActor in
            if let old { await old.hide() }
            await notch.expand()
        }
    }

    private func dismissStrong() {
        guard let notch = strongNotch else { return }
        strongNotch = nil
        Task { @MainActor in await notch.hide() }
    }

    // MARK: - 轻样式

    private func presentLight(systemName: String, color: Color, title: LocalizedStringKey, description: LocalizedStringKey) {
        let info = DynamicNotchInfo(
            icon: .init(systemName: systemName, color: color),
            title: title,
            description: description
        )
        Task { @MainActor in
            await info.expand()                                   // 内含 ~0.4s 动画
            try? await Task.sleep(for: .seconds(autoHideSeconds)) // 额外停留
            await info.hide()
        }
    }

    // MARK: - 文案

    private func sitTitle(minutes: Int, project: String?) -> String {
        if let p = project, !p.isEmpty {
            return "连续 \(minutes) 分钟了 · \(p) 项目"
        }
        return "连续 \(minutes) 分钟了"
    }
}
