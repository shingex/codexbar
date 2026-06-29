import Foundation
import XCTest

@MainActor
final class TokenStoreGatewayLifecycleTests: CodexBarTestCase {
    func testOpenRouterInitializationKeepsGatewayStoppedWhenInactive() {
        let openAIGateway = OpenAIAccountGatewayControllerSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: openAIGateway,
            openRouterGatewayService: openRouterGateway,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 1)
        XCTAssertEqual(openRouterGateway.stopCount, 0)
    }

    func testOpenRouterLeaseRestoreStartsGatewayWhenInactiveProviderStillHasServiceableState() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-restore")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: [404],
                leasedAt: Date(timeIntervalSince1970: 1_710_000_000),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [404] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 1)
        XCTAssertEqual(openRouterGateway.stopCount, 0)
        XCTAssertFalse(leaseStore.cleared)
        XCTAssertNil(leaseStore.lastSavedLease)
        XCTAssertEqual(openRouterGateway.lastProvider?.id, openRouterProvider.id)
        XCTAssertFalse(openRouterGateway.lastIsActiveProvider)
    }

    func testOpenRouterLeaseAcquireKeepsGatewayRunningAfterSwitchingAwayFromActiveProvider() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-acquire")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let runningPIDs: Set<pid_t> = [101, 202]
        let leaseStore = OpenRouterGatewayLeaseStoreSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: openRouterProvider.id, accountId: openRouterAccount.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { runningPIDs }
        )

        try store.activateCustomProvider(providerID: custom.provider.id, accountID: custom.account.id)

        XCTAssertEqual(openRouterGateway.stopCount, 0)
        XCTAssertEqual(leaseStore.lastSavedLease?.processIDs, runningPIDs)
        XCTAssertEqual(leaseStore.lastSavedLease?.sourceProviderId, "openrouter")
        XCTAssertEqual(openRouterGateway.lastProvider?.id, openRouterProvider.id)
        XCTAssertFalse(openRouterGateway.lastIsActiveProvider)
    }

    func testSwitchingFromOpenRouterToCompatibleProviderUsesGPTFallbackWhenProviderHasNoModel() throws {
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        try store.activateCustomProvider(providerID: custom.provider.id, accountID: custom.account.id)

        guard let target = gateway.routeTargets.compactMap({ route -> OpenAIAccountGatewayRouteTarget.CompatibleProvider? in
            guard case let .compatibleProvider(target) = route else { return nil }
            return target
        }).last else {
            XCTFail("expected compatible provider route target")
            return
        }
        XCTAssertEqual(target.modelID, "gpt-5.4")
    }

    func testSavingExperimentalCompressionUpdatesGatewayImmediately() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        let baselineCount = gateway.localCompressionConfigurations.count
        try store.saveExperimentalLocalCompressionEnabled(true)

        XCTAssertEqual(gateway.localCompressionConfigurations.count, baselineCount + 1)
        XCTAssertEqual(gateway.localCompressionConfigurations.last?.isEnabled, true)

        try store.saveExperimentalLocalCompressionEnabled(false)

        XCTAssertEqual(gateway.localCompressionConfigurations.count, baselineCount + 2)
        XCTAssertEqual(gateway.localCompressionConfigurations.last?.isEnabled, false)
    }

    func testSavingLocalCompressionSettingsUpdatesGatewayImmediately() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        let settings = CodexBarOpenAISettings.LocalCompressionSettings(
            minCharactersToCompress: 1024,
            minLinesToCompress: 25,
            targetRatio: 0.45,
            protectRecentItems: 2,
            compressUserMessages: false,
            compressSystemMessages: true,
            compressAssistantMessages: true,
            compressToolOutputs: false,
            appendCompressionMarker: false
        )

        let baselineCount = gateway.localCompressionConfigurations.count
        try store.saveLocalCompressionSettings(settings)

        XCTAssertEqual(gateway.localCompressionConfigurations.count, baselineCount + 1)
        XCTAssertEqual(gateway.localCompressionConfigurations.last?.settings, settings)
    }

    func testSavingReasoningRetryGuardUpdatesGatewayImmediately() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        let baselineCount = gateway.reasoningRetryGuardConfigurations.count
        try store.saveReasoningRetryGuardSettings(
            CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                isEnabled: true,
                matchMode: .cautious,
                reasoningEquals: [516, 1024],
                interceptStreaming: true,
                interceptNonStreaming: false,
                routeTargetRetryAttempts: 9,
                nonStreamStatusCode: 503,
                streamAction: .strict502,
                logMatch: false,
                endpoints: ["/v1/responses"]
            )
        )

        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.count, baselineCount + 1)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.isEnabled, true)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.matchMode, .cautious)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.reasoningEquals, Set([516, 1024]))
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.interceptStreaming, true)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.interceptNonStreaming, false)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.routeTargetRetryAttempts, 9)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.nonStreamStatusCode, 503)
        XCTAssertEqual(gateway.reasoningRetryGuardConfigurations.last?.endpoints, ["/v1/responses"])
        XCTAssertEqual(store.openAIAccountGatewayReasoningRetryGuardSnapshot.configuration.isEnabled, true)
    }

    func testLocalCompressionActivityAppendsPersistentHistory() throws {
        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        let activity = OpenAIAccountGatewayLocalCompressionActivity(
            route: .responses,
            accountUsageMode: .aggregateGateway,
            modelID: "gpt-5.4",
            inputByteCount: 2400,
            outputByteCount: 1200,
            inputTokenCount: 240,
            outputTokenCount: 120,
            recordedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )

        NotificationCenter.default.post(
            name: .openAIAccountGatewayDidApplyLocalCompression,
            object: activity
        )

        let timeout = Date().addingTimeInterval(1)
        while store.localCompressionHistory.isEmpty && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(store.localCompressionHistory.count, 1)
        XCTAssertEqual(store.localCompressionHistory.first?.inputTokenCount, 240)
        XCTAssertEqual(store.localCompressionHistory.first?.outputTokenCount, 120)
        XCTAssertEqual(store.localCompressionHistory.first?.compressionRatio ?? 0, 0.5, accuracy: 0.0001)

        let reloaded = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(reloaded.localCompressionHistory.first?.modelID, "gpt-5.4")
        XCTAssertEqual(reloaded.localCompressionHistory.first?.compressionRatio ?? 0, 0.5, accuracy: 0.0001)
    }

    func testOpenRouterLeaseRenewTracksNewRunningCodexProcesses() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-renew")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        var runningPIDs: Set<pid_t> = [101]
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: runningPIDs,
                leasedAt: Date(timeIntervalSince1970: 1_710_000_100),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { runningPIDs }
        )

        runningPIDs = [101, 202]
        store.markActiveAccount()

        XCTAssertEqual(openRouterGateway.stopCount, 0)
        XCTAssertEqual(leaseStore.lastSavedLease?.processIDs, runningPIDs)
        XCTAssertEqual(leaseStore.lastSavedLease?.sourceProviderId, "openrouter")
    }

    func testOpenRouterLeaseReleaseClearsPersistedLeaseWhenProviderBecomesActiveAgain() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-release")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: [303],
                leasedAt: Date(timeIntervalSince1970: 1_710_000_200),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [303] }
        )

        try store.activateOpenRouterProvider(accountID: openRouterAccount.id)

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertNil(leaseStore.lastSavedLease)
        XCTAssertTrue(openRouterGateway.lastIsActiveProvider)
        XCTAssertEqual(openRouterGateway.lastProvider?.id, openRouterProvider.id)
    }

    func testOpenRouterLeaseStaleCleanupStopsGatewayAfterAllLeasedProcessesExit() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-stale")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        var runningPIDs: Set<pid_t> = [909]
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: runningPIDs,
                leasedAt: Date(timeIntervalSince1970: 1_710_000_300),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { runningPIDs }
        )

        runningPIDs = []
        store.markActiveAccount()

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertEqual(openRouterGateway.stopCount, 1)
    }

    func testOpenRouterLeaseClearsWhenCanonicalProviderStopsBeingServiceable() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-invalid")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: [808],
                leasedAt: Date(timeIntervalSince1970: 1_710_000_400),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [808] }
        )

        try store.removeOpenRouterProviderAccount(accountID: openRouterAccount.id)

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertEqual(openRouterGateway.stopCount, 1)
        XCTAssertNil(openRouterGateway.lastProvider)
    }

    func testSwitchModeInitializationKeepsGatewayStopped() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 0)
        XCTAssertEqual(gateway.stopCount, 1)
        XCTAssertEqual(gateway.updatedModes, [.switchAccount])
    }

    func testAggregateModeInitializationStartsGateway() throws {
        var config = CodexBarConfig()
        config.openAI.accountUsageMode = .aggregateGateway
        try self.writeConfig(config)

        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes, [.aggregateGateway])
    }

    func testUpdatingUsageModeStartsAndStopsGateway() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct-gateway",
            email: "gateway@example.com"
        )

        store.addOrUpdate(account)
        try store.activate(account)

        let initialStopCount = gateway.stopCount
        let initialUpdateCount = gateway.updatedModes.count

        try store.updateOpenAIAccountUsageMode(.aggregateGateway)
        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, initialStopCount)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)

        try store.updateOpenAIAccountUsageMode(.switchAccount)
        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, initialStopCount + 1)
        XCTAssertEqual(gateway.updatedModes.count, initialUpdateCount + 2)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .switchAccount)
    }

    func testAggregateLeaseKeepsGatewayRunningAfterSwitchModeChange() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let runningPIDs: Set<pid_t> = [101, 202]
        let account = try self.makeOAuthAccount(
            accountID: "acct-lease",
            email: "lease@example.com"
        )
        let storedAccount = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedAccount.id,
            accounts: [storedAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: storedAccount.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .aggregateGateway),
            providers: [provider]
        )
        try self.writeConfig(config)

        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { runningPIDs }
        )

        try store.updateOpenAIAccountUsageMode(.switchAccount)

        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(leaseStore.savedProcessIDs, runningPIDs)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)
    }

    func testGatewayStopsOnceLeasedAggregateProcessesExit() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy(initialProcessIDs: [404])
        var runningPIDs: Set<pid_t> = [404]

        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { runningPIDs }
        )

        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)

        runningPIDs = []
        store.markActiveAccount()

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .switchAccount)
        XCTAssertEqual(gateway.stopCount, 1)
    }

    func testPersistedAggregateLeaseRestoresGatewayAfterRestart() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy(initialProcessIDs: [303])

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [303] }
        )

        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes, [.aggregateGateway])
    }

    func testGatewayRouteNotificationRefreshesAggregateRoutedAccount() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
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

        XCTAssertEqual(store.aggregateRoutedAccount?.accountId, account.accountId)
    }

    func testRuntimeRouteSnapshotShowsLeaseButNotFutureStickyAfterSwitchBack() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        gateway.currentRoutedAccountIDValue = "acct-lease"
        gateway.stickyBindings = [
            OpenAIAggregateStickyBindingSnapshot(
                threadID: "thread-lease",
                accountID: "acct-lease",
                updatedAt: Date().addingTimeInterval(-120)
            )
        ]
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy(initialProcessIDs: [404])
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [404] }
        )
        let attribution = OpenAIRunningThreadAttribution(
            threads: [],
            summary: .empty,
            recentActivityWindow: 5,
            diagnosticMessage: nil,
            unavailableReason: nil
        )

        let snapshot = store.openAIRuntimeRouteSnapshot(
            runningThreadAttribution: attribution,
            now: Date()
        )

        XCTAssertEqual(snapshot.configuredMode, .switchAccount)
        XCTAssertEqual(snapshot.effectiveMode, .aggregateGateway)
        XCTAssertTrue(snapshot.aggregateRuntimeActive)
        XCTAssertTrue(snapshot.leaseActive)
        XCTAssertFalse(snapshot.stickyAffectsFutureRouting)
        XCTAssertFalse(snapshot.staleStickyEligible)
        XCTAssertEqual(snapshot.latestRoutedAccountID, "acct-lease")
        XCTAssertTrue(snapshot.latestRoutedAccountIsSummary)
    }

    func testClearStaleAggregateStickyOnlyClearsGatewayBinding() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        gateway.stickyBindings = [
            OpenAIAggregateStickyBindingSnapshot(
                threadID: "thread-stale",
                accountID: "acct-stale",
                updatedAt: Date().addingTimeInterval(-120)
            )
        ]
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )
        let snapshot = OpenAIRuntimeRouteSnapshot(
            configuredMode: .aggregateGateway,
            effectiveMode: .aggregateGateway,
            aggregateRuntimeActive: true,
            latestRoutedAccountID: "acct-stale",
            latestRoutedAccountIsSummary: true,
            stickyAffectsFutureRouting: true,
            leaseActive: false,
            staleStickyEligible: true,
            staleStickyThreadID: "thread-stale",
            latestRouteAt: Date().addingTimeInterval(-120)
        )

        XCTAssertTrue(store.clearStaleAggregateSticky(using: snapshot))
        XCTAssertEqual(gateway.clearedStickyThreadIDs, ["thread-stale"])
        XCTAssertTrue(gateway.stickyBindings.isEmpty)
    }

    func testSwitchModeRestoresPreviousProviderTargetAfterAggregateMode() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let oauthAccount = try self.makeOAuthAccount(
            accountID: "acct-oauth",
            email: "oauth@example.com"
        )
        let storedOAuthAccount = CodexBarProviderAccount.fromTokenAccount(
            oauthAccount,
            existingID: oauthAccount.accountId
        )
        let compatibleAccount = CodexBarProviderAccount(
            id: "acct-compatible",
            kind: .apiKey,
            label: "compatible",
            apiKey: "sk-compatible"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuthAccount.id,
            accounts: [storedOAuthAccount]
        )
        let compatibleProvider = CodexBarProvider(
            id: "compatible-provider",
            kind: .openAICompatible,
            label: "Compatible",
            activeAccountId: compatibleAccount.id,
            accounts: [compatibleAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: compatibleProvider.id,
                accountId: compatibleAccount.id
            ),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                switchModeSelection: CodexBarActiveSelection(
                    providerId: compatibleProvider.id,
                    accountId: compatibleAccount.id
                )
            ),
            providers: [oauthProvider, compatibleProvider]
        )
        try self.writeConfig(config)

        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        try store.updateOpenAIAccountUsageMode(.aggregateGateway)

        XCTAssertEqual(store.config.openAI.switchModeSelection?.providerId, compatibleProvider.id)
        XCTAssertEqual(store.config.openAI.switchModeSelection?.accountId, compatibleAccount.id)
        XCTAssertEqual(store.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(store.config.active.accountId, storedOAuthAccount.id)

        try store.updateOpenAIAccountUsageMode(.switchAccount)

        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(store.config.active.providerId, compatibleProvider.id)
        XCTAssertEqual(store.config.active.accountId, compatibleAccount.id)
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
        let custom = self.makeCustomProvider()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(
                    providerId: custom.provider.id,
                    accountId: custom.account.id
                ),
                openAI: CodexBarOpenAISettings(accountUsageMode: .hybridProvider),
                providers: [oauthProvider, custom.provider]
            )
        )

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 1)
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
        let custom = self.makeCustomProvider()
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
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

    func testSwitchModeRestoreIgnoresThirdPartySelectionAndDoesNotRehydrateIt() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let thirdParty = self.makeThirdPartyModelProvider()
        let oauth = try self.makeOAuthAccount(
            accountID: "acct-oauth-switch",
            email: "switch@example.com"
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
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: thirdParty.provider.id, accountId: thirdParty.account.id),
                openAI: CodexBarOpenAISettings(
                    accountUsageMode: .switchAccount,
                    switchModeSelection: CodexBarActiveSelection(providerId: thirdParty.provider.id, accountId: thirdParty.account.id)
                ),
                providers: [oauthProvider, thirdParty.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        try store.updateOpenAIAccountUsageMode(.aggregateGateway)
        try store.updateOpenAIAccountUsageMode(.switchAccount)

        XCTAssertEqual(store.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(store.config.active.accountId, storedOAuth.id)
        XCTAssertNil(store.config.openAI.switchModeSelection)
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
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
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
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
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()

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
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        try store.activate(localAccount)

        let synchronizedAccount = try XCTUnwrap(syncService.lastConfig?.activeAccount())
        XCTAssertEqual(synchronizedAccount.accessToken, authAccount.accessToken)
        XCTAssertEqual(synchronizedAccount.oauthClientID, "app_activate_auth")
        XCTAssertEqual(store.activeAccount()?.accessToken, authAccount.accessToken)
    }
}

