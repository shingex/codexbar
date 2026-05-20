import XCTest

final class MenuBarOpenRefreshGateTests: XCTestCase {
    func testLocalCostSummaryReportsStaleAfterLocalDayChanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let updatedAt = ISO8601DateFormatter().date(from: "2026-05-19T15:50:40Z")!
        let now = ISO8601DateFormatter().date(from: "2026-05-19T16:00:01Z")!
        let summary = LocalCostSummary(
            todayCostUSD: 1,
            todayTokens: 1,
            last30DaysCostUSD: 1,
            last30DaysTokens: 1,
            lifetimeCostUSD: 1,
            lifetimeTokens: 1,
            dailyEntries: [],
            updatedAt: updatedAt
        )

        XCTAssertTrue(summary.isStaleForLocalDay(now: now, calendar: calendar))
    }

    func testLocalCostSummaryRemainsFreshWithinSameLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let updatedAt = ISO8601DateFormatter().date(from: "2026-05-19T16:00:01Z")!
        let now = ISO8601DateFormatter().date(from: "2026-05-19T23:00:00Z")!
        let summary = LocalCostSummary(
            todayCostUSD: 1,
            todayTokens: 1,
            last30DaysCostUSD: 1,
            last30DaysTokens: 1,
            lifetimeCostUSD: 1,
            lifetimeTokens: 1,
            dailyEntries: [],
            updatedAt: updatedAt
        )

        XCTAssertFalse(summary.isStaleForLocalDay(now: now, calendar: calendar))
    }

    func testFirstOpenTriggersRefreshWhenIdle() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
    }

    func testSecondOpenInSamePresentationDoesNotTriggerAgain() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false))
    }

    func testCloseResetsGateForNextOpen() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
        gate.resetForClose()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
    }

    func testOpenWhileRefreshAlreadyRunningStillConsumesPresentation() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: true))
        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false))
        gate.resetForClose()
        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
    }
}
