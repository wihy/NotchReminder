import XCTest
@testable import NotchReminder
import ReminderCore

@MainActor
final class PetViewModelTests: XCTestCase {

    func testSetMood() {
        let vm = PetViewModel()
        vm.setMood(.tired)
        XCTAssertEqual(vm.mood, .tired)
        vm.setMood(.dozing)
        XCTAssertEqual(vm.mood, .dozing)
    }

    func testPlayActAndClear() {
        let vm = PetViewModel()
        vm.playAct(.drink)
        XCTAssertEqual(vm.act, .drink)
        vm.clearAct()
        XCTAssertNil(vm.act)
    }

    func testSleepWake() {
        let vm = PetViewModel()
        XCTAssertTrue(vm.isAwake)
        vm.sleep()
        XCTAssertFalse(vm.isAwake)
        vm.wake()
        XCTAssertTrue(vm.isAwake)
    }

    func testPetAndClear() {
        let vm = PetViewModel()
        XCTAssertFalse(vm.isPetting)
        vm.pet()
        XCTAssertTrue(vm.isPetting)
        vm.clearPet()
        XCTAssertFalse(vm.isPetting)
    }

    func testActForMapping() {
        XCTAssertEqual(actFor(.water), .drink)
        XCTAssertEqual(actFor(.eye), .lookAway)
        XCTAssertEqual(actFor(.sit(minutes: 50, project: nil)), .stretch)
        XCTAssertEqual(actFor(.night(clock: "23:30")), .yawn)
    }
}
