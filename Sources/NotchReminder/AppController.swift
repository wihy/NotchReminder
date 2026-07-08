import Foundation
import ReminderCore

/// 判定「当前是否全屏」的探针。Task 3 默认 { false }(永不全屏), Task 5 Modify 改默认为 DoNotDisturb.isFullscreenActive; 单测可注入假探针。
public typealias FullscreenProbe = () -> Bool

/// 采样调度器 + 提醒落地编排层(CONTRACT §C3 单一 owner)。
/// 每 interval 秒: flushPending → 读 idle → 构造 Sample → ReminderEngine.advance → route。
/// CC 字段(ccActive/ccLastEvent/project)本阶段固定 false/nil/nil, 留 Task 6 接 ~/.notchreminder/cc.json。
@MainActor
public final class AppController {

    /// App 启动时(main.swift)赋值; 供 Task 7 的 MenuBar/SettingsWindow 访问。单测不碰它。
    public static var shared: AppController!

    private let presenter: NotchPresenter
    private var _config: ReminderConfig
    private var _state = ReminderState()
    private let idleProvider: () -> Double
    private let clock: () -> Date
    private let isFullscreen: FullscreenProbe
    private let ccReader = CCSignalReader()
    private var timer: Timer?

    /// 全屏期间被挡下的提醒, 按到达顺序排队, 免打扰结束后补放。
    public private(set) var pending: [Reminder] = []

    /// 强样式 snooze / 菜单「起身了」回调。App 启动时接为 manualRest(见 main.swift)。
    public var onSitSnooze: (() -> Void)?

    public init(
        presenter: NotchPresenter,
        config: ReminderConfig = ReminderConfig(),
        idleProvider: @escaping () -> Double = ActivityMonitor.currentIdleSeconds,
        clock: @escaping () -> Date = { Date() },
        dnd: @escaping FullscreenProbe = DoNotDisturb.isFullscreenActive
    ) {
        self.presenter = presenter
        self._config = config
        self.idleProvider = idleProvider
        self.clock = clock
        self.isFullscreen = dnd
    }

    // MARK: - 只读面(CONTRACT §C3c)

    public var config: ReminderConfig { _config }
    public var state: ReminderState { _state }

    // MARK: - 采样面(CONTRACT §C3a)

    /// 启动采样: 立即跑一次, 之后每 interval 秒一次(默认 10s, spec §5.3)。
    public func start(interval: TimeInterval = 10) {
        timer?.invalidate()
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
    }

    /// 采样一次并推进引擎。先 flushPending(免打扰结束补放), 再采样→advance→route。返回本次 [Reminder] 供测试断言。
    @discardableResult
    public func tick() -> [Reminder] {
        flushPending()
        let cc = ccReader.read()
        let sample = Sample(
            now: clock(),
            idleSeconds: idleProvider(),
            ccActive: cc?.ccActive ?? false,
            ccLastEvent: cc?.lastEvent,
            project: cc?.project
        )
        let (newState, reminders) = ReminderEngine.advance(_state, config: _config, sample: sample)
        _state = newState
        presenter.setPetMood(petMood(state: _state, config: _config, now: sample.now))
        route(reminders)
        return reminders
    }

    // MARK: - 路由面(CONTRACT §C3b)

    /// advance 产出的提醒逐条路由: 全屏 → 记 pending; 否则立即 present。
    public func route(_ reminders: [Reminder]) {
        for r in reminders {
            if isFullscreen() {
                pending.append(r)
            } else {
                show(r)
            }
        }
    }

    /// 免打扰结束后补放 pending。全屏仍在则整体继续挂起(不丢)。
    public func flushPending() {
        guard !pending.isEmpty else { return }
        guard !isFullscreen() else { return }
        let queued = pending
        pending.removeAll()
        for r in queued { show(r) }
    }

    private func show(_ r: Reminder) {
        presenter.present(r) { [weak self] action in
            if action == .snooze { self?.onSitSnooze?() }
        }
    }

    // MARK: - 命令面(CONTRACT §C3c)

    /// 替换配置并立即生效(采样循环下一拍即用新值)。
    public func applyConfig(_ config: ReminderConfig) {
        _config = config
    }

    /// 手动「我起身了」/ 强样式 snooze: 置 sitAccum=0、lastSitAlert=nil(与 onSitSnooze 同一实现)。
    public func manualRest() {
        _state.sitAccum = 0
        _state.lastSitAlert = nil
    }

    /// 专注静音: config.mutedUntil = now+seconds 并生效。
    public func muteFor(_ seconds: TimeInterval) {
        var cfg = _config
        cfg.mutedUntil = clock().addingTimeInterval(seconds)
        applyConfig(cfg)
    }
}
