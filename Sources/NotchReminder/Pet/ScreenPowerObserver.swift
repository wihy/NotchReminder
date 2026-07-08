import AppKit

/// 监听系统灭屏/唤醒, 推动 PetViewModel.sleep()/wake()(spec §3.5 耗电控制)。
/// 用 NSWorkspace 共享通知中心: screensDidSleep/Wake 覆盖「屏不亮」场景。
final class ScreenPowerObserver {
    private let vm: PetViewModel
    private var tokens: [NSObjectProtocol] = []

    init(vm: PetViewModel) { self.vm = vm }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                     object: nil, queue: .main) { [weak vm] _ in
            MainActor.assumeIsolated { vm?.sleep() }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                     object: nil, queue: .main) { [weak vm] _ in
            MainActor.assumeIsolated { vm?.wake() }
        })
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
    }
}
