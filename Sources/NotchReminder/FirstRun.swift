import AppKit

/// 首启一屏引导: 说明计时口径 + 打印 CC 插件一键安装命令。仅首次运行弹一次。
enum FirstRunGuide {

    /// CC 插件一键安装命令(与 Task 8 install.sh 一致)。
    static var ccInstallCommand: String {
        // Derive repo root from executable: <repoRoot>/.build/release/NotchReminder
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let repoRoot = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        return "bash \(repoRoot)/install.sh"
    }

    @MainActor
    static func presentIfNeeded(store: SettingsStore) {
        guard !store.hasCompletedFirstRun else { return }

        print("""
        [NotchReminder] 首次运行。要让提醒带上「正在跑哪个 CC 项目」, 请安装 CC 插件:
            \(ccInstallCommand)
        idle 计时只读系统空闲时长(CGEventSourceSecondsSinceLastEventType), 无需辅助功能权限。
        """)

        let alert = NSAlert()
        alert.messageText = "欢迎使用 NotchReminder"
        alert.informativeText = """
        它会盯住你的连续活跃时长, 在刘海周围弹久坐 / 喝水 / 护眼 / 熬夜提醒。

        · 计时基于系统空闲时长(只读), 无需辅助功能权限。
        · 想让提醒带上当前 Claude Code 项目名, 可装 CC 插件:
          \(ccInstallCommand)
        · 阈值、开关、开机自启都能在菜单栏「设置…」里调。
        """
        alert.addButton(withTitle: "知道了")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        store.hasCompletedFirstRun = true
    }
}
