import XCTest

final class OpenAIManualActivationResolverTests: XCTestCase {
    func testResolveAlwaysUpdatesConfigOnly() {
        let action = OpenAIManualActivationResolver.resolve()

        XCTAssertEqual(action, .updateConfigOnly)
    }
}
