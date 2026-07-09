import SwiftUI
import AppKit
import ReminderCore

// MARK: - 设计稿 tokens(配色 / 圆角), 对照 NotchReminder-Design v2.0

private extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private enum DS {
    // 提醒类别色(设计稿 Palette)
    static let sit = Color(hex: 0xF2A65A)
    static let water = Color(hex: 0x4FB4E6)
    static let eye = Color(hex: 0x5FBE86)
    static let night = Color(hex: 0x7C74D6)
    // 圆角刻度
    static let control: CGFloat = 8
    static let card: CGFloat = 14
}

/// 六面板导航项。左侧栏 icon + 文案(SF Symbols, 不用 emoji)。
private enum Panel: String, CaseIterable, Identifiable {
    case scenario, reminders, style, pet, dnd, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .scenario: return "情景模式"
        case .reminders: return "提醒项"
        case .style: return "提醒方式"
        case .pet: return "宠物"
        case .dnd: return "免打扰"
        case .general: return "通用"
        }
    }
    var systemImage: String {
        switch self {
        case .scenario: return "target"
        case .reminders: return "bell"
        case .style: return "speaker.wave.2"
        case .pet: return "pawprint"
        case .dnd: return "moon"
        case .general: return "gearshape"
        }
    }
}

/// 提醒项四类(手风琴 identity + 类别色/图标)。
private enum ReminderKind: String, Identifiable {
    case sit, water, eye, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sit: return "久坐起身"
        case .water: return "喝水"
        case .eye: return "护眼远眺"
        case .night: return "熬夜劝退"
        }
    }
    var subtitle: String {
        switch self {
        case .sit: return "连续活跃达阈值即提醒"
        case .water: return "累计工作时长到点补水"
        case .eye: return "用眼过久提醒远眺"
        case .night: return "深夜仍活跃时劝退"
        }
    }
    var icon: String {
        switch self {
        case .sit: return "figure.walk"
        case .water: return "drop.fill"
        case .eye: return "eye.fill"
        case .night: return "moon.stars.fill"
        }
    }
    var color: Color {
        switch self {
        case .sit: return DS.sit
        case .water: return DS.water
        case .eye: return DS.eye
        case .night: return DS.night
        }
    }
}

/// 设计稿六面板设置窗:左侧栏导航 + 右侧细配。所有图标用 SF Symbols; 全部语义色, 深浅色均可读。改动即存即生效。
@MainActor
struct SettingsView: View {

    let store: SettingsStore

    @State private var selectedPanel: Panel = .scenario
    @State private var expandedReminder: ReminderKind? = .sit

    // MARK: - config 派生态
    @State private var sitMin: Double
    @State private var waterMin: Double
    @State private var eyeMin: Double
    @State private var nightRepeatMin: Double
    @State private var sitEnabled: Bool
    @State private var waterEnabled: Bool
    @State private var eyeEnabled: Bool
    @State private var nightEnabled: Bool
    @State private var sitStyle: ReminderStyle
    @State private var waterStyle: ReminderStyle
    @State private var eyeStyle: ReminderStyle
    @State private var nightStyle: ReminderStyle
    @State private var sitSnoozeMin: Double
    @State private var waterSnoozeMin: Double
    @State private var eyeSnoozeMin: Double
    @State private var sitTitleT: String
    @State private var sitSubT: String
    @State private var waterTitleT: String
    @State private var waterSubT: String
    @State private var eyeTitleT: String
    @State private var eyeSubT: String
    @State private var nightTitleT: String
    @State private var nightSubT: String
    // 定时勿扰
    @State private var dndEnabled: Bool
    @State private var dndStart: Date
    @State private var dndEnd: Date

    // MARK: - 应用层 pref
    @State private var scenario: ScenarioPreset
    @State private var soundEnabled: Bool
    @State private var sitSound: String
    @State private var waterSound: String
    @State private var eyeSound: String
    @State private var nightSound: String
    @State private var breathingLight: Bool
    @State private var cardDwellSeconds: Double
    @State private var cardPosition: String
    @State private var petCharacter: String
    @State private var petColorTheme: String
    @State private var petSizeScale: Double
    @State private var petSide: String
    @State private var petAnimationIntensity: Double
    @State private var petEnabled: Bool
    @State private var petPauseOnBattery: Bool
    @State private var fullscreenSilence: Bool
    @State private var castingSilence: Bool
    @State private var launchAtLogin: Bool
    @State private var strongStyleStaysLonger: Bool

