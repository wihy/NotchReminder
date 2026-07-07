import CoreGraphics

/// 系统级活跃度采样。只读, 不监听/不记录输入内容, 因此无需辅助功能或输入监测权限。
public enum ActivityMonitor {

    /// 系统全局空闲秒数: 距上次任意键鼠/触控板输入过去的秒数。
    ///
    /// 用 `CGEventSource.secondsSinceLastEventType(_:eventType:)`(被动查询, 非事件监听),
    /// 已在本机 macOS 26.5 实测: 裸可执行直接返回真实 idle 值, 全程无 TCC 权限弹窗。
    /// - stateID 用 `.hidSystemState`(对应 C 常量 kCGEventSourceStateHIDSystemState)。
    /// - eventType 表达"任意输入": `kCGAnyInputEventType` 在 Swift 未桥接为符号, 用 `CGEventType(rawValue: ~0)!`
    ///   构造(~0 即全 1 位, 底层 C 值 0xFFFFFFFF)。
    /// 返回 `CFTimeInterval`(== `Double`), 单位秒。
    public static func currentIdleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}
