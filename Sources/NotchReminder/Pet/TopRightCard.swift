import SwiftUI
import AppKit

/// 右上角提醒卡:cardPosition == "topRight" 时, 提醒不展开刘海, 改由本浮层在主屏右上角显示。
/// 承载与刘海 expanded 相同的 PetExpandedView(复用同一 payload / petVM), 文案与按钮行为一致。
@MainActor
final class TopRightCardController {

    private let vm: PetViewModel
    private let payload: StrongPayload
    private var panel: NSPanel?
    private let margin: CGFloat = 12

    init(vm: PetViewModel, payload: StrongPayload) {
        self.vm = vm
        self.payload = payload
    }

    /// 在主屏右上角显示卡片(懒建 panel)。payload 已由 presenter 先行 set。
    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let p = panel ?? makePanel()
        panel = p
        // 依内容测量高度, 固定宽度, 贴主屏可见区右上角。
        let width: CGFloat = 380
        if let host = p.contentView {
            host.setFrameSize(NSSize(width: width, height: host.fittingSize.height))
        }
        let height = p.contentView?.fittingSize.height ?? 110
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.maxX - width - margin, y: vf.maxY - height - margin)
        p.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            p.animator().alphaValue = 1
        }
    }

    /// 淡出收起卡片。
    func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in
            p?.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let p = KeyableCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TopRightCardView(vm: vm, payload: payload))
        p.contentView = host
        return p
    }
}

/// 无边框浮层默认 canBecomeKey=false, 会让卡上按钮收不到点击。
/// 覆盖为可成 key(配合 .nonactivatingPanel: 可交互但不激活 App、不抢焦点)。
private final class KeyableCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 右上角卡外观:把复用的 PetExpandedView 放到圆角材质卡片上(脱离刘海需自带背景)。
private struct TopRightCardView: View {
    @ObservedObject var vm: PetViewModel
    @ObservedObject var payload: StrongPayload

    var body: some View {
        PetExpandedView(vm: vm, payload: payload)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 380)
    }
}
