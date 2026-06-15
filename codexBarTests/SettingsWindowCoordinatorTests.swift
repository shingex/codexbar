import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsWindowCoordinatorTests: XCTestCase {
    func testSwitchingPagesKeepsDraftAcrossEdits() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.4", "google/gemini-2.5-pro"]
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 14, field: .proRelativeToPlusMultiplier)
        coordinator.updateModelPricing(
            for: "google/gemini-2.5-pro",
            pricing: CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)
        coordinator.update(\.launchAtLoginEnabled, to: true, field: .launchAtLogin)
        coordinator.selectedPage = .updates

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .manual)
        coordinator.selectedPage = .usage
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
        XCTAssertEqual(coordinator.draft.plusRelativeWeight, 12)
        XCTAssertEqual(coordinator.draft.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(
            coordinator.draft.modelPricing["google/gemini-2.5-pro"],
            CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        XCTAssertEqual(coordinator.draft.preferredCodexAppPath, "/Applications/Codex.app")
        XCTAssertTrue(coordinator.draft.launchAtLoginEnabled)
        coordinator.selectedPage = .backup
        XCTAssertTrue(coordinator.draft.launchAtLoginEnabled)
    }

    func testBackupPageExistsButDoesNotCreateSettingsSaveRequests() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertTrue(SettingsPage.allCases.contains(.backup))

        coordinator.selectedPage = .backup

        XCTAssertTrue(coordinator.makeSaveRequests().isEmpty)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testCommittingUsageDisplayModeDoesNotLeaveDraftDirty() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.4"]
        )

        coordinator.commitUsageDisplayMode(.remaining)

        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
        XCTAssertTrue(coordinator.makeSaveRequests().isEmpty)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testConfiguredModelPricingStillAppearsWhenHistoricalModelsAreNotReady() {
        var config = self.makeConfig()
        config.modelPricing = [
            "google/gemini-2.5-pro": CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            ),
        ]

        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [],
            historicalModels: []
        )

        XCTAssertEqual(coordinator.historicalModels, ["google/gemini-2.5-pro"])
        XCTAssertEqual(
            coordinator.draft.modelPricing["google/gemini-2.5-pro"],
            CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
    }

    func testManualAccountOrderSectionVisibilityFollowsOrderingMode() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrderingMode: .quotaSort),
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertFalse(coordinator.showsManualAccountOrderSection)

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        XCTAssertTrue(coordinator.showsManualAccountOrderSection)

        coordinator.update(\.accountOrderingMode, to: .quotaSort, field: .accountOrderingMode)
        XCTAssertFalse(coordinator.showsManualAccountOrderSection)
    }

    func testSaveEmitsChangedDomainRequestsAndReopenReflectsSavedValues() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let launchAtLoginController = TestLaunchAtLoginController(isEnabled: false)
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4", "google/gemini-2.5-pro"],
            launchAtLoginController: launchAtLoginController
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 14, field: .proRelativeToPlusMultiplier)
        coordinator.update(\.teamRelativeToPlusMultiplier, to: 2.2, field: .teamRelativeToPlusMultiplier)
        coordinator.updateModelPricing(
            for: "google/gemini-2.5-pro",
            pricing: CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)
        coordinator.update(\.launchAtLoginEnabled, to: true, field: .launchAtLogin)

        let result = try coordinator.save(using: sink)
        let requests = result.requests

        XCTAssertEqual(sink.appliedRequests.count, 1)
        XCTAssertEqual(launchAtLoginController.appliedValues, [true])
        XCTAssertFalse(result.routeTargetApplied)
        XCTAssertEqual(
            requests.openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual
            )
        )
        XCTAssertEqual(
            requests.openAIUsage,
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                disableLocalUsageStats: false,
                plusRelativeWeight: 12,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2.2
            )
        )
        XCTAssertEqual(
            requests.desktop,
            DesktopSettingsUpdate(preferredCodexAppPath: "/Applications/Codex.app")
        )
        XCTAssertEqual(
            requests.launchAtLogin,
            LaunchAtLoginSettingsUpdate(isEnabled: true)
        )
        XCTAssertNil(sink.appliedRequests.first?.launchAtLogin)
        XCTAssertEqual(
            requests.modelPricing,
            ModelPricingSettingsUpdate(
                upserts: [
                    "google/gemini-2.5-pro": CodexBarModelPricing(
                        inputUSDPerToken: 0.9e-6,
                        cachedInputUSDPerToken: 0.4e-6,
                        outputUSDPerToken: 1.8e-6
                    ),
                ],
                removals: []
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4", "google/gemini-2.5-pro"],
            launchAtLoginController: launchAtLoginController
        )
        XCTAssertEqual(reopened.draft.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(reopened.draft.accountOrderingMode, .manual)
        XCTAssertEqual(reopened.draft.usageDisplayMode, .remaining)
        XCTAssertEqual(reopened.draft.plusRelativeWeight, 12)
        XCTAssertEqual(reopened.draft.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(reopened.draft.teamRelativeToPlusMultiplier, 2.2)
        XCTAssertEqual(reopened.draft.preferredCodexAppPath, "/Applications/Codex.app")
        XCTAssertTrue(reopened.draft.launchAtLoginEnabled)
        XCTAssertEqual(
            reopened.draft.modelPricing["google/gemini-2.5-pro"],
            CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
    }

    func testSavingRouteTargetFromThirdPartyBackToOAuthAppliesSelectionAndKeepsCodexSyncIntent() throws {
        let oauthAccount = try self.makeAccount(email: "oauth@example.com", accountId: "acct_oauth")
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
        let customAccount = CodexBarProviderAccount(
            id: "acct_custom",
            kind: .apiKey,
            label: "Custom",
            apiKey: "sk-custom"
        )
        let customProvider = CodexBarProvider(
            id: "custom-provider",
            kind: .openAICompatible,
            label: "Custom",
            activeAccountId: customAccount.id,
            accounts: [customAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: customProvider.id, accountId: customAccount.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
            providers: [oauthProvider, customProvider]
        )
        let sink = TestSettingsSaveSink(config: config)
        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [oauthAccount],
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectRouteTarget(.openAIAccount(accountID: oauthAccount.accountId))

        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(sink.config.active.accountId, storedOAuth.id)
        XCTAssertEqual(sink.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertNotNil(sink.appliedRouteTarget)
    }

    func testSavingRouteTargetFromThirdPartyBackToOAuthDoesNotReapplyThirdPartySelection() throws {
        let oauthAccount = try self.makeAccount(email: "oauth@example.com", accountId: "acct_oauth")
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
        let customAccount = CodexBarProviderAccount(
            id: "acct_custom",
            kind: .apiKey,
            label: "Custom",
            apiKey: "sk-custom"
        )
        let customProvider = CodexBarProvider(
            id: "custom-provider",
            kind: .openAICompatible,
            label: "Custom",
            activeAccountId: customAccount.id,
            accounts: [customAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: customProvider.id, accountId: customAccount.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
            providers: [oauthProvider, customProvider]
        )
        let sink = TestSettingsSaveSink(config: config)
        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [oauthAccount],
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectRouteTarget(.openAIAccount(accountID: oauthAccount.accountId))
        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(sink.config.active.accountId, storedOAuth.id)
        XCTAssertNil(sink.config.openAI.switchModeSelection?.providerId)
        XCTAssertNil(sink.config.openAI.switchModeSelection?.accountId)
    }

    func testSwitchingFromThirdPartyToOpenRouterDoesNotCarryThirdPartySelectionForward() throws {
        let oauthAccount = try self.makeAccount(email: "oauth@example.com", accountId: "acct_oauth")
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
        let openRouterAccount = CodexBarProviderAccount(
            id: "acct_openrouter",
            kind: .apiKey,
            label: "OpenRouter",
            apiKey: "sk-or"
        )
        let openRouterProvider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            activeAccountId: openRouterAccount.id,
            accounts: [openRouterAccount]
        )
        let customAccount = CodexBarProviderAccount(
            id: "acct_custom",
            kind: .apiKey,
            label: "Custom",
            apiKey: "sk-custom"
        )
        let customProvider = CodexBarProvider(
            id: "custom-provider",
            kind: .openAICompatible,
            label: "Custom",
            activeAccountId: customAccount.id,
            accounts: [customAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: customProvider.id, accountId: customAccount.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
            providers: [oauthProvider, openRouterProvider, customProvider]
        )
        let sink = TestSettingsSaveSink(config: config)
        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [oauthAccount],
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectRouteTarget(.openRouter(accountID: openRouterAccount.id, modelID: "openai/gpt-4.1", mode: .switchAccount))
        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.active.providerId, openRouterProvider.id)
        XCTAssertEqual(sink.config.active.accountId, openRouterAccount.id)
        XCTAssertEqual(sink.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertNil(sink.config.openAI.switchModeSelection?.providerId)
    }

    func testCancelRollsBackAcrossPagesAndDoesNotTriggerRequests() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let baseConfig = self.makeConfig()
        let sink = TestSettingsSaveSink(config: baseConfig)
        let coordinator = SettingsWindowCoordinator(
            config: baseConfig,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 14, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 15, field: .proRelativeToPlusMultiplier)
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)
        coordinator.update(\.launchAtLoginEnabled, to: true, field: .launchAtLogin)

        coordinator.cancel()

        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.4"]
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        XCTAssertEqual(
            reopened.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.4"]
            )
        )
    }

    func testLaunchAtLoginSaveUsesControllerWithoutPersistingToTokenStore() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let launchAtLoginController = TestLaunchAtLoginController(isEnabled: false)
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"],
            launchAtLoginController: launchAtLoginController
        )

        coordinator.update(\.launchAtLoginEnabled, to: true, field: .launchAtLogin)

        let result = try coordinator.save(using: sink)

        XCTAssertEqual(result.requests.launchAtLogin, LaunchAtLoginSettingsUpdate(isEnabled: true))
        XCTAssertEqual(launchAtLoginController.appliedValues, [true])
        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testSaveAndCloseClosesWindowAfterSuccessfulSave() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.saveAndClose(using: sink) {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(sink.appliedRequests.count, 1)
    }

    func testCancelAndCloseDoesNotSaveButClosesWindow() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.cancelAndClose {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .used)
    }

    func testSaveAndCloseKeepsWindowOpenWhenSaveFails() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )
        let sink = FailingSettingsSaveSink()
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.saveAndClose(using: sink) {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(coordinator.validationMessage, "save failed")
    }

    func testRouteSelectionIsDraftOnlyUntilSave() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectRouteMode(.aggregateGateway)

        XCTAssertTrue(coordinator.hasStagedRouteChange)
        XCTAssertNil(sink.appliedRouteTarget)

        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.requests.isEmpty)
        XCTAssertEqual(sink.appliedRouteTarget, .aggregateGateway)
        XCTAssertTrue(result.routeTargetApplied)
    }

    func testGettingStartedProgressMatchesModeRequirements() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(
            coordinator.gettingStartedProgress(
                mode: .switchAccount,
                openAIAccountCount: 1,
                thirdPartyAccountCount: 1
            ).completedStepCount,
            2
        )
        XCTAssertEqual(
            coordinator.gettingStartedProgress(
                mode: .hybridProvider,
                openAIAccountCount: 2,
                thirdPartyAccountCount: 0
            ).completedStepCount,
            1
        )
        XCTAssertEqual(
            coordinator.gettingStartedProgress(
                mode: .aggregateGateway,
                openAIAccountCount: 1,
                thirdPartyAccountCount: 5
            ).completedStepCount,
            1
        )
    }

    func testCompletedGettingStartedProgressOnlyShowsAfterWindowStateTransition() {
        let incomplete = SettingsGettingStartedProgress(
            mode: .hybridProvider,
            openAIAccountCount: 1,
            thirdPartyAccountCount: 0
        )
        let complete = SettingsGettingStartedProgress(
            mode: .hybridProvider,
            openAIAccountCount: 1,
            thirdPartyAccountCount: 1
        )

        XCTAssertTrue(
            SettingsGettingStartedProgress.shouldShowRequirementProgress(
                current: incomplete,
                previous: nil,
                showingCompletedProgress: false
            )
        )
        XCTAssertFalse(
            SettingsGettingStartedProgress.shouldShowRequirementProgress(
                current: complete,
                previous: nil,
                showingCompletedProgress: false
            )
        )
        XCTAssertTrue(
            SettingsGettingStartedProgress.shouldShowRequirementProgress(
                current: complete,
                previous: incomplete,
                showingCompletedProgress: false
            )
        )
    }

    func testReconcileExternalStateRefreshesUntouchedFieldsAndPreservesEditedFields() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        var externalConfig = self.makeConfig()
        externalConfig.openAI.accountOrderingMode = .manual
        externalConfig.openAI.usageDisplayMode = .remaining

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .manual)
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
    }

    func testReconcileExternalStateKeepsExplicitlyEditedFieldEvenIfValueMatchesOriginalBaseline() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.update(\.accountOrderingMode, to: .quotaSort, field: .accountOrderingMode)

        var externalConfig = self.makeConfig()
        externalConfig.openAI.accountOrderingMode = .manual

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .quotaSort)
        XCTAssertEqual(
            coordinator.makeSaveRequests().openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha", "acct_beta"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort
            )
        )
    }

    func testReconcileExternalStateMergesNewAccountsIntoEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])

        var externalConfig = self.makeConfig()
        externalConfig.setOpenAIAccountOrder(["acct_alpha", "acct_beta", "acct_gamma"])
        let updatedAccounts = initialAccounts + [
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_beta", "acct_alpha", "acct_gamma"])
        XCTAssertEqual(coordinator.orderedAccounts.map(\.id), ["acct_beta", "acct_alpha", "acct_gamma"])
    }

    func testReconcileExternalStateDropsRemovedAccountsFromEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrder: ["acct_alpha", "acct_beta", "acct_gamma"]),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.4"]
        )
        coordinator.setAccountOrder(["acct_gamma", "acct_beta", "acct_alpha"])

        let updatedAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let externalConfig = self.makeConfig(accountOrder: ["acct_alpha", "acct_gamma"])

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts,
            historicalModels: ["gpt-5.4"]
        )

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_gamma", "acct_alpha"])
        XCTAssertEqual(coordinator.orderedAccounts.map(\.id), ["acct_gamma", "acct_alpha"])
    }

    func testRecordsPageNavigationDoesNotDirtySettings() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let baseConfig = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(
            config: baseConfig,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectedPage = .records

        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(coordinator.makeSaveRequests(), SettingsSaveRequests())
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.4"]
            )
        )
    }

    func testSavingFromRecordsPageDoesNotEmitAdditionalSettingsRequests() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.4"]
        )

        coordinator.selectedPage = .records

        let result = try coordinator.save(using: sink)
        let requests = result.requests

        XCTAssertEqual(requests, SettingsSaveRequests())
        XCTAssertFalse(result.routeTargetApplied)
        XCTAssertTrue(sink.appliedRequests.isEmpty)
    }

    func testSidebarSelectionBindingStartsAtGettingStartedAndWritesBack() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.4"]
        )

        let selection = SettingsSidebarSelectionAdapter.binding(for: coordinator)

        XCTAssertEqual(selection.wrappedValue, .gettingStarted)

        selection.wrappedValue = .usage

        XCTAssertEqual(coordinator.selectedPage, .usage)
        XCTAssertEqual(selection.wrappedValue, .usage)
    }

    func testSidebarSelectionBindingIgnoresNil() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.4"],
            selectedPage: .records
        )

        let selection = SettingsSidebarSelectionAdapter.binding(for: coordinator)
        selection.wrappedValue = nil

        XCTAssertEqual(coordinator.selectedPage, .records)
        XCTAssertEqual(selection.wrappedValue, .records)
    }

    func testRecordsToUsageNavigationKeepsSelectionBackedDetail() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.4"],
            selectedPage: .records
        )

        SettingsSidebarSelectionAdapter.apply(.usage, to: coordinator)

        XCTAssertEqual(coordinator.selectedPage, .usage)
        XCTAssertEqual(SettingsSidebarSelectionAdapter.binding(for: coordinator).wrappedValue, .usage)
    }

    private func makeConfig(
        accountOrder: [String] = ["acct_alpha", "acct_beta"],
        accountOrderingMode: CodexBarOpenAIAccountOrderingMode = .quotaSort,
        modelPricing: [String: CodexBarModelPricing] = [:]
    ) -> CodexBarConfig {
        let alpha = CodexBarProviderAccount(
            id: "acct_alpha",
            kind: .oauthTokens,
            label: "alpha@example.com",
            email: "alpha@example.com",
            openAIAccountId: "acct_alpha",
            accessToken: "access-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha"
        )
        let beta = CodexBarProviderAccount(
            id: "acct_beta",
            kind: .oauthTokens,
            label: "beta@example.com",
            email: "beta@example.com",
            openAIAccountId: "acct_beta",
            accessToken: "access-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta"
        )
        let gamma = CodexBarProviderAccount(
            id: "acct_gamma",
            kind: .oauthTokens,
            label: "gamma@example.com",
            email: "gamma@example.com",
            openAIAccountId: "acct_gamma",
            accessToken: "access-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma"
        )

        return CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: "openai-oauth",
                accountId: "acct_alpha"
            ),
            modelPricing: modelPricing,
            openAI: CodexBarOpenAISettings(
                accountOrder: accountOrder,
                accountOrderingMode: accountOrderingMode
            ),
            providers: [
                CodexBarProvider(
                    id: "openai-oauth",
                    kind: .openAIOAuth,
                    label: "OpenAI",
                    activeAccountId: "acct_alpha",
                    accounts: [alpha, beta, gamma]
                )
            ]
        )
    }

    private func makeAccount(email: String, accountId: String) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)"
        )
    }
}

