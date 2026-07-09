import SwiftUI
import AppKit
import DynamicNotchKit
import ReminderCore
import IOKit.ps

/// 强样式浮层上「起身5分钟」/「知道了」两个按钮对应的动作(CONTRACT §C2)。
public enum SitAction: Equatable {
    case snooze   // 起身5分钟: 记真休息意图(由 AppController 清 sit 计时)
    case dismiss  // 知道了: 仅收起
}

/// 封装 DynamicNotchKit 的渲染。Task 4: 从「每条提醒新建临时 notch」重构为
/// **单一长存 DynamicNotch**——compactLeading = 宠物团子(平时呼吸), expanded = 提醒卡(PetExpandedView)。
/// 启动后 attachPet() 建一次 notch + 注冊灭屏观察; 平时 compact, 提醒 expand, 演完回 compact(不消失)。
/// petVM.showsPet=false 时用 hide(而非 compact)降级(宠物不可见)。整类 @MainActor。
@MainActor
public final class NotchPresenter {
    /// 轻样式停留时长(秒)。expand() 自身另含 ~0.4s 动画等待, 此为额外停留。
    /// 设计稿:接管为可配置(cardDwellSeconds), 默认 4 = 现状。
    private var autoHideSeconds: TimeInterval = 4
    /// 强样式兜底超时(秒): 用户不点按钮也自动收起, 避免强提醒永久占屏、阻塞后续提醒队列。
    private let strongTimeoutSeconds: TimeInterval = 30

    /// 提醒引擎配置(每类样式 + 文案模板来源)。AppController 在 applyConfig 时下发。
    private var cfg = ReminderConfig()
    /// 提示音总开关 + 每类音名(NSSound 系统音)。
    private var soundEnabled = true
    private var sitSound = "Ping"
    private var waterSound = "Ping"
    private var eyeSound = "Ping"
    private var nightSound = "Ping"
    /// 呼吸灯边框(设计稿;overlay 实现留二期, 此处持有开关供后续接线)。
    private var breathingLight = false

    /// 测试钩: present(_:onAction:) 被调用的累计次数(含无头测试环境)。内部可见, 供 @testable 测试断言。
    private(set) var presentCount = 0

    /// 长存 notch: compactLeading/compactTrailing=宠物(按 side 只渲染一侧), expanded=提醒卡。启动后建一次。
    private var notch: DynamicNotch<PetExpandedView, PetCompactView, PetCompactView>?
    /// 共享宠物状态机(长存 notch 的 compact/expanded 视图 + 灭屏观察 共用同一实例)。
    private let petVM = PetViewModel()
    /// 提醒卡运行时文案/按钮 holder(长存 notch 的 expanded 闭包捕获; 每条提醒 expand 前 set)。
    private let payload = StrongPayload()
    private var powerObserver: ScreenPowerObserver?
    /// 呼吸灯边框(提醒展示期间在屏幕四周叠脉动柔光)。仅 breathingLight 开启时用。
    private let breathingBorder = BreathingBorderController()
    /// 卡片位置: "notch"(展开刘海) | "topRight"(右上角浮层)。
    private var cardPosition = "notch"
    /// 右上角提醒卡浮层(topRight 模式下用; attachPet 时建, 复用 petVM/payload)。
    private var topRightCard: TopRightCardController?
    /// petPauseOnBattery: 电池供电时是否让宠物静止(hide)。attachPet 时读一次(v1 不监听运行时电源切换)。
    private var pauseOnBattery: Bool = false
    /// 点击刘海团子的回调(main 接为打开设置窗)。compact 视图捕获它。
    public var onPetTap: (() -> Void)?

    // MARK: - 串行提醒队列(C1 修复)
    //
    // 背景: ReminderEngine.advance 单次可返回多条提醒(如 [.water, .eye] 或 [.sit, .water]),
    // AppController.route 对每条同步调用 present。若每条各起 Task 直接操作同一长存 notch + 同一 payload,
    // 会互相覆盖文案/回调、竞态 expand/compact。故改为: present 只入队, 由单个串行 drain 循环
    // 逐条完整播完(expand → 等待本条结束 → 回 compact)再取下一条。water/eye 一旦被引擎产出即清零不重发,
    // 所以每条必须完整、正确地展示, 不能被后来者清空。

    /// 一条待展示的提醒(携带完整运行时内容; 与引擎解耦, presenter 只负责演出)。
    private struct QueuedReminder {
        let reminder: Reminder
        let onAction: ((SitAction) -> Void)?
    }
    private var queue: [QueuedReminder] = []
    private var draining = false

