import ReminderCore

/// 提醒触发时宠物的演出动作。
public enum PetAct: Equatable {
    case drink      // 喝水
    case lookAway   // 护眼远眺
    case stretch    // 久坐伸懒腰
    case yawn       // 熬夜打哈欠
}

/// Reminder → PetAct 平凡映射。
public func actFor(_ r: Reminder) -> PetAct {
    switch r {
    case .water:  return .drink
    case .eye:    return .lookAway
    case .sit:    return .stretch
    case .night:  return .yawn
    }
}
