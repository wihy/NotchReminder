import Foundation

/// 纯逻辑状态机。无副作用、不依赖 AppKit, 可 `swift test`。
public enum ReminderEngine {

    /// 墙钟是否处于「熬夜」窗口: hour >= 23 或 hour < 2(即 23:00–01:59)。
    public static func isNight(_ now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= 23 || hour < 2
    }

    /// 把时间格式化为 "HH:mm"(24 小时制, 本地时区)。
    public static func clockString(_ now: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }

    /// 纯函数: 喂入当前状态 + 配置 + 一次采样, 返回更新后状态与本次要产出的提醒列表。
    /// 本 Task 只实现 dt / active / rest / sit / CC 口径; water/eye/night 分支在 Task 4 补齐。
    public static func advance(
        _ state: ReminderState,
        config: ReminderConfig,
        sample: Sample
    ) -> (ReminderState, [Reminder]) {
        var newState = state
        let now = sample.now

        // ---- 1) dt ----
        var dt: TimeInterval
        if let last = state.lastSample {
            dt = now.timeIntervalSince(last)
        } else {
            dt = 0
        }
        if dt < 0 { dt = 0 }
        let dormant = dt > config.restThreshold  // 长时间未采样(休眠) → 按真休息

        // ---- 2) active / rest 判定 ----
        let byInput = sample.idleSeconds < config.activeIdleCeiling
        let byCC: Bool = {
            guard sample.ccActive, let ccLast = sample.ccLastEvent else { return false }
            return now.timeIntervalSince(ccLast) < config.ccGrace
        }()
        let active = byInput || byCC
        let rest = (sample.idleSeconds >= config.restThreshold && !byCC) || dormant

        // ---- 3) 计时器推进 ----
        if rest {
            newState.sitAccum = 0
            newState.eyeAccum = 0
            // water: 暂停累加, 不加不清
        } else if active {
            newState.sitAccum += dt
            newState.eyeAccum += dt
            newState.waterAccum += dt
        }
        // 灰区: 三累加均不变

        newState.lastSample = now

        // ---- 4) 触发判断(本 Task 仅 sit) ----
        var reminders: [Reminder] = []

        // sit
        if config.sitEnabled && newState.sitAccum >= config.sitThreshold {
            let snoozeOK: Bool = {
                guard let lastAlert = newState.lastSitAlert else { return true }
                return now.timeIntervalSince(lastAlert) >= config.sitSnooze
            }()
            if snoozeOK {
                reminders.append(.sit(minutes: Int(newState.sitAccum / 60), project: sample.project))
                newState.lastSitAlert = now  // 不清 sitAccum
            }
        }

        // ---- 5) muted 抑制产出(计时已照常推进) ----
        if let mutedUntil = config.mutedUntil, now < mutedUntil {
            return (newState, [])
        }

        return (newState, reminders)
    }
}
