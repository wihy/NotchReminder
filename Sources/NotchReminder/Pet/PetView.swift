import SwiftUI
import ReminderCore

// MARK: - 团子主体 Shape

/// 手绘团子: 一个带轻微变形的圆(用 Path 近似 squircle), 颜色按心情。
/// 视觉为 v1 草图, 可后续精修; 关键是 mood/act/isPetting 参数化能驱动姿态。
struct BlobShape: Shape {
    var squash: CGFloat  // 1.0=正圆, <1 压扁(累), >1 拉长(精神/伸懒腰)
    func path(in rect: CGRect) -> Path {
        let w = rect.width * squash
        let h = rect.height / squash
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
    /// 眼开合度(0=闭眼, 1=全开)。
    private var eyeOpen: CGFloat {
        if !isAwake { return 0 }                           // 睡着闭眼
        if mood == .sleepy { return 0.35 }                 // 半眯
        if mood == .tired || mood == .exhausted { return 0.6 }
        return 1
    }

    var body: some View {
        ZStack {
            BlobShape(squash: squash)
                .fill(color)
                .frame(width: size, height: size)
            // 两眼
            HStack(spacing: size * 0.18) {
                eye(open: eyeOpen)
                eye(open: eyeOpen)
            }
            .offset(y: -size * 0.08)
            // 嘴/装饰
            if act == .yawn || mood == .sleepy {
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
        .frame(width: size*1.4, height: size*1.4)
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
    var showsPet: Bool

    // 呼吸: 缓慢 scale autoreverse(~3.5s)。只在 awake 时动。
    @State private var breathe = false

    var body: some View {
        Group {
            if showsPet {
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

/// 提醒卡: 大团子(演出) + 文案 + [sit/night 带按钮]。取代旧 StrongReminderView。
/// 文案/按钮由外部 presenter 经 onSnooze/onDismiss 传入(与旧 StrongReminderView 同契约)。
struct PetExpandedView: View {
    @ObservedObject var vm: PetViewModel
    var showsPet: Bool
    let title: String
    let subtitle: String
    let showSnooze: Bool              // sit=true / night=false / water,eye 不会进 expanded 走带按钮路径
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if showsPet {
                PetBlob(mood: vm.mood, act: vm.act, isAwake: vm.isAwake, isPetting: false, size: 46)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.headline).foregroundStyle(.primary)
                Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if showSnooze {
                        Button(action: onSnooze) { Text(verbatim: "起身5分钟") }.buttonStyle(.borderedProminent)
                    }
                    Button(action: onDismiss) { Text(verbatim: "知道了") }.buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 360)
    }
}
