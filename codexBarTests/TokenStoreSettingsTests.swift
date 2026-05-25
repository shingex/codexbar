import Foundation
import XCTest

@MainActor
final class TokenStoreSettingsTests: CodexBarTestCase {
    func testInitializationRebuildsLocalCostSummaryWhenCacheIsMissing() throws {
        let fixture = Self.recentCostFixtureTimestamps()
        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-rebuild.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-rebuild","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"\#(fixture.firstUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"\#(fixture.secondUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        let timeout = Date().addingTimeInterval(3)
        while store.localCostSummary.updatedAt == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.todayTokens, 0)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 230)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 230)
        XCTAssertEqual(store.localCostSummary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 230)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].costUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.costCacheURL.path))
    }

    func testInitializationSeedsHistoricalModelsFromConfigThenRefreshesInBackground() throws {
        var config = CodexBarConfig()
        config.modelPricing = [
            "google/gemini-2.5-pro": CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            ),
        ]
        try self.writeConfig(config)

        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("historical-models.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"historical-models","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-historical-models-session-cache.json"),
            persistedUsageLedgerURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-historical-models-ledger.json")
        )

        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertEqual(store.historicalModels, ["google/gemini-2.5-pro"])

        let timeout = Date().addingTimeInterval(3)
        while Set(store.historicalModels) != Set(["google/gemini-2.5-pro", "gpt-5.4"]) && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(Set(store.historicalModels), Set(["google/gemini-2.5-pro", "gpt-5.4"]))
    }

    func testSaveModelPricingSettingsPersistsAcrossReload() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveModelPricingSettings(
            ModelPricingSettingsUpdate(
                upserts: [
                    "gpt-5.4": CodexBarModelPricing(
                        inputUSDPerToken: 9.9e-6,
                        cachedInputUSDPerToken: 9.9e-7,
                        outputUSDPerToken: 2.4e-5
                    ),
                ],
                removals: []
            )
        )

        XCTAssertEqual(
            store.config.modelPricing["gpt-5.4"],
            CodexBarModelPricing(
                inputUSDPerToken: 9.9e-6,
                cachedInputUSDPerToken: 9.9e-7,
                outputUSDPerToken: 2.4e-5
            )
        )

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(
            reloaded.modelPricing["gpt-5.4"],
            CodexBarModelPricing(
                inputUSDPerToken: 9.9e-6,
                cachedInputUSDPerToken: 9.9e-7,
                outputUSDPerToken: 2.4e-5
            )
        )
    }

    func testSaveModelPricingSettingsSanitizesNonFiniteValues() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveModelPricingSettings(
            ModelPricingSettingsUpdate(
                upserts: [
                    "gpt-5.4": CodexBarModelPricing(
                        inputUSDPerToken: .infinity,
                        cachedInputUSDPerToken: -1,
                        outputUSDPerToken: 2.4e-5
                    ),
                ],
                removals: []
            )
        )

        XCTAssertEqual(
            store.config.modelPricing["gpt-5.4"],
            CodexBarModelPricing(
                inputUSDPerToken: 0,
                cachedInputUSDPerToken: 0,
                outputUSDPerToken: 2.4e-5
            )
        )
    }

    func testInitializationRebuildsLocalCostSummaryWhenCachedSummaryIsZeroButLedgerExists() throws {
        let fixture = Self.recentCostFixtureTimestamps()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-zero-cache.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-zero-cache","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"\#(fixture.firstUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"\#(fixture.secondUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let sessionStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: root.appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: root.appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
        _ = LocalCostSummaryService(sessionLogStore: sessionStore).load(
            now: ISO8601Parsing.parse("2026-04-05T12:00:00Z") ?? Date()
        )

        let zeroSummary = LocalCostSummary(
            todayCostUSD: 0,
            todayTokens: 0,
            last30DaysCostUSD: 0,
            last30DaysTokens: 0,
            lifetimeCostUSD: 0,
            lifetimeTokens: 0,
            dailyEntries: [],
            updatedAt: ISO8601Parsing.parse("2026-04-20T10:10:00Z")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(zeroSummary),
            to: CodexPaths.costCacheURL
        )
        let ledgerData = try Data(contentsOf: root.appendingPathComponent(".codexbar/test-cost-event-ledger.json"))
        try CodexPaths.writeSecureFile(ledgerData, to: CodexPaths.costEventLedgerURL)

        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        let timeout = Date().addingTimeInterval(3)
        while store.localCostSummary.updatedAt == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 230)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 230)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 230)
    }

    func testInitializationRebuildsLocalCostSummaryWhenCachedSummaryIsFromPreviousLocalDay() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cross-day-cost.jsonl")
        let todayStart = Calendar.current.startOfDay(for: Date())
        let usageAt = todayStart.addingTimeInterval(60 * 60)
        let usageAtString = ISO8601DateFormatter().string(from: usageAt)
        let content = [
            #"{"payload":{"type":"session_meta","id":"cross-day-cost","timestamp":"\#(usageAtString)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"\#(usageAtString)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let staleSummary = LocalCostSummary(
            todayCostUSD: 9.99,
            todayTokens: 999,
            last30DaysCostUSD: 9.99,
            last30DaysTokens: 999,
            lifetimeCostUSD: 9.99,
            lifetimeTokens: 999,
            dailyEntries: [
                DailyCostEntry(
                    id: "stale",
                    date: todayStart.addingTimeInterval(-86_400),
                    costUSD: 9.99,
                    totalTokens: 999
                ),
            ],
            updatedAt: todayStart.addingTimeInterval(-60)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(staleSummary),
            to: CodexPaths.costCacheURL
        )

        let sessionStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: root.appendingPathComponent(".codexbar/test-cross-day-session-cache.json"),
            persistedUsageLedgerURL: root.appendingPathComponent(".codexbar/test-cross-day-ledger.json")
        )
        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 150, timeout: 3))
        XCTAssertEqual(store.localCostSummary.todayTokens, 150)
        XCTAssertEqual(store.localCostSummary.dailyEntries.first?.date, todayStart)
    }

    func testPreviousDayNonEmptyLocalCostSummaryStaysVisibleWhenRefreshReturnsEmpty() throws {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let cachedSummary = LocalCostSummary(
            todayCostUSD: 9.99,
            todayTokens: 999,
            last30DaysCostUSD: 9.99,
            last30DaysTokens: 999,
            lifetimeCostUSD: 9.99,
            lifetimeTokens: 999,
            dailyEntries: [
                DailyCostEntry(
                    id: "stale",
                    date: todayStart.addingTimeInterval(-86_400),
                    costUSD: 9.99,
                    totalTokens: 999
                ),
            ],
            updatedAt: todayStart.addingTimeInterval(-60)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(cachedSummary),
            to: CodexPaths.costCacheURL
        )

        let service = LocalCostSummaryServiceSpy(summaries: [.empty, .empty])
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertEqual(store.localCostSummary.todayTokens, 999)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 999)
        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))

        service.resumeNext()
        XCTAssertTrue(service.waitForStartedCallCount(2, timeout: 1))
        XCTAssertEqual(store.localCostSummary.todayTokens, 999)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 999)

        service.resumeNext()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store.localCostSummary.todayTokens, 999)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 999)

        let data = try Data(contentsOf: CodexPaths.costCacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedSummary = try decoder.decode(LocalCostSummary.self, from: data)
        XCTAssertEqual(persistedSummary.todayTokens, 999)
        XCTAssertEqual(persistedSummary.lifetimeTokens, 999)
    }

    func testForceLocalCostSummaryRefreshQueuesSingleFollowUpWhileRefreshIsRunning() throws {
        let service = LocalCostSummaryServiceSpy(
            summaries: [
                Self.makeSummary(tokens: 100),
                Self.makeSummary(tokens: 200),
            ]
        )
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        store.refreshLocalCostSummary(force: true, minimumInterval: 0)
        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))

        store.refreshLocalCostSummary(force: true, minimumInterval: 0)
        store.refreshLocalCostSummary(force: true, minimumInterval: 0)
        XCTAssertFalse(service.waitForStartedCallCount(2, timeout: 0.1))

        service.resumeNext()
        XCTAssertTrue(service.waitForStartedCallCount(2, timeout: 1))
        XCTAssertFalse(service.waitForStartedCallCount(3, timeout: 0.1))

        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 200, timeout: 1))
        XCTAssertEqual(service.loadCallCount, 2)
    }

    func testLocalCostSummaryRefreshPublishesBackgroundRefreshState() throws {
        let service = LocalCostSummaryServiceSpy(
            summaries: [
                Self.makeSummary(tokens: 100),
                Self.makeSummary(tokens: 200),
            ]
        )
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        store.refreshLocalCostSummary(force: true, minimumInterval: 0)
        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        XCTAssertTrue(self.waitForLocalCostRefreshState(store, isRefreshing: true, timeout: 1))

        service.resumeNext()
        if service.waitForStartedCallCount(2, timeout: 0.2) {
            service.resumeNext()
            XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 200, timeout: 1))
        } else {
            XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 100, timeout: 1))
        }
        XCTAssertTrue(self.waitForLocalCostRefreshState(store, isRefreshing: false, timeout: 1))
    }

    func testPendingThrottledLocalCostSummaryRefreshClearsBackgroundRefreshState() throws {
        let service = LocalCostSummaryServiceSpy(
            summaries: [
                Self.makeSummary(tokens: 50, updatedAt: Date()),
                Self.makeSummary(tokens: 100, updatedAt: Date()),
            ]
        )
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 50, timeout: 1))
        XCTAssertTrue(self.waitForLocalCostRefreshState(store, isRefreshing: false, timeout: 1))

        store.refreshLocalCostSummary(force: true, minimumInterval: 0)
        XCTAssertTrue(service.waitForStartedCallCount(2, timeout: 1))
        XCTAssertTrue(self.waitForLocalCostRefreshState(store, isRefreshing: true, timeout: 1))

        store.refreshLocalCostSummary(force: false, minimumInterval: 60)
        service.resumeNext()

        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 100, timeout: 1))
        XCTAssertFalse(service.waitForStartedCallCount(3, timeout: 0.2))
        XCTAssertTrue(self.waitForLocalCostRefreshState(store, isRefreshing: false, timeout: 1))
    }

    func testNonForcedLocalCostSummaryRefreshDefersWhileGatewayIsBusy() throws {
        let service = LocalCostSummaryServiceSpy(summaries: [Self.makeSummary(tokens: 100)])
        let gateway = OpenAIAccountGatewayControllerStub()
        gateway.isHandlingHighFrequencyRequestsValue = true
        let store = self.makeTokenStore(
            costSummaryService: service,
            openAIAccountGatewayService: gateway,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 100, timeout: 1))

        store.refreshLocalCostSummary(force: false, minimumInterval: 0, refreshSessionCache: true)

        XCTAssertFalse(service.waitForStartedCallCount(2, timeout: 0.2))
        XCTAssertTrue(self.waitForLocalCostRefreshState(store, isRefreshing: false, timeout: 1))
    }

    func testForcedLocalCostSummaryRefreshBypassesGatewayBusyDeferral() throws {
        let service = LocalCostSummaryServiceSpy(
            summaries: [
                Self.makeSummary(tokens: 100),
                Self.makeSummary(tokens: 200),
            ]
        )
        let gateway = OpenAIAccountGatewayControllerStub()
        gateway.isHandlingHighFrequencyRequestsValue = true
        let store = self.makeTokenStore(
            costSummaryService: service,
            openAIAccountGatewayService: gateway,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 100, timeout: 1))

        store.refreshLocalCostSummary(force: true, minimumInterval: 0, refreshSessionCache: true)

        XCTAssertTrue(service.waitForStartedCallCount(2, timeout: 1))
        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 200, timeout: 1))
    }

    func testLocalCostSummaryDueRefreshSkipsFreshSameDayCache() throws {
        let cachedSummary = Self.makeSummary(tokens: 100, updatedAt: Date())
        try self.writeLocalCostSummaryCache(cachedSummary)
        let service = LocalCostSummaryServiceSpy(summaries: [.empty])
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 100)

        store.refreshLocalCostSummaryIfDue(minimumInterval: 5 * 60)

        XCTAssertFalse(service.waitForStartedCallCount(1, timeout: 0.2))
    }

    func testLocalCostSummaryDueRefreshScansSessionCacheAfterMinimumInterval() throws {
        let cachedSummary = Self.makeSummary(tokens: 100, updatedAt: Date().addingTimeInterval(-10 * 60))
        try self.writeLocalCostSummaryCache(cachedSummary)
        let service = LocalCostSummaryServiceSpy(summaries: [
            Self.makeSummary(tokens: 200, updatedAt: Date()),
        ])
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 100)

        store.refreshLocalCostSummaryIfDue(minimumInterval: 5 * 60)

        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 200, timeout: 1))
        XCTAssertEqual(service.refreshSessionCacheFlags, [true])
    }

    func testStaleNonForcedLocalCostSummaryRefreshScansNewSessionFiles() throws {
        let fixture = Self.todayCostFixtureTimestamps()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let staleSummary = LocalCostSummary(
            todayCostUSD: 0,
            todayTokens: 0,
            last30DaysCostUSD: 0,
            last30DaysTokens: 0,
            lifetimeCostUSD: 0,
            lifetimeTokens: 0,
            dailyEntries: [],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(staleSummary),
            to: CodexPaths.costCacheURL
        )

        let sessionStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: root.appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: root.appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
        _ = LocalCostSummaryService(sessionLogStore: sessionStore).load(
            now: ISO8601Parsing.parse("2026-05-18T12:00:00Z") ?? Date()
        )

        let sessionContent = [
            #"{"payload":{"type":"session_meta","id":"today-cost","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"\#(fixture.usageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30}}}}"#,
        ].joined(separator: "\n") + "\n"
        try sessionContent.write(
            to: sessionDirectory.appendingPathComponent("today-cost.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        store.refreshLocalCostSummary(force: false, minimumInterval: 0, refreshSessionCache: true)

        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 150, timeout: 2))
        XCTAssertEqual(store.localCostSummary.todayTokens, 150)
        XCTAssertEqual(store.localCostSummary.dailyEntries.first?.totalTokens, 150)
    }

    func testEmptyLocalCostSummaryRefreshDoesNotOverwriteExistingNonEmptySummary() throws {
        let cachedSummary = Self.makeSummary(tokens: 456)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(cachedSummary),
            to: CodexPaths.costCacheURL
        )

        let service = LocalCostSummaryServiceSpy(summaries: [.empty])
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 456)

        store.refreshLocalCostSummary(force: true, minimumInterval: 0, refreshSessionCache: true)
        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        service.resumeNext()

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, service.loadCallCount < 1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store.localCostSummary.todayTokens, 456)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 456)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 456)

        let data = try Data(contentsOf: CodexPaths.costCacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedSummary = try decoder.decode(LocalCostSummary.self, from: data)
        XCTAssertEqual(persistedSummary.todayTokens, 456)
        XCTAssertEqual(persistedSummary.last30DaysTokens, 456)
        XCTAssertEqual(persistedSummary.lifetimeTokens, 456)
    }

    func testLoadDoesNotClearExistingNonEmptySummaryWhenCacheIsEmpty() throws {
        let nonEmptySummary = Self.makeSummary(tokens: 789)
        let service = LocalCostSummaryServiceSpy(summaries: [nonEmptySummary])
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        store.refreshLocalCostSummary(force: true, minimumInterval: 0, refreshSessionCache: true)
        XCTAssertTrue(service.waitForStartedCallCount(1, timeout: 1))
        service.resumeNext()
        XCTAssertTrue(self.waitForLocalCostSummary(store, tokens: 789, timeout: 1))

        let emptySummary = LocalCostSummary(
            todayCostUSD: 0,
            todayTokens: 0,
            last30DaysCostUSD: 0,
            last30DaysTokens: 0,
            lifetimeCostUSD: 0,
            lifetimeTokens: 0,
            dailyEntries: [],
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(emptySummary),
            to: CodexPaths.costCacheURL
        )

        store.load()

        XCTAssertEqual(store.localCostSummary.todayTokens, 789)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 789)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 789)
        XCTAssertTrue(service.waitForStartedCallCount(2, timeout: 1))
        service.resumeNext()
    }

    func testSaveOpenAIAccountSettingsWritesAccountOrderAndMode() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_beta", email: "beta@example.com"))

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual
            )
        )

        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
    }

    func testSaveSettingsDoesNotApplyRouteUntilRouteTargetIsApplied() throws {
        let oauthAccount = try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com", isActive: true)
        var config = CodexBarConfig()
        _ = config.upsertOAuthAccount(oauthAccount, activate: true)
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha"],
                accountUsageMode: .aggregateGateway,
                accountOrderingMode: .manual
            )
        )

        XCTAssertEqual(store.config.openAI.accountUsageMode, .aggregateGateway)
        XCTAssertEqual(store.config.activeProvider()?.kind, .openAIOAuth)

        let applied = try store.applySettingsRouteTarget(.openAIAccount(accountID: "acct_alpha"))

        XCTAssertTrue(applied)
        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(store.activeAccount()?.accountId, "acct_alpha")
    }

    func testSaveOpenAIUsageSettingsOnlyTouchesUsageFields() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual
            )
        )

        try store.saveOpenAIUsageSettings(
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                disableLocalUsageStats: true,
                plusRelativeWeight: 6,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2
            )
        )

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .remaining)
        XCTAssertTrue(store.config.openAI.disableLocalUsageStats)
        XCTAssertEqual(store.config.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(store.config.openAI.quotaSort.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(store.config.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)
        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
    }

    func testSaveUsageDisplayModePersistsOnlyDisplayMode() throws {
        var config = CodexBarConfig()
        config.openAI.usageDisplayMode = .remaining
        config.openAI.disableLocalUsageStats = true
        config.openAI.quotaSort = CodexBarOpenAISettings.QuotaSortSettings(
            plusRelativeWeight: 6,
            proRelativeToPlusMultiplier: 14,
            teamRelativeToPlusMultiplier: 2
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveUsageDisplayMode(.used)

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .used)
        XCTAssertTrue(store.config.openAI.disableLocalUsageStats)
        XCTAssertEqual(store.config.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(store.config.openAI.quotaSort.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(store.config.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)

        let persisted = try CodexBarConfigStore().load()
        XCTAssertEqual(persisted.openAI.usageDisplayMode, .used)
        XCTAssertTrue(persisted.openAI.disableLocalUsageStats)
        XCTAssertEqual(persisted.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(persisted.openAI.quotaSort.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(persisted.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)
    }

    func testDisablingLocalUsageStatsSkipsLocalCostSummaryRefresh() throws {
        var config = CodexBarConfig()
        config.openAI.disableLocalUsageStats = true
        try self.writeConfig(config)

        let service = LocalCostSummaryServiceSpy(summaries: [
            LocalCostSummary(
                todayCostUSD: 1,
                todayTokens: 100,
                last30DaysCostUSD: 1,
                last30DaysTokens: 100,
                lifetimeCostUSD: 1,
                lifetimeTokens: 100,
                dailyEntries: [],
                updatedAt: Date()
            ),
        ])
        let store = self.makeTokenStore(
            costSummaryService: service,
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        store.refreshLocalCostSummary(force: true, minimumInterval: 0, refreshSessionCache: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(service.loadCallCount, 0)
        XCTAssertNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 0)
    }

    func testSaveDesktopSettingsOnlyTouchesPreferredPath() throws {
        let store = TokenStore.shared
        store.load()
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: [],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort
            )
        )

        let validAppURL = try self.makeValidCodexApp(named: "Test/Codex.app")
        try store.saveDesktopSettings(
            DesktopSettingsUpdate(preferredCodexAppPath: validAppURL.path)
        )

        XCTAssertEqual(store.config.desktop.preferredCodexAppPath, validAppURL.path)
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .quotaSort)
    }

    func testRestoreActiveSelectionPersistsPreviousCompatibleProvider() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://a.example.com/v1",
            accountLabel: "Alpha",
            apiKey: "sk-provider-a"
        )
        let providerA = try XCTUnwrap(store.config.providers.first(where: { $0.label == "Provider A" }))
        let accountA = try XCTUnwrap(providerA.activeAccount)
        try store.activateCustomProvider(providerID: providerA.id, accountID: accountA.id)

        try store.addCustomProvider(
            label: "Provider B",
            baseURL: "https://b.example.com/v1",
            accountLabel: "Beta",
            apiKey: "sk-provider-b"
        )
        XCTAssertEqual(store.activeProvider?.label, "Provider A")

        try store.restoreActiveSelection(
            activeProviderID: providerA.id,
            activeAccountID: accountA.id
        )

        XCTAssertEqual(store.activeProvider?.id, providerA.id)
        XCTAssertEqual(store.activeProviderAccount?.id, accountA.id)
    }

    func testAddCustomProviderDoesNotActivateInCurrentMode() throws {
        let oauthAccount = TokenAccount(
            email: "active@example.com",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            expiresAt: nil,
            isActive: true
        )
        var config = CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: "openai-oauth",
                accountId: oauthAccount.accountId
            ),
            openAI: CodexBarOpenAISettings(accountUsageMode: .hybridProvider)
        )
        _ = config.upsertOAuthAccount(oauthAccount, activate: true)
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://a.example.com/v1",
            accountLabel: "Alpha",
            apiKey: "sk-provider-a"
        )

        XCTAssertEqual(store.config.openAI.accountUsageMode, .hybridProvider)
        XCTAssertEqual(store.activeProvider?.kind, .openAIOAuth)
        XCTAssertEqual(store.activeProviderAccount?.id, oauthAccount.accountId)
        XCTAssertNotNil(store.config.providers.first(where: { $0.label == "Provider A" }))
    }

    func testAddCustomProviderNamedOpenRouterAvoidsReservedProviderID() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "OpenRouter",
            baseURL: "https://relay.example.com/v1",
            accountLabel: "Relay",
            apiKey: "sk-relay"
        )

        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "OpenRouter" }))
        XCTAssertEqual(provider.kind, .openAICompatible)
        XCTAssertEqual(provider.id, "openrouter-custom")
    }

    func testUpdateCustomProviderEditsCurrentValuesWithoutChangingProviderID() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://old.example.com/v1",
            accountLabel: "Old Account",
            apiKey: "sk-old"
        )
        let addedProvider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "Provider A" }))
        let providerID = addedProvider.id
        let accountID = try XCTUnwrap(addedProvider.activeAccount?.id)
        try store.activateCustomProvider(providerID: providerID, accountID: accountID)

        try store.updateCustomProvider(
            providerID: providerID,
            request: CustomProviderUpdate(
                label: "Provider B",
                baseURL: "https://new.example.com/v1",
                accountID: accountID,
                accountLabel: "New Account",
                apiKey: "sk-new"
            )
        )

        let provider = try XCTUnwrap(store.config.provider(id: providerID))
        XCTAssertEqual(provider.id, providerID)
        XCTAssertEqual(provider.label, "Provider B")
        XCTAssertEqual(provider.baseURL, "https://new.example.com/v1")
        XCTAssertEqual(provider.activeAccountId, accountID)
        XCTAssertEqual(provider.activeAccount?.label, "New Account")
        XCTAssertEqual(provider.activeAccount?.apiKey, "sk-new")
        XCTAssertEqual(store.activeProvider?.id, providerID)
        XCTAssertEqual(store.activeProviderAccount?.id, accountID)
    }

    func testUpdateCustomProviderAccountDoesNotActivateEditedInactiveAccount() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://provider.example.com/v1",
            accountLabel: "Primary",
            apiKey: "sk-primary"
        )
        let addedProvider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "Provider A" }))
        let providerID = addedProvider.id
        let primaryAccountID = try XCTUnwrap(addedProvider.activeAccount?.id)
        try store.activateCustomProvider(providerID: providerID, accountID: primaryAccountID)
        try store.addCustomProviderAccount(providerID: providerID, label: "Backup", apiKey: "sk-backup")

        let providerBeforeEdit = try XCTUnwrap(store.config.provider(id: providerID))
        let backupAccountID = try XCTUnwrap(providerBeforeEdit.accounts.first(where: { $0.label == "Backup" })?.id)

        try store.updateCustomProviderAccount(
            providerID: providerID,
            accountID: backupAccountID,
            label: "Backup Edited",
            apiKey: "sk-backup-edited"
        )

        let provider = try XCTUnwrap(store.config.provider(id: providerID))
        let backupAccount = try XCTUnwrap(provider.accounts.first(where: { $0.id == backupAccountID }))
        XCTAssertEqual(backupAccount.label, "Backup Edited")
        XCTAssertEqual(backupAccount.apiKey, "sk-backup-edited")
        XCTAssertEqual(provider.activeAccountId, primaryAccountID)
        XCTAssertEqual(store.config.active.accountId, primaryAccountID)
        XCTAssertEqual(store.activeProviderAccount?.id, primaryAccountID)
    }

    func testProviderUsageRefreshPersistsStandardizedDataAndRawResponse() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        try store.addCustomProvider(
            label: "AI Input",
            baseURL: "https://ai.input.im/v1",
            accountLabel: "Default",
            apiKey: "sk-provider"
        )
        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "AI Input" }))

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
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

        try store.saveProviderUsageConfiguration(
            providerID: provider.id,
            configuration: CodexBarProviderUsageConfiguration()
        )
        store.refreshProviderUsage(providerID: provider.id)

        let timeout = Date().addingTimeInterval(3)
        while store.config.provider(id: provider.id)?.usageState?.lastUpdatedAt == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let state = try XCTUnwrap(store.config.provider(id: provider.id)?.usageState)
        XCTAssertNotNil(state.lastUpdatedAt)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.rawResponse, #"{"remaining":8.5,"subscription":{"daily_usage_usd":1.5,"daily_limit_usd":10,"weekly_limit_usd":0,"monthly_limit_usd":0}}"#)
        XCTAssertEqual(state.data?.remaining, 8.5)
        XCTAssertEqual(try XCTUnwrap(state.data?.today.usageRatio), 0.15, accuracy: 0.0001)
        XCTAssertNil(state.data?.weekly.usageRatio)
        XCTAssertNil(state.data?.monthly.usageRatio)
    }

    func testOpenRouterManualModelFallbackWorksWithoutCatalog() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-manual")

        XCTAssertNil(store.openRouterProvider?.openRouterEffectiveModelID)
        XCTAssertTrue(store.openRouterProvider?.cachedModelCatalog.isEmpty ?? true)

        try store.updateOpenRouterSelectedModel("google/gemini-2.5-pro")

        XCTAssertEqual(store.openRouterProvider?.selectedModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertTrue(store.openRouterProvider?.cachedModelCatalog.isEmpty ?? true)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openRouterProvider()?.selectedModelID, "google/gemini-2.5-pro")
    }

    func testOpenRouterPinnedModelsRemainAfterSwitchingCurrentModel() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_500)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(store.openRouterProvider?.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "openai/gpt-4.1")

        try store.updateOpenRouterSelectedModel("google/gemini-2.5-pro")

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(store.openRouterProvider?.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(store.openRouterProvider?.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
    }

    func testOpenRouterModelPickerDisplayPinsSelectedModelsAndRequiresSearchForUnselected() {
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
        ]
        let selected = Set(["google/gemini-2.5-pro"])

        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selected,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: ""
            ).map(\.id),
            ["google/gemini-2.5-pro"]
        )
        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selected,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: "claude"
            ).map(\.id),
            ["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"]
        )
    }

    func testOpenRouterModelPickerDisplayDoesNotRepinNewSelectionsAfterOpen() {
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
        ]
        let selectedAfterOpen = Set(["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"])

        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selectedAfterOpen,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: "claude"
            ).map(\.id),
            ["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"]
        )
        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selectedAfterOpen,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: ""
            ).map(\.id),
            ["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"]
        )
    }

    func testOpenRouterMenuModelOptionsShowAllPinnedModelsWithoutSelectedModel() throws {
        let account = CodexBarProviderAccount(
            id: "acct-openrouter-menu-models",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary",
            openRouterSelection: CodexBarOpenRouterSelection(
                selectedModelID: nil,
                pinnedModelIDs: [
                    "bytedance-seed/seed-2.0-mini",
                    "bytedance-seed/seed-1.6",
                    "custom/model-without-cache",
                ],
                cachedModelCatalog: [
                    CodexBarOpenRouterModel(id: "bytedance-seed/seed-1.6", name: "Seed 1.6"),
                    CodexBarOpenRouterModel(id: "bytedance-seed/seed-2.0-mini", name: "Seed 2.0 Mini"),
                ]
            )
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            activeAccountId: account.id,
            accounts: [account]
        )

        XCTAssertEqual(
            provider.openRouterMenuModelOptions(forAccountID: account.id),
            [
                CodexBarOpenRouterModel(id: "bytedance-seed/seed-1.6", name: "Seed 1.6"),
                CodexBarOpenRouterModel(id: "bytedance-seed/seed-2.0-mini", name: "Seed 2.0 Mini"),
                CodexBarOpenRouterModel(id: "custom/model-without-cache"),
            ]
        )
    }

    func testOpenRouterModelPickerCacheStatusLocalizesTimestamp() throws {
        let originalOverride = L.languageOverride
        defer {
            L.languageOverride = originalOverride
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let updatedAt = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 5,
                    day: 19,
                    hour: 9,
                    minute: 20
                )
            )
        )

        L.languageOverride = false
        XCTAssertEqual(
            L.openRouterModelPickerCacheStatus(count: 356, fetchedAt: updatedAt),
            "356 cached models • updated May 19, 2026 at 9:20"
        )

        L.languageOverride = true
        XCTAssertEqual(
            L.openRouterModelPickerCacheStatus(count: 356, fetchedAt: updatedAt),
            "已缓存 356 个模型 • 更新于 2026年5月19日 9:20"
        )
    }

    func testUpdateOpenRouterProviderEditsActiveKeyAndModelSelection() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_700)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            accountLabel: "Primary",
            apiKey: "sk-or-v1-old",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )
        let accountID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.updateOpenRouterProvider(
            request: OpenRouterProviderUpdate(
                accountID: accountID,
                accountLabel: "Updated Primary",
                apiKey: "sk-or-v1-new",
                selectedModelID: "google/gemini-2.5-pro",
                pinnedModelIDs: ["google/gemini-2.5-pro", "openai/gpt-4.1"],
                cachedModelCatalog: catalog,
                fetchedAt: fetchedAt
            )
        )

        let provider = try XCTUnwrap(store.openRouterProvider)
        XCTAssertEqual(provider.activeAccount?.label, "Updated Primary")
        XCTAssertEqual(provider.activeAccount?.apiKey, "sk-or-v1-new")
        XCTAssertEqual(provider.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(provider.pinnedModelIDs, ["google/gemini-2.5-pro", "openai/gpt-4.1"])
        XCTAssertEqual(provider.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(provider.modelCatalogFetchedAt, fetchedAt)
    }

    func testAddingOpenRouterKeyDoesNotInheritSelectedModels() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_800)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            accountLabel: "Primary",
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )
        let primaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.addOpenRouterProviderAccount(
            label: "Secondary",
            apiKey: "sk-or-v1-secondary"
        )
        let secondaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)
        let provider = try XCTUnwrap(store.openRouterProvider)

        XCTAssertNotEqual(primaryID, secondaryID)
        let secondarySelection = provider.openRouterSelection(forAccountID: secondaryID)
        XCTAssertNil(secondarySelection.selectedModelID)
        XCTAssertTrue(secondarySelection.pinnedModelIDs.isEmpty)
        XCTAssertEqual(secondarySelection.cachedModelCatalog.map(\.id), catalog.map(\.id))
        XCTAssertEqual(secondarySelection.modelCatalogFetchedAt, fetchedAt)
        XCTAssertNil(provider.openRouterEffectiveModelID(forAccountID: secondaryID))
    }

    func testUpdateOpenRouterProviderCanSaveLabelAndCacheWithoutAutoSelectingModel() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_900)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary")
        let accountID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.updateOpenRouterProvider(
            request: OpenRouterProviderUpdate(
                accountID: accountID,
                accountLabel: "Renamed",
                apiKey: "sk-or-v1-updated",
                selectedModelID: nil,
                pinnedModelIDs: ["google/gemini-2.5-pro"],
                cachedModelCatalog: catalog,
                fetchedAt: fetchedAt
            )
        )

        let provider = try XCTUnwrap(store.openRouterProvider)
        let selection = provider.openRouterSelection(forAccountID: accountID)
        XCTAssertEqual(provider.activeAccount?.label, "Renamed")
        XCTAssertEqual(provider.activeAccount?.apiKey, "sk-or-v1-updated")
        XCTAssertNil(selection.selectedModelID)
        XCTAssertEqual(selection.pinnedModelIDs, ["google/gemini-2.5-pro"])
        XCTAssertNil(provider.openRouterEffectiveModelID(forAccountID: accountID))
    }

    func testRefreshOpenRouterModelCatalogCachesFetchedModels() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: [
                        CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                        CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
                    ],
                    fetchedAt: fetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary")
        try await store.refreshOpenRouterModelCatalog()

        XCTAssertEqual(catalogService.requestedAPIKeys, ["sk-or-v1-primary"])
        XCTAssertEqual(
            store.openRouterProvider?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "openai/gpt-4.1"]
        )
        XCTAssertEqual(store.openRouterProvider?.modelCatalogFetchedAt, fetchedAt)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openRouterProvider()?.pinnedModelIDs, [])
        XCTAssertTrue(reloaded.openRouterProvider()?.cachedModelCatalog.isEmpty ?? false)
        XCTAssertNil(reloaded.openRouterProvider()?.modelCatalogFetchedAt)
    }

    func testRefreshOpenRouterModelCatalogForKeyDoesNotOverwriteOtherKeySelection() async throws {
        let firstFetchedAt = Date(timeIntervalSince1970: 1_710_000_100)
        let secondFetchedAt = Date(timeIntervalSince1970: 1_710_000_200)
        let firstCatalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]
        let secondCatalog = [
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
            CodexBarOpenRouterModel(id: "meta-llama/llama-4-maverick", name: "Llama 4 Maverick"),
        ]
        let refreshedCatalog = [
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
            CodexBarOpenRouterModel(id: "qwen/qwen3-235b-a22b", name: "Qwen3 235B A22B"),
        ]
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: refreshedCatalog,
                    fetchedAt: secondFetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(
            accountLabel: "Primary",
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: firstCatalog,
            fetchedAt: firstFetchedAt
        )
        let primaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.addOpenRouterProvider(
            accountLabel: "Secondary",
            apiKey: "sk-or-v1-secondary",
            selectedModelID: "anthropic/claude-3.7-sonnet",
            pinnedModelIDs: ["anthropic/claude-3.7-sonnet", "meta-llama/llama-4-maverick"],
            cachedModelCatalog: secondCatalog,
            fetchedAt: firstFetchedAt
        )
        let secondaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try await store.refreshOpenRouterModelCatalog(accountID: secondaryID)

        let provider = try XCTUnwrap(store.openRouterProvider)
        let primarySelection = provider.openRouterSelection(forAccountID: primaryID)
        let secondarySelection = provider.openRouterSelection(forAccountID: secondaryID)

        XCTAssertEqual(catalogService.requestedAPIKeys, ["sk-or-v1-secondary"])
        XCTAssertEqual(primarySelection.selectedModelID, "openai/gpt-4.1")
        XCTAssertEqual(primarySelection.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(primarySelection.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(primarySelection.modelCatalogFetchedAt, firstFetchedAt)
        XCTAssertEqual(secondarySelection.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(secondarySelection.pinnedModelIDs, ["anthropic/claude-3.7-sonnet", "meta-llama/llama-4-maverick"])
        XCTAssertEqual(secondarySelection.cachedModelCatalog.map(\.id), ["anthropic/claude-3.7-sonnet", "qwen/qwen3-235b-a22b"])
        XCTAssertEqual(secondarySelection.modelCatalogFetchedAt, secondFetchedAt)
        XCTAssertEqual(provider.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(provider.cachedModelCatalog.map(\.id), ["anthropic/claude-3.7-sonnet", "qwen/qwen3-235b-a22b"])
    }

    func testRefreshOpenRouterCatalogFailurePreservesSelectedModelAndCache() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_100)
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: [
                        CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                        CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
                    ],
                    fetchedAt: fetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary")
        try store.updateOpenRouterSelectedModel("anthropic/claude-3.7-sonnet")
        try await store.refreshOpenRouterModelCatalog()

        catalogService.result = .failure(URLError(.notConnectedToInternet))

        do {
            try await store.refreshOpenRouterModelCatalog()
            XCTFail("Expected refresh to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(
            store.openRouterProvider?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "google/gemini-2.5-pro"]
        )
        XCTAssertEqual(store.openRouterProvider?.modelCatalogFetchedAt, fetchedAt)
    }

    private func makeValidCodexApp(named relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let appURL = root.appendingPathComponent(relativePath)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let executableURL = resourcesURL.appendingPathComponent("codex")
        try Data().write(to: executableURL)
        return appURL
    }

    private static func recentCostFixtureTimestamps() -> (
        sessionStartedAt: String,
        firstUsageAt: String,
        secondUsageAt: String
    ) {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: Date())
        ) ?? Date().addingTimeInterval(-86_400)
        let formatter = ISO8601DateFormatter()
        return (
            formatter.string(from: yesterdayStart.addingTimeInterval(8 * 60 * 60)),
            formatter.string(from: yesterdayStart.addingTimeInterval(8 * 60 * 60 + 5 * 60)),
            formatter.string(from: yesterdayStart.addingTimeInterval(9 * 60 * 60 + 10 * 60))
        )
    }

    private static func todayCostFixtureTimestamps() -> (
        sessionStartedAt: String,
        usageAt: String
    ) {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let formatter = ISO8601DateFormatter()
        return (
            formatter.string(from: todayStart.addingTimeInterval(5 * 60)),
            formatter.string(from: todayStart.addingTimeInterval(10 * 60))
        )
    }

    private static func makeSummary(
        tokens: Int,
        updatedAt: Date? = nil
    ) -> LocalCostSummary {
        LocalCostSummary(
            todayCostUSD: 0,
            todayTokens: tokens,
            last30DaysCostUSD: 0,
            last30DaysTokens: tokens,
            lifetimeCostUSD: 0,
            lifetimeTokens: tokens,
            dailyEntries: [
                DailyCostEntry(
                    id: "summary-\(tokens)",
                    date: Date(timeIntervalSince1970: Double(tokens)),
                    costUSD: 0,
                    totalTokens: tokens
                ),
            ],
            updatedAt: updatedAt ?? Date(timeIntervalSince1970: Double(tokens))
        )
    }

    private func writeLocalCostSummaryCache(_ summary: LocalCostSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(summary),
            to: CodexPaths.costCacheURL
        )
    }

    private func waitForLocalCostSummary(
        _ store: TokenStore,
        tokens: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.localCostSummary.lifetimeTokens == tokens {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return store.localCostSummary.lifetimeTokens == tokens
    }

    private func waitForLocalCostRefreshState(
        _ store: TokenStore,
        isRefreshing: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.isRefreshingLocalCostSummaryInBackground == isRefreshing {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return store.isRefreshingLocalCostSummaryInBackground == isRefreshing
    }

    private func makeTokenStore(
        costSummaryService: any LocalCostSummaryLoading = LocalCostSummaryService(),
        openAIAccountGatewayService: OpenAIAccountGatewayControlling = OpenAIAccountGatewayControllerStub(),
        openRouterGatewayService: OpenRouterGatewayControlling = OpenRouterGatewayControllerStub(),
        openRouterCatalogService: any OpenRouterModelCatalogFetching,
        providerUsageService: ProviderUsageService = ProviderUsageService()
    ) -> TokenStore {
        TokenStore(
            syncService: CodexSyncServiceNoOp(),
            costSummaryService: costSummaryService,
            openAIAccountGatewayService: openAIAccountGatewayService,
            openRouterGatewayService: openRouterGatewayService,
            openRouterModelCatalogService: openRouterCatalogService,
            providerUsageService: providerUsageService,
            aggregateGatewayLeaseStore: AggregateGatewayLeaseStoreStub(),
            aggregateRouteJournalStore: AggregateRouteJournalStoreStub(),
            codexRunningProcessIDs: { [] }
        )
    }
}

private final class CodexSyncServiceNoOp: CodexSynchronizing {
    func synchronize(config _: CodexBarConfig) throws {}
}

private final class OpenAIAccountGatewayControllerStub: OpenAIAccountGatewayControlling {
    var isHandlingHighFrequencyRequestsValue = false

    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts _: [TokenAccount],
        quotaSortSettings _: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode _: CodexBarOpenAIAccountUsageMode,
        routeTarget _: OpenAIAccountGatewayRouteTarget
    ) {}

    func currentRoutedAccountID() -> String? { nil }
    func isHandlingHighFrequencyRequests(recentActivityWindow _: TimeInterval) -> Bool {
        self.isHandlingHighFrequencyRequestsValue
    }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID _: String) -> Bool { false }
}

