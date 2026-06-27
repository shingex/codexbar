import Combine
import ServiceManagement
import SwiftUI

private struct SettingsDeleteConfirmationRequest: Identifiable {
    enum Target {
        case openAIAccount(TokenAccount)
        case customProviderAccount(providerID: String, providerLabel: String, accountID: String, accountLabel: String)
        case customProvider(providerID: String, providerLabel: String)
        case openRouterAccount(accountID: String, accountLabel: String)
    }

    let id = UUID()
    let target: Target

    var title: String {
        switch self.target {
        case .openAIAccount:
            return L.deleteOpenAIAccountConfirmTitle
        case .customProviderAccount, .openRouterAccount:
            return L.deleteProviderAccountConfirmTitle
        case .customProvider:
            return L.deleteProviderConfirmTitle
        }
    }

    var message: String {
        switch self.target {
        case .openAIAccount(let account):
            return L.deleteOpenAIAccountConfirmMessage(account.email.isEmpty ? account.accountId : account.email)
        case .customProviderAccount(_, let providerLabel, _, let accountLabel):
            return L.deleteProviderAccountConfirmMessage(accountLabel, providerLabel)
        case .customProvider(_, let providerLabel):
            return L.deleteProviderConfirmMessage(providerLabel)
        case .openRouterAccount(_, let accountLabel):
            return L.deleteProviderAccountConfirmMessage(accountLabel, "OpenRouter")
        }
    }
}

enum SettingsTypography {
    static let pageTitle = Font.system(size: 18, weight: .semibold)
    static let pageHint = Font.system(size: 12, weight: .medium)
    static let sectionTitle = Font.system(size: 16, weight: .semibold)
    static let subsectionTitle = Font.system(size: 13, weight: .semibold)
    static let sectionHint = Font.system(size: 11, weight: .medium)
}