    private let soundOptions = ["Ping", "Submarine", "Glass", "Pop", "Tink", "Funk", "Hero", "Morse", "Bottle"]
    private let colorThemes = ["sky", "rose", "mint", "lavender", "amber", "graphite"]
    private let characters: [(id: String, name: String)] = [
        ("blob", "团子"), ("cat", "猫团"), ("droplet", "水灵"), ("sprout", "芽芽")
    ]
    private let scenarioDesc: [ScenarioPreset: String] = [
        .focus: "仅久坐+护眼 · 轻样式 · 静音提示",
        .relax: "全提醒开 · 强样式 · 高频",
        .eyeCare: "护眼 20 分钟 · 呼吸灯强",
        .custom: "手动细调各项"
    ]

    init(store: SettingsStore) {
        self.store = store
        let cfg = store.load()
        _sitMin = State(initialValue: cfg.sitThreshold / 60)
        _waterMin = State(initialValue: cfg.waterThreshold / 60)
        _eyeMin = State(initialValue: cfg.eyeThreshold / 60)
        _nightRepeatMin = State(initialValue: cfg.nightRepeat / 60)
        _sitEnabled = State(initialValue: cfg.sitEnabled)
        _waterEnabled = State(initialValue: cfg.waterEnabled)
        _eyeEnabled = State(initialValue: cfg.eyeEnabled)
        _nightEnabled = State(initialValue: cfg.nightEnabled)
        _sitStyle = State(initialValue: cfg.sitStyle)
        _waterStyle = State(initialValue: cfg.waterStyle)
        _eyeStyle = State(initialValue: cfg.eyeStyle)
        _nightStyle = State(initialValue: cfg.nightStyle)
        _sitSnoozeMin = State(initialValue: cfg.sitSnooze / 60)
        _waterSnoozeMin = State(initialValue: cfg.waterSnooze / 60)
        _eyeSnoozeMin = State(initialValue: cfg.eyeSnooze / 60)
        _sitTitleT = State(initialValue: cfg.sitTitleTemplate ?? "")
        _sitSubT = State(initialValue: cfg.sitSubtitleTemplate ?? "")
        _waterTitleT = State(initialValue: cfg.waterTitleTemplate ?? "")
        _waterSubT = State(initialValue: cfg.waterSubtitleTemplate ?? "")
        _eyeTitleT = State(initialValue: cfg.eyeTitleTemplate ?? "")
        _eyeSubT = State(initialValue: cfg.eyeSubtitleTemplate ?? "")
        _nightTitleT = State(initialValue: cfg.nightTitleTemplate ?? "")
        _nightSubT = State(initialValue: cfg.nightSubtitleTemplate ?? "")
        _dndEnabled = State(initialValue: cfg.dndStartMinute != nil && cfg.dndEndMinute != nil)
        _dndStart = State(initialValue: Self.date(fromMinute: cfg.dndStartMinute ?? 22 * 60))
        _dndEnd = State(initialValue: Self.date(fromMinute: cfg.dndEndMinute ?? 7 * 60))
        _scenario = State(initialValue: store.scenario)
        _soundEnabled = State(initialValue: store.soundEnabled)
        _sitSound = State(initialValue: store.sitSound)
        _waterSound = State(initialValue: store.waterSound)
        _eyeSound = State(initialValue: store.eyeSound)
        _nightSound = State(initialValue: store.nightSound)
        _breathingLight = State(initialValue: store.breathingLight)
        _cardDwellSeconds = State(initialValue: store.cardDwellSeconds)
        _cardPosition = State(initialValue: store.cardPosition)
        _petCharacter = State(initialValue: store.petCharacter)
        _petColorTheme = State(initialValue: store.petColorTheme)
        _petSizeScale = State(initialValue: store.petSizeScale)
        _petSide = State(initialValue: store.petSide)
        _petAnimationIntensity = State(initialValue: store.petAnimationIntensity)
        _petEnabled = State(initialValue: store.petEnabled)
        _petPauseOnBattery = State(initialValue: store.petPauseOnBattery)
        _fullscreenSilence = State(initialValue: store.fullscreenSilence)
        _castingSilence = State(initialValue: store.castingSilence)
        _launchAtLogin = State(initialValue: store.launchAtLogin)
        _strongStyleStaysLonger = State(initialValue: store.strongStyleStaysLonger)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 720, height: 560)
    }

    // MARK: - 左侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Panel.allCases) { p in
                let on = selectedPanel == p
                Button {
                    selectedPanel = p
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.systemImage)
                            .font(.system(size: 14))
                            .frame(width: 20)
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(p.title)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.control)
                            .fill(on ? Color.primary.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 176)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 右侧细配

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedPanel {
                case .scenario: scenarioPanel
                case .reminders: remindersPanel
                case .style: stylePanel
                case .pet: petPanel
                case .dnd: dndPanel
                case .general: generalPanel
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: 情景模式

    private var scenarioPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader("情景模式", "选择一个情景, 自动套用该场景下的全部阈值与样式。")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(ScenarioPreset.allCases, id: \.self) { p in scenarioCard(p) }
            }
        }
    }

    private func scenarioCard(_ preset: ScenarioPreset) -> some View {
        let selected = scenario == preset
        let isCustom = preset == .custom
        return Button { applyScenario(preset) } label: {
            Group {
                if isCustom {
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                        Text(preset.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.card)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: preset.systemImage)
                                .font(.system(size: 20))
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                            Spacer()
                            if selected { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
                        }
                        Text(preset.displayName).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                        Text(scenarioDesc[preset] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 92)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: DS.card).fill(Color.primary.opacity(0.04)))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.card)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                          lineWidth: selected ? 2 : 1)
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 提醒项(手风琴)

    private var remindersPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader("提醒项", "每类提醒可单独开关、调阈值、选样式, 并自定义文案。")
            reminderCard(.sit, enabled: $sitEnabled, threshold: $sitMin, thresholdRange: 10...120,
                         thresholdLabel: "触发阈值", snooze: $sitSnoozeMin, style: $sitStyle, sound: $sitSound,
                         titleT: $sitTitleT, subT: $sitSubT)
            reminderCard(.water, enabled: $waterEnabled, threshold: $waterMin, thresholdRange: 15...120,
                         thresholdLabel: "触发阈值", snooze: $waterSnoozeMin, style: $waterStyle, sound: $waterSound,
                         titleT: $waterTitleT, subT: $waterSubT)
            reminderCard(.eye, enabled: $eyeEnabled, threshold: $eyeMin, thresholdRange: 10...90,
                         thresholdLabel: "触发阈值", snooze: $eyeSnoozeMin, style: $eyeStyle, sound: $eyeSound,
                         titleT: $eyeTitleT, subT: $eyeSubT)
            reminderCard(.night, enabled: $nightEnabled, threshold: $nightRepeatMin, thresholdRange: 10...60,
                         thresholdLabel: "重复间隔", snooze: nil, style: $nightStyle, sound: $nightSound,
                         titleT: $nightTitleT, subT: $nightSubT)
        }
    }

    @ViewBuilder
    private func reminderCard(_ kind: ReminderKind, enabled: Binding<Bool>,
                              threshold: Binding<Double>, thresholdRange: ClosedRange<Double>,
                              thresholdLabel: String, snooze: Binding<Double>?,
                              style: Binding<ReminderStyle>, sound: Binding<String>,
                              titleT: Binding<String>, subT: Binding<String>) -> some View {
        let expanded = expandedReminder == kind
        VStack(alignment: .leading, spacing: 14) {
            // 头部: 点标题区展开/收起; 右侧总开关
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedReminder = expanded ? nil : kind }
                } label: {
                    HStack(spacing: 12) {
                        iconChip(kind.icon, kind.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                            Text(expanded ? kind.subtitle : summary(kind, threshold: threshold.wrappedValue, style: style.wrappedValue))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if !expanded {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Toggle("", isOn: enabled).labelsHidden()
                    .onChange(of: enabled.wrappedValue) { _, _ in persist() }
            }

            if expanded {
                Divider()
                // 阈值 / 静默 双列
                HStack(alignment: .top, spacing: 20) {
                    sliderRow(title: thresholdLabel, value: threshold, range: thresholdRange, unit: "分钟")
                    if let snooze {
                        sliderRow(title: "忽略后静默", value: snooze, range: 0...30, unit: "分钟")
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                // 样式 / 提示音 双列
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("提醒样式").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: style) {
                            Text("强 · 带按钮").tag(ReminderStyle.strong)
                            Text("轻 · 一闪").tag(ReminderStyle.light)
                        }
                        .labelsHidden().pickerStyle(.segmented)
                        .onChange(of: style.wrappedValue) { _, _ in persist() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("提示音").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: sound) {
                            ForEach(soundOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().disabled(!soundEnabled)
                        .onChange(of: sound.wrappedValue) { _, name in
                            if soundEnabled { NSSound(named: name)?.play() }
                            persistDisplayPrefs()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 自定义文案
                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义文案 · 变量 {分钟} {项目} {时钟}").font(.caption).foregroundStyle(.secondary)
                    TextField("标题模板(留空用内置默认)", text: titleT)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: titleT.wrappedValue) { _, _ in persist() }
                    TextField("副标题模板(留空用内置默认)", text: subT)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: subT.wrappedValue) { _, _ in persist() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.card).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: DS.card).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func summary(_ kind: ReminderKind, threshold: Double, style: ReminderStyle) -> String {
        let styleText = style == .strong ? "强样式" : "轻样式"
        if kind == .night {
            return "≥23:00 · 每 \(Int(threshold)) 分钟 · \(styleText)"
        }
        return "\(Int(threshold)) 分钟 · \(styleText)"
    }

    // MARK: 提醒方式

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader("提醒方式", "声音 / 呼吸灯 / 停留 / 位置")
            listCard {
                settingRow(icon: "speaker.wave.2.fill", iconColor: DS.water, title: "启用提示音",
                           subtitle: "各类具体音效在「提醒项」里逐类选择") {
                    Toggle("", isOn: $soundEnabled).labelsHidden()
                        .onChange(of: soundEnabled) { _, _ in persistDisplayPrefs() }
                }
                Divider()
                settingRow(icon: "rays", iconColor: DS.sit, title: "呼吸灯边框",
                           subtitle: "屏幕四周柔光脉动") {
                    Toggle("", isOn: $breathingLight).labelsHidden()
                        .onChange(of: breathingLight) { _, _ in persistDisplayPrefs() }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    sliderRow(title: "卡片停留时长", value: $cardDwellSeconds, range: 1...10, unit: "秒",
                              step: 1, onChange: { persistDisplayPrefs() })
                }
                Divider()
                settingRow(icon: "rectangle.topthird.inset.filled", iconColor: DS.eye, title: "卡片位置",
                           subtitle: "「右上角」用独立浮层, 宠物仍留刘海") {
                    Picker("", selection: $cardPosition) {
                        Text("刘海下").tag("notch")
                        Text("右上角").tag("topRight")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                    .onChange(of: cardPosition) { _, _ in persistDisplayPrefs() }
                }
            }
        }
    }

    // MARK: 宠物

    private var petPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader("宠物", "形象 / 配色 / 大小 / 位置 / 动画强度")
            listCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("形象").font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        ForEach(characters, id: \.id) { characterChip($0.id, name: $0.name) }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("配色主题").font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        ForEach(colorThemes, id: \.self) { colorSwatch($0) }
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    sliderRow(title: "大小", value: $petSizeScale, range: 0.8...1.3, unit: "×", step: 0.05,
                              decimals: 2, onChange: { persistPetAppearance() })
                    sliderRow(title: "动画强度", value: $petAnimationIntensity, range: 0...1, unit: "", step: 0.05,
                              decimals: 2, onChange: { persistPetAppearance() })
                }
                Divider()
                settingRow(icon: "arrow.left.and.right", iconColor: DS.night, title: "刘海侧位置", subtitle: nil) {
                    Picker("", selection: $petSide) {
                        Text("左侧").tag("left")
                        Text("右侧").tag("right")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 140)
                    .onChange(of: petSide) { _, _ in persistPetAppearance() }
                }
            }
            listCard {
                settingRow(icon: "pawprint.fill", iconColor: DS.eye, title: "启用刘海宠物", subtitle: nil) {
                    Toggle("", isOn: $petEnabled).labelsHidden()
                        .onChange(of: petEnabled) { _, on in
                            store.petEnabled = on
                            AppController.shared?.presenterSetPetEnabled(on)
                        }
                }
                Divider()
                settingRow(icon: "battery.25", iconColor: DS.sit, title: "电池模式静止(省电)",
                           subtitle: "重启生效") {
                    Toggle("", isOn: $petPauseOnBattery).labelsHidden()
                        .onChange(of: petPauseOnBattery) { _, on in store.petPauseOnBattery = on }
                }
            }
        }
    }

    private func characterChip(_ id: String, name: String) -> some View {
        let selected = petCharacter == id
        return Button {
            petCharacter = id
            persistPetAppearance()
        } label: {
            VStack(spacing: 6) {
                PetBlob(mood: .fresh, act: nil, isAwake: true, isPetting: false,
                        size: 30, colorOverride: PetViewModel.themeColor(petColorTheme), character: id)
                    .frame(width: 46, height: 46)
                Text(name).font(.caption).foregroundStyle(.primary)
            }
            .frame(width: 66, height: 78)
            .background(RoundedRectangle(cornerRadius: DS.control).fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.control)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func colorSwatch(_ theme: String) -> some View {
        let selected = petColorTheme == theme
        let color = PetViewModel.themeColor(theme) ?? Color(hex: 0x99CCE6)
        return Button {
            petColorTheme = theme
            persistPetAppearance()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 30, height: 30)
                .overlay(
                    Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                        .padding(-3)
                )
                .overlay(
                    theme == "sky"
                        ? Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.white)
                        : nil
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 免打扰

    private var dndPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader("免打扰", "时段 / 全屏 / 投屏自动静默")
            listCard {
                settingRow(icon: "moon.fill", iconColor: DS.night, title: "定时勿扰", subtitle: nil) {
                    Toggle("", isOn: $dndEnabled).labelsHidden()
                        .onChange(of: dndEnabled) { _, _ in persist() }
                }
                if dndEnabled {
                    HStack(spacing: 10) {
                        DatePicker("", selection: $dndStart, displayedComponents: .hourAndMinute)
                            .labelsHidden().onChange(of: dndStart) { _, _ in persist() }
                        Text("至").foregroundStyle(.secondary)
                        DatePicker("", selection: $dndEnd, displayedComponents: .hourAndMinute)
                            .labelsHidden().onChange(of: dndEnd) { _, _ in persist() }
                        Spacer()
                    }
                    Text("窗口内计时照常, 仅不弹提醒; 跨午夜(如 22:30→07:00)自动识别。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            listCard {
                settingRow(icon: "rectangle.inset.filled", iconColor: DS.water, title: "全屏应用时静默",
                           subtitle: "看视频 / 玩游戏不打扰") {
                    Toggle("", isOn: $fullscreenSilence).labelsHidden()
                        .onChange(of: fullscreenSilence) { _, on in
                            store.fullscreenSilence = on
                            AppController.shared?.fullscreenSilenceEnabled = on
                        }
                }
                Divider()
                settingRow(icon: "airplayvideo", iconColor: DS.eye, title: "投屏 / 演示时静默",
                           subtitle: "检测到屏幕镜像 / 投屏自动静默") {
                    Toggle("", isOn: $castingSilence).labelsHidden()
                        .onChange(of: castingSilence) { _, on in
                            store.castingSilence = on
                            AppController.shared?.castingSilenceEnabled = on
                        }
                }
            }
        }
    }

    // MARK: 通用

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader("通用", "启动 / 提醒 / 关于")
            listCard {
                settingRow(icon: "power", iconColor: DS.eye, title: "开机自启", subtitle: nil) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { _, on in
                            store.launchAtLogin = on
                            if on { LaunchAgent.enable() } else { LaunchAgent.disable() }
                        }
                }
                Divider()
                settingRow(icon: "clock", iconColor: DS.sit, title: "强样式提醒停留更久", subtitle: nil) {
                    Toggle("", isOn: $strongStyleStaysLonger).labelsHidden()
                        .onChange(of: strongStyleStaysLonger) { _, on in store.strongStyleStaysLonger = on }
                }
            }
            HStack {
                Label("版本", systemImage: "info.circle").foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "NotchReminder \(reminderCoreVersion)").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 复用组件

    private func panelHeader(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }

    /// 类别色图标胶囊(圆角方块 + 着色 SF Symbol)。
    private func iconChip(_ systemImage: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(color.opacity(0.18))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: systemImage).font(.system(size: 14)).foregroundStyle(color))
    }

    /// 分组列表卡(白底圆角 + 细边; 内含 rows / Divider)。
    private func listCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.card).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: DS.card).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// 单行设置项: 图标胶囊 + 标题(+副标题) + 右侧控件。
    private func settingRow<Control: View>(icon: String?, iconColor: Color, title: String, subtitle: String?,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            if let icon { iconChip(icon, iconColor) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            control()
        }
    }

    /// 滑杆行: 标题 + 右侧值, 下方全宽 Slider。
    @ViewBuilder
    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           unit: String, step: Double = 5, decimals: Int = 0,
                           onChange: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text("\(formatted(value.wrappedValue, decimals: decimals))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { _, _ in
                    if let onChange { onChange() } else { persist() }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ v: Double, decimals: Int) -> String {
        decimals <= 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
    }

    // MARK: - 持久化

    private func persist() {
        var cfg = store.load()
        cfg.sitThreshold = sitMin * 60
        cfg.waterThreshold = waterMin * 60
        cfg.eyeThreshold = eyeMin * 60
        cfg.nightRepeat = nightRepeatMin * 60
        cfg.sitEnabled = sitEnabled
        cfg.waterEnabled = waterEnabled
        cfg.eyeEnabled = eyeEnabled
        cfg.nightEnabled = nightEnabled
        cfg.sitStyle = sitStyle
        cfg.waterStyle = waterStyle
        cfg.eyeStyle = eyeStyle
        cfg.nightStyle = nightStyle
        cfg.sitSnooze = sitSnoozeMin * 60
        cfg.waterSnooze = waterSnoozeMin * 60
        cfg.eyeSnooze = eyeSnoozeMin * 60
        if dndEnabled {
            cfg.dndStartMinute = Self.minuteOfDay(dndStart)
            cfg.dndEndMinute = Self.minuteOfDay(dndEnd)
        } else {
            cfg.dndStartMinute = nil
            cfg.dndEndMinute = nil
        }
        cfg.sitTitleTemplate = nilIfEmpty(sitTitleT)
        cfg.sitSubtitleTemplate = nilIfEmpty(sitSubT)
        cfg.waterTitleTemplate = nilIfEmpty(waterTitleT)
        cfg.waterSubtitleTemplate = nilIfEmpty(waterSubT)
        cfg.eyeTitleTemplate = nilIfEmpty(eyeTitleT)
        cfg.eyeSubtitleTemplate = nilIfEmpty(eyeSubT)
        cfg.nightTitleTemplate = nilIfEmpty(nightTitleT)
        cfg.nightSubtitleTemplate = nilIfEmpty(nightSubT)
        store.save(cfg)
        AppController.shared?.applyConfig(cfg)
    }

    private func persistDisplayPrefs() {
        store.soundEnabled = soundEnabled
        store.sitSound = sitSound
        store.waterSound = waterSound
        store.eyeSound = eyeSound
        store.nightSound = nightSound
        store.breathingLight = breathingLight
        store.cardDwellSeconds = cardDwellSeconds
        store.cardPosition = cardPosition
        AppController.shared?.presenterApplyDisplayPrefs(
            cardDwellSeconds: cardDwellSeconds, breathingLight: breathingLight,
            soundEnabled: soundEnabled, sitSound: sitSound, waterSound: waterSound,
            eyeSound: eyeSound, nightSound: nightSound, cardPosition: cardPosition)
    }

    private func persistPetAppearance() {
        store.petCharacter = petCharacter
        store.petColorTheme = petColorTheme
        store.petSizeScale = petSizeScale
        store.petSide = petSide
        store.petAnimationIntensity = petAnimationIntensity
        AppController.shared?.presenterApplyPetAppearance(
            character: petCharacter, colorTheme: petColorTheme,
            sizeScale: CGFloat(petSizeScale), side: petSide,
            animationIntensity: CGFloat(petAnimationIntensity))
    }

    private func applyScenario(_ preset: ScenarioPreset) {
        scenario = preset
        store.scenario = preset
        var cfg = store.load()
        cfg = preset.apply(to: cfg)
        store.save(cfg)
        AppController.shared?.applyConfig(cfg)
        refreshFromConfig(cfg)
    }

    private func refreshFromConfig(_ cfg: ReminderConfig) {
        sitMin = cfg.sitThreshold / 60
        waterMin = cfg.waterThreshold / 60
        eyeMin = cfg.eyeThreshold / 60
        nightRepeatMin = cfg.nightRepeat / 60
        sitEnabled = cfg.sitEnabled
        waterEnabled = cfg.waterEnabled
        eyeEnabled = cfg.eyeEnabled
        nightEnabled = cfg.nightEnabled
        sitStyle = cfg.sitStyle
        waterStyle = cfg.waterStyle
        eyeStyle = cfg.eyeStyle
        nightStyle = cfg.nightStyle
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func minuteOfDay(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func date(fromMinute m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
}

/// 宿主 SwiftUI 设置窗的 NSWindow 控制器。单实例复用, 再次点"设置…"只前置已有窗。
@MainActor
final class SettingsWindowController {

    private let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(store: store))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        w.title = "NotchReminder 设置"
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
