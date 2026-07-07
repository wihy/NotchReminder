import Foundation

/// 生成并管理 ~/Library/LaunchAgents/com.notchreminder.agent.plist,
/// 用现代 launchctl bootstrap/bootout(gui/UID 图形域)装/卸开机自启。
///
/// 路线: 裸 SPM 二进制 + LaunchAgent(非 SMAppService)。菜单栏 App 必须用
/// LaunchAgent(跑在登录用户 Aqua 图形会话, 才能画状态栏图标), 不能用 LaunchDaemon。
enum LaunchAgent {

    static let label = "com.notchreminder.agent"

    /// plist 落地路径: ~/Library/LaunchAgents/com.notchreminder.agent.plist
    static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 当前登录用户的图形域, e.g. "gui/501"。
    private static var guiDomain: String { "gui/\(getuid())" }

    /// 当前运行的可执行绝对路径(自启应指向"当前这个二进制")。回落到 release 产物路径。
    static var currentExecPath: String {
        Bundle.main.executablePath
            ?? "/Users/chunhaixu/NotchReminder/.build/release/NotchReminder"
    }

    /// 是否已装: plist 文件存在 且 launchctl print 命中该 label。
    static var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: plistPath) else { return false }
        let rc = runLaunchctl(["print", "\(guiDomain)/\(label)"]).status
        return rc == 0
    }

    /// 生成 plist 文本(execPath 为可执行绝对路径)。
    static func plistContents(execPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(execPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>Crashed</key>
                <true/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
        </dict>
        </plist>
        """
    }

    /// 写 plist 并 bootstrap 到图形域。成功返回 true。
    @discardableResult
    static func enable() -> Bool {
        let dir = (plistPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try plistContents(execPath: currentExecPath)
                .write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[LaunchAgent] write plist failed: \(error)")
            return false
        }
        // 已加载则先 bootout, 避免 "service already bootstrapped" 报错。
        _ = runLaunchctl(["bootout", guiDomain, plistPath])
        let r = runLaunchctl(["bootstrap", guiDomain, plistPath])
        if r.status != 0 {
            NSLog("[LaunchAgent] bootstrap failed rc=\(r.status): \(r.output)")
        }
        return r.status == 0
    }

    /// bootout 并删 plist。成功(或本就未装)返回 true。
    @discardableResult
    static func disable() -> Bool {
        _ = runLaunchctl(["bootout", guiDomain, plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        return !FileManager.default.fileExists(atPath: plistPath)
    }

    // MARK: - launchctl runner

    private static func runLaunchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "\(error)")
        }
    }
}
