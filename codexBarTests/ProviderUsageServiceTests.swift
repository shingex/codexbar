import Foundation
import XCTest

final class ProviderUsageServiceTests: CodexBarTestCase {
    func testProviderUsageWarningLevelUsesOpenAIRemainingThresholds() {
        XCTAssertEqual(
            ProviderUsageVisualStyle.warningLevel(
                for: CodexBarProviderUsagePeriod(used: 225, limit: 300)
            ),
            .normal
        )
        XCTAssertEqual(
            ProviderUsageVisualStyle.warningLevel(
                for: CodexBarProviderUsagePeriod(used: 225.9, limit: 300)
            ),
            .warning
        )
        XCTAssertEqual(
            ProviderUsageVisualStyle.warningLevel(
                for: CodexBarProviderUsagePeriod(used: 270, limit: 300)
            ),
            .critical
        )
        XCTAssertEqual(
            ProviderUsageVisualStyle.warningLevel(
                for: CodexBarProviderUsagePeriod(used: 300, limit: 300)
            ),
            .critical
        )
    }

    func testNormalizerRecognizesInputUsageShapeAndUnlimitedPeriods() throws {
        let object: [String: Any] = [
            "remaining": 8.5,
            "subscription": [
                "daily_usage_usd": 1.5,
                "daily_limit_usd": 10,
                "weekly_limit_usd": 0,
                "monthly_limit_usd": 0,
                "planName": "Pro",
            ],
        ]

        let usage = try ProviderUsageNormalizer().normalize(jsonObject: object)

        XCTAssertEqual(usage.unit, "USD")
        XCTAssertEqual(usage.remaining, 8.5)
        XCTAssertEqual(usage.today.used, 1.5)
        XCTAssertEqual(usage.today.limit, 10)
        XCTAssertEqual(try XCTUnwrap(usage.today.usageRatio), 0.15, accuracy: 0.0001)
        XCTAssertNil(usage.weekly.usageRatio)
        XCTAssertNil(usage.monthly.usageRatio)
        XCTAssertEqual(usage.planName, "Pro")
    }

    func testNormalizerUsesTodayItemFromDailyUsageArray() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_779_292_800) // 2026-05-20T00:00:00Z
        let object: [String: Any] = [
            "daily_usage": [
                ["date": "2026-05-19", "actual_cost": 2.1],
                ["date": "2026-05-20", "cost": 3.2],
            ],
            "daily": ["limit": 8],
        ]

        let usage = try ProviderUsageNormalizer(calendar: calendar, now: { now }).normalize(jsonObject: object)

        XCTAssertEqual(usage.today.used, 3.2)
        XCTAssertEqual(usage.today.limit, 8)
    }

    func testServiceSendsAuthorizationHeaderAndUsesBaseURLDefault() async throws {
        let provider = CodexBarProvider(
            id: "ai-input",
            kind: .openAICompatible,
            label: "AI Input",
            baseURL: "https://ai.input.im/v1"
        )
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: "Default",
            apiKey: "sk-provider"
        )
        let configuration = CodexBarProviderUsageConfiguration()

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ai.input.im/v1/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexBar/1.0")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":8.5,"subscription":{"daily_usage_usd":1.5,"daily_limit_usd":10,"weekly_limit_usd":0,"monthly_limit_usd":0}}"#.utf8
            )
            return (response, data)
        }

        let result = try await ProviderUsageService(urlSession: self.makeMockSession()).fetch(
            provider: provider,
            account: account,
            configuration: configuration
        )

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.data?.remaining, 8.5)
        XCTAssertEqual(try XCTUnwrap(result.data?.today.usageRatio), 0.15, accuracy: 0.0001)
        XCTAssertNil(result.data?.weekly.usageRatio)
        XCTAssertNil(result.data?.monthly.usageRatio)
    }

    func testServiceReturnsUnableToDetectFieldsWithoutCrashing() async throws {
        let provider = CodexBarProvider(
            id: "ai-input",
            kind: .openAICompatible,
            label: "AI Input",
            baseURL: "https://ai.input.im/v1"
        )
        let account = CodexBarProviderAccount(kind: .apiKey, label: "Default", apiKey: "sk-provider")

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"balance":99}"#.utf8))
        }

        let result = try await ProviderUsageService(urlSession: self.makeMockSession()).fetch(
            provider: provider,
            account: account,
            configuration: CodexBarProviderUsageConfiguration()
        )

        XCTAssertNil(result.data)
        XCTAssertEqual(result.errorMessage, ProviderUsageError.unableToDetectFields.localizedDescription)
        XCTAssertEqual(result.rawResponse, #"{"balance":99}"#)
    }

    func testServiceMapsAuthFailure() async {
        let provider = CodexBarProvider(
            id: "ai-input",
            kind: .openAICompatible,
            label: "AI Input",
            baseURL: "https://ai.input.im/v1"
        )
        let account = CodexBarProviderAccount(kind: .apiKey, label: "Default", apiKey: "sk-provider")

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await ProviderUsageService(urlSession: self.makeMockSession()).fetch(
                provider: provider,
                account: account,
                configuration: CodexBarProviderUsageConfiguration()
            )
            XCTFail("Expected authorization failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Authorization failed")
        }
    }
}