@MainActor
private final class TestSettingsSaveSink: SettingsSaveRequestApplying {
    private(set) var config: CodexBarConfig
    private(set) var appliedRequests: [SettingsSaveRequests] = []
    private(set) var appliedRouteTarget: SettingsRouteTarget?

    init(config: CodexBarConfig) {
        self.config = config
    }

    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        self.appliedRequests.append(requests)
        try SettingsSaveRequestApplier.apply(requests, to: &self.config)
    }

    func applySettingsRouteTarget(_ target: SettingsRouteTarget) throws -> Bool {
        self.appliedRouteTarget = target
        switch target {
        case .openAIAccount(let accountID):
            _ = try self.config.activateOAuthAccount(accountID: accountID)
            self.config.openAI.accountUsageMode = .switchAccount
        case .aggregateGateway:
            self.config.openAI.accountUsageMode = .aggregateGateway
        case .compatibleProvider(let providerID, let accountID, _, let mode):
            self.config.active.providerId = providerID
            self.config.active.accountId = accountID
            self.config.openAI.accountUsageMode = mode
        case .openRouter(let accountID, _, let mode):
            self.config.active.providerId = self.config.openRouterProvider()?.id
            self.config.active.accountId = accountID
            self.config.openAI.accountUsageMode = mode
        }
        return true
    }
}

