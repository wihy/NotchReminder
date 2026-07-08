import SwiftUI
import ReminderCore

// MARK: - 团子主体 Shape

/// 手绘团子: 一个带轻微变形的圆(用 Path 近似 squircle), 颜色按心情。
/// 视觉为 v1 草图, 可后续精修; 关键是 mood/act/isPetting 参数化能驱动姿态。
///
/// squash 语义(修正前公式方向反了, 导致累时变竖蛋而非压扁):
/// - <1 压扁(累/塌一摊): 更宽更矮
/// - =1 正圆
/// - >1 拉长(精神/伸懒腰): 更窄更高
struct BlobShape: Shape {
    var squash: CGFloat
    func path(in rect: CGRect) -> Path {
        let w = rect.width / squash   // squash<1 → 更宽(压扁)
        let h = rect.height * squash  // squash<1 → 更矮(压扁)
        let r = CGRect(x: rect.midX - w/2, y: rect.midY - h/2, width: w, height: h)
        return Path(ellipseIn: r)
    }
}

// MARK: - 单只团子(共享姿态逻辑)

/// 按 mood/act/isPetting 选颜色 + squash + 眼/嘴装饰。compact 与 expanded 复用。
struct PetBlob: View {
    let mood: PetMood
    let act: PetAct?
    let isAwake: Bool
    let isPetting: Bool
    var size: CGFloat = 40

    private var color: Color {
        switch mood {
        case .fresh:     return Color(red: 0.55, green: 0.85, blue: 0.95)
        case .calm:      return Color(red: 0.60, green: 0.80, blue: 0.90)
        case .tired:     return Color(red: 0.70, green: 0.75, blue: 0.85)
        case .exhausted: return Color(red: 0.78, green: 0.72, blue: 0.82)
        case .sleepy:    return Color(red: 0.66, green: 0.62, blue: 0.82)
        case .dozing:    return Color(red: 0.72, green: 0.70, blue: 0.80)
        }
    }
    private var squash: CGFloat {
        if isPetting { return 1.12 }                       // rua: 弹起
        if act == .stretch { return 1.15 }                 // 伸懒腰: 拉长
        switch mood {
        case .exhausted: return 0.72                       // 塌一摊
        case .tired:     return 0.85
        case .fresh:     return 1.05
        default:         return 0.95
        }
    }
    /// 眼开合度基线(0=闭眼, 1=全开)。动效层的眨眼会在此基线上瞬时压低。
    private var eyeOpenBase: CGFloat {
        if !isAwake { return 0 }                           // 睡着闭眼
        if mood == .sleepy { return 0.35 }                 // 半眯
        if mood == .tired || mood == .exhausted { return 0.6 }
        return 1
    }

    // MARK: - 动效状态(全部本地 @State, 由 mood/act/isAwake 触发, 不改状态机)

    /// 眨眼: 清醒且无 act 时周期性瞬闭。true=正在眨(闭眼一瞬)。
    @State private var blinking = false
    /// 动作脉冲相位: drink 点头 / stretch 拉伸 幅度在 0↔1 间往复。
    @State private var actPhase: CGFloat = 0
    /// 远眺时眼球横向偏移(lookAway): -1↔1 往复。
    @State private var gaze: CGFloat = 0
    /// 打哈欠/喝水的轻微左右摇晃角度驱动: -1↔1。
    @State private var sway: CGFloat = 0

    /// 眨眼定时: 清醒无 act 时每 ~3s 触发一次瞬闭。
    private let blinkTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    private var eyeOpen: CGFloat {
        if blinking && isAwake && act == nil { return 0.05 }  // 眨眼瞬闭
        return eyeOpenBase
    }

    /// 动作叠加的纵向缩放(drink 点头下沉 / stretch 向上拉伸)。
    private var actScaleY: CGFloat {
        switch act {
        case .drink:   return 1 - actPhase * 0.12   // 咕咚: 微微下压
        case .stretch: return 1 + actPhase * 0.18   // 伸懒腰: 纵向拉长脉冲
        default:       return 1
        }
    }
    /// 动作叠加的旋转角(yawn/drink 轻晃)。
    private var swayAngle: Angle {
        guard act == .yawn || act == .drink else { return .zero }
        return .degrees(Double(sway) * 4)
    }