private struct SystemLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject private var store: TokenStore
    @ObservedObject private var updateCoordinator: UpdateCoordinator
    private let codexAppPathPanelService: CodexAppPathPanelService
    private let onClose: () -> Void

    @StateObject private var coordinator: SettingsWindowCoordinator
    @StateObject private var recordsModel: SettingsRecordsModel
    @State private var pendingCodexLaunchPrompt = false
    @State private var closeAfterLaunchPrompt = false
    @State private var pendingDeleteConfirmation: SettingsDeleteConfirmationRequest?
    @State private var refreshingAccounts: Set<String> = []

    private let oauthAccountService = CodexBarOAuthAccountService()
    private let openAIAccountCSVService = OpenAIAccountCSVService()
    private let openAIAccountCSVPanelService = OpenAIAccountCSVPanelService()
    private let codexDesktopLaunchProbeService = CodexDesktopLaunchProbeService()
    private let backupService = CodexBarBackupService()
    private let backupPanelService = CodexBarBackupPanelService()

    @MainActor
    init(
        store: TokenStore,
        updateCoordinator: UpdateCoordinator? = nil,
        codexAppPathPanelService: CodexAppPathPanelService,
        onClose: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._updateCoordinator = ObservedObject(wrappedValue: updateCoordinator ?? .shared)
        self.codexAppPathPanelService = codexAppPathPanelService
        self.onClose = onClose
        self._coordinator = StateObject(
            wrappedValue: SettingsWindowCoordinator(
                config: store.config,
                accounts: store.accounts,
                historicalModels: store.historicalModels,
                launchAtLoginController: SystemLaunchAtLoginController()
            )
        )
        self._recordsModel = StateObject(
            wrappedValue: SettingsRecordsModel(
                service: RecordsSnapshotService()
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
        } detail: {
            self.detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(self.modeAccentColor)
        .accentColor(self.modeAccentColor)
        .buttonStyle(SettingsHoverButtonStyle())
        .alert(
            L.launchCodexPromptTitle,
            isPresented: self.$pendingCodexLaunchPrompt
        ) {
            Button(L.launchCodexPromptConfirm) {
                Task {
                    await self.launchCodexInstanceAfterPrompt()
                    self.finishAfterLaunchPrompt()
                }
            }

            Button(L.launchCodexPromptCancel, role: .cancel) {
                self.finishAfterLaunchPrompt()
            }
        } message: {
            Text(L.launchCodexPromptMessage)
        }
        .alert(item: self.$pendingDeleteConfirmation) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text(L.deleteConfirm)) {
                    self.performConfirmedDelete(request)
                },
                secondaryButton: .cancel(Text(L.cancel))
            )
        }
        .onReceive(self.store.$config.dropFirst()) { config in
            self.coordinator.reconcileExternalState(
                config: config,
                accounts: self.store.accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$accounts.dropFirst()) { accounts in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$historicalModels.dropFirst()) { historicalModels in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: self.store.accounts,
                historicalModels: historicalModels
            )
        }
    }

    private var sidebar: some View {
        List(SettingsPage.allCases, selection: SettingsSidebarSelectionAdapter.binding(for: self.coordinator)) { page in
            SettingsSidebarRow(
                page: page,
                isSelected: self.coordinator.selectedPage == page
            )
                .tag(Optional(page))
                .contentShape(Rectangle())
                .onTapGesture {
                    SettingsSidebarSelectionAdapter.apply(page, to: self.coordinator)
                }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: SettingsSidebarRow.minimumColumnWidth,
            ideal: max(220, SettingsSidebarRow.minimumColumnWidth),
            max: 300
        )
    }

    private var modeAccentColor: Color {
        Color(nsColor: self.coordinator.draft.route.mode.themeAccentColor)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let validationMessage = self.coordinator.validationMessage {
                SettingsValidationBanner(message: validationMessage)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }

            Group {
                switch self.coordinator.selectedPage {
                case .gettingStarted:
                    ScrollView {
                        SettingsGettingStartedPage(
                            store: self.store,
                            coordinator: self.coordinator,
                            refreshingAccounts: self.refreshingAccounts,
                            onAuthenticateOpenAI: self.startOAuthLogin,
                            onImportOpenAI: self.importOpenAIAccounts,
                            onRefreshOpenAI: self.refreshOpenAIAccount,
                            onReauthOpenAI: self.reauthOpenAIAccount,
                            onExportOpenAI: self.exportOpenAIAccount,
                            onDeleteOpenAI: self.confirmDeleteOpenAIAccount,
                            onAddProvider: self.openAddProviderWindow,
                            onAddProviderAccount: self.openAddProviderAccountWindow,
                            onEditProvider: self.openEditProviderWindow,
                            onEditProviderAccount: self.openEditProviderAccountWindow,
                            onDeleteProviderAccount: self.confirmDeleteCompatibleAccount,
                            onDeleteProvider: self.confirmDeleteProvider,
                            onAddOpenRouterAccount: self.openAddOpenRouterAccountWindow,
                            onEditOpenRouterAccount: self.openEditOpenRouterWindow,
                            onDeleteOpenRouterAccount: self.confirmDeleteOpenRouterAccount,
                            onSaveRouteSelection: self.saveRouteSelection
                        )
                        .settingsDetailPagePadding()
                    }
                case .accounts:
                    ScrollView {
                        SettingsAccountsPage(
                            coordinator: self.coordinator,
                            codexAppPathPanelService: self.codexAppPathPanelService,
                            onSave: self.saveAccountSettings
                        )
                        .settingsDetailPagePadding()
                    }
                case .skills:
                    SettingsSkillsPage()
                case .backup:
                    ScrollView {
                        SettingsBackupPage(
                            backupService: self.backupService,
                            backupPanelService: self.backupPanelService,
                            onRestoreCodexBarSettings: self.reloadSettingsState,
                            validationMessage: self.$coordinator.validationMessage
                        )
                        .settingsDetailPagePadding()
                    }
                case .records:
                    SettingsRecordsPage(recordsModel: self.recordsModel) {
                        SettingsSidebarSelectionAdapter.apply(.usage, to: self.coordinator)
                    }
                    .padding(20)
                case .usage:
                    ScrollView {
                        SettingsUsagePage(
                            store: self.store,
                            coordinator: self.coordinator,
                            onSave: self.saveUsageSettings,
                            onSaveProviderUsage: self.saveProviderUsageConfiguration,
                            onRefreshProviderUsage: self.refreshProviderUsage,
                            onDisableProviderUsage: self.disableProviderUsage
                        )
                        .settingsDetailPagePadding()
                    }
                case .updates:
                    ScrollView {
                        SettingsUpdatesPage(updateCoordinator: self.updateCoordinator)
                            .settingsDetailPagePadding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func saveRouteSelection() {
        do {
            let result = try self.coordinator.saveGettingStartedSettings(using: self.store)
            if result.routeTargetApplied {
                self.closeAfterLaunchPrompt = true
                self.pendingCodexLaunchPrompt = true
            } else {
                self.onClose()
            }
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func saveAccountSettings() {
        do {
            _ = try self.coordinator.saveAccountSettings(using: self.store)
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func saveUsageSettings() {
        do {
            _ = try self.coordinator.saveUsageSettings(using: self.store)
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func finishAfterLaunchPrompt() {
        self.pendingCodexLaunchPrompt = false
        if self.closeAfterLaunchPrompt {
            self.closeAfterLaunchPrompt = false
            self.onClose()
        }
    }

    private func launchCodexInstanceAfterPrompt() async {
        do {
            _ = try await self.codexDesktopLaunchProbeService.restartCodex()
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func startOAuthLogin() {
        OpenAILoginCoordinator.shared.start()
    }

    private func importOpenAIAccounts() {
        do {
            guard let importURL = self.openAIAccountCSVPanelService.requestImportURL() else {
                return
            }

            let importText = try String(contentsOf: importURL, encoding: .utf8)
            let parsed = try self.openAIAccountCSVService.parseCSV(importText)
            _ = try self.oauthAccountService.importAccounts(
                parsed.accounts,
                activeAccountID: nil,
                interopContext: parsed.interopContext
            )
            self.store.load()
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func exportOpenAIAccount(_ account: TokenAccount) {
        do {
            let snapshot = try self.oauthAccountService.exportAccountsForInterchange()
            guard let exportText = try self.openAIAccountCSVService.makeCSV(
                forAccountID: account.accountId,
                from: snapshot
            ) else {
                self.coordinator.validationMessage = L.noOpenAIAccountsToExport
                return
            }

            guard let exportURL = self.openAIAccountCSVPanelService.requestExportURL() else {
                return
            }

            try exportText.write(to: exportURL, atomically: true, encoding: .utf8)
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func openAddProviderWindow() {
        DetachedWindowPresenter.shared.show(
            id: "settings-add-provider",
            title: L.addProviderTitle,
            size: CGSize(width: 520, height: 620)
        ) {
            AddProviderSheet(store: store) { preset, label, baseURL, accountLabel, apiKey, thirdPartySelection, openRouterSelection in
                do {
                    switch preset {
                    case .custom:
                        try store.addCustomProvider(label: label, baseURL: baseURL, accountLabel: accountLabel, apiKey: apiKey)
                    case .thirdParty:
                        guard let thirdPartySelection else {
                            throw TokenStoreError.invalidInput
                        }
                        try store.addThirdPartyModelProvider(
                            provider: thirdPartySelection.provider,
                            label: label,
                            baseURL: thirdPartySelection.baseURL,
                            selectedModelID: thirdPartySelection.selectedModelID,
                            pinnedModelIDs: thirdPartySelection.pinnedModelIDs,
                            accountLabel: accountLabel,
                            apiKey: apiKey
                        )
                    case .openRouter:
                        let openRouterSelection = openRouterSelection ?? OpenRouterSelectionPayload(
                            apiKey: apiKey,
                            selectedModelID: nil,
                            pinnedModelIDs: [],
                            cachedModelCatalog: [],
                            fetchedAt: nil
                        )
                        try store.addOpenRouterProvider(
                            accountLabel: accountLabel,
                            apiKey: openRouterSelection.apiKey,
                            selectedModelID: openRouterSelection.selectedModelID,
                            pinnedModelIDs: openRouterSelection.pinnedModelIDs,
                            cachedModelCatalog: openRouterSelection.cachedModelCatalog,
                            fetchedAt: openRouterSelection.fetchedAt
                        )
                    }
                    self.store.load()
                    self.coordinator.validationMessage = nil
                    DetachedWindowPresenter.shared.close(id: "settings-add-provider")
                } catch {
                    self.coordinator.validationMessage = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "settings-add-provider")
            }
        }
    }

    private func openEditProviderWindow(provider: CodexBarProvider) {
        DetachedWindowPresenter.shared.show(
            id: "settings-edit-provider-\(provider.id)",
            title: L.editProviderTitle,
            size: CGSize(
                width: provider.kind == .openRouter || provider.isThirdPartyModelProvider ? 520 : 420,
                height: provider.kind == .openRouter || provider.isThirdPartyModelProvider ? 620 : 260
            )
        ) {
            AddProviderSheet(store: store, editingProvider: provider) { preset, label, baseURL, accountLabel, apiKey, thirdPartySelection, openRouterSelection in
                do {
                    switch preset {
                    case .custom:
                        try store.updateCustomProvider(
                            providerID: provider.id,
                            request: CustomProviderUpdate(
                                label: label,
                                baseURL: baseURL,
                                accountID: provider.activeAccount?.id,
                                accountLabel: accountLabel,
                                apiKey: apiKey
                            )
                        )
                    case .thirdParty:
                        guard let thirdPartySelection else {
                            throw TokenStoreError.invalidInput
                        }
                        try store.updateThirdPartyModelProvider(
                            providerID: provider.id,
                            request: ThirdPartyModelProviderUpdate(
                                provider: thirdPartySelection.provider,
                                label: label,
                                baseURL: thirdPartySelection.baseURL,
                                selectedModelID: thirdPartySelection.selectedModelID,
                                pinnedModelIDs: thirdPartySelection.pinnedModelIDs,
                                accountID: provider.activeAccount?.id,
                                accountLabel: accountLabel,
                                apiKey: apiKey
                            )
                        )
                    case .openRouter:
                        let openRouterSelection = openRouterSelection ?? OpenRouterSelectionPayload(
                            apiKey: apiKey,
                            selectedModelID: nil,
                            pinnedModelIDs: [],
                            cachedModelCatalog: [],
                            fetchedAt: nil
                        )
                        try store.updateOpenRouterProvider(
                            request: OpenRouterProviderUpdate(
                                accountID: provider.activeAccount?.id,
                                accountLabel: accountLabel,
                                apiKey: openRouterSelection.apiKey,
                                selectedModelID: openRouterSelection.selectedModelID,
                                pinnedModelIDs: openRouterSelection.pinnedModelIDs,
                                cachedModelCatalog: openRouterSelection.cachedModelCatalog,
                                fetchedAt: openRouterSelection.fetchedAt
                            )
                        )
                    }
                    self.reloadSettingsState()
                    self.coordinator.validationMessage = nil
                    DetachedWindowPresenter.shared.close(id: "settings-edit-provider-\(provider.id)")
                } catch {
                    self.coordinator.validationMessage = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "settings-edit-provider-\(provider.id)")
            }
        }
    }

    private func openAddProviderAccountWindow(provider: CodexBarProvider) {
        DetachedWindowPresenter.shared.show(
            id: "settings-add-provider-account-\(provider.id)",
            title: L.addProviderAccountTitle,
            size: CGSize(width: 400, height: 220)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey in
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey)
                    self.reloadSettingsState()
                    self.coordinator.validationMessage = nil
                    DetachedWindowPresenter.shared.close(id: "settings-add-provider-account-\(provider.id)")
                } catch {
                    self.coordinator.validationMessage = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "settings-add-provider-account-\(provider.id)")
            }
        }
    }

    private func openEditProviderAccountWindow(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        if provider.isThirdPartyModelProvider {
            DetachedWindowPresenter.shared.show(
                id: "settings-edit-provider-account-\(account.id)",
                title: "\(L.editProviderAccountTitle) · \(account.label)",
                size: CGSize(width: 520, height: 620)
            ) {
                AddProviderSheet(store: store, editingProvider: provider, editingAccount: account) { preset, label, baseURL, accountLabel, apiKey, thirdPartySelection, _ in
                    do {
                        guard preset == .thirdParty,
                              let thirdPartySelection else {
                            throw TokenStoreError.invalidInput
                        }
                        try store.updateThirdPartyModelProvider(
                            providerID: provider.id,
                            request: ThirdPartyModelProviderUpdate(
                                provider: thirdPartySelection.provider,
                                label: label,
                                baseURL: thirdPartySelection.baseURL,
                                selectedModelID: thirdPartySelection.selectedModelID,
                                pinnedModelIDs: thirdPartySelection.pinnedModelIDs,
                                accountID: account.id,
                                accountLabel: accountLabel,
                                apiKey: apiKey
                            )
                        )
                        self.reloadSettingsState()
                        self.coordinator.validationMessage = nil
                        DetachedWindowPresenter.shared.close(id: "settings-edit-provider-account-\(account.id)")
                    } catch {
                        self.coordinator.validationMessage = error.localizedDescription
                    }
                } onCancel: {
                    DetachedWindowPresenter.shared.close(id: "settings-edit-provider-account-\(account.id)")
                }
            }
            return
        }
        DetachedWindowPresenter.shared.show(
            id: "settings-edit-provider-account-\(account.id)",
            title: "\(L.editProviderAccountTitle) · \(account.label)",
            size: CGSize(width: 400, height: 220)
        ) {
            AddProviderAccountSheet(provider: provider, account: account) { label, apiKey in
                do {
                    try store.updateCustomProviderAccount(
                        providerID: provider.id,
                        accountID: account.id,
                        label: label,
                        apiKey: apiKey
                    )
                    self.reloadSettingsState()
                    self.coordinator.validationMessage = nil
                    DetachedWindowPresenter.shared.close(id: "settings-edit-provider-account-\(account.id)")
                } catch {
                    self.coordinator.validationMessage = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "settings-edit-provider-account-\(account.id)")
            }
        }
    }

    private func openAddOpenRouterAccountWindow(provider: CodexBarProvider) {
        DetachedWindowPresenter.shared.show(
            id: "settings-add-openrouter-key",
            title: L.addOpenRouterKeyTitle,
            size: CGSize(width: 520, height: 620)
        ) {
            OpenRouterKeyEditorSheet(provider: provider, store: store) { accountLabel, selection in
                do {
                    try store.addOpenRouterProviderAccount(
                        label: accountLabel,
                        apiKey: selection.apiKey,
                        selectedModelID: selection.selectedModelID,
                        pinnedModelIDs: selection.pinnedModelIDs,
                        cachedModelCatalog: selection.cachedModelCatalog,
                        fetchedAt: selection.fetchedAt
                    )
                    self.reloadSettingsState()
                    self.coordinator.validationMessage = nil
                    DetachedWindowPresenter.shared.close(id: "settings-add-openrouter-key")
                } catch {
                    self.coordinator.validationMessage = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "settings-add-openrouter-key")
            }
        }
    }

    private func openEditOpenRouterWindow(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        DetachedWindowPresenter.shared.show(
            id: "settings-edit-openrouter-key-\(account.id)",
            title: "\(L.editOpenRouterKeyTitle) · \(account.label)",
            size: CGSize(width: 500, height: 520)
        ) {
            OpenRouterKeyEditorSheet(provider: provider, store: store, account: account) { accountLabel, selection in
                do {
                    try store.updateOpenRouterProvider(
                        request: OpenRouterProviderUpdate(
                            accountID: account.id,
                            accountLabel: accountLabel,
                            apiKey: selection.apiKey,
                            selectedModelID: selection.selectedModelID,
                            pinnedModelIDs: selection.pinnedModelIDs,
                            cachedModelCatalog: selection.cachedModelCatalog,
                            fetchedAt: selection.fetchedAt
                        )
                    )
                    self.reloadSettingsState()
                    self.coordinator.validationMessage = nil
                    DetachedWindowPresenter.shared.close(id: "settings-edit-openrouter-key-\(account.id)")
                } catch {
                    self.coordinator.validationMessage = error.localizedDescription
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "settings-edit-openrouter-key-\(account.id)")
            }
        }
    }

    private func refreshOpenAIAccount(_ account: TokenAccount) {
        Task {
            self.refreshingAccounts.insert(account.id)
            _ = await WhamService.shared.refreshOne(account: account, store: self.store)
            self.refreshingAccounts.remove(account.id)
            self.reloadSettingsState()
        }
    }

    private func saveProviderUsageConfiguration(
        provider: CodexBarProvider,
        configuration: CodexBarProviderUsageConfiguration
    ) {
        do {
            try self.store.saveProviderUsageConfiguration(providerID: provider.id, configuration: configuration)
            self.reloadSettingsState()
            self.store.refreshProviderUsage(providerID: provider.id)
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func refreshProviderUsage(_ provider: CodexBarProvider) {
        self.store.refreshProviderUsage(providerID: provider.id)
        self.reloadSettingsState()
    }

    private func disableProviderUsage(_ provider: CodexBarProvider) {
        do {
            try self.store.disableProviderUsage(providerID: provider.id)
            self.reloadSettingsState()
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func reauthOpenAIAccount(_: TokenAccount) {
        self.startOAuthLogin()
    }

    private func confirmDeleteOpenAIAccount(_ account: TokenAccount) {
        self.pendingDeleteConfirmation = SettingsDeleteConfirmationRequest(target: .openAIAccount(account))
    }

    private func confirmDeleteCompatibleAccount(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = SettingsDeleteConfirmationRequest(
            target: .customProviderAccount(
                providerID: provider.id,
                providerLabel: provider.label,
                accountID: account.id,
                accountLabel: account.label
            )
        )
    }

    private func confirmDeleteProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = SettingsDeleteConfirmationRequest(
            target: .customProvider(providerID: provider.id, providerLabel: provider.label)
        )
    }

    private func confirmDeleteOpenRouterAccount(_ account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = SettingsDeleteConfirmationRequest(
            target: .openRouterAccount(accountID: account.id, accountLabel: account.label)
        )
    }

    private func performConfirmedDelete(_ request: SettingsDeleteConfirmationRequest) {
        do {
            switch request.target {
            case .openAIAccount(let account):
                self.store.remove(account)
            case .customProviderAccount(let providerID, _, let accountID, _):
                try self.store.removeCustomProviderAccount(providerID: providerID, accountID: accountID)
            case .customProvider(let providerID, _):
                try self.store.removeCustomProvider(providerID: providerID)
            case .openRouterAccount(let accountID, _):
                try self.store.removeOpenRouterProviderAccount(accountID: accountID)
            }
            self.reloadSettingsState()
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func reloadSettingsState() {
        self.store.load()
        self.coordinator.reconcileExternalState(
            config: self.store.config,
            accounts: self.store.accounts,
            historicalModels: self.store.historicalModels
        )
    }
}

extension View {
    func settingsDetailPagePadding() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func settingsGettingStartedCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }

    func settingsCardPadding() -> some View {
        self
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
    }

    func settingsCardBackground(isHovering: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.secondary.opacity(0.08) : Color(NSColor.controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.14 : 0.10), lineWidth: 1)
            }
    }
}

@MainActor
enum SettingsSidebarSelectionAdapter {
    static func binding(for coordinator: SettingsWindowCoordinator) -> Binding<SettingsPage?> {
        Binding(
            get: { coordinator.selectedPage },
            set: { selection in
                self.apply(selection, to: coordinator)
            }
        )
    }

    static func apply(_ selection: SettingsPage?, to coordinator: SettingsWindowCoordinator) {
        guard let selection else { return }
        coordinator.selectedPage = selection
    }
}

private struct SettingsSidebarRow: View {
    static let horizontalPadding: CGFloat = 22
    static let iconWidth: CGFloat = 20
    static let iconTitleSpacing: CGFloat = 12
    static let titleFontSize: CGFloat = 13
    static let titleFontWeight: NSFont.Weight = .semibold
    static let rowHorizontalPadding: CGFloat = 10

    let page: SettingsPage
    let isSelected: Bool

    @State private var isHovering = false

    static var minimumColumnWidth: CGFloat {
        let widestTitle = SettingsPage.allCases
            .map { self.measuredTitleWidth($0.title) }
            .max() ?? 0
        return (Self.horizontalPadding * 2) +
            (Self.rowHorizontalPadding * 2) +
            Self.iconWidth +
            Self.iconTitleSpacing +
            ceil(widestTitle)
    }

    var body: some View {
        HStack(spacing: Self.iconTitleSpacing) {
            Image(systemName: self.page.iconName)
                .font(.system(size: Self.titleFontSize, weight: self.isSelected ? .semibold : .medium))
                .frame(width: Self.iconWidth, alignment: .center)
            Text(self.page.title)
                .lineLimit(1)
        }
            .font(.system(size: 13, weight: self.isSelected ? .semibold : .medium))
            .foregroundColor(self.isSelected ? .accentColor : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.rowHorizontalPadding)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(self.backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(0.12)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.10)
        }
        return Color.clear
    }

    private static func measuredTitleWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Self.titleFontSize, weight: Self.titleFontWeight)
        return (title as NSString).size(withAttributes: [.font: font]).width
    }
}

private struct SettingsValidationBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.red)
            Text(self.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct SettingsPageActionBar: View {
    let isVisible: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        if self.isVisible {
            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(L.cancel, action: self.onCancel)
                    .buttonStyle(
                        SettingsHoverButtonStyle(
                            horizontalPadding: 16,
                            verticalPadding: 7,
                            minWidth: 74,
                            minHeight: 34
                        )
                    )
                    .keyboardShortcut(.cancelAction)

                Button(L.save, action: self.onSave)
                    .buttonStyle(
                        SettingsHoverButtonStyle(
                            isPrimary: true,
                            horizontalPadding: 18,
                            verticalPadding: 7,
                            minWidth: 86,
                            minHeight: 34
                        )
                    )
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }
}

private struct SettingsAccountsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let codexAppPathPanelService: CodexAppPathPanelService
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsLaunchAtLoginSection(
                isEnabled: Binding(
                    get: { self.coordinator.draft.launchAtLoginEnabled },
                    set: { self.coordinator.update(\.launchAtLoginEnabled, to: $0, field: .launchAtLogin) }
                )
            )

            SettingsAccountOrderingModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountOrderingMode },
                    set: { self.coordinator.update(\.accountOrderingMode, to: $0, field: .accountOrderingMode) }
                )
            )

            if self.coordinator.showsManualAccountOrderSection {
                SettingsAccountOrderSection(coordinator: self.coordinator)
            }

            SettingsCodexAppPathSettingsSection(
                preferredCodexAppPath: Binding(
                    get: { self.coordinator.draft.preferredCodexAppPath },
                    set: { self.coordinator.update(\.preferredCodexAppPath, to: $0, field: .preferredCodexAppPath) }
                ),
                validationMessage: self.$coordinator.validationMessage,
                codexAppPathPanelService: self.codexAppPathPanelService
            )

            SettingsPageActionBar(
                isVisible: self.coordinator.hasAccountSettingsChanges,
                onCancel: self.coordinator.cancelAccountSettingsChanges,
                onSave: self.onSave
            )
        }
    }
}

private struct SettingsLaunchAtLoginSection: View {
    @Binding var isEnabled: Bool

    @State private var isHovering = false

    var body: some View {
        SettingsLabeledBlock(title: L.launchAtLoginTitle) {
            Button {
                self.isEnabled.toggle()
            } label: {
                HStack(alignment: .center, spacing: 18) {
                    Text(L.launchAtLoginHint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 20)

                    Image(systemName: self.isEnabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(self.isEnabled ? .accentColor : .secondary)
                        .frame(width: 22, height: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .settingsCardBackground(isHovering: self.isHovering)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { self.isHovering = $0 }
        }
    }
}

private struct SettingsGettingStartedPage: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let refreshingAccounts: Set<String>
    let onAuthenticateOpenAI: () -> Void
    let onImportOpenAI: () -> Void
    let onRefreshOpenAI: (TokenAccount) -> Void
    let onReauthOpenAI: (TokenAccount) -> Void
    let onExportOpenAI: (TokenAccount) -> Void
    let onDeleteOpenAI: (TokenAccount) -> Void
    let onAddProvider: () -> Void
    let onAddProviderAccount: (CodexBarProvider) -> Void
    let onEditProvider: (CodexBarProvider) -> Void
    let onEditProviderAccount: (CodexBarProvider, CodexBarProviderAccount) -> Void
    let onDeleteProviderAccount: (CodexBarProvider, CodexBarProviderAccount) -> Void
    let onDeleteProvider: (CodexBarProvider) -> Void
    let onAddOpenRouterAccount: (CodexBarProvider) -> Void
    let onEditOpenRouterAccount: (CodexBarProvider, CodexBarProviderAccount) -> Void
    let onDeleteOpenRouterAccount: (CodexBarProviderAccount) -> Void
    let onSaveRouteSelection: () -> Void

    private var groupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.groupedAccounts(
            from: self.store.accounts,
            summary: .empty,
            quotaSortSettings: self.store.config.openAI.quotaSort,
            preferredAccountOrder: self.store.config.openAI.preferredDisplayAccountOrder,
            highlightActiveAccount: self.coordinator.draft.route.mode == .switchAccount
        )
    }

    private var thirdPartyAccountCount: Int {
        self.store.customProviders.reduce(0) { $0 + $1.accounts.count } +
            self.store.thirdPartyModelProviders.reduce(0) { $0 + $1.accounts.count } +
            (self.store.openRouterProvider?.accounts.count ?? 0)
    }

    private var currentRequirementProgress: SettingsGettingStartedProgress {
        self.coordinator.gettingStartedProgress(
            mode: self.coordinator.draft.route.mode,
            openAIAccountCount: self.store.accounts.count,
            thirdPartyAccountCount: self.thirdPartyAccountCount
        )
    }

    @State private var previousRequirementProgress: SettingsGettingStartedProgress?
    @State private var showCompletedRequirementProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGettingStartedModeSection(coordinator: self.coordinator)

            if self.shouldShowRequirementProgress {
                SettingsGettingStartedRequirementProgressCard(
                    progress: self.currentRequirementProgress
                )
            }

            SettingsGettingStartedOpenAISection(
                store: self.store,
                coordinator: self.coordinator,
                groupedAccounts: self.groupedAccounts,
                refreshingAccounts: self.refreshingAccounts,
                onAuthenticateOpenAI: self.onAuthenticateOpenAI,
                onImportOpenAI: self.onImportOpenAI,
                onRefreshOpenAI: self.onRefreshOpenAI,
                onReauthOpenAI: self.onReauthOpenAI,
                onExportOpenAI: self.onExportOpenAI,
                onDeleteOpenAI: self.onDeleteOpenAI
            )

            SettingsGettingStartedProviderSection(
                store: self.store,
                coordinator: self.coordinator,
                onAddProvider: self.onAddProvider,
                onAddProviderAccount: self.onAddProviderAccount,
                onEditProvider: self.onEditProvider,
                onEditProviderAccount: self.onEditProviderAccount,
                onDeleteProviderAccount: self.onDeleteProviderAccount,
                onDeleteProvider: self.onDeleteProvider,
                onAddOpenRouterAccount: self.onAddOpenRouterAccount,
                onEditOpenRouterAccount: self.onEditOpenRouterAccount,
                onDeleteOpenRouterAccount: self.onDeleteOpenRouterAccount
            )

            SettingsPageActionBar(
                isVisible: self.coordinator.hasGettingStartedChanges,
                onCancel: self.coordinator.cancelGettingStartedChanges,
                onSave: self.onSaveRouteSelection
            )
        }
        .onAppear {
            self.previousRequirementProgress = self.currentRequirementProgress
            self.showCompletedRequirementProgress = false
        }
        .onChange(of: self.currentRequirementProgress) { progress in
            let previous = self.previousRequirementProgress
            self.showCompletedRequirementProgress = progress.isComplete && previous?.isComplete == false
            self.previousRequirementProgress = progress
        }
    }

    private var shouldShowRequirementProgress: Bool {
        SettingsGettingStartedProgress.shouldShowRequirementProgress(
            current: self.currentRequirementProgress,
            previous: self.previousRequirementProgress,
            showingCompletedProgress: self.showCompletedRequirementProgress
        )
    }
}

private struct SettingsGettingStartedModeSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.gettingStartedModeTitle)
                .font(SettingsTypography.sectionTitle)

            VStack(spacing: 0) {
                ForEach(Array(CodexBarOpenAIAccountUsageMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    SettingsGettingStartedModeRow(
                        mode: mode,
                        isSelected: self.coordinator.draft.route.mode == mode
                    ) {
                        self.coordinator.selectRouteMode(mode)
                    }
                    if index != CodexBarOpenAIAccountUsageMode.allCases.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
        }
    }
}

private struct SettingsGettingStartedModeRow: View {
    let mode: CodexBarOpenAIAccountUsageMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 16) {
                Image(systemName: self.iconName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(self.iconColor)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(self.iconColor.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(self.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(self.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: self.isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(self.isSelected ? self.iconColor : .secondary.opacity(0.45))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(self.isHovering ? Color.secondary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
    }

    private var title: String {
        if self.mode == .hybridProvider {
            return "\(self.mode.gettingStartedTitle)\(L.gettingStartedRecommendedSuffix)"
        }
        return self.mode.gettingStartedTitle
    }

    private var detail: String {
        self.mode.gettingStartedDetail
    }

    private var iconName: String {
        switch self.mode {
        case .switchAccount:
            return "cable.connector"
        case .aggregateGateway:
            return "point.3.connected.trianglepath.dotted"
        case .hybridProvider:
            return "arrow.triangle.branch"
        }
    }

    private var iconColor: Color {
        Color(nsColor: self.mode.themeAccentColor)
    }
}

private struct SettingsGettingStartedRequirementProgressCard: View {
    let progress: SettingsGettingStartedProgress

    private var isReady: Bool {
        self.progress.isComplete
    }

    private var accentColor: Color {
        self.isReady ? .green : Color(nsColor: self.progress.mode.themeAccentColor)
    }

    private var iconName: String {
        self.isReady ? "checkmark" : "cable.connector"
    }

    private var title: String {
        self.isReady ? L.gettingStartedRequirementCompletedTitle : L.gettingStartedRequirementTitle
    }

    private var detail: String {
        self.isReady
            ? L.gettingStartedRequirementCompletedDetail(for: self.progress.mode.gettingStartedTitle)
            : L.gettingStartedRequirementDetail(for: self.progress.mode)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: self.iconName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(self.accentColor)
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(self.accentColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(self.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text(self.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            SettingsGettingStartedProgressRing(
                completed: self.progress.completedStepCount,
                required: self.progress.requiredStepCount,
                color: self.accentColor
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(self.accentColor.opacity(self.isReady ? 0.18 : 0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.title), \(self.progress.completedStepCount)/\(self.progress.requiredStepCount)")
    }
}

private struct SettingsGettingStartedProgressRing: View {
    let completed: Int
    let required: Int
    let color: Color

    private var progress: Double {
        guard self.required > 0 else { return 0 }
        return min(Double(self.completed) / Double(self.required), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 4)
            Circle()
                .trim(from: 0, to: self.progress)
                .stroke(
                    self.color,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(self.completed)/\(self.required)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .frame(width: 48, height: 48)
    }
}

private struct SettingsGettingStartedOpenAISection: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let groupedAccounts: [OpenAIAccountGroup]
    let refreshingAccounts: Set<String>
    let onAuthenticateOpenAI: () -> Void
    let onImportOpenAI: () -> Void
    let onRefreshOpenAI: (TokenAccount) -> Void
    let onReauthOpenAI: (TokenAccount) -> Void
    let onExportOpenAI: (TokenAccount) -> Void
    let onDeleteOpenAI: (TokenAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.gettingStartedOpenAISectionTitle)
                .font(SettingsTypography.sectionTitle)

            VStack(spacing: 0) {
                if self.store.accounts.isEmpty {
                    SettingsGettingStartedEmptyHeader(
                        title: L.gettingStartedOpenAIEmptyTitle,
                        detail: L.gettingStartedOpenAIEmptyDetail
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(self.groupedAccounts) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.email)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                                ForEach(group.accounts) { account in
                                    AccountRowView(
                                        account: account,
                                        rowState: self.rowState(for: account),
                                        isRefreshing: self.refreshingAccounts.contains(account.id),
                                        usageDisplayMode: self.coordinator.draft.usageDisplayMode
                                    ) {
                                        self.coordinator.selectRouteTarget(.openAIAccount(accountID: account.accountId))
                                    } onRefresh: {
                                        self.onRefreshOpenAI(account)
                                    } onReauth: {
                                        self.onReauthOpenAI(account)
                                    } onExport: {
                                        self.onExportOpenAI(account)
                                    } onDelete: {
                                        self.onDeleteOpenAI(account)
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                }

                Divider()

                SettingsGettingStartedActionRow(
                    iconName: "globe",
                    title: L.gettingStartedOpenAIAuthActionTitle,
                    detail: L.gettingStartedOpenAIAuthActionDetail,
                    buttonTitle: L.gettingStartedOpenAIAuthButton,
                    buttonIconName: "arrow.up.right.square",
                    action: self.onAuthenticateOpenAI
                )

                Divider().padding(.leading, 18)

                SettingsGettingStartedActionRow(
                    iconName: "curlybraces",
                    title: L.gettingStartedOpenAIImportActionTitle,
                    detail: L.gettingStartedOpenAIImportActionDetail,
                    buttonTitle: L.gettingStartedOpenAIImportButton,
                    buttonIconName: "square.and.arrow.down",
                    action: self.onImportOpenAI
                )
            }
            .settingsGettingStartedCard()
        }
    }

    private func rowState(for account: TokenAccount) -> OpenAIAccountRowState {
        let mode = self.coordinator.draft.route.mode
        switch mode {
        case .switchAccount:
            return OpenAIAccountRowState(
                isNextUseTarget: self.coordinator.isRouteTargetSelected(.openAIAccount(accountID: account.accountId)),
                runningThreadCount: 0,
                accountUsageMode: .switchAccount,
                actionTitle: L.openAIAccountSwitchAction
            )
        case .aggregateGateway:
            return OpenAIAccountRowState(
                isNextUseTarget: false,
                runningThreadCount: 0,
                accountUsageMode: .aggregateGateway,
                actionTitle: ""
            )
        case .hybridProvider:
            return OpenAIAccountRowState(
                isNextUseTarget: false,
                runningThreadCount: 0,
                accountUsageMode: .switchAccount,
                actionTitle: L.openAIAccountSwitchAction
            )
        }
    }
}

private struct SettingsGettingStartedProviderSection: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let onAddProvider: () -> Void
    let onAddProviderAccount: (CodexBarProvider) -> Void
    let onEditProvider: (CodexBarProvider) -> Void
    let onEditProviderAccount: (CodexBarProvider, CodexBarProviderAccount) -> Void
    let onDeleteProviderAccount: (CodexBarProvider, CodexBarProviderAccount) -> Void
    let onDeleteProvider: (CodexBarProvider) -> Void
    let onAddOpenRouterAccount: (CodexBarProvider) -> Void
    let onEditOpenRouterAccount: (CodexBarProvider, CodexBarProviderAccount) -> Void
    let onDeleteOpenRouterAccount: (CodexBarProviderAccount) -> Void

    private var openRouterProvider: CodexBarProvider? {
        self.store.openRouterProvider
    }

    private var activationMode: CodexBarOpenAIAccountUsageMode? {
        switch self.coordinator.draft.route.mode {
        case .switchAccount:
            return .switchAccount
        case .hybridProvider:
            return .hybridProvider
        case .aggregateGateway:
            return nil
        }
    }

    private var providerUseActionTitle: String {
        switch self.coordinator.draft.route.mode {
        case .switchAccount:
            return L.openAIAccountSwitchAction
        case .hybridProvider:
            return L.providerUseAction
        case .aggregateGateway:
            return ""
        }
    }

    private var usageDisplayMode: CodexBarUsageDisplayMode {
        self.coordinator.draft.usageDisplayMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.gettingStartedProviderSectionTitle)
                .font(SettingsTypography.sectionTitle)

            VStack(spacing: 0) {
                if self.store.customProviders.isEmpty &&
                    self.store.thirdPartyModelProviders.isEmpty &&
                    self.openRouterProvider == nil {
                    SettingsGettingStartedEmptyHeader(
                        title: L.gettingStartedProviderEmptyTitle,
                        detail: L.gettingStartedProviderEmptyDetail
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if self.store.customProviders.isEmpty == false {
                            self.providerGroup(title: "OpenAI中转", providers: self.store.customProviders)
                        }
                        if self.store.thirdPartyModelProviders.isEmpty == false {
                            self.thirdPartyProviderGroup(title: "第三方模型", providers: self.store.thirdPartyModelProviders)
                        }
                        if let provider = self.openRouterProvider {
                            self.openRouterSection(provider)
                        }
                    }
                    .padding(14)
                }

                Divider()

                SettingsGettingStartedActionRow(
                    iconName: "lock",
                    iconForegroundColor: .accentColor,
                    iconBackgroundColor: Color.accentColor.opacity(0.10),
                    title: L.gettingStartedPrivacyNote,
                    titleColor: .accentColor,
                    detail: "",
                    buttonTitle: L.addProviderTitle,
                    buttonIconName: "plus",
                    action: self.onAddProvider
                )
            }
            .settingsGettingStartedCard()
        }
    }

    private func providerGroup(title: String, providers: [CodexBarProvider]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)

            ForEach(providers) { provider in
                CompatibleProviderRowView(
                    provider: provider,
                    isActiveProvider: self.isProviderSelected(provider),
                    activeAccountId: self.selectedAccountID(for: provider),
                    usageDisplayMode: self.usageDisplayMode,
                    useActionTitle: self.providerUseActionTitle
                ) { account in
                    guard let activationMode = self.activationMode else { return }
                    self.coordinator.selectRouteTarget(
                        .compatibleProvider(
                            providerID: provider.id,
                            accountID: account.id,
                            modelID: nil,
                            mode: activationMode
                        )
                    )
                } onAddAccount: {
                    self.onAddProviderAccount(provider)
                } onEditProvider: {
                    self.onEditProvider(provider)
                } onEditAccount: { account in
                    self.onEditProviderAccount(provider, account)
                } onDeleteAccount: { account in
                    self.onDeleteProviderAccount(provider, account)
                } onDeleteProvider: {
                    self.onDeleteProvider(provider)
                }
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func thirdPartyProviderGroup(title: String, providers: [CodexBarProvider]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)

            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(self.isProviderSelected(provider) ? .accentColor : .primary)
                        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)

                    ForEach(provider.accounts) { account in
                    ThirdPartyModelKeyRowView(
                        provider: provider,
                        account: account,
                        isActiveProvider: self.isProviderSelected(provider),
                        activeAccountId: self.selectedAccountID(for: provider),
                        usageDisplayMode: self.usageDisplayMode,
                        useActionTitle: self.providerUseActionTitle,
                        selectedModelIDOverride: self.selectedThirdPartyModelID(for: provider)
                    ) {
                        guard let activationMode = self.activationMode else { return }
                            self.coordinator.selectRouteTarget(
                                .compatibleProvider(
                                    providerID: provider.id,
                                    accountID: account.id,
                                    modelID: provider.thirdPartyEffectiveModelID(forAccountID: account.id),
                                    mode: activationMode
                                )
                            )
                        } onSelectModel: { modelID in
                            guard let activationMode = self.activationMode else { return }
                            self.coordinator.selectRouteTarget(
                                .compatibleProvider(
                                    providerID: provider.id,
                                    accountID: account.id,
                                    modelID: modelID,
                                    mode: activationMode
                                )
                            )
                        } onEditAccount: {
                            self.onEditProviderAccount(provider, account)
                        } onDeleteAccount: {
                            self.onDeleteProviderAccount(provider, account)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func openRouterSection(_ provider: CodexBarProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("OpenRouter")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    self.onAddOpenRouterAccount(provider)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .menuPanelHoverChrome(cornerRadius: 5)
            }
            .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)

            ForEach(provider.accounts) { account in
                OpenRouterKeyRowView(
                    provider: provider,
                    account: account,
                    isActiveProvider: self.isOpenRouterAccountSelected(accountID: account.id),
                    activeAccountId: self.selectedOpenRouterAccountID,
                    usageDisplayMode: self.usageDisplayMode,
                    useActionTitle: self.providerUseActionTitle,
                    selectedModelIDOverride: self.selectedOpenRouterModelID
                ) {
                    guard let activationMode = self.activationMode else { return }
                    self.coordinator.selectRouteTarget(
                        .openRouter(
                            accountID: account.id,
                            modelID: provider.openRouterEffectiveModelID(forAccountID: account.id),
                            mode: activationMode
                        )
                    )
                } onSelectModel: { modelID in
                    guard let activationMode = self.activationMode else { return }
                    self.coordinator.selectRouteTarget(
                        .openRouter(accountID: account.id, modelID: modelID, mode: activationMode)
                    )
                } onEditModel: {
                    self.onEditOpenRouterAccount(provider, account)
                } onDeleteAccount: {
                    self.onDeleteOpenRouterAccount(account)
                }
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func isProviderSelected(_ provider: CodexBarProvider) -> Bool {
        guard case .compatibleProvider(let providerID, _, _, let mode) = self.coordinator.selectedRouteTarget else {
            return false
        }
        return providerID == provider.id && mode == self.coordinator.draft.route.mode
    }

    private func selectedAccountID(for provider: CodexBarProvider) -> String? {
        guard case .compatibleProvider(let providerID, let accountID, _, let mode) = self.coordinator.selectedRouteTarget,
              providerID == provider.id,
              mode == self.coordinator.draft.route.mode else {
            return nil
        }
        return accountID
    }

    private func selectedThirdPartyModelID(for provider: CodexBarProvider) -> String? {
        guard case .compatibleProvider(let providerID, _, let modelID, let mode) = self.coordinator.selectedRouteTarget,
              providerID == provider.id,
              mode == self.coordinator.draft.route.mode else {
            return nil
        }
        return modelID
    }

    private var selectedOpenRouterAccountID: String? {
        guard case .openRouter(let accountID, _, let mode) = self.coordinator.selectedRouteTarget,
              mode == self.coordinator.draft.route.mode else {
            return nil
        }
        return accountID
    }

    private var selectedOpenRouterModelID: String? {
        guard case .openRouter(_, let modelID, let mode) = self.coordinator.selectedRouteTarget,
              mode == self.coordinator.draft.route.mode else {
            return nil
        }
        return modelID
    }

    private func isOpenRouterAccountSelected(accountID: String) -> Bool {
        self.selectedOpenRouterAccountID == accountID
    }
}

private struct SettingsGettingStartedEmptyHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 52, height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.3, dash: [5, 4]))
                        .foregroundColor(.accentColor.opacity(0.5))
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(self.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(self.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

private struct SettingsGettingStartedActionRow: View {
    let iconName: String
    var iconForegroundColor: Color = .secondary
    var iconBackgroundColor: Color = Color.secondary.opacity(0.10)
    let title: String
    var titleColor: Color = .primary
    let detail: String
    let buttonTitle: String
    let buttonIconName: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: self.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(self.iconForegroundColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(self.iconBackgroundColor)
                )

            Text(self.title)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(self.titleColor)

            if self.detail.isEmpty == false {
                Text(self.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                self.action()
            } label: {
                Label(self.buttonTitle, systemImage: self.buttonIconName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 104, minHeight: 28)
            }
            .buttonStyle(SettingsGettingStartedActionButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SettingsGettingStartedActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsGettingStartedActionButtonBody(configuration: configuration)
    }
}

private struct SettingsGettingStartedActionButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        self.configuration.label
            .foregroundColor(self.foregroundColor)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(self.borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(self.isEnabled ? 1 : 0.45)
            .onHover { self.isHovering = $0 }
    }

    private var foregroundColor: Color {
        self.isEnabled ? .primary : .secondary
    }

    private var backgroundColor: Color {
        guard self.isEnabled else { return Color.secondary.opacity(0.08) }
        if self.configuration.isPressed {
            return Color.secondary.opacity(0.24)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.18)
        }
        return Color.secondary.opacity(0.10)
    }

    private var borderColor: Color {
        if self.configuration.isPressed {
            return Color.primary.opacity(0.18)
        }
        if self.isHovering {
            return Color.primary.opacity(0.12)
        }
        return Color.primary.opacity(0.05)
    }
}

private struct SettingsProviderUsageIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsProviderUsageIconButtonBody(configuration: configuration)
    }
}

private struct SettingsProviderUsageIconChrome<Content: View>: View {
    let isPressed: Bool
    let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(isPressed: Bool = false, @ViewBuilder content: () -> Content) {
        self.isPressed = isPressed
        self.content = content()
    }

    var body: some View {
        self.content
            .foregroundColor(self.foregroundColor)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(self.borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(self.isEnabled ? 1 : 0.45)
            .onHover { self.isHovering = $0 }
    }

    private var foregroundColor: Color {
        self.isEnabled ? .primary : .secondary
    }

    private var backgroundColor: Color {
        guard self.isEnabled else { return Color.secondary.opacity(0.08) }
        if self.isPressed {
            return Color.secondary.opacity(0.24)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.18)
        }
        return Color.secondary.opacity(0.10)
    }

    private var borderColor: Color {
        if self.isPressed {
            return Color.primary.opacity(0.18)
        }
        if self.isHovering {
            return Color.primary.opacity(0.12)
        }
        return Color.primary.opacity(0.05)
    }
}

private struct SettingsProviderUsageIconButtonBody: View {
    let configuration: ButtonStyle.Configuration

    var body: some View {
        SettingsProviderUsageIconChrome(isPressed: self.configuration.isPressed) {
            self.configuration.label
        }
    }
}

private struct SettingsProviderUsageMenuLabel: View {
    var body: some View {
        SettingsProviderUsageIconChrome {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
        }
    }
}

private struct SettingsUsagePage: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let onSave: () -> Void
    let onSaveProviderUsage: (CodexBarProvider, CodexBarProviderUsageConfiguration) -> Void
    let onRefreshProviderUsage: (CodexBarProvider) -> Void
    let onDisableProviderUsage: (CodexBarProvider) -> Void

    private var usageProviders: [CodexBarProvider] {
        self.store.config.providers.filter { $0.kind == .openAICompatible || $0.kind == .openRouter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(SettingsPage.usage.title)
                .font(SettingsTypography.pageTitle)

            SettingsUsageDisplayModeSection(
                usageDisplayMode: Binding(
                    get: { self.coordinator.draft.usageDisplayMode },
                    set: { self.applyUsageDisplayMode($0) }
                )
            )

            SettingsProviderUsageSection(
                providers: self.usageProviders,
                usageDisplayMode: self.coordinator.draft.usageDisplayMode,
                onSaveProviderUsage: self.onSaveProviderUsage,
                onRefreshProviderUsage: self.onRefreshProviderUsage,
                onDisableProviderUsage: self.onDisableProviderUsage
            )

            SettingsQuotaSortSection(
                plusRelativeWeight: Binding(
                    get: { self.coordinator.draft.plusRelativeWeight },
                    set: { self.coordinator.update(\.plusRelativeWeight, to: $0, field: .plusRelativeWeight) }
                ),
                proRelativeToPlusMultiplier: Binding(
                    get: { self.coordinator.draft.proRelativeToPlusMultiplier },
                    set: { self.coordinator.update(\.proRelativeToPlusMultiplier, to: $0, field: .proRelativeToPlusMultiplier) }
                ),
                teamRelativeToPlusMultiplier: Binding(
                    get: { self.coordinator.draft.teamRelativeToPlusMultiplier },
                    set: { self.coordinator.update(\.teamRelativeToPlusMultiplier, to: $0, field: .teamRelativeToPlusMultiplier) }
                )
            )

            SettingsModelPricingSection(coordinator: self.coordinator)

            SettingsPageActionBar(
                isVisible: self.coordinator.hasUsageSettingsChanges,
                onCancel: self.coordinator.cancelUsageSettingsChanges,
                onSave: self.onSave
            )
        }
    }

    private func applyUsageDisplayMode(_ mode: CodexBarUsageDisplayMode) {
        do {
            try self.store.saveUsageDisplayMode(mode)
            self.coordinator.commitUsageDisplayMode(mode)
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: self.store.accounts,
                historicalModels: self.store.historicalModels
            )
        }
    }
}

private struct SettingsProviderUsageSection: View {
    let providers: [CodexBarProvider]
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onSaveProviderUsage: (CodexBarProvider, CodexBarProviderUsageConfiguration) -> Void
    let onRefreshProviderUsage: (CodexBarProvider) -> Void
    let onDisableProviderUsage: (CodexBarProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.providerUsageSectionTitle)
                    .font(SettingsTypography.sectionTitle)
            }

            if self.providers.isEmpty {
                Text(L.providerUsageNoData)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCardPadding()
                    .settingsCardBackground()
            } else {
                VStack(spacing: 18) {
                    ForEach(self.providers) { provider in
                        SettingsProviderUsageCard(
                            provider: provider,
                            usageDisplayMode: self.usageDisplayMode,
                            onSave: { configuration in
                                self.onSaveProviderUsage(provider, configuration)
                            },
                            onRefresh: {
                                self.onRefreshProviderUsage(provider)
                            },
                            onDisable: {
                                self.onDisableProviderUsage(provider)
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsProviderUsageCard: View {
    let provider: CodexBarProvider
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onSave: (CodexBarProviderUsageConfiguration) -> Void
    let onRefresh: () -> Void
    let onDisable: () -> Void

    @State private var selectedWindow: ProviderUsageWindow = .today
    @State private var isEditing = false
    @State private var draftURL = ""
    @State private var draftHeaders = ""
    @State private var draftTimeout = 30.0
    @State private var draftInterval = 0
    @State private var showsRawResponse = false

    private var configuration: CodexBarProviderUsageConfiguration? {
        self.provider.usageConfiguration
    }

    private var state: CodexBarProviderUsageState? {
        self.provider.usageState
    }

    private var availableWindows: [ProviderUsageWindow] {
        guard let data = ProviderUsageFormat.records(for: self.provider).first?.data else {
            return []
        }
        return ProviderUsageFormat.availableWindows(for: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header

            if self.configuration != nil {
                Divider()
                    .padding(.top, 16)
                    .padding(.bottom, 22)
            } else {
                Color.clear
                    .frame(height: 24)
            }

            if self.isEditing {
                self.editor
                    .padding(.top, -6)
            } else if self.configuration != nil {
                self.configuredBody
            } else {
                self.emptyBody
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .onAppear {
            self.resetDraft()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(self.provider.label.uppercased())
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if self.configuration != nil {
                HStack(alignment: .center, spacing: 10) {
                    Text(self.lastUpdatedText(self.state?.lastUpdatedAt))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Button(action: self.onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(SettingsProviderUsageIconButtonStyle())
                    .help(L.providerUsageRefresh)
                }

                Menu {
                    Button(L.providerUsageEditAPI) {
                        self.beginEditing()
                    }
                    Button(L.providerUsageDisableAPI, role: .destructive) {
                        self.onDisable()
                    }
                    Button(L.providerUsageViewRawResponse) {
                        self.showsRawResponse.toggle()
                    }
                } label: {
                    SettingsProviderUsageMenuLabel()
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .help(L.providerUsageMore)
            }
        }
    }

    private var configuredBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            if self.availableWindows.count > 1 {
                SettingsProviderUsageWindowTabs(selection: self.$selectedWindow, windows: self.availableWindows)
            }

            if let error = self.state?.lastError {
                Text(error)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            let records = ProviderUsageFormat.records(for: self.provider)
            if records.isEmpty {
                Text(L.providerUsageEmptyTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.045))
                    )
            } else {
                VStack(spacing: 18) {
                    ForEach(records) { record in
                        SettingsProviderUsageRecordCard(
                            record: record,
                            selectedWindow: self.selectedWindow,
                            usageDisplayMode: self.usageDisplayMode
                        )
                    }
                }
            }

            if self.showsRawResponse {
                Text(self.state?.rawResponse?.isEmpty == false ? self.state?.rawResponse ?? "" : L.providerUsageNoData)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.05))
                    )
            }
        }
    }

    private var emptyBody: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 50, height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(L.providerUsageEmptyTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text(L.providerUsageSectionHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 20)

            Button(action: self.beginEditing) {
                Text(L.providerUsageAddAPI)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 112, minHeight: 30)
            }
            .buttonStyle(SettingsGettingStartedActionButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            self.textField(title: L.providerUsageURLLabel, placeholder: L.providerUsageURLPlaceholder, text: self.$draftURL)
            self.headersEditor

            HStack(alignment: .top, spacing: 14) {
                self.doubleField(title: L.providerUsageTimeoutLabel, value: self.$draftTimeout)
                self.integerField(title: L.providerUsageIntervalLabel, value: self.$draftInterval)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(L.providerUsageSave) {
                    self.onSave(
                        CodexBarProviderUsageConfiguration(
                            requestURL: self.draftURL,
                            requestHeaders: self.headers(from: self.draftHeaders),
                            timeoutSeconds: self.draftTimeout,
                            intervalMinutes: self.draftInterval
                        )
                    )
                    self.isEditing = false
                }
                .buttonStyle(.borderedProminent)

                Button(L.providerUsageCancel) {
                    self.resetDraft()
                    self.isEditing = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func beginEditing() {
        self.resetDraft()
        self.isEditing = true
    }

    private func resetDraft() {
        let configuration = self.provider.usageConfiguration ?? CodexBarProviderUsageConfiguration()
        self.draftURL = configuration.requestURL ?? self.defaultUsageURLString()
        self.draftHeaders = self.headersText(from: configuration.requestHeaders)
        self.draftTimeout = configuration.timeoutSeconds
        self.draftInterval = configuration.intervalMinutes
    }

    private func defaultUsageURLString() -> String {
        let baseURL = self.provider.baseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        switch self.provider.thirdPartyModelProvider {
        case .deepSeek:
            return baseURL.isEmpty ? "https://api.deepseek.com/user/balance" : baseURL + "/user/balance"
        case .mimo:
            return "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
        case .custom, .none:
            guard baseURL.isEmpty == false else { return "" }
            if let url = URL(string: baseURL),
               url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last == "v1" {
                return baseURL + "/usage"
            }
            return baseURL + "/v1/usage"
        }
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.providerUsageHeadersLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextEditor(text: self.$draftHeaders)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minHeight: 68, maxHeight: 92)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            Text(L.providerUsageHeadersPlaceholder)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func headersText(from headers: [String: String]) -> String {
        headers.keys.sorted().map { key in
            "\(key): \(headers[key] ?? "")"
        }.joined(separator: "\n")
    }

    private func headers(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  let separator = trimmed.firstIndex(of: ":") else {
                continue
            }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false, value.isEmpty == false else { continue }
            headers[String(name)] = String(value)
        }
        return headers
    }

    private func textField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium))
                .frame(minHeight: 32)
        }
    }

    private func doubleField(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minHeight: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func integerField(title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minHeight: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastUpdatedText(_ date: Date?) -> String {
        guard let date else { return L.providerUsageNeverUpdated }
        return "\(L.providerUsageLastUpdated) \(self.relativeTimeString(for: date))"
    }

    private func relativeTimeString(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return L.zh ? "刚刚" : "just now"
        }
        if seconds < 3_600 {
            let minutes = max(1, seconds / 60)
            return L.zh ? "\(minutes) 分钟前" : "\(minutes) min ago"
        }
        if seconds < 86_400 {
            let hours = max(1, seconds / 3_600)
            return L.zh ? "\(hours) 小时前" : "\(hours) hr ago"
        }
        let days = max(1, seconds / 86_400)
        return L.zh ? "\(days) 天前" : "\(days) days ago"
    }

}

private struct SettingsProviderUsageWindowTabs: View {
    @Binding var selection: ProviderUsageWindow
    let windows: [ProviderUsageWindow]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(self.windows) { window in
                SettingsProviderUsageWindowTabButton(
                    window: window,
                    isSelected: self.selection == window
                ) {
                    self.selection = window
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct SettingsProviderUsageWindowTabButton: View {
    let window: ProviderUsageWindow
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            Text(ProviderUsageFormat.title(for: self.window))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(self.isSelected ? .white : .primary)
                .frame(width: 56, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(self.backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(self.isHovering ? 0.88 : 1.0)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.14)
        }
        return Color.clear
    }
}

private struct SettingsProviderUsageRecordCard: View {
    let record: ProviderUsageDisplayRecord
    let selectedWindow: ProviderUsageWindow
    let usageDisplayMode: CodexBarUsageDisplayMode

    private var effectiveWindow: ProviderUsageWindow {
        if self.record.data.period(for: self.selectedWindow).hasAnyValue {
            return self.selectedWindow
        }
        return ProviderUsageFormat.primaryConfiguredWindow(for: self.record.data)
    }

    private var period: CodexBarProviderUsagePeriod {
        self.record.data.period(for: self.effectiveWindow)
    }

    private var shouldInlineStatusPill: Bool {
        self.record.data.isBalanceOnly && self.record.data.isValid != nil
    }

    private var hasPackageMetaRow: Bool {
        if self.record.data.planName != nil || self.record.data.expiresAt != nil {
            return true
        }
        if self.record.isSharedPackage, self.record.lastError != nil {
            return true
        }
        return self.record.data.isValid != nil && self.shouldInlineStatusPill == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if self.record.isSharedPackage {
                self.sharedPackageHeader
            } else {
                self.accountHeader
            }

            if self.record.data.isBalanceOnly {
                self.balanceDetailsCard
            } else {
                self.usageValueCard
            }
        }
    }

    private var sharedPackageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.record.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if self.shouldInlineStatusPill {
                    self.statusPill
                }
                Spacer(minLength: 8)
                if let error = self.record.lastError {
                    Text(error)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            if self.hasPackageMetaRow {
                self.packageMetaRow
            }
        }
    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.record.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let subtitle = self.record.subtitle {
                    Text(subtitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if self.shouldInlineStatusPill {
                    self.statusPill
                }
                Spacer(minLength: 8)
                if let error = self.record.lastError {
                    Text(error)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            if self.hasPackageMetaRow {
                self.packageMetaRow
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if let isValid = self.record.data.isValid {
            SettingsProviderUsageStatusPill(
                title: isValid ? L.providerUsageValid : L.providerUsageInvalid,
                color: isValid ? .green : .red
            )
        }
    }

    private var packageMetaRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if self.shouldInlineStatusPill == false {
                self.statusPill
            }
            if let planName = self.record.data.planName {
                Text("\(L.providerUsagePlan)：\(planName)")
            }
            if let expiresAt = self.record.data.expiresAt {
                Text("\(L.providerUsageExpires)：\(self.localizedDateTime(expiresAt))")
            }
            Spacer(minLength: 0)
            if self.record.isSharedPackage, let error = self.record.lastError {
                Text(error)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private var usageValueCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 34) {
                self.amountBlock
                    .frame(maxWidth: .infinity, alignment: .leading)

                self.ratioBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private var balanceDetailsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if self.record.data.balanceDetails.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 34) {
                    ForEach(self.record.data.balanceDetails) { detail in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(detail.label)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(ProviderUsageFormat.money(detail.amount, unit: self.record.data.unit))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.primary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let remaining = self.record.data.remaining {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.providerUsageRemaining)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(ProviderUsageFormat.money(remaining, unit: self.record.data.unit))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private var amountBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ProviderUsageFormat.displayLabel(for: self.effectiveWindow, mode: self.usageDisplayMode))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(self.amountText)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)

                if let limit = self.period.limit, limit > 0 {
                    Text("/ \(ProviderUsageFormat.money(limit, unit: self.record.data.unit))")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private var ratioBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.usageDisplayMode == .remaining ? L.providerUsageRemainingRatio : L.providerUsageUsedRatio)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            if let ratio = self.period.displayedRatio(mode: self.usageDisplayMode),
               self.period.isUnlimited == false {
                HStack(alignment: .center, spacing: 14) {
                    Text(String(format: "%.1f%%", ratio * 100))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(self.progressColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 82, alignment: .leading)

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.14))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(self.progressColor)
                                .frame(width: proxy.size.width * min(max(ratio, 0), 1))
                        }
                    }
                    .frame(height: 7)
                }
            } else {
                Text("--")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }
        }
    }

    private var amountText: String {
        guard let amount = self.period.displayedAmount(mode: self.usageDisplayMode) else {
            return "--"
        }
        return ProviderUsageFormat.money(amount, unit: self.record.data.unit)
    }

    private var progressColor: Color {
        ProviderUsageVisualStyle.progressColor(for: self.period)
    }

    private func localizedDateTime(_ rawValue: String) -> String {
        guard let date = Self.parseRemoteDate(rawValue) else {
            return rawValue
        }
        return Self.localDateTimeFormatter.string(from: date)
    }

    private static func parseRemoteDate(_ rawValue: String) -> Date? {
        if let date = Self.iso8601FormatterWithFractionalSeconds.date(from: rawValue) {
            return date
        }
        if let date = Self.iso8601Formatter.date(from: rawValue) {
            return date
        }
        return nil
    }

    private static let localDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = L.zh ? Locale(identifier: "zh-Hans") : .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private static let iso8601FormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct SettingsProviderUsageStatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(self.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(self.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(self.color.opacity(0.12))
            )
    }
}

private struct SettingsBackupPage: View {
    let backupService: CodexBarBackupService
    let backupPanelService: CodexBarBackupPanelService
    let onRestoreCodexBarSettings: () -> Void
    @Binding var validationMessage: String?

    @State private var codexBarLatestBackup: CodexBarBackupSummary?
    @State private var codexLatestBackup: CodexBarBackupSummary?
    @State private var codexBarBackupSucceeded = false
    @State private var codexBackupSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsPage.backup.title)
                    .font(SettingsTypography.pageTitle)

                Text(L.backupPageHint)
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("1. \(L.backupCodexBarCardTitle)")
                    .font(SettingsTypography.sectionTitle)
                    .foregroundColor(.primary)

                SettingsBackupCard(
                    iconName: "externaldrive.fill",
                    accentColor: .blue,
                    contentTitle: L.backupIncludedContentTitle,
                    bulletItems: [
                        L.backupCodexBarContentAppSettings,
                        L.backupCodexBarContentAccounts,
                    ],
                    lastBackup: self.codexBarLatestBackup,
                    showsSuccessCheck: self.codexBarBackupSucceeded,
                    footer: L.backupCodexBarFooter,
                    onBackup: {
                        self.performBackup(kind: .codexbarSettings)
                    },
                    onRestore: {
                        self.performRestore(kind: .codexbarSettings)
                    },
                    onShowDetails: {
                        self.revealLatestBackup(self.codexBarLatestBackup)
                    }
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("2. \(L.backupCodexCardTitle)")
                    .font(SettingsTypography.sectionTitle)
                    .foregroundColor(.primary)

                SettingsBackupCard(
                    iconName: "doc.badge.gearshape.fill",
                    accentColor: .green,
                    contentTitle: L.backupIncludedFilesTitle,
                    bulletItems: [
                        L.backupCodexContentAuth,
                        L.backupCodexContentConfig,
                    ],
                    lastBackup: self.codexLatestBackup,
                    showsSuccessCheck: self.codexBackupSucceeded,
                    footer: L.backupCodexFooter,
                    onBackup: {
                        self.performBackup(kind: .codexConfig)
                    },
                    onRestore: {
                        self.performRestore(kind: .codexConfig)
                    },
                    onShowDetails: {
                        self.revealLatestBackup(self.codexLatestBackup)
                    }
                )
            }

            SettingsBackupManagementCard(
                backupsDirectoryURL: self.backupService.backupsDirectoryURL
            ) {
                self.backupPanelService.openBackupsDirectory(self.backupService.backupsDirectoryURL)
            }
        }
        .onAppear {
            self.refreshLatestBackups()
        }
    }

    private func performBackup(kind: CodexBarBackupKind) {
        do {
            _ = try self.backupService.createBackup(kind: kind)
            self.validationMessage = nil
            self.setBackupSucceeded(true, for: kind)
            self.refreshLatestBackups()
        } catch {
            self.setBackupSucceeded(false, for: kind)
            self.validationMessage = error.localizedDescription
        }
    }

    private func performRestore(kind: CodexBarBackupKind) {
        guard let url = self.backupPanelService.requestRestoreURL(kind: kind) else { return }
        do {
            _ = try self.backupService.restoreBackup(from: url, expectedKind: kind)
            if kind == .codexbarSettings {
                self.onRestoreCodexBarSettings()
            }
            self.validationMessage = nil
            self.setBackupSucceeded(false, for: kind)
            self.refreshLatestBackups()
        } catch {
            self.validationMessage = error.localizedDescription
        }
    }

    private func revealLatestBackup(_ summary: CodexBarBackupSummary?) {
        guard let summary else { return }
        self.backupPanelService.revealBackupFile(summary.url)
    }

    private func refreshLatestBackups() {
        self.codexBarLatestBackup = self.backupService.latestBackupSummary(kind: .codexbarSettings)
        self.codexLatestBackup = self.backupService.latestBackupSummary(kind: .codexConfig)
    }

    private func setBackupSucceeded(_ succeeded: Bool, for kind: CodexBarBackupKind) {
        switch kind {
        case .codexbarSettings:
            self.codexBarBackupSucceeded = succeeded
        case .codexConfig:
            self.codexBackupSucceeded = succeeded
        }
    }
}

private struct SettingsBackupCard: View {
    let iconName: String
    let accentColor: Color
    let contentTitle: String
    let bulletItems: [String]
    let lastBackup: CodexBarBackupSummary?
    let showsSuccessCheck: Bool
    let footer: String
    let onBackup: () -> Void
    let onRestore: () -> Void
    let onShowDetails: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 22) {
                    Image(systemName: self.iconName)
                        .font(.system(size: 30, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(self.accentColor)
                        .frame(width: 64, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.accentColor.opacity(0.10))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(self.accentColor.opacity(0.14), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 14) {
                        Text(self.contentTitle)
                            .font(.system(size: 15, weight: .semibold))

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(self.bulletItems, id: \.self) { item in
                                Text("•  \(item)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text(L.backupLastBackupLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(self.lastBackupText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    if self.showsSuccessCheck {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(self.accentColor)
                            .accessibilityLabel(L.backupSucceededAccessibilityLabel)
                    }
                    Button(L.backupDetailsAction) {
                        self.onShowDetails()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(self.lastBackup == nil ? .secondary : .accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .menuPanelHoverChrome(cornerRadius: 5, hoverOpacity: 0.10)
                    .disabled(self.lastBackup == nil)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        SettingsBackupActionButton(
                            title: L.backupNowAction,
                            iconName: "square.and.arrow.up",
                            accentColor: self.accentColor,
                            isPrimary: true,
                            action: self.onBackup
                        )
                        SettingsBackupActionButton(
                            title: L.backupRestoreAction,
                            iconName: "folder",
                            accentColor: self.accentColor,
                            isPrimary: false,
                            action: self.onRestore
                        )
                    }
                    VStack(spacing: 12) {
                        SettingsBackupActionButton(
                            title: L.backupNowAction,
                            iconName: "square.and.arrow.up",
                            accentColor: self.accentColor,
                            isPrimary: true,
                            action: self.onBackup
                        )
                        SettingsBackupActionButton(
                            title: L.backupRestoreAction,
                            iconName: "folder",
                            accentColor: self.accentColor,
                            isPrimary: false,
                            action: self.onRestore
                        )
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                Text(self.footer)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .settingsCardBackground()
    }

    private var lastBackupText: String {
        guard let lastBackup else { return L.backupNeverBackedUp }
        return Self.dateFormatter.string(from: lastBackup.createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct SettingsBackupActionButton: View {
    let title: String
    let iconName: String
    let accentColor: Color
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                Image(systemName: self.iconName)
                    .font(.system(size: 16, weight: .semibold))
                Text(self.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundColor(self.isPrimary ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(self.borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        if self.isPrimary {
            return self.accentColor.opacity(self.isHovering ? 0.92 : 1.0)
        }
        return Color(NSColor.windowBackgroundColor).opacity(self.isHovering ? 0.95 : 0.78)
    }

    private var borderColor: Color {
        self.isPrimary ? self.accentColor.opacity(0.18) : Color.primary.opacity(self.isHovering ? 0.16 : 0.10)
    }
}

private struct SettingsBackupManagementCard: View {
    let backupsDirectoryURL: URL
    let onOpenDirectory: () -> Void

    @State private var isHoveringOpenButton = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                self.copy

                Spacer(minLength: 24)

                self.openButton
            }

            VStack(alignment: .leading, spacing: 18) {
                self.copy
                self.openButton
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .settingsCardBackground()
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.backupManagementTitle)
                .font(.system(size: 17, weight: .semibold))
            Text(L.backupManagementHint)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var openButton: some View {
        Button(action: self.onOpenDirectory) {
            HStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .semibold))
                Text(L.backupManageFilesAction)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 22)
            .frame(minWidth: 210)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(self.isHoveringOpenButton ? 1.0 : 0.78))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(self.isHoveringOpenButton ? 0.16 : 0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { self.isHoveringOpenButton = $0 }
    }
}

private struct SettingsUpdatesPage: View {
    @ObservedObject var updateCoordinator: UpdateCoordinator

    private var currentVersion: String {
        AppVersionDisplay.versionAndBuild
    }

    private var latestVersion: String {
        if let availability = self.updateCoordinator.pendingAvailability {
            return availability.release.version
        }
        switch self.updateCoordinator.state {
        case let .upToDate(_, checkedVersion):
            return checkedVersion
        case let .executing(availability):
            return availability.release.version
        case let .updateAvailable(availability):
            return availability.release.version
        case .idle, .checking, .failed:
            return L.settingsUpdatesUnknownVersion
        }
    }

    private var statusText: String {
        switch self.updateCoordinator.state {
        case .idle:
            return L.settingsUpdatesIdle
        case .checking:
            return L.settingsUpdatesChecking
        case let .upToDate(currentVersion, _):
            return L.settingsUpdatesUpToDate(currentVersion)
        case let .updateAvailable(availability):
            return L.settingsUpdatesAvailable(
                availability.currentVersion,
                availability.release.version
            )
        case let .executing(availability):
            return L.settingsUpdatesExecuting(availability.release.version)
        case let .failed(message):
            return L.settingsUpdatesFailed(message)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsPage.updates.title)
                    .font(SettingsTypography.pageTitle)

                Text(L.settingsUpdatesPageHint)
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    SettingsUpdatesInfoRow(
                        title: L.settingsUpdatesCurrentVersionTitle,
                        value: self.currentVersion
                    )
                    Divider().padding(.leading, 16)
                    SettingsUpdatesInfoRow(
                        title: L.settingsUpdatesLatestVersionTitle,
                        value: self.latestVersion
                    )
                    Divider().padding(.leading, 16)
                    SettingsUpdatesInfoRow(
                        title: L.settingsUpdatesStatusTitle,
                        value: self.statusText
                    )
                }
                .settingsCardBackground()
            }

            HStack(spacing: 10) {
                Button {
                    Task { await self.updateCoordinator.checkForUpdates(trigger: .manual) }
                } label: {
                    Label(L.settingsUpdatesCheckAction, systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 112, minHeight: 30)
                }
                .buttonStyle(SettingsGettingStartedActionButtonStyle())
                .disabled(self.updateCoordinator.isChecking)

                if self.updateCoordinator.pendingAvailability != nil {
                    Button {
                        Task { await self.updateCoordinator.handleToolbarAction() }
                    } label: {
                        Label(L.settingsUpdatesInstallAction, systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 112, minHeight: 30)
                    }
                    .buttonStyle(SettingsGettingStartedActionButtonStyle())
                    .disabled(self.updateCoordinator.isChecking)
                }
            }

            if self.updateCoordinator.isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.settingsUpdatesChecking)
                        .font(SettingsTypography.sectionHint)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct SettingsUpdatesInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(self.title)
                .font(SettingsTypography.subsectionTitle)
                .foregroundColor(.primary)
                .frame(width: 160, alignment: .leading)
            Text(self.value)
                .font(SettingsTypography.pageHint)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

private struct SettingsAccountUsageModeSection: View {
    @Binding var mode: CodexBarOpenAIAccountUsageMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountUsageModeTitle)
                .font(SettingsTypography.subsectionTitle)

            Text(L.accountUsageModeHint)
                .font(SettingsTypography.sectionHint)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexBarOpenAIAccountUsageMode.allCases) { option in
                    SettingsSelectableOptionButton(
                        title: option.title,
                        detail: option.detail,
                        isSelected: self.mode == option
                    ) {
                        self.mode = option
                    }
                }
            }
        }
    }
}

private struct SettingsLabeledBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.title)
                .font(SettingsTypography.sectionTitle)

            self.content
        }
    }
}

private struct SettingsCodexAppPathSettingsSection: View {
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService

    var body: some View {
        SettingsLabeledBlock(title: L.codexAppPathSectionTitle) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L.codexAppPathHint)
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsCodexAppPathSection(
                    preferredCodexAppPath: self.$preferredCodexAppPath,
                    validationMessage: self.$validationMessage,
                    codexAppPathPanelService: self.codexAppPathPanelService
                )
            }
        }
    }
}

