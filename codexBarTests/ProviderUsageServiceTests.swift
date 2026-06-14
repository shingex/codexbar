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
            let data = Data(#"{"remaining":8.5,"subscription":{"daily_usage_usd":1.5,"daily_limit_usd":10,"weekly_limit_usd":0,"monthly_limit_usd":0}}"#.utf8)
            return (response, data)
        }

        let result = try await ProviderUsageService(urlSession: self.makeMockSession()).fetch(
            provider: provider,
            account: account,
            configuration: CodexBarProviderUsageConfiguration()
        )

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.data?.remaining, 8.5)
        XCTAssertEqual(try XCTUnwrap(result.data?.today.usageRatio), 0.15, accuracy: 0.0001)
        XCTAssertNil(result.data?.weekly.usageRatio)
        XCTAssertNil(result.data?.monthly.usageRatio)
    }

    func testNormalizerParsesMimoTokenPlanUsageResponse() throws {
        let object: [String: Any] = [
            "code": 0,
            "data": [
                "usage": [
                    "items": [
                        ["name": "plan_total_token", "used": 3_000_000_000, "limit": 10_000_000_000],
                        ["name": "compensation_total_token", "used": 1_000_000_000, "limit": 2_000_000_000],
                        ["name": "irrelevant_token", "used": 5_000_000_000, "limit": 5_000_000_000],
                    ]
                ]
            ],
        ]

        let usage = try ProviderUsageNormalizer().normalize(jsonObject: object)

        XCTAssertEqual(usage.isValid, true)
        XCTAssertEqual(usage.unit, "B Credits")
        XCTAssertEqual(usage.remaining, 8.0)
        XCTAssertEqual(usage.monthly.used, 4.0)
        XCTAssertEqual(usage.monthly.limit, 12.0)
        XCTAssertEqual(usage.totalUsed, 4.0)
        XCTAssertEqual(usage.planName, "MiMo Token Plan")
        XCTAssertEqual(try XCTUnwrap(usage.monthly.usageRatio), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ProviderUsageFormat.availableWindows(for: usage), [.monthly])
        XCTAssertFalse(usage.isBalanceOnly)
    }

    func testMimoCookieHeaderIsNormalizedBeforeSending() async throws {
        let provider = CodexBarProvider(
            id: "mimo",
            kind: .openAICompatible,
            label: "MiMo",
            baseURL: "https://api.xiaomimimo.com/v1",
            thirdPartyModelProvider: .mimo
        )
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: "Default",
            apiKey: " serviceToken = abc ; userId = def\n"
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "serviceToken=abc; userId=def")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"code":0,"data":{"usage":{"items":[{"name":"plan_total_token","used":1,"limit":2}]}}}"#.utf8))
        }

        _ = try await ProviderUsageService(urlSession: self.makeMockSession()).fetch(
            provider: provider,
            account: account,
            configuration: CodexBarProviderUsageConfiguration()
        )
    }

    func testMimoProviderUsesTokenPlanUsageURLAndCookieHeader() async throws {
        let provider = CodexBarProvider(
            id: "mimo",
            kind: .openAICompatible,
            label: "MiMo",
            baseURL: "https://api.xiaomimimo.com/v1",
            thirdPartyModelProvider: .mimo
        )
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: "Default",
            apiKey: "tp-mimo-token-plan-key"
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "serviceToken=abc; userId=def")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://platform.xiaomimimo.com/console/plan-manage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://platform.xiaomimimo.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"code":0,"data":{"usage":{"items":[{"name":"plan_total_token","used":1500000,"limit":5000000},{"name":"compensation_total_token","used":500000,"limit":1000000}]}}}"#.utf8
            )
            return (response, data)
        }

        let result = try await ProviderUsageService(urlSession: self.makeMockSession()).fetch(
            provider: provider,
            account: account,
            configuration: CodexBarProviderUsageConfiguration(
                requestHeaders: ["Cookie": "serviceToken=abc; userId=def"]
            )
        )

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.data?.unit, "M Credits")
        XCTAssertEqual(result.data?.remaining, 4.0)
        XCTAssertEqual(result.data?.monthly.used, 2.0)
        XCTAssertEqual(result.data?.monthly.limit, 6.0)
    }

}
