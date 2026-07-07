import AppKit

/// 菜单栏 accessory App 委托: 挂一个 NSStatusItem, 菜单含「测试提醒 / 退出」。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let presenter = NotchPresenter()
    private var controller: AppController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "NotchReminder")
        }
        let menu = NSMenu()
        let testItem = NSMenuItem(title: "测试提醒", action: #selector(fireTest), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu

        let c = AppController(presenter: presenter)
        c.onSitSnooze = { [weak c] in c?.manualRest() }   // snooze 与「我起身了」同一清零语义(CONTRACT §C3)
        AppController.shared = c                            // 供 Task 7 菜单/设置窗访问
        controller = c
        c.start()
    }

    /// 菜单「测试提醒」回调: 弹刘海测试卡片。选择器在主线程触发, 与 @MainActor 一致。
    @objc private func fireTest() {
        presenter.showTest()
    }
}

let app = NSApplication.shared
// 顶层是 nonisolated 上下文, AppDelegate 是 @MainActor 类型, 用 assumeIsolated 在主 actor 上构造。
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏 accessory: 无 Dock 图标、无主菜单
app.run()
