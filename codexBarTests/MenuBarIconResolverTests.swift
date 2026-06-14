import XCTest

final class MenuBarIconResolverTests: XCTestCase {
    func testCompatibleProviderIgnoresInactiveOAuthWarningsAndUsesModeFallback() {
        let accounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                secondaryUsedPercent: 100
            )
        ]

        let icon = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: .openAICompatible
        )

        XCTAssertEqual(icon, "person.crop.circle")
    }

    func testActiveOAuthAccountStillDrivesWarningIcon() {
        let accounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                secondaryUsedPercent: 100,
                isActive: true
            )
        ]

        let icon = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: .openAIOAuth
        )

        XCTAssertEqual(icon, "exclamationmark.triangle.fill")
    }

    func testVisualWarningThresholdControlsBoltWarningIcon() {
        let warningAccounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                primaryUsedPercent: 85,
                secondaryUsedPercent: 10,
                isActive: true
            )
        ]
        let healthyAccounts = [
            TokenAccount(
                email: "bob@example.com",
                accountId: "acct_bob",
                primaryUsedPercent: 75,
                secondaryUsedPercent: 10,
                isActive: true
            )
        ]

        let warning = MenuBarIconResolver.iconName(
            accounts: warningAccounts,
            activeProviderKind: .openAIOAuth
        )
        let healthy = MenuBarIconResolver.iconName(
            accounts: healthyAccounts,
            activeProviderKind: .openAIOAuth
        )

        XCTAssertEqual(warning, "bolt.circle.fill")
        XCTAssertEqual(healthy, "person.crop.circle")
    }

    func testUpdateAvailableOverridesNormalIcon() {
        let accounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                primaryUsedPercent: 100,
                secondaryUsedPercent: 100,
                isActive: true
            )
        ]

        let icon = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: .openAIOAuth,
            updateAvailable: true
        )

        XCTAssertEqual(icon, "arrow.down.circle.fill")
    }

    func testHybridModeUsesMixRoutingIcon() {
        let icon = MenuBarIconResolver.iconName(
            accounts: [],
            activeProviderKind: .openAICompatible,
            accountUsageMode: .hybridProvider
        )

        XCTAssertEqual(icon, "arrow.triangle.branch")
    }

    func testThirdPartyModelProviderUsesModelIconBeforeModeFallback() {
        let provider = CodexBarProvider(
            id: "deepseek",
            kind: .openAICompatible,
            label: "DeepSeek",
            defaultModel: "deepseek-v4-pro",
            thirdPartyModelProvider: .deepSeek
        )

        let icon = MenuBarIconResolver.iconSource(
            accounts: [],
            activeProvider: provider,
            accountUsageMode: .hybridProvider
        )

        XCTAssertEqual(icon, MenuBarModelIconLibrary.deepSeek)
    }

    func testOpenRouterUsesVerifiedModelFamilyIconBeforeOpenRouterFallback() {
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            selectedModelID: "anthropic/claude-sonnet-4.5"
        )

        let icon = MenuBarIconResolver.iconSource(
            accounts: [],
            activeProvider: provider,
            accountUsageMode: .hybridProvider
        )

        XCTAssertEqual(icon, MenuBarModelIconLibrary.claude)
    }

    func testCompatibleRelayUsesVerifiedDefaultModelIconOnlyWhenRecognized() {
        let recognized = CodexBarProvider(
            id: "relay",
            kind: .openAICompatible,
            label: "Relay",
            defaultModel: "google/gemini-2.5-pro"
        )
        let unknown = CodexBarProvider(
            id: "relay",
            kind: .openAICompatible,
            label: "Relay",
            defaultModel: "unknown/vendor-model"
        )

        let recognizedIcon = MenuBarIconResolver.iconSource(
            accounts: [],
            activeProvider: recognized,
            accountUsageMode: .hybridProvider
        )
        let unknownIcon = MenuBarIconResolver.iconSource(
            accounts: [],
            activeProvider: unknown,
            accountUsageMode: .hybridProvider
        )

        XCTAssertEqual(recognizedIcon, MenuBarModelIconLibrary.gemini)
        XCTAssertEqual(unknownIcon.fallbackSystemSymbolName, "arrow.triangle.branch")
    }

    func testAggregateModeUsesModeFallbackWhenNoStatusOrModelIconExists() {
        let icon = MenuBarIconResolver.iconName(
            accounts: [],
            activeProviderKind: .openAIOAuth,
            accountUsageMode: .aggregateGateway
        )

        XCTAssertEqual(icon, "person.2.crop.square.stack")
    }
}
