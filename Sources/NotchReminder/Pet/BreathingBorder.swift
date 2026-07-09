import SwiftUI
import AppKit

/// 呼吸灯边框:提醒展示期间在主屏四周叠一层脉动柔光。
/// 用一个全屏、透明、点击穿透的 NSPanel 承载 SwiftUI 边框, 不干扰任何交互。
@MainActor
final class BreathingBorderController {

    private var panel: NSPanel?

    /// 显示呼吸边框(懒建 panel, 覆盖主屏)。重复调用只前置。
    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(screen.frame, display: true)
        p.orderFrontRegardless()
    }

    /// 收起呼吸边框。
    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = true    // 点击穿透
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: BreathingBorderView())
        return p
    }
}

/// 屏幕四周的脉动柔光边框。语义色(accentColor), 深浅色均可见。
private struct BreathingBorderView: View {
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: pulse ? 12 : 4)
            .blur(radius: 7)
            .opacity(pulse ? 0.9 : 0.35)
            .padding(3)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
