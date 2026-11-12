import Foundation
import XCTest

@MainActor
final class TokenStoreGatewayLifecycleTests: CodexBarTestCase {
    func testModelRoutingHotSwitchKeepsOfficialLoginAndDoesNotResynchronizeCodex() throws {
        let native = try self.makeOAuthAccount(accountID: "native", email: "native@example.test")
        let selected = try self.makeOAuthAccount(accountID: "selected", email: "selected@example.test")
        let first = CodexBarProviderAccount.fromTokenAccount(native, existingID: native.accountId)
        let second = CodexBarProviderAccount.fromTokenAccount(selected, existingID: selected.accountId)
        let oauth = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: first.id, accounts: [first, second])
        let vendor = self.makeThirdPartyModelProvider()
        let initial = CodexBarConfig(active: .init(providerId: oauth.id, accountId: first.id), providers: [oauth, vendor.provider])
        try self.writeConfig(initial)
        let sync = RecordingSyncService()
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(syncService: sync, openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(), codexRunningProcessIDs: { [] })
        var draft = SettingsRouteDraft(config: store.config)
        draft.style = .follow
        draft.modelRoutingEnabled = true
        draft.target = .openAIAccount(accountID: second.id, mode: .switchAccount)
        XCTAssertTrue(try store.applySettingsRoute(draft))
        let afterEnable = sync.callCount
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, first.id)
        try store.activateCustomProvider(providerID: vendor.provider.id, accountID: vendor.account.id, modelID: "deepseek-v4-pro")
        XCTAssertEqual(sync.callCount, afterEnable)
        XCTAssertEqual(store.config.active.providerId, vendor.provider.id)
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, first.id)
        try store.updateThirdPartySelectedModel("deepseek-chat", providerID: vendor.provider.id, accountID: vendor.account.id)
        XCTAssertEqual(sync.callCount, afterEnable)
        try store.activate(selected)
        XCTAssertNil(MenuPanelTarget.resolve(config: store.config)?.modelID)
        XCTAssertEqual(MenuPanelPresentation.activeResource(config: store.config), .account(providerID: oauth.id, accountID: second.id))
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, first.id)
        XCTAssertEqual(sync.callCount, afterEnable)
    }

    func testUnifiedSwitchRemembersTargetAndAlwaysReturnsToNativeOAuth() throws {
        let native = try self.makeOAuthAccount(accountID: "native", email: "native@example.test")
        let key = CodexBarProviderAccount.fromTokenAccount(native, existingID: native.accountId)
        let oauth = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: key.id, accounts: [key])
        let vendor = self.makeThirdPartyModelProvider()
        var config = CodexBarConfig(active: .init(providerId: oauth.id, accountId: key.id), providers: [oauth, vendor.provider])
        config.openAI.modelRoutingStyle = .follow
        try self.writeConfig(config)
        let sync = RecordingSyncService()
        let store = TokenStore(syncService: sync, openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(), openRouterGatewayService: OpenRouterGatewayControllerSpy())
        try store.setCodexIntegrationEnabled(true, selection: .init(providerId: vendor.provider.id, accountId: vendor.account.id))
        let enabledCalls = sync.callCount
        XCTAssertTrue(store.config.openAI.modelRoutingEnabled)
        try store.updateThirdPartySelectedModel("deepseek-chat", providerID: vendor.provider.id, accountID: vendor.account.id)
        XCTAssertEqual(sync.callCount, enabledCalls)
        try store.setCodexIntegrationEnabled(false)
        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(store.config.active.providerId, oauth.id)
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, key.id)
        XCTAssertEqual(store.config.openAI.lastModelRoutingSelection?.providerId, vendor.provider.id)
        try store.setCodexIntegrationEnabled(true)
        XCTAssertEqual(store.config.active.providerId, vendor.provider.id)
        XCTAssertEqual(store.config.activeProvider()?.thirdPartyEffectiveModelID, "deepseek-chat")
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, key.id)
    }

    func testLegacyHybridMigratesIntoUnifiedIntegrationPreservingTarget() throws {
        let native = try self.makeOAuthAccount(accountID: "native", email: "native@example.test")
        let key = CodexBarProviderAccount.fromTokenAccount(native, existingID: native.accountId)
        let oauth = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: key.id, accounts: [key])
        let vendor = self.makeThirdPartyModelProvider()
        try self.writeLegacyHybridConfig(active: .init(providerId: vendor.provider.id, accountId: vendor.account.id),
            providers: [oauth, vendor.provider])
        let store = TokenStore(syncService: RecordingSyncService(), openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(), openRouterGatewayService: OpenRouterGatewayControllerSpy())
        XCTAssertTrue(store.config.openAI.modelRoutingEnabled)
        XCTAssertTrue(store.codexReloadRequired)
        XCTAssertEqual(store.config.active.providerId, vendor.provider.id)
        XCTAssertEqual(store.config.openAI.lastModelRoutingSelection?.accountId, vendor.account.id)
    }

    func testUnavailableRememberedTargetDoesNotSilentlyFallBack() throws {
        let native = try self.makeOAuthAccount(accountID: "native", email: "native@example.test")
        let key = CodexBarProviderAccount.fromTokenAccount(native, existingID: native.accountId)
        let oauth = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: key.id, accounts: [key])
        var config = CodexBarConfig(active: .init(providerId: oauth.id, accountId: key.id), providers: [oauth])
        config.openAI.lastModelRoutingSelection = .init(providerId: "deleted", accountId: "missing")
        try self.writeConfig(config)
        let store = TokenStore(syncService: RecordingSyncService(), openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(), openRouterGatewayService: OpenRouterGatewayControllerSpy())
        XCTAssertThrowsError(try store.setCodexIntegrationEnabled(true))
        XCTAssertFalse(store.config.openAI.modelRoutingEnabled)
        XCTAssertEqual(store.config.active.providerId, oauth.id)
        XCTAssertEqual(store.config.openAI.lastModelRoutingSelection, config.openAI.lastModelRoutingSelection)
    }

    func testFailedLegacyMigrationPreservesTheExistingRoute() throws {
        let native = try self.makeOAuthAccount(accountID: "native", email: "native@example.test")
        let key = CodexBarProviderAccount.fromTokenAccount(native, existingID: native.accountId)
        let oauth = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: key.id, accounts: [key])
        let vendor = self.makeThirdPartyModelProvider()
        let original = CodexBarActiveSelection(providerId: vendor.provider.id, accountId: vendor.account.id)
        try self.writeLegacyHybridConfig(active: original, providers: [oauth, vendor.provider])
        let store = TokenStore(syncService: FailingIntegrationSync(), openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(), openRouterGatewayService: OpenRouterGatewayControllerSpy())
        XCTAssertFalse(store.config.openAI.modelRoutingEnabled)
        XCTAssertEqual(store.config.active, original)
        XCTAssertEqual(store.config.openAI.accountUsageMode, .hybridProvider)
        XCTAssertNotNil(store.routingError)
        XCTAssertFalse(store.codexReloadRequired)
        XCTAssertFalse(try CodexBarConfigStore().load().openAI.modelRoutingEnabled)
    }

    func testLegacyAggregateModeCannotAcquireGatewayLeaseAfterMigration() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(Data(#"{"openAI":{"accountUsageMode":"aggregate_gateway"}}"#.utf8), to: CodexPaths.barConfigURL)
        try CodexPaths.writeSecureFile(Data(#"{"aggregateLeaseProcessIDs":[1234],"updatedAt":"2026-11-10T00:00:00Z"}"#.utf8), to: CodexPaths.openAIGatewayStateURL)
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(syncService: RecordingSyncService(), openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(), codexRunningProcessIDs: { [1234] })
        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertFalse(store.config.openAI.modelRoutingEnabled)
        XCTAssertEqual(gateway.startCount, 0)
        XCTAssertEqual(gateway.routeTargets.last, OpenAIAccountGatewayRouteTarget.none)
    }

    func testOpenRouterInitializationKeepsGatewayStoppedWhenInactive() {
        let openAIGateway = OpenAIAccountGatewayControllerSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: openAIGateway,
            openRouterGatewayService: openRouterGateway,
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 0)
        XCTAssertEqual(openRouterGateway.stopCount, 1)
    }

    func testOpenRouterInitializationStartsGatewayWhenActiveProviderIsOpenRouter() throws {
        let account = CodexBarProviderAccount(
            id: "acct-openrouter",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "openai/gpt-4.1",
            activeAccountId: account.id,
            accounts: [account]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
                providers: [provider]
            )
        )

        let openAIGateway = OpenAIAccountGatewayControllerSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: openAIGateway,
            openRouterGatewayService: openRouterGateway,
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 1)
        XCTAssertEqual(openRouterGateway.stopCount, 0)
    }

    func testLegacyProviderWithoutRequestModelDoesNotInventAGatewayTarget() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-model")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let gateway = OpenAIAccountGatewayControllerSpy()
        let oauthAccount = try self.makeOAuthAccount(
            accountID: "acct-oauth-model-fallback",
            email: "fallback@example.com"
        )
        let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
            oauthAccount,
            existingID: oauthAccount.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuth.id,
            accounts: [storedOAuth]
        )
        try self.writeConfig(
            CodexBarConfig(
                global: CodexBarGlobalSettings(
                    defaultModel: "anthropic/claude-3.7-sonnet",
                    reviewModel: "anthropic/claude-3.7-sonnet",
                    reasoningEffort: "high"
                ),
                active: CodexBarActiveSelection(providerId: openRouterProvider.id, accountId: openRouterAccount.id),
                openAI: CodexBarOpenAISettings(accountUsageMode: .hybridProvider),
                providers: [oauthProvider, openRouterProvider, custom.provider]
            )
        )
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        try store.activateCustomProvider(providerID: custom.provider.id, accountID: custom.account.id)

        XCTAssertEqual(gateway.routeTargets.last, OpenAIAccountGatewayRouteTarget.none)

    }

    func testLegacyRetryGatewaySettingsCannotEnableExperimentalBehavior() throws {
        var config = CodexBarConfig()
        config.openAI.reasoningRetryGuard = .init(isEnabled: true, routeTargetRetryAttempts: 9)
        config.openAI.gatewayPromptPatch = .init(isEnabled: true, instructions: "legacy instruction")
        try self.writeConfig(config)
        let gateway = OpenAIAccountGatewayControllerSpy()

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.isEnabled, false)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.routeTargetRetryAttempts, 0)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.retryUpstreamCapacityErrors, false)
        XCTAssertEqual(gateway.promptPatchConfigurations.last?.isEnabled, false)
    }

    func testRemovingActiveOAuthAccountSynchronizesFallbackProvider() throws {
        let oauth = try self.makeOAuthAccount(
            accountID: "acct-remove-active-oauth",
            email: "delete@example.com",
            isActive: true
        )
        let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
            oauth,
            existingID: oauth.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuth.id,
            accounts: [storedOAuth]
        )
        let custom = self.makeCustomProvider()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: storedOAuth.id),
                providers: [oauthProvider, custom.provider]
            )
        )
        let syncService = RecordingSyncService()
        let store = TokenStore(
            syncService: syncService,
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        let baselineSyncCount = syncService.callCount
        try store.remove(oauth)

        XCTAssertEqual(store.config.active.providerId, custom.provider.id)
        XCTAssertEqual(store.config.active.accountId, custom.account.id)
        XCTAssertNil(store.config.oauthProvider())
        XCTAssertEqual(syncService.callCount, baselineSyncCount + 1)
        XCTAssertEqual(syncService.lastConfig?.active.providerId, custom.provider.id)
        XCTAssertNil(syncService.lastConfig?.oauthProvider())
    }

    func testSwitchModeInitializationKeepsGatewayStopped() {
        let gateway = OpenAIAccountGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 0)
        XCTAssertEqual(gateway.stopCount, 1)
        XCTAssertEqual(gateway.updatedModes, [.switchAccount])
    }

    func testGatewayRouteNotificationRefreshesRoutedAccount() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct-routed",
            email: "routed@example.com"
        )

        store.addOrUpdate(account)
        gateway.currentRoutedAccountIDValue = account.accountId

        NotificationCenter.default.post(
            name: .openAIAccountGatewayDidRouteAccount,
            object: gateway,
            userInfo: ["accountID": account.accountId]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store.gatewayRoutedAccount?.accountId, account.accountId)
    }

    func testCustomProviderTargetWithOAuthLoginStartsUnifiedGateway() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let oauthAccount = try self.makeOAuthAccount(
            accountID: "acct-oauth-route",
            email: "oauth-route@example.com"
        )
        let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
            oauthAccount,
            existingID: oauthAccount.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuth.id,
            accounts: [storedOAuth]
        )
        var custom = self.makeCustomProvider()
        custom.provider.accounts[0].modelSelection = .init(selectedModelID: "gpt-5.4", pinnedModelIDs: ["gpt-5.4"])
        try self.writeLegacyHybridConfig(active: .init(providerId: custom.provider.id, accountId: custom.account.id),
            providers: [oauthProvider, custom.provider])

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 2)
        guard case .compatibleProvider(let target)? = gateway.routeTargets.last else {
            XCTFail("expected compatible provider route target")
            return
        }
        XCTAssertEqual(target.providerID, custom.provider.id)
        XCTAssertEqual(target.accountID, custom.account.id)
    }

    func testActivatingCustomProviderDoesNotChangeOAuthLoginAccount() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let firstOAuth = try self.makeOAuthAccount(
            accountID: "acct-oauth-first",
            email: "first@example.com"
        )
        let secondOAuth = try self.makeOAuthAccount(
            accountID: "acct-oauth-second",
            email: "second@example.com"
        )
        let storedFirst = CodexBarProviderAccount.fromTokenAccount(
            firstOAuth,
            existingID: firstOAuth.accountId
        )
        let storedSecond = CodexBarProviderAccount.fromTokenAccount(
            secondOAuth,
            existingID: secondOAuth.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedSecond.id,
            accounts: [storedFirst, storedSecond]
        )
        var custom = self.makeCustomProvider()
        custom.provider.accounts[0].modelSelection = .init(selectedModelID: "gpt-5.4", pinnedModelIDs: ["gpt-5.4"])
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: storedSecond.id),
                providers: [oauthProvider, custom.provider]
            )
        )
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        try store.activateCustomProvider(providerID: custom.provider.id, accountID: custom.account.id)

        XCTAssertEqual(store.config.openAI.accountUsageMode, .hybridProvider)
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, storedSecond.id)
        XCTAssertEqual(store.config.active.providerId, custom.provider.id)
        guard case .compatibleProvider? = gateway.routeTargets.last else {
            XCTFail("expected compatible provider route target")
            return
        }
    }

    func testActivatingCustomProviderInSwitchModeKeepsProviderAsSwitchTarget() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let firstOAuth = try self.makeOAuthAccount(
            accountID: "acct-oauth-first",
            email: "first@example.com"
        )
        let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
            firstOAuth,
            existingID: firstOAuth.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuth.id,
            accounts: [storedOAuth]
        )
        let custom = self.makeCustomProvider()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: storedOAuth.id),
                providers: [oauthProvider, custom.provider]
            )
        )
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )
        let initialStopCount = gateway.stopCount

        try store.activateCustomProvider(
            providerID: custom.provider.id,
            accountID: custom.account.id,
            accountUsageMode: .switchAccount
        )

        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(store.config.oauthProvider()?.activeAccountId, storedOAuth.id)
        XCTAssertEqual(store.config.active.providerId, custom.provider.id)
        XCTAssertEqual(store.config.active.accountId, custom.account.id)
        XCTAssertEqual(store.config.openAI.switchModeSelection?.providerId, custom.provider.id)
        XCTAssertEqual(store.config.openAI.switchModeSelection?.accountId, custom.account.id)
        XCTAssertEqual(gateway.startCount, 0)
        XCTAssertEqual(gateway.stopCount, initialStopCount + 1)
        XCTAssertEqual(gateway.routeTargets.last, OpenAIAccountGatewayRouteTarget.none)
    }

    func testSwitchingBackFromThirdPartyProviderToOAuthClearsThirdPartySwitchSelection() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let firstOAuth = try self.makeOAuthAccount(
            accountID: "acct-oauth-first",
            email: "first@example.com"
        )
        let secondOAuth = try self.makeOAuthAccount(
            accountID: "acct-oauth-second",
            email: "second@example.com"
        )
        let storedFirst = CodexBarProviderAccount.fromTokenAccount(
            firstOAuth,
            existingID: firstOAuth.accountId
        )
        let storedSecond = CodexBarProviderAccount.fromTokenAccount(
            secondOAuth,
            existingID: secondOAuth.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedSecond.id,
            accounts: [storedFirst, storedSecond]
        )
        let thirdParty = self.makeThirdPartyModelProvider()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: storedSecond.id),
                openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
                providers: [oauthProvider, thirdParty.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        try store.activateCustomProvider(
            providerID: thirdParty.provider.id,
            accountID: thirdParty.account.id,
            accountUsageMode: .switchAccount
        )
        try store.updateOpenAIAccountUsageMode(.switchAccount)
        try store.restoreActiveSelection(activeProviderID: oauthProvider.id, activeAccountID: storedSecond.id)

        XCTAssertEqual(store.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(store.config.active.accountId, storedSecond.id)
        XCTAssertNil(store.config.openAI.switchModeSelection?.providerId)
        XCTAssertNil(store.config.openAI.switchModeSelection?.accountId)
        XCTAssertEqual(gateway.routeTargets.last, OpenAIAccountGatewayRouteTarget.none)
    }

    func testLegacyHybridOAuthMigratesAndStartsIntegratedGateway() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let oauth = try self.makeOAuthAccount(
            accountID: "acct-oauth-hybrid",
            email: "hybrid@example.com"
        )
        let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
            oauth,
            existingID: oauth.accountId
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuth.id,
            accounts: [storedOAuth]
        )
        try self.writeLegacyHybridConfig(active: .init(providerId: oauthProvider.id, accountId: storedOAuth.id),
            providers: [oauthProvider])

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.routeTargets.last, OpenAIAccountGatewayRouteTarget.openAIAccount(accountID: storedOAuth.id))
    }

    func testThirdPartyModelProviderInSwitchModeStartsUnifiedGatewayWithoutOAuthLogin() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let thirdParty = self.makeThirdPartyModelProvider()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(
                    providerId: thirdParty.provider.id,
                    accountId: thirdParty.account.id
                ),
                openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
                providers: [thirdParty.provider]
            )
        )

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 1)
        guard case .compatibleProvider(let target)? = gateway.routeTargets.last else {
            XCTFail("expected third-party compatible provider route target")
            return
        }
        XCTAssertEqual(target.providerID, thirdParty.provider.id)
        XCTAssertEqual(target.accountID, thirdParty.account.id)
        XCTAssertEqual(target.thirdPartyModelProvider, .deepSeek)
    }

    func testInitializationAbsorbsNewerAuthJSONSnapshot() throws {
        let olderRefreshAt = Date(timeIntervalSince1970: 1_760_000_000)
        let newerRefreshAt = Date(timeIntervalSince1970: 1_760_000_600)
        let localAccount = try self.makeOAuthAccount(
            accountID: "acct_load_reconcile",
            email: "load-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_760_003_600),
            oauthClientID: "app_local_load",
            tokenLastRefreshAt: olderRefreshAt
        )
        let authAccount = try self.makeOAuthAccount(
            accountID: "acct_load_reconcile",
            email: "load-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_760_007_200),
            oauthClientID: "app_auth_load",
            tokenLastRefreshAt: newerRefreshAt
        )
        let stored = CodexBarProviderAccount.fromTokenAccount(localAccount, existingID: localAccount.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: stored.id,
            accounts: [stored]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
                providers: [provider]
            )
        )
        try self.writeAuthJSON(
            accessToken: authAccount.accessToken,
            refreshToken: authAccount.refreshToken,
            idToken: authAccount.idToken,
            remoteAccountID: authAccount.remoteAccountId,
            clientID: "app_auth_load",
            lastRefresh: newerRefreshAt
        )

        let store = TokenStore(
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            codexRunningProcessIDs: { [] }
        )

        let resolved = try XCTUnwrap(store.oauthAccount(accountID: localAccount.accountId))
        XCTAssertEqual(resolved.accessToken, authAccount.accessToken)
        XCTAssertEqual(resolved.oauthClientID, "app_auth_load")
        XCTAssertEqual(resolved.tokenLastRefreshAt, newerRefreshAt)
    }

    func testActivateAbsorbsNewerAuthJSONBeforeSynchronizing() throws {
        let syncService = RecordingSyncService()
        let gateway = OpenAIAccountGatewayControllerSpy()

        let activeOtherAccount = try self.makeOAuthAccount(
            accountID: "acct_active_other",
            email: "active-other@example.com"
        )
        let localAccount = try self.makeOAuthAccount(
            accountID: "acct_activate_reconcile",
            email: "activate-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_770_003_600),
            oauthClientID: "app_activate_local",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let authAccount = try self.makeOAuthAccount(
            accountID: "acct_activate_reconcile",
            email: "activate-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_770_007_200),
            oauthClientID: "app_activate_auth",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_770_000_600)
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: activeOtherAccount.accountId,
            accounts: [
                CodexBarProviderAccount.fromTokenAccount(activeOtherAccount, existingID: activeOtherAccount.accountId),
                CodexBarProviderAccount.fromTokenAccount(localAccount, existingID: localAccount.accountId),
            ]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: activeOtherAccount.accountId),
                providers: [provider]
            )
        )
        try self.writeAuthJSON(
            accessToken: authAccount.accessToken,
            refreshToken: authAccount.refreshToken,
            idToken: authAccount.idToken,
            remoteAccountID: authAccount.remoteAccountId,
            clientID: "app_activate_auth",
            lastRefresh: Date(timeIntervalSince1970: 1_770_000_600)
        )

        let store = TokenStore(
            syncService: syncService,
            openAIAccountGatewayService: gateway,
            codexRunningProcessIDs: { [] }
        )

        try store.activate(localAccount)

        let synchronizedAccount = try XCTUnwrap(syncService.lastConfig?.activeAccount())
        XCTAssertEqual(synchronizedAccount.accessToken, authAccount.accessToken)
        XCTAssertEqual(synchronizedAccount.oauthClientID, "app_activate_auth")
        XCTAssertEqual(store.activeAccount()?.accessToken, authAccount.accessToken)
    }
}

