import Foundation
import XCTest

final class WhamServiceParsingTests: XCTestCase {
    func testPlusAccountKeepsFiveHourPrimaryAndSevenDaySecondary() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0.0,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_775_372_003.0,
                ],
                "secondary_window": [
                    "used_percent": 100.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_690_771.0,
                ],
            ],
        ])

        XCTAssertEqual(result.primaryLimitWindowSeconds, 18_000)
        XCTAssertEqual(result.secondaryLimitWindowSeconds, 604_800)
        XCTAssertEqual(result.primaryUsedPercent, 0)
        XCTAssertEqual(result.secondaryUsedPercent, 100)
    }

    func testFreeAccountTreatsPrimaryAsWeeklyWhenApiSaysSevenDays() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "free",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 100.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_860_349.0,
                ],
                "secondary_window": NSNull(),
            ],
        ])

        XCTAssertEqual(result.primaryLimitWindowSeconds, 604_800)
        XCTAssertNil(result.secondaryLimitWindowSeconds)
        XCTAssertEqual(result.primaryUsedPercent, 100)
        XCTAssertEqual(result.secondaryUsedPercent, 0)
    }

    func testSecondaryWindowDurationIsPreservedEvenWhenUsageIsZero() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0.0,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_775_372_003.0,
                ],
                "secondary_window": [
                    "used_percent": 0.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_690_771.0,
                ],
            ],
        ])

        XCTAssertEqual(result.secondaryLimitWindowSeconds, 604_800)
        XCTAssertEqual(result.secondaryUsedPercent, 0)
        XCTAssertNotNil(result.secondaryResetAt)
    }

    func testMissingFiveHourWindowKeepsOnlyWeeklyLimit() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": NSNull(),
                "secondary_window": [
                    "used_percent": 36.0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_775_690_771.0,
                ],
            ],
        ])

        XCTAssertNil(result.primaryLimitWindowSeconds)
        XCTAssertNil(result.primaryResetAt)
        XCTAssertEqual(result.secondaryLimitWindowSeconds, 604_800)
        XCTAssertEqual(result.secondaryUsedPercent, 36)
    }

    func testMonthlyLimitWindowDurationIsPreserved() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 18.0,
                    "limit_window_seconds": 30 * 86_400,
                    "reset_at": 1_777_677_120.0,
                ],
                "secondary_window": NSNull(),
            ],
        ])

        XCTAssertEqual(result.primaryLimitWindowSeconds, 30 * 86_400)
        XCTAssertEqual(result.primaryUsedPercent, 18)
        XCTAssertNil(result.secondaryLimitWindowSeconds)
    }
}
