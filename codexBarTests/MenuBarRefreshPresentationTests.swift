import XCTest

final class MenuBarRefreshPresentationTests: XCTestCase {
    func testOpenPanelRefreshDoesNotShowFooterLoading() {
        XCTAssertFalse(
            MenuBarRefreshPresentation.shouldShowFooterLoading(
                isOpenAIRefreshInProgress: true,
                initiatedByUser: false
            )
        )
    }

    func testManualOpenAIRefreshShowsFooterLoading() {
        XCTAssertTrue(
            MenuBarRefreshPresentation.shouldShowFooterLoading(
                isOpenAIRefreshInProgress: true,
                initiatedByUser: true
            )
        )
    }

    func testIdleStateDoesNotShowFooterLoadingEvenForUserInitiatedRefresh() {
        XCTAssertFalse(
            MenuBarRefreshPresentation.shouldShowFooterLoading(
                isOpenAIRefreshInProgress: false,
                initiatedByUser: true
            )
        )
    }
}
