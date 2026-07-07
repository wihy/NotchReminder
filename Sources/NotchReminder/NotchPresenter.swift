import AppKit
import DynamicNotchKit

/// 封装 DynamicNotchKit 的最小刘海浮层入口。
/// DynamicNotchInfo.init 本身非 @MainActor(可任意上下文构造); 仅 expand/hide 经
/// DynamicNotchControllable 协议为 @MainActor async, 故 showTest() 标 @MainActor 以承载 await。
/// Task 5 会用 present(_:onAction:) 取代 showTest(), 并保留 public 可访问性。
public final class NotchPresenter {
    public init() {}

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
