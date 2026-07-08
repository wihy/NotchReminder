import SwiftUI
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
    private let autoHideSeconds: TimeInterval = 4
    /// 强样式兜底超时(秒): 用户不点按钮也自动收起, 避免强提醒永久占屏、阻塞后续提醒队列。
    private let strongTimeoutSeconds: TimeInterval = 30

    /// 测试钩: present(_:onAction:) 被调用的累计次数(含无头测试环境)。内部可见, 供 @testable 测试断言。
    private(set) var presentCount = 0

    /// 长存 notch: compactLeading=宠物, expanded=提醒卡(PetExpandedView)。启动后建一次。
    private var notch: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>?
    /// 共享宠物状态机(长存 notch 的 compact/expanded 视图 + 灭屏观察 共用同一实例)。
    private let petVM = PetViewModel()
    /// 提醒卡运行时文案/按钮 holder(长存 notch 的 expanded 闭包捕获; 每条提醒 expand 前 set)。
    private let payload = StrongPayload()
    private var powerObserver: ScreenPowerObserver?
    /// petPauseOnBattery: 电池供电时是否让宠物静止(hide)。attachPet 时读一次(v1 不监听运行时电源切换)。
    private var pauseOnBattery: Bool = false

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
    public func attachPet(pauseOnBattery: Bool = false) {
        self.pauseOnBattery = pauseOnBattery
        let vm = petVM
        let payload = self.payload
        let n = DynamicNotch(
            expanded: {
                PetExpandedView(vm: vm, payload: payload)
            },
            compactLeading: {
                PetCompactView(vm: vm)
            }
        )
        notch = n
        powerObserver = ScreenPowerObserver(vm: petVM)
        powerObserver?.start()
        Task { @MainActor [weak self] in await self?.settle() }
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

    /// 展示单条提醒: 写 payload → playAct → expand → 等待结束(强提醒等按钮/兜底超时; 轻样式定时)。
    private func show(_ item: QueuedReminder) async {
        guard let n = notch else { return }
        let r = item.reminder
        let onAction = item.onAction
        petVM.playAct(actFor(r))

        switch r {
        case let .sit(minutes, project):
            await showStrong(
                title: sitTitle(minutes: minutes, project: project),
                subtitle: "起来走两步, 眼睛也歇歇",
                showSnooze: true, onAction: onAction, n: n
            )
        case let .night(clock):
            await showStrong(
                title: "\(clock) 了",
                subtitle: "明天的你会感谢现在睡觉的你",
                showSnooze: false, onAction: onAction, n: n
            )
        case .water:
            await showLight(title: "喝口水", subtitle: "补个水, 顺手站一下", n: n)
        case .eye:
            await showLight(title: "远眺 20 秒", subtitle: "看向 6 米外, 放松睫状肌", n: n)
        }
        petVM.clearAct()
    }

    // MARK: - 强样式(sit / night): 等用户点按钮, 兜底超时自动收起

    /// 强提醒: 写 payload(含按钮动作) → expand → 挂起等待「按钮点击」或「兜底超时」二者先到,
    /// 期间不返回, 从而串行阻塞后续提醒(不会被覆盖)。sit 带 snooze+dismiss, night 仅 dismiss。
    private func showStrong(
        title: String,
        subtitle: String,
        showSnooze: Bool,
        onAction: ((SitAction) -> Void)?,
        n: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>
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
                await n.expand()
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
        n: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>
    ) async {
        payload.set(
            title: title, subtitle: subtitle,
            showSnooze: false, showDismiss: false,
            onSnooze: nil, onDismiss: nil
        )
        await n.expand()
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

    // MARK: - 文案

    private func sitTitle(minutes: Int, project: String?) -> String {
        if let p = project, !p.isEmpty {
            return "连续 \(minutes) 分钟了 · \(p) 项目"
        }
        return "连续 \(minutes) 分钟了"
    }
}