private struct SettingsAccountOrderingModeSection: View {
    @Binding var mode: CodexBarOpenAIAccountOrderingMode

    var body: some View {
        SettingsLabeledBlock(title: L.accountOrderingModeTitle) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L.accountOrderingModeHint)
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(CodexBarOpenAIAccountOrderingMode.allCases) { option in
                        SettingsSelectableOptionButton(
                            title: option.title,
                            detail: option.detail,
                            isSelected: self.mode == option
                        ) {
                            self.mode = option
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsSelectableOptionButton: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(self.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: self.isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(self.isSelected ? .accentColor : .secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(self.borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(0.05)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.10)
        }
        return Color(NSColor.windowBackgroundColor).opacity(0.58)
    }

    private var borderColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(0.24)
        }
        return Color.primary.opacity(self.isHovering ? 0.14 : 0.09)
    }
}

private struct SettingsAccountOrderSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.accountOrderTitle)
                .font(.system(size: 16, weight: .semibold))

            if self.coordinator.orderedAccounts.isEmpty {
                Text(L.noOpenAIAccountsForOrdering)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(self.coordinator.orderedAccounts.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(item.detail)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 6) {
                                Button(L.moveUp) {
                                    self.coordinator.moveAccount(accountID: item.id, offset: -1)
                                }
                                .disabled(index == 0)

                                Button(L.moveDown) {
                                    self.coordinator.moveAccount(accountID: item.id, offset: 1)
                                }
                                .disabled(index == self.coordinator.orderedAccounts.count - 1)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.windowBackgroundColor).opacity(0.58))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                        }
                    }
                }
            }
        }
        .settingsCardPadding()
        .settingsCardBackground()
    }
}

