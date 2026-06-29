import Foundation
import XCTest

final class CodexResetCreditServiceTests: CodexBarTestCase {
    func testSanitizedSnapshotKeepsAvailableCreditsSortedByLocalExpiration() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

        let snapshot = CodexResetCreditService.sanitizedSnapshot(
            from: [
                "available_count": 2,
                "credits": [
                    [
                        "id": "credit-later",
                        "status": "available",
                        "reset_type": "codex_rate_limits",
                        "expires_at": "2026-07-16T07:51:44Z",
                    ],
                    [
                        "id": "credit-used",
                        "status": "redeemed",
                        "reset_type": "codex_rate_limits",
                        "expires_at": "2026-07-15T07:51:44Z",
                    ],
                    [
                        "id": "credit-earlier",
                        "status": "available",
                        "reset_type": "codex_rate_limits",
                        "expires_at": "2026-07-14T07:51:44Z",
                    ],
                ],
            ],
            queriedAt: Date(timeIntervalSince1970: 1_780_000_000),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.credits.map(\.id), ["-earlier", "it-later"])
        XCTAssertEqual(snapshot.credits.first?.status, "available")
        XCTAssertEqual(snapshot.credits.first?.expiresAt?.timeLocal, "2026-07-14 15:51:44 GMT+8")
    }

    func testFetchSendsOAuthHeadersAndReturnsSanitizedSnapshot() async throws {
        let service = CodexResetCreditService(
            endpoint: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            urlSession: self.makeMockSession(),
            now: { Date(timeIntervalSince1970: 1_780_000_000) }
        )
        let account = TokenAccount(
            accountId: "local-account",
            openAIAccountId: "remote-account",
            accessToken: "access-token"
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "remote-account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "Codex Desktop")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OAI-Product-Sku"), "CODEX")

            let data = Data(
                """
                {
                  "available_count": 1,
                  "credits": [
                    {
                      "id": "reset-credit-12345678",
                      "status": "available",
                      "reset_type": "codex_rate_limits",
                      "expires_at": "2026-07-16T07:51:44Z"
                    }
                  ]
                }
                """.utf8
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        let result = try await service.fetch(account: account)

        XCTAssertEqual(result.snapshot.availableCount, 1)
        XCTAssertEqual(result.snapshot.credits.first?.id, "12345678")
        XCTAssertEqual(result.snapshot.queriedAt, Date(timeIntervalSince1970: 1_780_000_000))
    }

    func testFetchTreats401AsAuthorizationFailure() async throws {
        let service = CodexResetCreditService(urlSession: self.makeMockSession())
        let account = TokenAccount(accountId: "local-account", accessToken: "access-token")
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        do {
            _ = try await service.fetch(account: account)
            XCTFail("Expected authorization failure")
        } catch let error as CodexResetCreditError {
            XCTAssertEqual(error, .authorizationFailed)
        }
    }

    func testCacheRoundTripUsesCodexBarCacheFile() throws {
        let cacheURL = CodexPaths.resetCreditCacheURL
        let service = CodexResetCreditService(cacheURL: cacheURL)
        let snapshot = CodexResetCreditSnapshot(
            queriedAt: Date(timeIntervalSince1970: 1_780_000_000),
            availableCount: 1,
            credits: [
                CodexResetCredit(
                    id: "12345678",
                    status: "available",
                    resetType: "codex_rate_limits",
                    expiresAt: CodexResetCreditDateTime(
                        dateLocal: "2026-07-16",
                        timeLocal: "2026-07-16 15:51:44 CST",
                        timeUTC: "2026-07-16 07:51:44 UTC"
                    )
                ),
            ]
        )

        try service.saveCache(CodexResetCreditCache(snapshotsByAccountID: ["acct": snapshot]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(service.loadCache().snapshotsByAccountID["acct"], snapshot)
    }
}
