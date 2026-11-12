import XCTest

final class MenuBarRefreshPresentationTests: XCTestCase {
    func testIconTracksOAuthRefresh() {
        XCTAssertTrue(MenuBarRefreshPresentation.shouldAnimateIcon(isOpenAIRefreshInProgress: true))
        XCTAssertFalse(MenuBarRefreshPresentation.shouldAnimateIcon(isOpenAIRefreshInProgress: false))
    }

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