private struct SettingsCodexAppPathSection: View {
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService

    private var status: CodexDesktopPreferredAppPathStatus {
        CodexDesktopLaunchProbeService.preferredAppPathStatus(for: self.preferredCodexAppPath)
    }

    private var displayedValue: String {
        switch self.status {
        case .automatic:
            return L.codexAppPathAutomaticStatus
        case .manualValid(let path), .manualInvalid(let path):
            return path
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L.codexAppPathTitle)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 110, alignment: .leading)

            Group {
                switch self.status {
                case .automatic:
                    Text(self.displayedValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                case .manualValid, .manualInvalid:
                    Text(self.displayedValue)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(self.statusColor)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 0)

            Button(L.codexAppPathChooseAction) {
                self.chooseCodexApp()
            }

            if (self.preferredCodexAppPath ?? "").isEmpty == false {
                Button(L.codexAppPathResetAction) {
                    self.preferredCodexAppPath = nil
                    self.validationMessage = nil
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.58))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }

    private var statusColor: Color {
        switch self.status {
        case .automatic:
            return .secondary
        case .manualValid:
            return .primary
        case .manualInvalid:
            return .orange
        }
    }

    private func chooseCodexApp() {
        guard let selectedURL = self.codexAppPathPanelService.requestCodexAppURL(
            currentPath: self.preferredCodexAppPath
        ) else {
            return
        }

        guard let validatedURL = CodexDesktopLaunchProbeService.validatedPreferredCodexAppURL(
            from: selectedURL.path
        ) else {
            self.validationMessage = L.codexAppPathInvalidSelection
            return
        }

        self.preferredCodexAppPath = validatedURL.path
        self.validationMessage = nil
    }
}

private struct SettingsUsageDisplayModeSection: View {
    @Binding var usageDisplayMode: CodexBarUsageDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L.usageDisplayModeTitle, selection: self.$usageDisplayMode) {
                ForEach(CodexBarUsageDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct SettingsQuotaSortSection: View {
    @Binding var plusRelativeWeight: Double
    @Binding var proRelativeToPlusMultiplier: Double
    @Binding var teamRelativeToPlusMultiplier: Double

    private var proAbsoluteWeight: Double {
        self.plusRelativeWeight * self.proRelativeToPlusMultiplier
    }

    private var teamAbsoluteWeight: Double {
        self.plusRelativeWeight * self.teamRelativeToPlusMultiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.quotaSortSettingsTitle)
                .font(SettingsTypography.subsectionTitle)

            Text(L.quotaSortSettingsHint)
                .font(SettingsTypography.sectionHint)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortPlusWeightTitle)
                        .font(SettingsTypography.sectionHint)
                    Spacer()
                    Text(L.quotaSortPlusWeightValue(self.plusRelativeWeight))
                        .font(SettingsTypography.sectionHint)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: self.$plusRelativeWeight,
                    in: CodexBarOpenAISettings.QuotaSortSettings.plusRelativeWeightRange,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortProRatioTitle)
                        .font(SettingsTypography.sectionHint)
                    Spacer()
                    Text(
                        L.quotaSortProRatioValue(
                            self.proRelativeToPlusMultiplier,
                            absoluteProWeight: self.proAbsoluteWeight
                        )
                    )
                    .font(SettingsTypography.sectionHint)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Slider(
                    value: self.$proRelativeToPlusMultiplier,
                    in: CodexBarOpenAISettings.QuotaSortSettings.proRelativeToPlusRange,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortTeamRatioTitle)
                        .font(SettingsTypography.sectionHint)
                    Spacer()
                    Text(
                        L.quotaSortTeamRatioValue(
                            self.teamRelativeToPlusMultiplier,
                            absoluteTeamWeight: self.teamAbsoluteWeight
                        )
                    )
                    .font(SettingsTypography.sectionHint)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Slider(
                    value: self.$teamRelativeToPlusMultiplier,
                    in: CodexBarOpenAISettings.QuotaSortSettings.teamRelativeToPlusRange,
                    step: 0.1
                )
            }
        }
    }
}

