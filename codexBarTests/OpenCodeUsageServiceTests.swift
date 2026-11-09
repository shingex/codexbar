import Foundation
import XCTest

final class OpenCodeUsageServiceTests: CodexBarTestCase {
    func testFetchGoUsageMapsOfficialPercentWindows() async throws {
        let payload = Data(
            """
            {
              "usage": {
                "rolling": {"status": "ok", "percent": 11, "resetsAt": "2026-08-17T17:10:09.580Z"},
                "weekly": {"status": "ok", "percent": 4, "resetsAt": "2026-08-24T00:00:00.580Z"},
                "monthly": {"status": "ok", "percent": 2, "resetsAt": "2026-09-13T04:26:00.580Z"}
              }
            }
            """.utf8
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "opencode.ai")
            XCTAssertEqual(request.url?.path, "/inference/go/v1/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-opencode")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }
        let service = OpenCodeUsageService(urlSession: self.makeMockSession())

        let snapshot = try await service.fetchGoUsage(apiKey: "sk-opencode")
        XCTAssertEqual(snapshot.rolling.percent, 11)
        XCTAssertEqual(snapshot.weekly.percent, 4)
        XCTAssertEqual(snapshot.monthly.percent, 2)
        XCTAssertNotNil(snapshot.rolling.resetsAt)

        let usage = snapshot.providerUsageData
        XCTAssertEqual(usage.unit, "%")
        XCTAssertEqual(usage.planName, "OpenCode Go")
        XCTAssertEqual(usage.isValid, true)
        XCTAssertEqual(usage.today.used, 11)
        XCTAssertEqual(usage.today.limit, 100)
        XCTAssertEqual(usage.today.remaining, 89)
        XCTAssertEqual(usage.weekly.used, 4)
        XCTAssertEqual(usage.monthly.used, 2)
        XCTAssertNotNil(usage.today.resetAt)
        XCTAssertEqual(ProviderUsageFormat.title(for: .today, data: usage), L.openCodeRollingWindowTitle)
        XCTAssertEqual(
            ProviderUsageFormat.displayLabel(for: .today, mode: .remaining, data: usage),
            L.openCodeRollingRemaining
        )
        XCTAssertEqual(
            ProviderUsageFormat.displayLabel(for: .today, mode: .used, data: usage),
            L.openCodeRollingUsed
        )
        XCTAssertEqual(ProviderUsageFormat.multiWindowLabel(for: .today, data: usage), "5h")
        XCTAssertEqual(ProviderUsageFormat.multiWindowLabel(for: .weekly, data: usage), L.zh ? "每周" : "Weekly")
        XCTAssertEqual(ProviderUsageFormat.multiWindowLabel(for: .monthly, data: usage), L.zh ? "每月" : "Monthly")
    }

    func testFetchGoUsageMarksInvalidStatusWindows() async throws {
        let payload = Data(
            #"{"usage":{"rolling":{"status":"limited","percent":100,"resetsAt":"2026-08-17T17:10:09Z"},"weekly":{"status":"ok","percent":4},"monthly":{"status":"ok","percent":2}}}"#.utf8
        )
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }
        let service = OpenCodeUsageService(urlSession: self.makeMockSession())

        let snapshot = try await service.fetchGoUsage(apiKey: "sk-opencode")
        XCTAssertEqual(snapshot.providerUsageData.isValid, false)
        XCTAssertEqual(snapshot.providerUsageData.today.used, 100)
        XCTAssertEqual(snapshot.providerUsageData.today.remaining, 0)
    }
}