    public init() {}

    // MARK: - 启动接线(由 AppDelegate 调)

    /// 建长存 notch + 注册灭屏观察; 据 petVM.showsPet 决定初始 compact 还是 hide。
    /// pauseOnBattery=true 且当前是电池供电 → hide 而非 compact(v1 启动时读一次, 重启生效)。
    ///
    /// 设计稿参数化: 接收提醒配置(样式/文案模板) + 卡片停留/呼吸灯/提示音 + 宠物外观。
    /// 全部带默认值 = 现状, 保证既有无参调用不回归。cardPosition 决定 notch 样式(重启生效)。
    public func attachPet(
        pauseOnBattery: Bool = false,
        config: ReminderConfig = ReminderConfig(),
        cardDwellSeconds: TimeInterval = 4,
        breathingLight: Bool = false,
        soundEnabled: Bool = true,
        sitSound: String = "Ping",
        waterSound: String = "Ping",
        eyeSound: String = "Ping",
        nightSound: String = "Ping",
        cardPosition: String = "notch",
        petCharacter: String = "blob",
        petColorTheme: String = "sky",
        petSizeScale: CGFloat = 1.0,
        petSide: String = "left",
        petAnimationIntensity: CGFloat = 0.6
    ) {
        self.pauseOnBattery = pauseOnBattery
        self.cfg = config
        self.autoHideSeconds = cardDwellSeconds
        self.breathingLight = breathingLight
        self.soundEnabled = soundEnabled
        self.sitSound = sitSound
        self.waterSound = waterSound
        self.eyeSound = eyeSound
        self.nightSound = nightSound
        petVM.setAppearance(character: petCharacter, colorTheme: petColorTheme,
                            sizeScale: petSizeScale, side: petSide,
                            animationIntensity: petAnimationIntensity)
        self.cardPosition = cardPosition
        let vm = petVM
        let payload = self.payload
        // 刘海始终常驻宠物(compact); topRight 模式下提醒卡改走右上角浮层, 不展开刘海。
        let n = DynamicNotch(
            expanded: {
                PetExpandedView(vm: vm, payload: payload)
            },
            compactLeading: {
                PetCompactView(vm: vm, slot: "left", onTap: { [weak self] in self?.onPetTap?() })
            },
            compactTrailing: {
                PetCompactView(vm: vm, slot: "right", onTap: { [weak self] in self?.onPetTap?() })
            }
        )
        notch = n
        topRightCard = TopRightCardController(vm: petVM, payload: payload)
        powerObserver = ScreenPowerObserver(vm: petVM)
        powerObserver?.start()
        Task { @MainActor [weak self] in await self?.settle() }
    }

    // MARK: - 设置窗实时下发(AppController 转发)

    /// 下发提醒配置(每类样式 + 文案模板)。applyConfig 时调, 下一条提醒即用新值。
    public func applyReminderConfig(_ config: ReminderConfig) { cfg = config }

    /// 下发提醒方式 pref(停留时长 / 呼吸灯 / 提示音总开关 + 每类音名)。
    public func applyDisplayPrefs(cardDwellSeconds: TimeInterval, breathingLight: Bool,
                                  soundEnabled: Bool, sitSound: String, waterSound: String,
                                  eyeSound: String, nightSound: String, cardPosition: String) {
        self.autoHideSeconds = cardDwellSeconds
        self.breathingLight = breathingLight
        self.soundEnabled = soundEnabled
        self.sitSound = sitSound
        self.waterSound = waterSound
        self.eyeSound = eyeSound
        self.nightSound = nightSound
        self.cardPosition = cardPosition
    }

    /// 下发宠物外观(转发给 petVM, compact/expanded 立即重绘)。
    public func applyPetAppearance(character: String, colorTheme: String,
                                   sizeScale: CGFloat, side: String, animationIntensity: CGFloat) {
        petVM.setAppearance(character: character, colorTheme: colorTheme,
                            sizeScale: sizeScale, side: side, animationIntensity: animationIntensity)
    }