final class OpenAIAccountGatewayControllerSpy: OpenAIAccountGatewayControlling {
    var startCount = 0
    var stopCount = 0
    var updatedModes: [CodexBarOpenAIAccountUsageMode] = []
    var routeTargets: [OpenAIAccountGatewayRouteTarget] = []
    var promptPatchConfigurations: [CodexBarOpenAISettings.GatewayPromptPatchSettings] = []
    var reasoningRetryGuardConfigurations: [OpenAIAccountGatewayReasoningRetryGuardConfiguration] = []
    var reasoningRetryGuardSnapshotValue: OpenAIAccountGatewayReasoningRetryGuardSnapshot = .empty
    var currentRoutedAccountIDValue: String?
    private(set) var clearedStickyThreadIDs: [String] = []

    func startIfNeeded() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    func updateState(
        accounts: [TokenAccount],
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) {
        self.updatedModes.append(accountUsageMode)
        self.routeTargets.append(routeTarget)
    }

    func setGatewayPromptPatchConfiguration(_ settings: CodexBarOpenAISettings.GatewayPromptPatchSettings) {
        self.promptPatchConfigurations.append(settings)
    }

    func setReasoningRetryGuardConfiguration(_ configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration) {
        self.reasoningRetryGuardConfigurations.append(configuration)
        self.reasoningRetryGuardSnapshotValue.configuration = configuration
    }