private final class OpenAIAccountGatewayControllerSpy: OpenAIAccountGatewayControlling {
    var startCount = 0
    var stopCount = 0
    var updatedModes: [CodexBarOpenAIAccountUsageMode] = []
    var routeTargets: [OpenAIAccountGatewayRouteTarget] = []
    var localCompressionConfigurations: [(isEnabled: Bool, settings: CodexBarOpenAISettings.LocalCompressionSettings)] = []
    var reasoningRetryGuardConfigurations: [OpenAIAccountGatewayReasoningRetryGuardConfiguration] = []
    var reasoningRetryGuardSnapshotValue: OpenAIAccountGatewayReasoningRetryGuardSnapshot = .empty
    var currentRoutedAccountIDValue: String?
    var stickyBindings: [OpenAIAggregateStickyBindingSnapshot] = []
    private(set) var clearedStickyThreadIDs: [String] = []

    func startIfNeeded() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) {
        self.updatedModes.append(accountUsageMode)
        self.routeTargets.append(routeTarget)
    }

    func setExperimentalLocalCompressionConfiguration(
        isEnabled: Bool,
        settings: CodexBarOpenAISettings.LocalCompressionSettings
    ) {
        self.localCompressionConfigurations.append((isEnabled, settings))
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

    func isHandlingHighFrequencyRequests(recentActivityWindow _: TimeInterval) -> Bool {
        false
    }

    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] {
        self.stickyBindings
    }

    func clearStickyBinding(threadID: String) -> Bool {
        self.clearedStickyThreadIDs.append(threadID)
        let before = self.stickyBindings.count
        self.stickyBindings.removeAll { $0.threadID == threadID }
        return self.stickyBindings.count != before
    }
}

private final class OpenRouterGatewayControllerSpy: OpenRouterGatewayControlling {
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

    func isHandlingHighFrequencyRequests(recentActivityWindow _: TimeInterval) -> Bool {
        false
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

private final class OpenAIAggregateGatewayLeaseStoreSpy: OpenAIAggregateGatewayLeaseStoring {
    private(set) var savedProcessIDs: Set<pid_t> = []
    private(set) var cleared = false
    private let initialProcessIDs: Set<pid_t>

    init(initialProcessIDs: Set<pid_t> = []) {
        self.initialProcessIDs = initialProcessIDs
    }

    func loadProcessIDs() -> Set<pid_t> {
        self.initialProcessIDs
    }

    func saveProcessIDs(_ processIDs: Set<pid_t>) {
        self.savedProcessIDs = processIDs
        self.cleared = false
    }

    func clear() {
        self.savedProcessIDs = []
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
