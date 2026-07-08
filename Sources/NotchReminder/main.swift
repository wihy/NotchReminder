import AppKit

/// 菜单栏 accessory App 委托: 挂一个 NSStatusItem, 完整菜单由 MenuBarController 管理。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let presenter = NotchPresenter()
    private var controller: AppController!
    private let settingsStore = SettingsStore()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let c = AppController(presenter: presenter, config: settingsStore.load())  // 初始 config 来自持久化
        c.onSitSnooze = { [weak c] in c?.manualRest() }   // snooze 与「我起身了」同一清零语义(CONTRACT §C3)
        AppController.shared = c                            // 供菜单/设置窗访问
        controller = c
        // Task 7: 完整菜单 + 首启引导(替换 Task 1 的占位菜单)
        let mbc = MenuBarController(statusItem: statusItem, store: settingsStore)
        mbc.attach()
        menuBarController = mbc
        FirstRunGuide.presentIfNeeded(store: settingsStore)
        presenter.attachPet(pauseOnBattery: settingsStore.petPauseOnBattery)
        presenter.setPetEnabled(settingsStore.petEnabled)
        c.start()
    }
}

let app = NSApplication.shared
// 顶层是 nonisolated 上下文, AppDelegate 是 @MainActor 类型, 用 assumeIsolated 在主 actor 上构造。
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏 accessory: 无 Dock 图标、无主菜单
app.run()
