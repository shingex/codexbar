import AppKit
import XCTest

final class MenuBarPopoverSizingTests: XCTestCase {
    func testInitialSizeUsesStableWidthAndDefaultHeight() {
        let size = MenuBarPopoverSizing.initialSize(availableHeight: 1200)

        XCTAssertEqual(size.width, MenuBarStatusItemIdentity.popoverContentWidth)
        XCTAssertEqual(size.height, MenuBarPopoverSizing.defaultHeight)
    }

    func testClampedHeightCapsToAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 2000, availableHeight: 1400),
            1400
        )
    }

    func testClampedHeightFallsBackToConfiguredMaximumWhenAvailableHeightIsUnknown() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 2000, availableHeight: nil),
            MenuBarPopoverSizing.maximumHeight
        )
    }

    func testClampedHeightRespectsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 600, availableHeight: 500),
            500
        )
    }

    func testClampedHeightFollowsShortContentHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(desiredHeight: 100, availableHeight: 200),
            100
        )
    }

    func testStableHeightKeepsCurrentHeightWhenContentOverflows() {
        XCTAssertEqual(
            MenuBarPopoverSizing.stableHeight(
                contentHeight: 2000,
                availableHeight: 700,
                currentHeight: 520
            ),
            520
        )
    }

    func testStableHeightKeepsCurrentHeightWhenContentShrinksDuringSameOpen() {
        XCTAssertEqual(
            MenuBarPopoverSizing.stableHeight(
                contentHeight: 180,
                availableHeight: 700,
                currentHeight: 520
            ),
            520
        )
    }

    func testStableHeightStillRespectsAvailableHeightCap() {
        XCTAssertEqual(
            MenuBarPopoverSizing.stableHeight(
                contentHeight: 700,
                availableHeight: 480,
                currentHeight: 520
            ),
            480
        )
    }

    func testMiddleContentHeightUsesLockedPopoverHeightMinusFixedChrome() {
        XCTAssertEqual(
            MenuBarPopoverSizing.middleContentHeight(lockedContentHeight: 520),
            434
        )
    }

    func testContentHeightLimitCapsToEightyPercentOfVisibleScreenHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.contentHeightLimit(
                availableHeight: 1400,
                visibleScreenHeight: 1000
            ),
            800
        )
    }

    func testContentHeightLimitStillRespectsSpaceBelowStatusItem() {
        XCTAssertEqual(
            MenuBarPopoverSizing.contentHeightLimit(
                availableHeight: 500,
                visibleScreenHeight: 1000
            ),
            500
        )
    }

    func testContentHeightLimitCanUseScreenCapWithoutStatusItemBudget() {
        XCTAssertEqual(
            MenuBarPopoverSizing.contentHeightLimit(
                availableHeight: nil,
                visibleScreenHeight: 1000
            ),
            800
        )
    }

    func testPreservingTopScrollOriginKeepsFlippedOffsetStable() {
        XCTAssertEqual(
            MenuBarPopoverSizing.preservingTopScrollOriginY(
                topOffset: 42,
                documentHeight: 900,
                viewportHeight: 360,
                isFlipped: true
            ),
            42
        )
    }

    func testPreservingTopScrollOriginClampsWhenContentShrinks() {
        XCTAssertEqual(
            MenuBarPopoverSizing.preservingTopScrollOriginY(
                topOffset: 600,
                documentHeight: 500,
                viewportHeight: 360,
                isFlipped: true
            ),
            140
        )
    }

    func testPreservingTopScrollOriginHandlesNonFlippedCoordinates() {
        XCTAssertEqual(
            MenuBarPopoverSizing.preservingTopScrollOriginY(
                topOffset: 80,
                documentHeight: 900,
                viewportHeight: 360,
                isFlipped: false
            ),
            460
        )
    }

    func testFlexibleSectionHeightCapReturnsRemainingBudgetForScrollableSection() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 260,
                availableHeight: 520
            ),
            160
        )
    }

    func testFlexibleSectionHeightCapFloorsToMinimumHeightWhenFixedChromeExceedsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 120,
                availableHeight: 400
            ),
            MenuBarPopoverSizing.minimumHeight
        )
    }

    func testFlexibleSectionHeightCapReturnsNilWithoutAvailableHeight() {
        XCTAssertNil(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 260,
                availableHeight: nil
            )
        )
    }

    func testFlexibleSectionHeightCapPrioritizesKeepingFixedChromeVisibleWhenBannerAppears() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 708,
                flexibleSectionHeight: 248,
                availableHeight: 520
            ),
            60
        )
    }

    func testFlexibleSectionHeightCapUsesMaximumAvailableHeightInsteadOfInitialPopoverHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 708,
                flexibleSectionHeight: 248,
                availableHeight: 700
            ),
            240
        )
    }
}
