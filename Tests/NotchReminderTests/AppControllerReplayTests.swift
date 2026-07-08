import XCTest
@testable import NotchReminder
import ReminderCore

@MainActor
final class AppControllerReplayTests: XCTestCase {

    func testFullscreenRoutesToPending() {
        let controller = AppController(presenter: NotchPresenter(), dnd: { true }, ccProvider: { nil })
        controller.route([.water, .eye])
        XCTAssertEqual(controller.pending, [.water, .eye])
    }

    func testNonFullscreenDoesNotQueue() {
        let controller = AppController(presenter: NotchPresenter(), dnd: { false }, ccProvider: { nil })
        controller.route([.water])
        XCTAssertTrue(controller.pending.isEmpty)
    }

    func testFlushPendingClearsWhenNotFullscreen() {
        var fullscreen = true
        let presenter = NotchPresenter()
        let controller = AppController(presenter: presenter, dnd: { fullscreen }, ccProvider: { nil })
        controller.route([.water, .eye])   // 全屏 → 入队
        XCTAssertEqual(controller.pending.count, 2)
        fullscreen = false
        controller.flushPending()           // 结束 → 补放并清空
        XCTAssertTrue(controller.pending.isEmpty)
        XCTAssertEqual(presenter.presentCount, 2, "flushPending should re-present all queued reminders")
    }

    func testFlushPendingKeepsWhenStillFullscreen() {
        let controller = AppController(presenter: NotchPresenter(), dnd: { true }, ccProvider: { nil })
        controller.route([.water])          // 全屏 → 入队
        controller.flushPending()           // 仍全屏 → 保留
        XCTAssertEqual(controller.pending, [.water])
    }
}