private final class OpenRouterGatewayControllerStub: OpenRouterGatewayControlling {
    var isHandlingHighFrequencyRequestsValue = false

    func startIfNeeded() {}
    func stop() {}
    func updateState(provider _: CodexBarProvider?, isActiveProvider _: Bool) {}
    func isHandlingHighFrequencyRequests(recentActivityWindow _: TimeInterval) -> Bool {
        self.isHandlingHighFrequencyRequestsValue
    }
}

private final class AggregateGatewayLeaseStoreStub: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_: Set<pid_t>) {}
    func clear() {}
}

private final class AggregateRouteJournalStoreStub: OpenAIAggregateRouteJournalStoring {
    func recordRoute(threadID _: String, accountID _: String, timestamp _: Date) {}
    func routeHistory() -> [OpenAIAggregateRouteRecord] { [] }
}

private final class LocalCostSummaryServiceSpy: LocalCostSummaryLoading {
    private let condition = NSCondition()
    private var summaries: [LocalCostSummary]
    private var resumeCount = 0
    private(set) var loadCallCount = 0
    private(set) var refreshSessionCacheFlags: [Bool] = []

    init(summaries: [LocalCostSummary]) {
        self.summaries = summaries
    }

    func historicalModels(refreshSessionCache _: Bool) -> [String] {
        []
    }

