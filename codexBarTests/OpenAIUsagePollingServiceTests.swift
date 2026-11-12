import Foundation
import XCTest

final class OpenAIUsagePollingServiceTests: XCTestCase {
    func testPollingIncludesEveryStaleOrUnfetchedOAuthAccount() {
        let now = Date(timeIntervalSince1970: 100)
        let accounts = [
            TokenAccount(email: "active@example.com", accountId: "active", lastChecked: now, isActive: true),
            TokenAccount(email: "stale@example.com", accountId: "stale", lastChecked: now.addingTimeInterval(-80)),
            TokenAccount(email: "new@example.com", accountId: "new"),
            TokenAccount(email: "expired@example.com", accountId: "expired", tokenExpired: true),
            TokenAccount(email: "suspended@example.com", accountId: "suspended", isSuspended: true)
        ]

        XCTAssertEqual(OpenAIUsagePollingPolicy.accountsToRefresh(accounts: accounts, now: now, maxAge: 60)
            .map(\.accountId), ["stale", "new"])
    }

    func testExplicitRefreshIncludesFreshSelectedAccount() {
        let now = Date(timeIntervalSince1970: 100)
        let account = TokenAccount(email: "selected@example.com", accountId: "selected", lastChecked: now)
        XCTAssertEqual(OpenAIUsagePollingPolicy.accountsToRefresh(
            accounts: [account], now: now, maxAge: 60, forcedAccountID: account.accountId
        ).map(\.accountId), [account.accountId])
    }
}
