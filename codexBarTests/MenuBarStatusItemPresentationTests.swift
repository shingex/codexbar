import XCTest

final class MenuBarStatusItemPresentationTests: XCTestCase {
    func testPlanWindowsUseTheConfiguredUsageDirection() {
        let provider = CodexBarProvider(id: "plan", kind: .openAICompatible, label: "Plan",
            usageState: .init(data: .init(unit: "USD",
                today: .init(used: 20, limit: 100), weekly: .init(used: 35, limit: 100), monthly: .init(used: 70, limit: 100))))
        XCTAssertEqual(ProviderUsageFormat.quotaStatusTitle(for: provider, mode: .used), "20%/35%/70%")
        XCTAssertEqual(ProviderUsageFormat.quotaStatusTitle(for: provider, mode: .remaining), "80%/65%/30%")
    }

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
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "person.crop.circle")
        XCTAssertEqual(presentation.title, "67%/48%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testFallbackProviderLabelIsTrimmed() {
        let provider = CodexBarProvider(id: "compatible", kind: .openAICompatible, label: "ProviderLong")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "person.crop.circle")
        XCTAssertEqual(presentation.title, "Provid")
        XCTAssertEqual(presentation.emphasis, .secondary)
    }

    func testHybridModeWithoutAPIUsageUsesProviderLabel() {
        let provider = CodexBarProvider(id: "compatible", kind: .openAICompatible, label: "ai.input.im")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "arrow.triangle.branch")
        XCTAssertEqual(presentation.title, "ai.inp")
        XCTAssertEqual(presentation.emphasis, .secondary)
    }

    func testHybridModeWithActiveOAuthProviderUsesNativeAccountUsage() {
        let account = TokenAccount(
            email: "active@example.com",
            accountId: "acct_active",
            primaryUsedPercent: 26,
            secondaryUsedPercent: 81,
            isActive: true
        )
        let provider = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: provider,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "bolt.circle.fill")
        XCTAssertEqual(presentation.title, "26%/81%")
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

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.title, "58%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testProviderStatusTitleUsesActiveAccountUsageSnapshot() {
        let activeAccount = CodexBarProviderAccount(
            id: "acct-star",
            kind: .apiKey,
            label: "Star",
            apiKey: "sk-star"
        )
        let inactiveAccount = CodexBarProviderAccount(
            id: "acct-kami",
            kind: .apiKey,
            label: "Kami",
            apiKey: "sk-kami"
        )
        let provider = CodexBarProvider(
            id: "compatible",
            kind: .openAICompatible,
            label: "Input",
            activeAccountId: activeAccount.id,
            usageState: CodexBarProviderUsageState(
                data: CodexBarProviderUsageData(
                    unit: "USD",
                    remaining: 484.94,
                    today: CodexBarProviderUsagePeriod(used: 15.06, limit: 500, remaining: 484.94)
                ),
                accountSnapshots: [
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: inactiveAccount.id,
                        accountLabel: inactiveAccount.label,
                        data: CodexBarProviderUsageData(
                            unit: "USD",
                            remaining: 484.94,
                            today: CodexBarProviderUsagePeriod(used: 15.06, limit: 500, remaining: 484.94)
                        )
                    ),
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: activeAccount.id,
                        accountLabel: activeAccount.label,
                        data: CodexBarProviderUsageData(
                            unit: "USD",
                            remaining: 164.86,
                            today: CodexBarProviderUsagePeriod(used: 135.14, limit: 300, remaining: 164.86)
                        )
                    ),
                ]
            ),
            accounts: [inactiveAccount, activeAccount]
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            usageDisplayMode: .remaining,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.title, "55%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testProviderStatusTitleDoesNotFallbackToInactiveUsageWhenActiveSnapshotHasNoData() {
        let activeAccount = CodexBarProviderAccount(
            id: "acct-star",
            kind: .apiKey,
            label: "Star",
            apiKey: "sk-star"
        )
        let inactiveAccount = CodexBarProviderAccount(
            id: "acct-kami",
            kind: .apiKey,
            label: "Kami",
            apiKey: "sk-kami"
        )
        let provider = CodexBarProvider(
            id: "compatible",
            kind: .openAICompatible,
            label: "Input",
            defaultModel: "kimi-k2",
            activeAccountId: activeAccount.id,
            usageState: CodexBarProviderUsageState(
                data: CodexBarProviderUsageData(
                    unit: "USD",
                    remaining: 484.94,
                    today: CodexBarProviderUsagePeriod(used: 15.06, limit: 500, remaining: 484.94)
                ),
                accountSnapshots: [
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: inactiveAccount.id,
                        accountLabel: inactiveAccount.label,
                        data: CodexBarProviderUsageData(
                            unit: "USD",
                            remaining: 484.94,
                            today: CodexBarProviderUsagePeriod(used: 15.06, limit: 500, remaining: 484.94)
                        )
                    ),
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: activeAccount.id,
                        accountLabel: activeAccount.label,
                        data: nil,
                        lastError: "timeout"
                    ),
                ]
            ),
            accounts: [inactiveAccount, activeAccount]
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            usageDisplayMode: .remaining,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.title, "Input")
        XCTAssertEqual(presentation.emphasis, .secondary)
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
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.deepSeek)
        XCTAssertEqual(presentation.title, "DeepSe")
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
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.deepSeek)
        XCTAssertEqual(presentation.title, "58%")
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
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.xiaomiMiMo)
        XCTAssertEqual(presentation.title, "MiMo")
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

        for (modelID, iconSource, _) in cases {
            let provider = CodexBarProvider(
                id: "openrouter",
                kind: .openRouter,
                label: "OpenRouter",
                selectedModelID: modelID
            )

            let presentation = MenuBarStatusItemPresentation.make(
                accounts: [],
                activeProvider: provider,
                usageDisplayMode: .used,
                accountUsageMode: .hybridProvider,
                updateAvailable: false
            )

            XCTAssertEqual(presentation.iconSource, iconSource, modelID)
            XCTAssertEqual(presentation.title, "OpenRo", modelID)
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
            usageDisplayMode: .used,
            accountUsageMode: .hybridProvider,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconSource, MenuBarModelIconLibrary.qwen)
        XCTAssertEqual(presentation.title, "58%")
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
