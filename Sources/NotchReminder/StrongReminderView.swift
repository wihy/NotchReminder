import SwiftUI

/// 强样式浮层内容: 标题 + 副标题 + 一到两个按钮。
/// 用 Text(verbatim:) 承载运行时插值文案, 避免 LocalizedStringKey 本地化查表。
struct StrongReminderView: View {
    let title: String
    let subtitle: String
    let showSnooze: Bool
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(verbatim: subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if showSnooze {
                    Button(action: onSnooze) {
                        Text(verbatim: "起身5分钟")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: onDismiss) {
                    Text(verbatim: "知道了")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 360)
    }
}
