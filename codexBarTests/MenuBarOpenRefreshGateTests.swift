import XCTest

final class MenuBarOpenRefreshGateTests: XCTestCase {


    func testFirstOpenTriggersRefreshWhenIdle() {
        var gate = MenuBarOpenRefreshGate()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false, now: now))
    }

    func testSecondOpenInsideCooldownDoesNotTriggerAgain() {
        var gate = MenuBarOpenRefreshGate()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false, now: now))
        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false, now: now.addingTimeInterval(4.9)))
    }

    func testCloseDoesNotResetCooldown() {
        var gate = MenuBarOpenRefreshGate()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false, now: now))
        gate.resetForClose()

        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false, now: now.addingTimeInterval(4.9)))
        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false, now: now.addingTimeInterval(5)))
    }

    func testOpenWhileRefreshAlreadyRunningStillConsumesCooldown() {
        var gate = MenuBarOpenRefreshGate()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: true, now: now))
        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false, now: now.addingTimeInterval(4.9)))
        gate.resetForClose()
        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false, now: now.addingTimeInterval(5)))
    }
}
