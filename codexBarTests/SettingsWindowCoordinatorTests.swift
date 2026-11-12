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
            accounts: accounts
        )

        coordinator.moveAccount(accountID: "acct_beta", offset: -1)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.selectedPage = .accounts
        coordinator.selectedPage = .updates

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_beta", "acct_alpha"])
        coordinator.selectedPage = .usage
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
        coordinator.selectedPage = .accounts
        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_beta", "acct_alpha"])
    }

    func testBackupPageExistsButDoesNotCreateSettingsSaveRequests() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: []
        )

        XCTAssertTrue(SettingsPage.allCases.contains(.backup))

        coordinator.selectedPage = .backup

        XCTAssertTrue(coordinator.makeSaveRequests().isEmpty)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testSkillsPageExistsAndDoesNotCreateSettingsSaveRequests() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: []
        )

        XCTAssertTrue(SettingsPage.allCases.contains(.skills))

        coordinator.selectedPage = .skills

        XCTAssertTrue(coordinator.makeSaveRequests().isEmpty)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testCommittingUsageDisplayModeDoesNotLeaveDraftDirty() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: []
        )

        coordinator.commitUsageDisplayMode(.remaining)

        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
        XCTAssertTrue(coordinator.makeSaveRequests().isEmpty)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testSaveEmitsChangedDomainRequestsAndReopenReflectsSavedValues() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts
        )

        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.selectedPage = .accounts

        let result = try coordinator.save(using: sink)
        let requests = result.requests

        XCTAssertEqual(sink.appliedRequests.count, 1)
        XCTAssertFalse(result.routeTargetApplied)
        XCTAssertEqual(
            requests.openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount
            )
        )
        XCTAssertEqual(
            requests.openAIUsage,
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining
            )
        )
        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts
        )
        XCTAssertEqual(reopened.draft.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(reopened.draft.usageDisplayMode, .remaining)
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
            accounts: [oauthAccount]
        )

        coordinator.selectRouteTarget(.openAIAccount(accountID: oauthAccount.accountId, mode: .switchAccount))

        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(sink.config.active.accountId, storedOAuth.id)
        XCTAssertEqual(sink.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertNotNil(sink.appliedRouteTarget)
    }

    func testInitialOAuthRouteTargetUsesLocalAccountIDForQuickSwitchSelection() throws {
        let oauthAccount = try self.makeAccount(
            email: "oauth@example.com",
            accountId: "acct_local",
            openAIAccountId: "acct_remote"
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
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: storedOAuth.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
            providers: [oauthProvider]
        )
        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [oauthAccount]
        )

        XCTAssertEqual(
            coordinator.draft.route.target,
            .openAIAccount(accountID: oauthAccount.accountId, mode: .switchAccount)
        )
        XCTAssertTrue(
            coordinator.isRouteTargetSelected(
                .openAIAccount(accountID: oauthAccount.accountId, mode: .switchAccount)
            )
        )
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
            accounts: [oauthAccount]
        )

        coordinator.selectRouteTarget(.openAIAccount(accountID: oauthAccount.accountId, mode: .switchAccount))
        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(sink.config.active.accountId, storedOAuth.id)
        XCTAssertNil(sink.config.openAI.switchModeSelection?.providerId)
        XCTAssertNil(sink.config.openAI.switchModeSelection?.accountId)
    }

    func testSavingHybridOAuthRouteKeepsSelectedOAuthAccountInHybridMode() throws {
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
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: storedOAuth.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
            providers: [oauthProvider]
        )
        let sink = TestSettingsSaveSink(config: config)
        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [oauthAccount]
        )

        coordinator.selectRouteTarget(
            .openAIAccount(accountID: oauthAccount.accountId, mode: .hybridProvider)
        )
        let result = try coordinator.saveGettingStartedSettings(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.openAI.accountUsageMode, .hybridProvider)
        XCTAssertEqual(sink.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(sink.config.active.accountId, storedOAuth.id)
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
            accounts: [oauthAccount]
        )

        coordinator.selectRouteTarget(.openRouter(accountID: openRouterAccount.id, modelID: "openai/gpt-4.1", mode: .switchAccount))
        let result = try coordinator.save(using: sink)

        XCTAssertTrue(result.routeTargetApplied)
        XCTAssertEqual(sink.config.active.providerId, openRouterProvider.id)
        XCTAssertEqual(sink.config.active.accountId, openRouterAccount.id)
        XCTAssertEqual(sink.config.openAI.accountUsageMode, .hybridProvider)
        XCTAssertTrue(coordinator.draft.route.modelRoutingEnabled)
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
            accounts: accounts
        )

        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.selectedPage = .accounts

        coordinator.cancel()

        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts
        )
        XCTAssertEqual(
            reopened.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts
            )
        )
    }

    func testImmediatePreferencesApplyWithoutSavingStagedAccountOrder() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let launchAtLoginController = TestLaunchAtLoginController(isEnabled: false)
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            launchAtLoginController: launchAtLoginController
        )
        let path = try self.makeValidCodexApp(named: "Immediate/Codex.app").path

        coordinator.moveAccount(accountID: "acct_beta", offset: -1)
        coordinator.applyLaunchAtLogin(true)
        coordinator.applyPreferredCodexAppPath(path, using: sink)
        XCTAssertEqual(sink.config.desktop.preferredCodexAppPath, path)
        coordinator.applyPreferredCodexAppPath(nil, using: sink)
        XCTAssertNil(sink.config.desktop.preferredCodexAppPath)
        coordinator.applyUsagePollingInterval(1, using: sink)
        XCTAssertEqual(sink.config.openAI.usagePollingIntervalSeconds, 5)
        XCTAssertEqual(sink.config.openAI.usageDisplayMode, .used)
        XCTAssertEqual(launchAtLoginController.appliedValues, [true])
        XCTAssertEqual(sink.config.openAI.accountOrder, ["acct_alpha", "acct_beta"])
        XCTAssertTrue(sink.appliedRequests.allSatisfy { $0.openAIAccount == nil })

        coordinator.cancelAccountSettingsChanges()
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertTrue(coordinator.draft.launchAtLoginEnabled)
        XCTAssertNil(coordinator.draft.preferredCodexAppPath)
        XCTAssertEqual(coordinator.draft.usagePollingIntervalSeconds, 5)
    }

    func testFailedImmediateSaveKeepsAppliedPreference() {
        let config = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [])
        coordinator.applyUsagePollingInterval(30, using: FailingSettingsSaveSink())
        XCTAssertEqual(coordinator.draft.usagePollingIntervalSeconds, config.openAI.usagePollingIntervalSeconds)
        XCTAssertEqual(coordinator.validationMessage, "save failed")
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
            accounts: accounts
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
            accounts: accounts
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
            accounts: accounts
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
            accounts: initialAccounts
        )

        var externalConfig = self.makeConfig()
        externalConfig.openAI.usageDisplayMode = .remaining

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts
        )

        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
    }

    func testReconcileExternalStateKeepsExplicitlyEditedFieldEvenIfValueMatchesOriginalBaseline() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts
        )

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.usageDisplayMode, to: .used, field: .usageDisplayMode)

        var externalConfig = self.makeConfig()
        externalConfig.openAI.usageDisplayMode = .remaining

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts
        )

        XCTAssertEqual(coordinator.draft.usageDisplayMode, .used)
        XCTAssertEqual(coordinator.makeSaveRequests().openAIUsage?.usageDisplayMode, .used)
    }

    func testReconcileExternalStateMergesNewAccountsIntoEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts
        )
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])

        var externalConfig = self.makeConfig()
        externalConfig.setOpenAIAccountOrder(["acct_alpha", "acct_beta", "acct_gamma"])
        let updatedAccounts = initialAccounts + [
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts
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
            accounts: initialAccounts
        )
        coordinator.setAccountOrder(["acct_gamma", "acct_beta", "acct_alpha"])

        let updatedAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let externalConfig = self.makeConfig(accountOrder: ["acct_alpha", "acct_gamma"])

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts
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
            accounts: accounts
        )

        coordinator.selectedPage = .records

        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(coordinator.makeSaveRequests(), SettingsSaveRequests())
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts
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
            accounts: accounts
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
            accounts: []
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
            selectedPage: .records
        )

        SettingsSidebarSelectionAdapter.apply(.usage, to: coordinator)

        XCTAssertEqual(coordinator.selectedPage, .usage)
        XCTAssertEqual(SettingsSidebarSelectionAdapter.binding(for: coordinator).wrappedValue, .usage)
    }

    private func makeConfig(
        accountOrder: [String] = ["acct_alpha", "acct_beta"]
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
            openAI: CodexBarOpenAISettings(
                accountOrder: accountOrder
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

    private func makeAccount(
        email: String,
        accountId: String,
        openAIAccountId: String? = nil
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            openAIAccountId: openAIAccountId,
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)"
        )
    }

    private func makeValidCodexApp(named relativePath: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-settings-window-tests-\(UUID().uuidString)", isDirectory: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let appURL = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.openai.codex"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: infoPlistURL, options: .atomic)

        let executableURL = resourcesURL.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return appURL
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

    func applySettingsRoute(_ route: SettingsRouteDraft) throws -> Bool {
        let targetApplied: Bool
        if let target = route.target {
            targetApplied = try self.applySettingsRouteTarget(target)
        } else {
            targetApplied = false
        }
        return targetApplied
    }

    func applySettingsRouteTarget(_ target: SettingsRouteTarget) throws -> Bool {
        self.appliedRouteTarget = target
        switch target {
        case .openAIAccount(let accountID, let mode):
            _ = try self.config.activateOAuthAccount(accountID: accountID)
            self.config.openAI.accountUsageMode = mode
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

    func applySettingsRoute(_ route: SettingsRouteDraft) throws -> Bool {
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
        XCTAssertEqual(window.contentMinSize, CGSize(width: 700, height: 280))
        XCTAssertEqual(window.minSize.width, 700)
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
        XCTAssertEqual(existingWindow.contentMinSize, CGSize(width: 700, height: 280))
        XCTAssertEqual(existingWindow.minSize.width, 700)
        XCTAssertEqual(existingWindow.level, .normal)
        XCTAssertEqual(self.contentSize(of: existingWindow), CGSize(width: 940, height: 700))
    }

    func testExistingSettingsWindowEnforcesMinimumContentSizeOnReuse() throws {
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
        existingWindow.minSize = .zero
        existingWindow.contentMinSize = .zero
        existingWindow.setContentSize(CGSize(width: 520, height: 240))

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            Text("Updated")
        }

        XCTAssertTrue(existingWindow.styleMask.contains(.resizable))
        XCTAssertEqual(existingWindow.contentMinSize, CGSize(width: 700, height: 280))
        XCTAssertEqual(existingWindow.minSize.width, 700)
        XCTAssertEqual(existingWindow.level, .normal)
        XCTAssertEqual(self.contentSize(of: existingWindow), CGSize(width: 700, height: 280))
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
