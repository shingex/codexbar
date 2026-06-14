import XCTest

final class MenuBarStatusItemPresentationTests: XCTestCase {
    func testActiveAccountUsesUsageSummary() {
        let account = TokenAccount(
            email: "active@example.com",
            accountId: "acct_active",
            primaryUsedPercent: 67,
            secondaryUsedPercent: 48,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            disableLocalUsageStats: false,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "person.crop.circle")
        XCTAssertEqual(presentation.title, "67%/48%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testAggregateModeUsesAggregateRoutedAccountSummary() {
        let aggregate = TokenAccount(
            email: "agg@example.com",
            accountId: "acct_agg",
            primaryUsedPercent: 42,
            secondaryUsedPercent: 80
        )
        let provider = CodexBarProvider(id: "openai", kind: .openAIOAuth, label: "OpenAI")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: aggregate,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .aggregateGateway,
            disableLocalUsageStats: false,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.title, L.openAIRouteSummaryCompact("42%"))
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testFallbackProviderLabelIsTrimmed() {
        let provider = CodexBarProvider(id: "compatible", kind: .openAICompatible, label: "ProviderLong")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            disableLocalUsageStats: false,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "person.crop.circle")
        XCTAssertEqual(presentation.title, "Provid")
        XCTAssertEqual(presentation.emphasis, .secondary)
    }