private struct FailingSettingsSaveSink: SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        throw TestSaveError.failed
    }

    func applySettingsRouteTarget(_ target: SettingsRouteTarget) throws -> Bool {
        throw TestSaveError.failed
    }

    private enum TestSaveError: LocalizedError {
        case failed

        var errorDescription: String? { "save failed" }
    }
}

@MainActor
private final class TestLaunchAtLoginController: LaunchAtLoginControlling {
    private(set) var isEnabled: Bool
    private(set) var appliedValues: [Bool] = []

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        self.isEnabled = isEnabled
        self.appliedValues.append(isEnabled)
    }
}

@MainActor
final class DetachedWindowPresenterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testDefaultWindowRemainsNonResizable() throws {
        let presenter = DetachedWindowPresenter()
        let id = "detached-window-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }

        let window = try self.window(withID: id)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, .zero)
    }

    func testOpenAISettingsWindowIsResizableAndAppliesMinimumContentSize() throws {
        let presenter = DetachedWindowPresenter()
        let id = "openai-settings-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            EmptyView()
        }

        let window = try self.window(withID: id)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, CGSize(width: 640, height: 280))
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(self.contentSize(of: window), CGSize(width: 820, height: 620))
    }

    func testExistingSettingsWindowReplaysConfigurationWithoutResettingUserSizedContent() throws {
        let presenter = DetachedWindowPresenter()
        let id = "openai-settings-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            EmptyView()
        }

        let existingWindow = try self.window(withID: id)
        existingWindow.setContentSize(CGSize(width: 940, height: 700))

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            Text("Updated")
        }

        XCTAssertTrue(existingWindow.styleMask.contains(.resizable))
        XCTAssertEqual(existingWindow.contentMinSize, CGSize(width: 640, height: 280))
        XCTAssertEqual(existingWindow.level, .normal)
        XCTAssertEqual(self.contentSize(of: existingWindow), CGSize(width: 940, height: 700))
    }

    func testDefaultWindowReuseStillResetsContentSize() throws {
        let presenter = DetachedWindowPresenter()
        let id = "detached-window-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }

        let existingWindow = try self.window(withID: id)
        existingWindow.setContentSize(CGSize(width: 610, height: 510))

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }

        XCTAssertFalse(existingWindow.styleMask.contains(.resizable))
        XCTAssertEqual(existingWindow.contentMinSize, .zero)
        XCTAssertEqual(self.contentSize(of: existingWindow), CGSize(width: 420, height: 320))
    }

    func testHoverPanelUsesTransparentNonClippingHost() throws {
        let presenter = DetachedWindowPresenter()
        let id = "hover-panel-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.showHoverPanel(
            id: id,
            size: CGSize(width: 320, height: 240),
            origin: CGPoint(x: 120, y: 160)
        ) {
            EmptyView()
        }

        let window = try self.window(withID: id)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.contentView?.layer?.masksToBounds ?? true)
        XCTAssertFalse(window.contentView?.clipsToBounds ?? true)
        XCTAssertFalse(window.contentViewController?.view.layer?.masksToBounds ?? true)
        XCTAssertFalse(window.contentViewController?.view.clipsToBounds ?? true)
    }

    func testExistingHoverPanelReappliesTransparentNonClippingHost() throws {
        let presenter = DetachedWindowPresenter()
        let id = "hover-panel-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.showHoverPanel(
            id: id,
            size: CGSize(width: 320, height: 240),
            origin: CGPoint(x: 120, y: 160)
        ) {
            EmptyView()
        }

        let window = try self.window(withID: id)
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.clipsToBounds = true
        window.contentViewController?.view.layer?.masksToBounds = true
        window.contentViewController?.view.clipsToBounds = true

        presenter.showHoverPanel(
            id: id,
            size: CGSize(width: 340, height: 260),
            origin: CGPoint(x: 140, y: 180)
        ) {
            Text("Updated")
        }

        XCTAssertFalse(window.contentView?.layer?.masksToBounds ?? true)
        XCTAssertFalse(window.contentView?.clipsToBounds ?? true)
        XCTAssertFalse(window.contentViewController?.view.layer?.masksToBounds ?? true)
        XCTAssertFalse(window.contentViewController?.view.clipsToBounds ?? true)
        XCTAssertEqual(window.frame.origin, CGPoint(x: 140, y: 180))
        XCTAssertEqual(window.frame.size, CGSize(width: 340, height: 260))
    }

    private func window(withID id: String) throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == id })
    }

    private func contentSize(of window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }
}
