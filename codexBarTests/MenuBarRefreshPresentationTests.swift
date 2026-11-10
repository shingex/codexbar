import XCTest

final class MenuBarRefreshPresentationTests: XCTestCase {
    func testIconKeepsAnimatingUntilOAuthAndCostRefreshBothFinish() {
        XCTAssertTrue(MenuBarRefreshPresentation.shouldAnimateIcon(isOpenAIRefreshInProgress: true, isLocalCostRefreshInProgress: false))
        XCTAssertTrue(MenuBarRefreshPresentation.shouldAnimateIcon(isOpenAIRefreshInProgress: false, isLocalCostRefreshInProgress: true))
        XCTAssertFalse(MenuBarRefreshPresentation.shouldAnimateIcon(isOpenAIRefreshInProgress: false, isLocalCostRefreshInProgress: false))
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
