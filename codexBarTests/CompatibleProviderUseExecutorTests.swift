import XCTest

final class CompatibleProviderUseExecutorTests: XCTestCase {
    func testUseActivatesWithoutLaunching() async throws {
        let tracker = CompatibleProviderUseEffectTracker()

        try await CompatibleProviderUseExecutor.execute {
            tracker.activateCount += 1
        }

        XCTAssertEqual(tracker.activateCount, 1)
    }
}

private final class CompatibleProviderUseEffectTracker {
    var activateCount = 0
}
