import XCTest

final class OpenAIAccountUsageModeTransitionExecutorTests: XCTestCase {

    func testSwitchingIntoHybridOnlyUpdatesConfig() async throws {
        let tracker = UsageModeTransitionEffectTracker(currentMode: .switchAccount)

        let action = try await OpenAIAccountUsageModeTransitionExecutor.execute(
            targetMode: .hybridProvider,
            currentMode: tracker.currentMode,
            applyMode: {
                tracker.applyCount += 1
                tracker.currentMode = .hybridProvider
            }
        )

        XCTAssertEqual(action, .updateConfigOnly)
        XCTAssertEqual(tracker.applyCount, 1)
        XCTAssertEqual(tracker.launchCount, 0)
        XCTAssertEqual(tracker.rollbackCount, 0)
        XCTAssertEqual(tracker.currentMode, .hybridProvider)
    }

}

private final class UsageModeTransitionEffectTracker {
    var currentMode: CodexBarOpenAIAccountUsageMode
    var applyCount = 0
    var rollbackCount = 0
    var launchCount = 0

    init(currentMode: CodexBarOpenAIAccountUsageMode) {
        self.currentMode = currentMode
    }
}

private enum DummyError: Error, Equatable {
    case failed
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
