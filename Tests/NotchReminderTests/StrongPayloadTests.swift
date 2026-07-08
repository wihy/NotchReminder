import XCTest
@testable import NotchReminder

/// C2 回归守卫: 提醒卡按钮由 showSnooze/showDismiss 独立控制。
/// 修复前「知道了」按钮恒渲染, water/eye 出现点了没反应的悬空 dismiss;
/// 修复后 water/eye 两者皆 false(无按钮区), sit=snooze+dismiss, night=仅 dismiss。
@MainActor
final class StrongPayloadTests: XCTestCase {

    func testLightReminderHasNoButtons() {
        // water/eye 轻样式: 有正文, 无任何按钮。
        let p = StrongPayload()
        p.set(title: "喝口水", subtitle: "补个水, 顺手站一下",
              showSnooze: false, showDismiss: false, onSnooze: nil, onDismiss: nil)
        XCTAssertEqual(p.title, "喝口水")
        XCTAssertFalse(p.showSnooze)
        XCTAssertFalse(p.showDismiss)
        XCTAssertNil(p.onSnooze)
        XCTAssertNil(p.onDismiss)
    }

    func testSitReminderHasSnoozeAndDismiss() {
        let p = StrongPayload()
        p.set(title: "连续 50 分钟了", subtitle: "起来走两步, 眼睛也歇歇",
              showSnooze: true, showDismiss: true, onSnooze: {}, onDismiss: {})
        XCTAssertTrue(p.showSnooze)
        XCTAssertTrue(p.showDismiss)
        XCTAssertNotNil(p.onSnooze)
        XCTAssertNotNil(p.onDismiss)
    }

    func testNightReminderHasDismissOnly() {
        let p = StrongPayload()
        p.set(title: "23:30 了", subtitle: "明天的你会感谢现在睡觉的你",
              showSnooze: false, showDismiss: true, onSnooze: nil, onDismiss: {})
        XCTAssertFalse(p.showSnooze)
        XCTAssertTrue(p.showDismiss)
        XCTAssertNotNil(p.onDismiss)
    }

    func testSetOverwritesPreviousContent() {
        // 队列串行复用同一 payload: 后一条 set 必须完整覆盖前一条(不残留旧回调)。
        let p = StrongPayload()
        p.set(title: "连续 50 分钟了", subtitle: "起来走两步",
              showSnooze: true, showDismiss: true, onSnooze: {}, onDismiss: {})
        p.set(title: "喝口水", subtitle: "补个水",
              showSnooze: false, showDismiss: false, onSnooze: nil, onDismiss: nil)
        XCTAssertEqual(p.title, "喝口水")
        XCTAssertFalse(p.showSnooze)
        XCTAssertFalse(p.showDismiss)
        XCTAssertNil(p.onSnooze, "旧 sit 的 snooze 回调不能残留到轻样式卡")
        XCTAssertNil(p.onDismiss)
    }
}