    func reasoningRetryGuardSnapshot() -> OpenAIAccountGatewayReasoningRetryGuardSnapshot {
        self.reasoningRetryGuardSnapshotValue
    }

    func currentRoutedAccountID() -> String? {
        self.currentRoutedAccountIDValue
    }


}

final class OpenRouterGatewayControllerSpy: OpenRouterGatewayControlling {
    var startCount = 0
    var stopCount = 0
    private(set) var lastProvider: CodexBarProvider?
    private(set) var lastIsActiveProvider = false

    func startIfNeeded() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {
        self.lastProvider = provider
        self.lastIsActiveProvider = isActiveProvider
    }

}

private final class OpenRouterGatewayLeaseStoreSpy: OpenRouterGatewayLeaseStoring {
    private var currentLease: OpenRouterGatewayLeaseSnapshot?
    private(set) var lastSavedLease: OpenRouterGatewayLeaseSnapshot?
    private(set) var cleared = false

    init(initialLease: OpenRouterGatewayLeaseSnapshot? = nil) {
        self.currentLease = initialLease
    }

    func loadLease() -> OpenRouterGatewayLeaseSnapshot? {
        self.currentLease
    }

    func saveLease(_ lease: OpenRouterGatewayLeaseSnapshot) {
        self.currentLease = lease
        self.lastSavedLease = lease
        self.cleared = false
    }

