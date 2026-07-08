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

    /// 测试钩: present(_:onAction:) 被调用的累计次数(含无头测试环境)。内部可见, 供 @testable 测试断言。
    private(set) var presentCount = 0

    /// 长存 notch: compactLeading=宠物, expanded=提醒卡(PetExpandedView)。启动后建一次。
    private var notch: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>?
    /// 共享宠物状态机(长存 notch 的 compact/expanded 视图 + 灭屏观察 共用同一实例)。
    private let petVM = PetViewModel()
    /// 强提醒运行时文案/按钮 holder(长存 notch 的 expanded 闭包捕获; sit/night expand 前 set)。
    private let payload = StrongPayload()
    private var powerObserver: ScreenPowerObserver?

    public init() {}

    // MARK: - 启动接线(由 AppDelegate 调)

    /// 建长存 notch + 注册灭屏观察; 据 petVM.showsPet 决定初始 compact 还是 hide。
    /// pauseOnBattery=true 且当前是电池供电 → hide 而非 compact(v1 启动时读一次, 重启生效)。
    public func attachPet(pauseOnBattery: Bool = false) {
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
        let shouldHideForBattery = pauseOnBattery && isOnBattery
        Task { @MainActor in
            if petVM.showsPet && !shouldHideForBattery {
                await n.compact()
            } else {
                await n.hide()
            }
        }
    }

    /// 当前是否电池供电(非 AC 接入)。读一次, v1 不监听运行时电源切换。
    /// IOKit 读失败或无电源信息时安全降级为 false(不因电源判定隐藏宠物)。
    private var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as Array? else { return false }
        guard let desc = list.first as? [String: Any] else { return false }
        return (desc[kIOPSPowerSourceStateKey] as? String) != kIOPSACPowerValue
    }

    /// Task 5 设置窗调: 开/关宠物。on→compact(宠物可见), off→hide(彻底收起)。
    /// 同时刷 vm.showsPet → 长存 notch 的 compact/expanded 视图(闭包捕获 vm)立即重绘。
    public func setPetEnabled(_ on: Bool) {
        petVM.setShowsPet(on)
        Task { @MainActor in
            guard let n = notch else { return }
            if on { await n.compact() } else { await n.hide() }
        }
    }

    /// AppController 每 tick 推当前宠物心情(由 petMood() 映射引擎状态)。
    public func setPetMood(_ m: PetMood) { petVM.setMood(m) }

    // MARK: - 提醒入口(签名与 v1 一致, AppController 调用点不变)

    public func present(_ r: Reminder, onAction: ((SitAction) -> Void)?) {
        presentCount += 1
        guard let n = notch else { return }
        petVM.playAct(actFor(r))
        switch r {
        case let .sit(minutes, project):
            expandStrong(
                title: sitTitle(minutes: minutes, project: project),
                subtitle: "起来走两步, 眼睛也歇歇",
                showSnooze: true, onAction: onAction, n: n
            )
        case let .night(clock):
            expandStrong(
                title: "\(clock) 了",
                subtitle: "明天的你会感谢现在睡觉的你",
                showSnooze: false, onAction: onAction, n: n
            )
        case .water, .eye:
            // 轻样式: expand → 停留 → clearAct → 回 compact(宠物不消失)。
            // 无按钮 → 不碰 payload(其内容为上次 sit/night 残留, 但轻样式不走 PetExpandedView 的按钮/文案路径,
            // 因 expand 显示的是同一 PetExpandedView, 故这里也清一下 payload 以免显示旧文案)。
            payload.set(title: "", subtitle: "", showSnooze: false, onSnooze: {}, onDismiss: {})
            Task { @MainActor in
                await n.expand()
                try? await Task.sleep(for: .seconds(autoHideSeconds))
                petVM.clearAct()
                if petVM.showsPet { await n.compact() } else { await n.hide() }
            }
        }
    }

    // MARK: - 强样式(sit / night)

    /// 强提醒: 先把本次 title/subtitle/按钮动作塞进 payload(长存 notch 的 expanded 视图捕获该 payload),
    /// @Published 变化触发重绘, 再 await expand() 显示。按钮点击经 payload.onSnooze/onDismiss 回调,
    /// 回调内推进 onAction + afterStrong(清演出 + 回 compact)。
    private func expandStrong(
        title: String,
        subtitle: String,
        showSnooze: Bool,
        onAction: ((SitAction) -> Void)?,
        n: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>
    ) {
        payload.set(
            title: title,
            subtitle: subtitle,
            showSnooze: showSnooze,
            onSnooze: { onAction?(.snooze); self.afterStrong(n: n) },
            onDismiss: { onAction?(.dismiss); self.afterStrong(n: n) }
        )
        Task { @MainActor in await n.expand() }
    }

    /// 强提醒按钮点击后: 清演出 + 回 compact(或 petVM.showsPet=false 时 hide)。
    private func afterStrong(n: DynamicNotch<PetExpandedView, PetCompactView, EmptyView>) {
        petVM.clearAct()
        Task { @MainActor in
            if petVM.showsPet { await n.compact() } else { await n.hide() }
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