private struct SettingsModelPricingSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.modelPricingSectionTitle)
                .font(SettingsTypography.subsectionTitle)

            Text(L.modelPricingSectionHint)
                .font(SettingsTypography.sectionHint)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.coordinator.historicalModels.isEmpty {
                Text(L.modelPricingSectionEmpty)
                    .font(SettingsTypography.sectionHint)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.coordinator.historicalModels, id: \.self) { model in
                        SettingsModelPricingRow(
                            model: model,
                            pricing: Binding(
                                get: { self.coordinator.draft.modelPricing[model] ?? .zero },
                                set: { self.coordinator.updateModelPricing(for: model, pricing: $0) }
                            )
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsModelPricingRow: View {
    let model: String
    @Binding var pricing: CodexBarModelPricing

    private let fieldWidth: CGFloat = 120
    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...10))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.model)
                .font(SettingsTypography.sectionHint)
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 10) {
                self.priceField(
                    title: L.modelPricingInputTitle,
                    binding: Binding(
                        get: { self.pricing.inputUSDPerToken },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: $0,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingCachedInputTitle,
                    binding: Binding(
                        get: { self.pricing.cachedInputUSDPerToken },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: $0,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingOutputTitle,
                    binding: Binding(
                        get: { self.pricing.outputUSDPerToken },
                        set: {
                            self.pricing = CodexBarModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: $0
                            )
                        }
                    )
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func priceField(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SettingsTypography.sectionHint)
                .foregroundColor(.secondary)

            TextField(title, value: binding, format: self.numberFormat)
                .textFieldStyle(.roundedBorder)
                .frame(width: self.fieldWidth)
        }
    }
}

