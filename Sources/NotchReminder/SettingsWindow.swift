import SwiftUI
import AppKit
import ReminderCore

/// 设置窗内容: 四类阈值 Slider(分钟) + 四开关 + 开机自启 + 样式偏好。改动即存即生效。
struct SettingsView: View {

    let store: SettingsStore

    // 阈值(分钟, 双向绑定回写秒到 config)
    @State private var sitMin: Double
    @State private var waterMin: Double
    @State private var eyeMin: Double
    @State private var nightRepeatMin: Double
    // 四开关
    @State private var sitEnabled: Bool
    @State private var waterEnabled: Bool
    @State private var eyeEnabled: Bool
    @State private var nightEnabled: Bool
    // 偏好
    @State private var launchAtLogin: Bool
    @State private var strongStyleStaysLonger: Bool

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
        _launchAtLogin = State(initialValue: store.launchAtLogin)
        _strongStyleStaysLonger = State(initialValue: store.strongStyleStaysLonger)
    }

    var body: some View {
        Form {
            Section("提醒阈值") {
                sliderRow(title: "🧍 久坐起身", value: $sitMin, range: 10...120, unit: "分钟")
                sliderRow(title: "💧 喝水", value: $waterMin, range: 15...120, unit: "分钟")
                sliderRow(title: "👀 护眼远眺", value: $eyeMin, range: 10...90, unit: "分钟")
                sliderRow(title: "🌙 熬夜重复间隔", value: $nightRepeatMin, range: 10...60, unit: "分钟")
            }
            Section("开关") {
                Toggle("久坐起身", isOn: $sitEnabled).onChange(of: sitEnabled) { _, _ in persist() }
                Toggle("喝水", isOn: $waterEnabled).onChange(of: waterEnabled) { _, _ in persist() }
                Toggle("护眼远眺", isOn: $eyeEnabled).onChange(of: eyeEnabled) { _, _ in persist() }
                Toggle("熬夜劝退", isOn: $nightEnabled).onChange(of: nightEnabled) { _, _ in persist() }
            }
            Section("通用") {
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        store.launchAtLogin = on
                        if on { LaunchAgent.enable() } else { LaunchAgent.disable() }
                    }
                Toggle("强样式提醒停留更久", isOn: $strongStyleStaysLonger)
                    .onChange(of: strongStyleStaysLonger) { _, on in
                        store.strongStyleStaysLonger = on
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }

    @ViewBuilder
    private func sliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 5)
                .onChange(of: value.wrappedValue) { _, _ in persist() }
        }
    }

    /// 把当前 UI 值组装成 ReminderConfig(保留未暴露的引擎阈值默认)并存 + 生效。
    private func persist() {
        var cfg = store.load()  // 拿到当前(含未暴露字段)
        cfg.sitThreshold = sitMin * 60
        cfg.waterThreshold = waterMin * 60
        cfg.eyeThreshold = eyeMin * 60
        cfg.nightRepeat = nightRepeatMin * 60
        cfg.sitEnabled = sitEnabled
        cfg.waterEnabled = waterEnabled
        cfg.eyeEnabled = eyeEnabled
        cfg.nightEnabled = nightEnabled
        store.save(cfg)
        AppController.shared.applyConfig(cfg)
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
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