    /// 当前是否电池供电(非 AC 接入)。读一次, v1 不监听运行时电源切换。
    /// IOKit 读失败或无电源信息时安全降级为 false(不因电源判定隐藏宠物)。
    private var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as Array? else { return false }
        guard let desc = list.first as? [String: Any] else { return false }
        return (desc[kIOPSPowerSourceStateKey] as? String) != kIOPSACPowerValue
    }

    /// Task 5 设置窗调: 开/关宠物。on→回到静止态(compact 或据电池 hide), off→hide(彻底收起)。
    /// 同时刷 vm.showsPet → 长存 notch 的 compact/expanded 视图(闭包捕获 vm)立即重绘。
    /// 注(I1 修复): on 分支不再无条件 compact, 而是走 settle()——否则会覆盖 pauseOnBattery 的 hide。
    public func setPetEnabled(_ on: Bool) {
        petVM.setShowsPet(on)
        Task { @MainActor [weak self] in
            guard let self, self.notch != nil else { return }
            if on { await self.settle() } else { await self.notch?.hide() }
        }
    }

    /// AppController 每 tick 推当前宠物心情(由 petMood() 映射引擎状态)。
    public func setPetMood(_ m: PetMood) { petVM.setMood(m) }

    // MARK: - 提醒入口(签名与 v1 一致, AppController 调用点不变)

    /// 入队并触发串行 drain。同一 tick 内 route 会连续同步调用多次 present(每条提醒一次),
    /// 全部入队后由单个 drain 循环逐条完整播完, 互不覆盖(C1 修复)。
    /// presentCount 在 guard 之前自增, 保留无头测试(notch=nil)下的钩子语义。
    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
        presentCount += 1
        guard notch != nil else { return }
        queue.append(QueuedReminder(reminder: r, onAction: onAction))
        guard !draining else { return }
        draining = true
        Task { @MainActor [weak self] in await self?.drain() }
    }

    // MARK: - 串行 drain

    /// 逐条取出队列提醒, 完整播完一条(expand → 等本条结束 → 回静止)再取下一条。
    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            await show(item)
        }
        draining = false
        await settle()
    }

    /// 展示单条提醒: 写 payload → playAct → 按 config 的每类 style 决定强/轻 → expand → 等待结束。
    /// 样式不再按提醒类型写死, 而是读 cfg.{sit,water,eye,night}Style; 文案走模板(nil 用内置默认)。
    private func show(_ item: QueuedReminder) async {
        guard let n = notch else { return }
        let r = item.reminder
        let onAction = item.onAction
        petVM.playAct(actFor(r))
        playSound(for: r)

        // 呼吸灯: 本条提醒展示期间点亮四周柔光, 演完收起(开关在展示前捕获)。
        let glowing = breathingLight
        if glowing { breathingBorder.show() }

        let c = contentFor(r)
        if c.style == .strong {
            await showStrong(title: c.title, subtitle: c.subtitle,
                             showSnooze: c.showSnooze, onAction: onAction, n: n)
        } else {
            await showLight(title: c.title, subtitle: c.subtitle, n: n)
        }

        if glowing { breathingBorder.hide() }
        if cardPosition == "topRight" { topRightCard?.hide() }
        petVM.clearAct()
    }

    /// 展开提醒卡面: topRight → 右上角浮层; 否则展开刘海。
    private func expandCard(_ n: DynamicNotch<PetExpandedView, PetCompactView, PetCompactView>) async {
        if cardPosition == "topRight" {
            topRightCard?.show()
        } else {
            await n.expand()
        }
    }

    /// 组装单条提醒的运行时内容: 样式取 cfg 的每类 style; 文案取模板(nil 用内置默认)。
    /// strong 时仅 sit 显示 snooze(+dismiss), 其余仅 dismiss(showSnooze=false)。
    private func contentFor(_ r: Reminder) -> (title: String, subtitle: String, style: ReminderStyle, showSnooze: Bool) {
        let curClock = ReminderEngine.clockString(Date())
        switch r {
        case let .sit(minutes, project):
            let title = cfg.sitTitleTemplate.map { render($0, minutes: minutes, project: project, clock: curClock) }
                ?? defaultSitTitle(minutes: minutes, project: project)
            let subtitle = cfg.sitSubtitleTemplate.map { render($0, minutes: minutes, project: project, clock: curClock) }
                ?? "起来走两步, 眼睛也歇歇"
            return (title, subtitle, cfg.sitStyle, true)
        case let .night(clock):
            let title = cfg.nightTitleTemplate.map { render($0, minutes: nil, project: nil, clock: clock) }
                ?? "\(clock) 了"
            let subtitle = cfg.nightSubtitleTemplate.map { render($0, minutes: nil, project: nil, clock: clock) }
                ?? "明天的你会感谢现在睡觉的你"
            return (title, subtitle, cfg.nightStyle, false)
        case .water:
            let title = cfg.waterTitleTemplate.map { render($0, minutes: nil, project: nil, clock: curClock) }
                ?? "喝口水"
            let subtitle = cfg.waterSubtitleTemplate.map { render($0, minutes: nil, project: nil, clock: curClock) }
                ?? "补个水, 顺手站一下"
            return (title, subtitle, cfg.waterStyle, false)
        case .eye:
            let title = cfg.eyeTitleTemplate.map { render($0, minutes: nil, project: nil, clock: curClock) }
                ?? "远眺 20 秒"
            let subtitle = cfg.eyeSubtitleTemplate.map { render($0, minutes: nil, project: nil, clock: curClock) }
                ?? "看向 6 米外, 放松睫状肌"
            return (title, subtitle, cfg.eyeStyle, false)
        }
    }

    /// 模板占位替换: 支持中英双写 {minutes}/{分钟}、{project}/{项目}、{clock}/{时钟}。
    private func render(_ template: String, minutes: Int?, project: String?, clock: String?) -> String {
        var s = template
        let m = minutes.map(String.init) ?? ""
        s = s.replacingOccurrences(of: "{minutes}", with: m).replacingOccurrences(of: "{分钟}", with: m)
        let p = project ?? ""
        s = s.replacingOccurrences(of: "{project}", with: p).replacingOccurrences(of: "{项目}", with: p)
        let c = clock ?? ""
        s = s.replacingOccurrences(of: "{clock}", with: c).replacingOccurrences(of: "{时钟}", with: c)
        return s
    }

    /// 提示音: 总开关开启时按该类音名播放一次(NSSound 找不到该音名则静默降级)。
    private func playSound(for r: Reminder) {
        guard soundEnabled else { return }
        let name: String
        switch r {
        case .sit:   name = sitSound
        case .water: name = waterSound
        case .eye:   name = eyeSound
        case .night: name = nightSound
        }
        NSSound(named: name)?.play()
    }

    // MARK: - 强样式(sit / night): 等用户点按钮, 兜底超时自动收起

    /// 强提醒: 写 payload(含按钮动作) → expand → 挂起等待「按钮点击」或「兜底超时」二者先到,
    /// 期间不返回, 从而串行阻塞后续提醒(不会被覆盖)。sit 带 snooze+dismiss, night 仅 dismiss。
    private func showStrong(
        title: String,
        subtitle: String,
        showSnooze: Bool,
        onAction: ((SitAction) -> Void)?,
        n: DynamicNotch<PetExpandedView, PetCompactView, PetCompactView>
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // resumeOnce: 按钮点击与兜底超时可能都触发, 只放行一次。
            // resumeOnce 守卫: 按钮点击与兜底超时可能都触发, 只放行一次(不捕获 self, 无环)。
            var finished = false
            let finish: (SitAction?) -> Void = { action in
                guard !finished else { return }
                finished = true
                if let action { onAction?(action) }
                cont.resume()
            }
            payload.set(
                title: title,
                subtitle: subtitle,
                showSnooze: showSnooze,
                showDismiss: true,
                onSnooze: { finish(.snooze) },
                onDismiss: { finish(.dismiss) }
            )
            Task { @MainActor in
                await self.expandCard(n)
                // 兜底: 用户长时间不点也自动收起, 避免强提醒永久占屏、阻塞队列。
                try? await Task.sleep(for: .seconds(strongTimeoutSeconds))
                finish(nil)
            }
        }
    }

    // MARK: - 轻样式(water / eye): 展示正文, 无按钮, 停留后自动收起

    private func showLight(
        title: String,
        subtitle: String,
        n: DynamicNotch<PetExpandedView, PetCompactView, PetCompactView>
    ) async {
        payload.set(
            title: title, subtitle: subtitle,
            showSnooze: false, showDismiss: false,
            onSnooze: nil, onDismiss: nil
        )
        await expandCard(n)
        try? await Task.sleep(for: .seconds(autoHideSeconds))
    }

    // MARK: - 静止态

    /// 回到「无提醒」的静止态: 宠物开且非电池静止 → compact; 否则 hide。
    /// drain 结束、attachPet、setPetEnabled(on) 均汇聚到此, 统一决策(I1 修复的单一入口)。
    private func settle() async {
        guard let n = notch else { return }
        let hideForBattery = pauseOnBattery && isOnBattery
        if petVM.showsPet && !hideForBattery {
            await n.compact()
        } else {
            await n.hide()
        }
    }

    // MARK: - 文案(内置默认, 模板为 nil 时用)

    private func defaultSitTitle(minutes: Int, project: String?) -> String {
        if let p = project, !p.isEmpty {
            return "连续 \(minutes) 分钟了 · \(p) 项目"
        }
        return "连续 \(minutes) 分钟了"
    }
}
