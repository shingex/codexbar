import Foundation
import XCTest

final class UsageHTTPRefreshClientTests: CodexBarTestCase {
    func testCooldownHonorsServerGuidanceAndEscalatesRateLimits() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(UsageHTTPRefreshClient.cooldown(status: 200, retryAfter: nil, failures: 0, now: now), 5)
        XCTAssertEqual(UsageHTTPRefreshClient.cooldown(status: 429, retryAfter: nil, failures: 1, now: now), 900)
        XCTAssertEqual(UsageHTTPRefreshClient.cooldown(status: 429, retryAfter: nil, failures: 2, now: now), 1800)
        XCTAssertEqual(UsageHTTPRefreshClient.cooldown(status: 429, retryAfter: "7200", failures: 3, now: now), 7200)
        XCTAssertEqual(UsageHTTPRefreshClient.cooldown(status: 403, retryAfter: nil, failures: 1, now: now), 1800)
        XCTAssertEqual(UsageHTTPRefreshClient.cooldown(status: 429, retryAfter: "invalid", failures: 1, now: now), 900)
    }

    func testRepeatedUsageReadsShareOneNetworkRequest() async throws {
        let client = UsageHTTPRefreshClient()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var calls = 0
        MockURLProtocol.handler = { request in
            calls += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let request = URLRequest(url: URL(string: "https://usage.example.test/usage")!)
        _ = try await client.data(for: request, using: session)
        _ = try await client.data(for: request, using: session)
        XCTAssertEqual(calls, 1)
    }
}