    func clear() {
        self.currentLease = nil
        self.lastSavedLease = nil
        self.cleared = true
    }
}

private final class RecordingSyncService: CodexSynchronizing {
    private(set) var callCount = 0
    private(set) var lastConfig: CodexBarConfig?

    func synchronize(config: CodexBarConfig) throws {
        self.callCount += 1
        self.lastConfig = config
    }
}

private extension TokenStoreGatewayLifecycleTests {
    func writeLegacyHybridConfig(active: CodexBarActiveSelection, providers: [CodexBarProvider]) throws {
        let config = CodexBarConfig(active: active, openAI: .init(accountUsageMode: .hybridProvider), providers: providers)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var openAI = try XCTUnwrap(json["openAI"] as? [String: Any])
        openAI.removeValue(forKey: "modelRoutingStyle")
        json["openAI"] = openAI
        try CodexPaths.writeSecureFile(JSONSerialization.data(withJSONObject: json), to: CodexPaths.barConfigURL)
    }

    func makeOpenRouterAccount(id: String) -> CodexBarProviderAccount {
        CodexBarProviderAccount(
            id: id,
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-\(id)"
        )
    }

    func makeOpenRouterProvider(account: CodexBarProviderAccount) -> CodexBarProvider {
        CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "openai/gpt-4.1",
            activeAccountId: account.id,
            accounts: [account]
        )
    }

    func makeCustomProvider() -> (provider: CodexBarProvider, account: CodexBarProviderAccount) {
        let account = CodexBarProviderAccount(
            id: "acct-compatible",
            kind: .apiKey,
            label: "Compatible",
            apiKey: "sk-compatible"
        )
        let provider = CodexBarProvider(
            id: "compatible-provider",
            kind: .openAICompatible,
            label: "Compatible",
            enabled: true,
            baseURL: "https://example.invalid/v1",
            activeAccountId: account.id,
            accounts: [account]
        )
        return (provider, account)
    }

    func makeThirdPartyModelProvider() -> (provider: CodexBarProvider, account: CodexBarProviderAccount) {
        let account = CodexBarProviderAccount(
            id: "acct-deepseek",
            kind: .apiKey,
            label: "DeepSeek",
            apiKey: "sk-deepseek"
        )
        let provider = CodexBarProvider(
            id: "deepseek",
            kind: .openAICompatible,
            label: "DeepSeek",
            enabled: true,
            baseURL: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL,
            defaultModel: "deepseek-v4-pro",
            thirdPartyModelProvider: .deepSeek,
            activeAccountId: account.id,
            accounts: [account]
        )
        return (provider, account)
    }
}

private struct FailingIntegrationSync: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws { throw CodexModelRoutingError.missingCatalog }
}