    var body: some View {
        ZStack {
            BlobShape(squash: squash)
                .fill(color)
                .frame(width: size, height: size)
            // 两眼(远眺时随 gaze 横移)
            HStack(spacing: size * 0.18) {
                eye(open: eyeOpen)
                eye(open: eyeOpen)
            }
            .offset(x: gaze * size * 0.10, y: -size * 0.08)
            // 嘴: 打哈欠时随 actPhase 张大, sleepy 小圆点
            if act == .yawn {
                Ellipse().fill(Color.black.opacity(0.55))
                    .frame(width: size*0.14, height: size*0.10 + actPhase*size*0.18)
                    .offset(y: size * 0.12)
            } else if mood == .sleepy {
                Circle().fill(Color.black.opacity(0.55)).frame(width: size*0.10, height: size*0.10)
                    .offset(y: size * 0.12)
            }
            if mood == .exhausted {
                Text(verbatim: "💦").font(.system(size: size*0.28)).offset(x: size*0.32, y: -size*0.28)
            }
            if !isAwake || mood == .dozing {
                Text(verbatim: "z").font(.system(size: size*0.30, weight: .bold))
                    .offset(x: size*0.30, y: -size*0.34)
            }
        }
        .scaleEffect(x: 1, y: actScaleY, anchor: .bottom)
        .rotationEffect(swayAngle)
        .frame(width: size*1.4, height: size*1.4)
        .onReceive(blinkTimer) { _ in
            guard isAwake, act == nil else { return }
            withAnimation(.easeInOut(duration: 0.09)) { blinking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.easeInOut(duration: 0.12)) { blinking = false }
            }
        }
        .onChange(of: act) { _, newAct in startActAnimation(newAct) }
        .onAppear { startActAnimation(act) }
    }

    /// 按当前 act 启动对应的重复动画; act=nil 时复位。
    private func startActAnimation(_ a: PetAct?) {
        // 复位到基线, 再据动作起循环。
        actPhase = 0; gaze = -1; sway = -1
        switch a {
        case .drink:
            // 咕咚点头 + 轻晃, 快节奏往复。
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { actPhase = 1 }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { sway = 1 }
        case .lookAway:
            // 远眺: 眼球缓慢左右扫(-1↔1 居中对称)。
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { gaze = 1 }
        case .stretch:
            // 伸懒腰: 慢速纵向拉伸脉冲。
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { actPhase = 1 }
        case .yawn:
            // 打哈欠: 嘴缓慢张大 + 身体轻晃。
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { actPhase = 1 }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { sway = 1 }
        case .none:
            break
        }
    }

    private func eye(open: CGFloat) -> some View {
        Capsule().fill(Color.black.opacity(0.8))
            .frame(width: size*0.07, height: size*0.12 * max(0.05, open))
    }
}

// MARK: - compact(刘海旁)

/// 刘海旁的小团子。绑 vm, 平时呼吸 + 偶尔眨眼(由 act/isPetting 覆盖)。showsPet=false → EmptyView。
struct PetCompactView: View {
    @ObservedObject var vm: PetViewModel

    // 呼吸: 缓慢 scale autoreverse(~3.5s)。只在 awake 时动。
    @State private var breathe = false

    var body: some View {
        Group {
            if vm.showsPet {
                PetBlob(mood: vm.mood, act: vm.act, isAwake: vm.isAwake, isPetting: vm.isPetting, size: 22)
                    .scaleEffect(vm.isAwake && vm.act == nil ? (breathe ? 1.05 : 0.95) : 1)
                    .animation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true), value: breathe)
                    .onAppear {
                        if vm.isAwake { breathe.toggle() }
                    }
                    .onChange(of: vm.isAwake) { _, awake in if awake { breathe.toggle() } }
            } else {
                EmptyView()
            }
        }
    }
}

// MARK: - expanded(提醒卡)

/// 提醒卡运行时内容 holder。长存 notch 的 expanded 视图在 attachPet 时建一次,
/// 其后每条提醒的文案/按钮是运行时来的, 故由 presenter 先 payload.set(...) 再
/// await notch.expand(); 视图 @ObservedObject payload → set 触发重绘显示最新内容。
///
/// 四种提醒统一走此卡, 由 showSnooze/showDismiss 显式控制按钮:
/// - sit:   showSnooze=true,  showDismiss=true  (起身5分钟 + 知道了)
/// - night: showSnooze=false, showDismiss=true  (知道了)
/// - water/eye(轻样式): showSnooze=false, showDismiss=false (无按钮, auto-hide)
@MainActor
final class StrongPayload: ObservableObject {
    @Published var title: String = ""
    @Published var subtitle: String = ""
    @Published var showSnooze: Bool = false
    @Published var showDismiss: Bool = false
    var onSnooze: (() -> Void)?
    var onDismiss: (() -> Void)?

    func set(title: String, subtitle: String, showSnooze: Bool, showDismiss: Bool,
             onSnooze: (() -> Void)?, onDismiss: (() -> Void)?) {
        self.title = title
        self.subtitle = subtitle
        self.showSnooze = showSnooze
        self.showDismiss = showDismiss
        self.onSnooze = onSnooze
        self.onDismiss = onDismiss
    }
}

/// 提醒卡: 大团子(演出) + 文案 + [按钮显式控制]。取代旧 StrongReminderView。
/// 文案/按钮经 payload(StrongPayload) 注入: 长存 notch 的 expanded 闭包捕获 payload,
/// presenter 在 expand 前 payload.set(...), @Published 变化触发视图重绘。
/// 按钮由 payload.showSnooze/showDismiss 分别控制——轻样式(water/eye)两者皆 false 时无按钮区。
struct PetExpandedView: View {
    @ObservedObject var vm: PetViewModel
    @ObservedObject var payload: StrongPayload

    var body: some View {
        HStack(spacing: 14) {
            if vm.showsPet {
                PetBlob(mood: vm.mood, act: vm.act, isAwake: vm.isAwake, isPetting: false, size: 46)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: payload.title).font(.headline).foregroundStyle(.primary)
                Text(verbatim: payload.subtitle).font(.subheadline).foregroundStyle(.secondary)
                if payload.showSnooze || payload.showDismiss {
                    HStack(spacing: 10) {
                        if payload.showSnooze {
                            Button(action: { payload.onSnooze?() }) { Text(verbatim: "起身5分钟") }.buttonStyle(.borderedProminent)
                        }
                        if payload.showDismiss {
                            Button(action: { payload.onDismiss?() }) { Text(verbatim: "知道了") }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 360)
    }
}
