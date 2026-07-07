import AppKit
import Foundation
import ReminderCore

/// 构建并刷新完整菜单栏菜单。作为 NSMenuDelegate, 每次弹出前(menuNeedsUpdate)重建,
/// 保证只读状态行反映最新 state。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let store: SettingsStore
    private let menu = NSMenu()
    private lazy var settingsWC = SettingsWindowController(store: store)

    init(statusItem: NSStatusItem, store: SettingsStore) {
        self.statusItem = statusItem
        self.store = store
        super.init()
    }

    /// 挂菜单到 statusItem 并设 delegate。
    func attach() {
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "NotchReminder")
        }
        rebuild()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: - Build

    private func rebuild() {
        menu.removeAllItems()

        let config = AppController.shared.config
        let state = AppController.shared.state
        let project = currentProject()

        // 只读状态行 1: 连续工作 Nmin · <project>
        let workedMin = Int(state.sitAccum / 60)
        let line1 = "连续工作 \(workedMin)min · \(project)"
        menu.addItem(disabledItem(line1))

        // 只读状态行 2: 下次久坐 Nmin 后
        let remainSec = max(0, config.sitThreshold - state.sitAccum)
        let remainMin = Int(ceil(remainSec / 60))
        let line2: String
        if !config.sitEnabled {
            line2 = "久坐提醒已关闭"
        } else if let muted = config.mutedUntil, Date() < muted {
            line2 = "专注中 · 提醒已静音"
        } else {
            line2 = "下次久坐提醒：\(remainMin)min 后"
        }
        menu.addItem(disabledItem(line2))

        menu.addItem(.separator())

        // 手动动作
        addItem("☕️ 我起身了", #selector(didTapManualRest))
        addItem("🔕 专注 1 小时", #selector(didTapFocusOneHour))

        menu.addItem(.separator())

        // 四开关(勾选态绑定 config)
        addToggle("久坐起身", on: config.sitEnabled, #selector(didToggleSit))
        addToggle("喝水", on: config.waterEnabled, #selector(didToggleWater))
        addToggle("护眼远眺", on: config.eyeEnabled, #selector(didToggleEye))
        addToggle("熬夜劝退", on: config.nightEnabled, #selector(didToggleNight))

        menu.addItem(.separator())

        addItem("⚙️ 设置…", #selector(didTapSettings))
        addItem("退出", #selector(didTapQuit))
    }

    // MARK: - Item helpers

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addItem(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addToggle(_ title: String, on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func didTapManualRest() {
        AppController.shared.manualRest()
    }

    @objc private func didTapFocusOneHour() {
        AppController.shared.muteFor(3600)
    }

    @objc private func didToggleSit()   { toggle { $0.sitEnabled.toggle() } }
    @objc private func didToggleWater() { toggle { $0.waterEnabled.toggle() } }
    @objc private func didToggleEye()   { toggle { $0.eyeEnabled.toggle() } }
    @objc private func didToggleNight() { toggle { $0.nightEnabled.toggle() } }

    @objc private func didTapSettings() {
        settingsWC.show()
    }

    @objc private func didTapQuit() {
        NSApp.terminate(nil)
    }

    /// 翻转某开关: 取当前 config → 变更 → 存 → 生效。
    private func toggle(_ mutate: (inout ReminderConfig) -> Void) {
        var cfg = AppController.shared.config
        mutate(&cfg)
        store.save(cfg)
        AppController.shared.applyConfig(cfg)
    }

    // MARK: - cc.json project

    /// 从 ~/.notchreminder/cc.json 读 project(CONTRACT §5.2)。缺失/未激活显示 "—"。
    private func currentProject() -> String {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".notchreminder/cc.json")
        guard
            let data = FileManager.default.contents(atPath: path),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let active = obj["cc_active"] as? Bool, active,
            let project = obj["project"] as? String, !project.isEmpty
        else {
            return "—"
        }
        return project
    }
}