    func testHybridModeUsesTodayCostInsteadOfProviderLabel() {
        let provider = CodexBarProvider(id: "compatible", kind: .openAICompatible, label: "ai.input.im")
        let summary = LocalCostSummary(
            todayCostUSD: 20.9,
            todayTokens: 187_840_000,
            last30DaysCostUSD: 411.18,
            last30DaysTokens: 2_860_000_000,
            lifetimeCostUSD: 411.18,
            lifetimeTokens: 2_860_000_000,
            dailyEntries: [],
            updatedAt: Date()
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: summary,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            disableLocalUsageStats: false,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "arrow.triangle.branch")
        XCTAssertTrue(presentation.title.contains("20.90"))
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testProviderUsageAPITakesPriorityForProviderStatusTitle() {
        let provider = CodexBarProvider(
            id: "compatible",
            kind: .openAICompatible,
            label: "ai.input.im",
            usageState: CodexBarProviderUsageState(
                data: CodexBarProviderUsageData(
                    unit: "USD",
                    remaining: 126.18,
                    today: CodexBarProviderUsagePeriod(used: 173.82, limit: 300, remaining: 126.18)
                )
            )
        )
        let summary = LocalCostSummary(
            todayCostUSD: 20.9,
            todayTokens: 187_840_000,
            last30DaysCostUSD: 411.18,
            last30DaysTokens: 2_860_000_000,
            lifetimeCostUSD: 411.18,
            lifetimeTokens: 2_860_000_000,
            dailyEntries: [],
            updatedAt: Date()
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: summary,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            disableLocalUsageStats: true,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.title, "$173.82/57.9%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testThirdPartyModelProviderUsesModelIconAndCompactModelFallback() {
        let provider = CodexBarProvider(
            id: "deepseek",
            kind: .openAICompatible,
            label: "DeepSeek",
            defaultModel: "deepseek-v4-pro",
            thirdPartyModelProvider: .deepSeek
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            disableLocalUsageStats: true,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.deepSeek)
        XCTAssertEqual(presentation.title, "DS4P")
        XCTAssertEqual(presentation.emphasis, .secondary)
    }

    func testThirdPartyModelProviderPrefixesUsageWithProviderCode() {
        let provider = CodexBarProvider(
            id: "deepseek",
            kind: .openAICompatible,
            label: "DeepSeek",
            defaultModel: "deepseek-v4-pro",
            thirdPartyModelProvider: .deepSeek,
            usageState: CodexBarProviderUsageState(
                data: CodexBarProviderUsageData(
                    unit: "USD",
                    remaining: 126.18,
                    today: CodexBarProviderUsagePeriod(used: 173.82, limit: 300, remaining: 126.18)
                )
            )
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            disableLocalUsageStats: true,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.deepSeek)
        XCTAssertEqual(presentation.title, "DS$173.82/57.9%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testMiMoModelProviderUsesCompactModelFallback() {
        let provider = CodexBarProvider(
            id: "mimo",
            kind: .openAICompatible,
            label: "MiMo",
            defaultModel: "mimo-v2.5-pro",
            thirdPartyModelProvider: .mimo
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            disableLocalUsageStats: true,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.xiaomiMiMo)
        XCTAssertEqual(presentation.title, "MM2.5P")
    }

    func testOpenRouterVerifiedModelFamiliesUseCompactModelFallbacks() {
        let cases: [(String, MenuBarStatusItemIconSource, String)] = [
            ("openai/gpt-5.1-codex-mini", MenuBarModelIconLibrary.openAI, "OA5M"),
            ("anthropic/claude-sonnet-4.5", MenuBarModelIconLibrary.claude, "CL4.5S"),
            ("google/gemini-2.5-pro", MenuBarModelIconLibrary.gemini, "GM2.5P"),
            ("qwen/qwen3-coder-plus", MenuBarModelIconLibrary.qwen, "QW3C"),
            ("moonshotai/kimi-k2.7-code", MenuBarModelIconLibrary.kimi, "KM2.7C"),
            ("mistralai/codestral-2508", MenuBarModelIconLibrary.mistral, "MS2508C"),
            ("x-ai/grok-4.20", MenuBarModelIconLibrary.grok, "GX4.2"),
            ("z-ai/glm-5.1", MenuBarModelIconLibrary.zai, "ZA5.1"),
        ]

        for (modelID, iconSource, title) in cases {
            let provider = CodexBarProvider(
                id: "openrouter",
                kind: .openRouter,
                label: "OpenRouter",
                selectedModelID: modelID
            )

            let presentation = MenuBarStatusItemPresentation.make(
                accounts: [],
                activeProvider: provider,
                aggregateRoutedAccount: nil,
                localCostSummary: .empty,
                usageDisplayMode: .used,
                accountUsageMode: .hybridProvider,
                disableLocalUsageStats: true,
                updateAvailable: false
            )

            XCTAssertEqual(presentation.iconSource, iconSource, modelID)
            XCTAssertEqual(presentation.title, title, modelID)
            XCTAssertEqual(presentation.emphasis, .secondary, modelID)
        }
    }

    func testVerifiedRelayModelPrefixesUsageWithProviderCode() {
        let provider = CodexBarProvider(
            id: "relay",
            kind: .openAICompatible,
            label: "Relay",
            defaultModel: "qwen/qwen3-coder-plus",
            usageState: CodexBarProviderUsageState(
                data: CodexBarProviderUsageData(
                    unit: "USD",
                    remaining: 126.18,
                    today: CodexBarProviderUsagePeriod(used: 173.82, limit: 300, remaining: 126.18)
                )
            )
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            localCostSummary: .empty,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            disableLocalUsageStats: true,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.qwen)
        XCTAssertEqual(presentation.title, "QW$173.82/57.9%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testProviderUsageTitleIsAvailableWithoutActiveProvider() {
        let provider = CodexBarProvider(
            id: "compatible",
            kind: .openAICompatible,
            label: "ai.input.im",
            usageState: CodexBarProviderUsageState(
                data: CodexBarProviderUsageData(
                    unit: "USD",
                    remaining: 126.18,
                    today: CodexBarProviderUsagePeriod(used: 173.82, limit: 300, remaining: 126.18)
                )
            )
        )

        XCTAssertEqual(ProviderUsageFormat.compactStatusTitle(for: provider, mode: .used), "$173.82/57.9%")
    }

    func testStatusItemImageUsesTemplateRendering() {
        let presentation = MenuBarStatusItemPresentation(
            iconName: "terminal.fill",
            title: "67%/48%",
            emphasis: .primary
        )

        let image = presentation.makeTemplateImage(accessibilityDescription: "Codexbar")

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
    }

    func testAttributedTitleDoesNotPinForegroundColor() {
        let presentation = MenuBarStatusItemPresentation(
            iconName: "exclamationmark.triangle.fill",
            title: "每周额度",
            emphasis: .critical
        )

        let title = presentation.attributedTitle
        let attributes = title.attributes(at: 0, effectiveRange: nil)

        XCTAssertEqual(title.string, " 每周额度")
        XCTAssertNotNil(attributes[.font] as? NSFont)
        XCTAssertNil(attributes[.foregroundColor])
    }
}
