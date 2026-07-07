import Foundation
import CoreGraphics
import AppKit

public enum DoNotDisturb {

    // MARK: - 手动静音(可靠部分; 写入 ReminderConfig.mutedUntil, 供 Task 7 菜单栏调用)

    /// 从 now 起静音 seconds 秒, 返回应写入 ReminderConfig.mutedUntil 的时间点。
    public static func muteFor(_ seconds: TimeInterval, now: Date = Date()) -> Date {
        return now.addingTimeInterval(seconds)
    }

    /// mutedUntil 是否仍在生效: 非 nil 且 now < mutedUntil。
    public static func isMuted(_ mutedUntil: Date?, now: Date = Date()) -> Bool {
        guard let until = mutedUntil else { return false }
        return now < until
    }

    // MARK: - 全屏近似(best-effort; spec §5.4 免打扰。摄像头占用检测本版不做, 见 §8/§9 v2)

    /// 当前是否有 App 处于全屏(演示 / 看片 / 会议)。CGWindowList 近似, 非精确。
    /// 判据: 存在一个普通层级(kCGWindowLayer==0)、有归属进程、且 bounds 完整覆盖某块屏 frame 的窗口。
    /// 全屏 App 会占满整屏并遮住菜单栏, 其窗口 bounds ≈ 该屏 CGDisplayBounds。
    public static func isFullscreenActive() -> Bool {
        let option: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // 收集所有屏的 CGDisplayBounds(全局坐标, 原点左上)。
        let screenFrames: [CGRect] = NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
        }
        guard !screenFrames.isEmpty else { return false }

        for info in infoList {
            // 只看普通层(全屏 App 内容窗口在 layer 0; 菜单栏/Dock 等在非 0 层)。
            let layer = (info[kCGWindowLayer as String] as? Int) ?? Int.min
            guard layer == 0 else { continue }
            // 必须有归属进程(排除系统装饰窗口)。
            guard (info[kCGWindowOwnerPID as String] as? Int) != nil else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            // 该窗口是否覆盖了某整块屏(允许 1pt 误差)。
            for frame in screenFrames where coversFullScreen(window: rect, screen: frame) {
                return true
            }
        }
        return false
    }

    /// 窗口是否近似覆盖整块屏(原点重合、宽高不小于屏)。
    private static func coversFullScreen(window: CGRect, screen: CGRect) -> Bool {
        let tol: CGFloat = 1
        return abs(window.origin.x - screen.origin.x) <= tol
            && abs(window.origin.y - screen.origin.y) <= tol
            && window.width >= screen.width - tol
            && window.height >= screen.height - tol
    }
}