    func load(
        now _: Date,
        modelPricingOverrides _: [String: CodexBarModelPricing],
        refreshSessionCache: Bool
    ) -> LocalCostSummary {
        self.condition.lock()
        self.loadCallCount += 1
        self.refreshSessionCacheFlags.append(refreshSessionCache)
        let callIndex = self.loadCallCount
        self.condition.broadcast()
        while self.resumeCount < callIndex {
            self.condition.wait()
        }
        let summary = self.summaries.isEmpty ? .empty : self.summaries.removeFirst()
        self.condition.unlock()
        return summary
    }

    func waitForStartedCallCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        self.condition.lock()
        defer { self.condition.unlock() }
        while self.loadCallCount < count {
            let now = Date()
            if now >= deadline { return false }
            if Thread.isMainThread {
                self.condition.unlock()
                RunLoop.main.run(until: min(deadline, now.addingTimeInterval(0.01)))
                self.condition.lock()
                continue
            }
            self.condition.wait(until: min(deadline, now.addingTimeInterval(0.01)))
        }
        return true
    }

    func resumeNext() {
        self.condition.lock()
        self.resumeCount += 1
        self.condition.broadcast()
        self.condition.unlock()
    }
}

private final class OpenRouterModelCatalogServiceSpy: OpenRouterModelCatalogFetching {
    var result: Result<OpenRouterModelCatalogSnapshot, Error>
    private(set) var requestedAPIKeys: [String] = []

    init(result: Result<OpenRouterModelCatalogSnapshot, Error>) {
        self.result = result
    }

    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        self.requestedAPIKeys.append(apiKey)
        return try self.result.get()
    }
}