private extension SettingsPage {
    var title: String {
        switch self {
        case .gettingStarted:
            return L.settingsGettingStartedPageTitle
        case .accounts:
            return L.settingsAccountsPageTitle
        case .backup:
            return L.settingsBackupPageTitle
        case .records:
            return L.settingsRecordsPageTitle
        case .skills:
            return L.settingsSkillsPageTitle
        case .usage:
            return L.settingsUsagePageTitle
        case .updates:
            return L.settingsUpdatesPageTitle
        }
    }

    var iconName: String {
        switch self {
        case .gettingStarted:
            return "sparkles"
        case .accounts:
            return "person.crop.circle"
        case .backup:
            return "externaldrive"
        case .records:
            return "clock.arrow.circlepath"
        case .skills:
            return "wrench.and.screwdriver"
        case .usage:
            return "chart.bar"
        case .updates:
            return "arrow.trianglehead.2.clockwise"
        }
    }
}

private extension CodexBarOpenAIAccountUsageMode {
    var title: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitch
        case .aggregateGateway:
            return L.accountUsageModeAggregate
        case .hybridProvider:
            return L.accountUsageModeHybrid
        }
    }

    var detail: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchHint
        case .aggregateGateway:
            return L.accountUsageModeAggregateHint
        case .hybridProvider:
            return L.accountUsageModeHybridHint
        }
    }

    var gettingStartedTitle: String {
        switch self {
        case .switchAccount:
            return L.gettingStartedModeSwitchTitle
        case .aggregateGateway:
            return L.gettingStartedModeAggregateTitle
        case .hybridProvider:
            return L.gettingStartedModeHybridTitle
        }
    }

    var gettingStartedDetail: String {
        switch self {
        case .switchAccount:
            return L.gettingStartedModeSwitchDetail
        case .aggregateGateway:
            return L.gettingStartedModeAggregateDetail
        case .hybridProvider:
            return L.gettingStartedModeHybridDetail
        }
    }
}

private extension CodexBarOpenAIAccountOrderingMode {
    var title: String {
        switch self {
        case .quotaSort:
            return L.accountOrderingModeQuotaSort
        case .manual:
            return L.accountOrderingModeManual
        }
    }

    var detail: String {
        switch self {
        case .quotaSort:
            return L.accountOrderingModeQuotaSortHint
        case .manual:
            return L.accountOrderingModeManualHint
        }
    }
}
