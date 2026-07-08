import Foundation

/// 宠物心情。由引擎现有状态经 petMood() 纯函数映射(spec §3.1)。
public enum PetMood: Equatable {
    case fresh       // 刚开工 / 刚真休息过(sitAccum 低)
    case calm        // 正常工作
    case tired       // 连续 ≥ sitThreshold(50min)
    case exhausted   // 连续 ≥ 90min
    case sleepy      // 夜里(23:00–01:59)
    case dozing      // 静音/专注中
}

/// 把引擎现有状态映射成宠物心情。纯函数: 无副作用、不依赖 AppKit、确定、可单测。
/// 优先级(首个命中即返回, spec §3.1):
/// 1) now < mutedUntil → .dozing
/// 2) isNight(now)     → .sleepy
/// 3) sitAccum ≥ 90*60 → .exhausted
/// 4) sitAccum ≥ sitThreshold → .tired
/// 5) sitAccum < 10*60 → .fresh
/// 6) else             → .calm
public func petMood(state: ReminderState, config: ReminderConfig, now: Date) -> PetMood {
    if let mutedUntil = config.mutedUntil, now < mutedUntil {
        return .dozing
    }
    if ReminderEngine.isNight(now) {
        return .sleepy
    }
    if state.sitAccum >= 90 * 60 {
        return .exhausted
    }
    if state.sitAccum >= config.sitThreshold {
        return .tired
    }
    if state.sitAccum < 10 * 60 {
        return .fresh
    }
    return .calm
}
