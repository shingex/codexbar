import XCTest

final class OpenAIManualActivationExecutorTests: XCTestCase {
    func testActivationUpdatesConfigWithoutLaunching() async throws {
        let tracker = ManualActivationEffectTracker()

        let result = try await OpenAIManualActivationExecutor.execute(
            targetAccountID: "acct-primary",
            targetMode: .switchAccount
        ) {
            tracker.activateCount += 1
        }

        XCTAssertEqual(result.action, .updateConfigOnly)
        XCTAssertEqual(result.targetAccountID, "acct-primary")
        XCTAssertEqual(result.targetMode, .switchAccount)
        XCTAssertFalse(result.launchedNewInstance)
        XCTAssertFalse(result.affectsRunningThreads)
        XCTAssertEqual(result.copyKey, .defaultTargetUpdated)
        XCTAssertEqual(result.immediateEffectRecommendation, .noneNeeded)
        XCTAssertEqual(tracker.activateCount, 1)
    }
}

private final class ManualActivationEffectTracker {
    var activateCount = 0
}
