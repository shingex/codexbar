import AppKit
import Combine
import ServiceManagement
import SwiftUI

private struct SettingsDeleteConfirmationRequest {
    enum Target {
        case openAIAccount(TokenAccount)
        case customProviderAccount(providerID: String, providerLabel: String, accountID: String, accountLabel: String)
        case customProvider(providerID: String, providerLabel: String)
        case openRouterAccount(accountID: String, accountLabel: String)
    }

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

enum SettingsPalette {
    static let secondaryText = Color.primary.opacity(0.72)
}

enum SettingsTypography {
    static let pageTitle = Font.system(size: 22, weight: .semibold)
    static let pageHint = Font.system(size: 12)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let sectionHint = Font.system(size: 11, weight: .medium)
}

enum SettingsSpacing {
    static let page: CGFloat = 24
    static let section: CGFloat = 24
    static let card: CGFloat = 16
    static let row: CGFloat = 8
    static let text: CGFloat = 4
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 8
}

struct SettingsDivider: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(width: self.axis == .vertical ? 1 / self.displayScale : nil,
                   height: self.axis == .horizontal ? 1 / self.displayScale : nil)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct SettingsPanelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private enum SettingsWindowLayout {
    static let minimumWidth: CGFloat = 700
    static let minimumHeight: CGFloat = 280
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

    @AppStorage(L.languageOverrideKey) private var languageOverride: Bool?
    @StateObject private var coordinator: SettingsWindowCoordinator
    @StateObject private var recordsModel: SettingsRecordsModel
    @State private var pendingRouteChoice: SettingsRouteDraft?
    @State private var pendingCodexLaunchPrompt = false
    @State private var closeAfterLaunchPrompt = false
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
        selectedPage: SettingsPage = .gettingStarted,
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
                selectedPage: selectedPage,
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
        .id(self.languageOverride ?? L.zh)
        .frame(
            minWidth: SettingsWindowLayout.minimumWidth,
            minHeight: SettingsWindowLayout.minimumHeight
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(self.modeAccentColor)
        .accentColor(self.modeAccentColor)
        .buttonStyle(SettingsHoverButtonStyle())
        .alert(
            L.launchCodexPromptTitle,
            isPresented: self.$pendingCodexLaunchPrompt
        ) {
            Button(L.launchCodexPromptConfirm) {
                guard self.commitPendingRoute() else { return }
                Task {
                    await self.launchCodexInstanceAfterPrompt()
                    self.finishAfterLaunchPrompt()
                }
            }

            Button(L.launchCodexPromptCancel) {
                guard self.commitPendingRoute() else { return }
                self.finishAfterLaunchPrompt()
            }
            Button(L.zh ? "取消" : "Cancel", role: .cancel) {
                self.pendingRouteChoice = nil
                self.coordinator.acceptSavedRoute(SettingsRouteDraft(config: self.store.config))
                self.pendingCodexLaunchPrompt = false
                self.closeAfterLaunchPrompt = false
            }
        } message: {
            Text(L.launchCodexPromptMessage)
        }
        .onChange(of: self.coordinator.draft.route) { route in
            guard self.coordinator.selectedPage == .gettingStarted,
                  self.coordinator.hasStagedRouteChange,
                  self.pendingRouteChoice == nil else { return }
            self.pendingRouteChoice = route
            self.pendingCodexLaunchPrompt = true
        }
        .onReceive(self.store.$config.dropFirst()) { config in
            self.coordinator.reconcileExternalState(
                config: config,
                accounts: self.store.accounts,
            )
        }
        .onReceive(self.store.$accounts.dropFirst()) { accounts in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: accounts,
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidSucceed)) { _ in
            self.reloadSettingsState()
            self.coordinator.validationMessage = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidFail)) { notification in
            self.coordinator.validationMessage = notification.userInfo?["message"] as? String ?? "OpenAI login failed."
        }
    }

    private var sidebar: some View {
        List(selection: SettingsSidebarSelectionAdapter.binding(for: self.coordinator)) {
            ForEach(SettingsPage.allCases) { page in
                SettingsSidebarRow(
                    page: page,
                    isSelected: self.coordinator.selectedPage == page
                )
                .tag(Optional(page))
                .contentShape(Rectangle())
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .onTapGesture {
                    SettingsSidebarSelectionAdapter.apply(page, to: self.coordinator)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: SettingsSidebarRow.minimumColumnWidth, alignment: .leading)
        .navigationSplitViewColumnWidth(
            min: SettingsSidebarRow.minimumColumnWidth,
            ideal: SettingsSidebarRow.idealColumnWidth,
            max: SettingsSidebarRow.maximumColumnWidth
        )
    }

    private var modeAccentColor: Color {
        ModelTheme.color(config: self.store.config)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let validationMessage = self.coordinator.validationMessage {
                SettingsValidationBanner(message: validationMessage)
                    .padding(.horizontal, SettingsSpacing.page)
                    .padding(.top, SettingsSpacing.card)
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
                            onAddProvider: { self.openAddProviderWindow() },
                            onAddProviderAccount: self.openAddProviderAccountWindow,
                            onEditProvider: self.openEditProviderWindow,
                            onEditProviderAccount: self.openEditProviderAccountWindow,
                            onDeleteProviderAccount: self.confirmDeleteCompatibleAccount,
                            onDeleteProvider: self.confirmDeleteProvider,
                            onAddOpenRouterAccount: self.openAddOpenRouterAccountWindow,
                            onEditOpenRouterAccount: self.openEditOpenRouterWindow,
                            onDeleteOpenRouterAccount: self.confirmDeleteOpenRouterAccount,
                            onMoveProvider: self.moveProvider
                        )
                        .settingsDetailPagePadding()
                    }
                case .accounts:
                    ScrollView {
                        SettingsAccountsPage(
                            coordinator: self.coordinator,
                            isChinese: Binding(
                                get: { self.languageOverride ?? L.zh },
                                set: { self.languageOverride = $0 }
                            ),
                            codexAppPathPanelService: self.codexAppPathPanelService,
                            onSetCodexAppPath: { self.coordinator.applyPreferredCodexAppPath($0, using: self.store) },
                            onSelectRoutingStyle: { style in
                                var route = self.coordinator.draft.route
                                route.style = style
                                self.pendingRouteChoice = route
                                self.pendingCodexLaunchPrompt = true
                            }
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
                    .padding(SettingsSpacing.page)
                case .usage:
                    ScrollView {
                        SettingsUsagePage(
                            store: self.store,
                            coordinator: self.coordinator,
                            onSaveProviderUsage: self.saveProviderUsageConfiguration,
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if self.coordinator.selectedPage == .accounts {
                SettingsPageActionBar(
                    isVisible: self.coordinator.hasAccountSettingsChanges,
                    onCancel: self.coordinator.cancelAccountSettingsChanges,
                    onSave: self.saveAccountSettings
                )
            }
        }
        .background {
            SettingsPanelBackdrop().ignoresSafeArea().allowsHitTesting(false)
        }
    }

    private func commitPendingRoute() -> Bool {
        do {
            if let route = self.pendingRouteChoice {
                _ = try self.store.applySettingsRoute(route)
                self.coordinator.acceptSavedRoute(SettingsRouteDraft(config: self.store.config))
            }
            self.pendingRouteChoice = nil
            self.coordinator.reconcileExternalState(config: self.store.config, accounts: self.store.accounts)
            return true
        } catch { self.coordinator.validationMessage = error.localizedDescription; return false }
    }

    private func saveAccountSettings() {
        do {
            _ = try self.coordinator.saveAccountSettings(using: self.store)
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
            let result = try self.oauthAccountService.importAccounts(
                parsed.accounts,
                activeAccountID: parsed.activeAccountID,
                interopContext: parsed.interopContext
            )
            self.reloadSettingsState()
            self.coordinator.validationMessage = nil
            self.refreshImportedOpenAIAccounts(accountIDs: result.importedAccountIDs)
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

    private func openAddProviderWindow(defaultPreset: AddProviderPreset = .custom) {
        DetachedWindowPresenter.shared.show(
            id: "settings-add-provider",
            title: L.addProviderTitle,
            size: CGSize(width: 520, height: 720)
        ) {
            AddProviderSheet(store: store, defaultPreset: defaultPreset) { preset, label, baseURL, accountLabel, apiKey, thirdPartySelection, openRouterSelection in
                do {
                    switch preset {
                    case .custom:
                        try store.addCustomProvider(label: label, baseURL: baseURL, accountLabel: accountLabel, apiKey: apiKey, selectedModelID: thirdPartySelection?.selectedModelID, pinnedModelIDs: thirdPartySelection?.pinnedModelIDs ?? [])
                    case .thirdParty, .openCode:
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
                            apiKey: apiKey,
                            openCodePlan: thirdPartySelection.openCodePlan,
                            cachedModelCatalog: thirdPartySelection.cachedModelCatalog,
                            fetchedAt: thirdPartySelection.fetchedAt
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
                        try store.updateCustomProviderMetadata(providerID: provider.id, label: label, baseURL: baseURL)
                    case .thirdParty, .openCode:
                        try store.updateThirdPartyProviderMetadata(providerID: provider.id,
                            provider: provider.thirdPartyModelProvider ?? .custom, label: label, baseURL: baseURL)
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
            size: CGSize(width: 480, height: 420)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey, models in
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey, selectedModelID: models.selectedModelID, pinnedModelIDs: models.pinnedModelIDs)
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
                        guard (preset == .thirdParty || preset == .openCode),
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
                                apiKey: apiKey,
                                openCodePlan: thirdPartySelection.openCodePlan,
                            cachedModelCatalog: thirdPartySelection.cachedModelCatalog,
                            fetchedAt: thirdPartySelection.fetchedAt
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
            size: CGSize(width: 480, height: 420)
        ) {
            AddProviderAccountSheet(provider: provider, account: account) { label, apiKey, models in
                do {
                    try store.updateCustomProviderAccount(
                        providerID: provider.id,
                        accountID: account.id,
                        label: label,
                        apiKey: apiKey, selectedModelID: models.selectedModelID, pinnedModelIDs: models.pinnedModelIDs
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
            self.coordinator.validationMessage = nil
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
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
        self.presentDeleteConfirmationSynchronously(
            SettingsDeleteConfirmationRequest(target: .openAIAccount(account))
        )
    }

    private func confirmDeleteCompatibleAccount(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        self.presentDeleteConfirmationSynchronously(
            SettingsDeleteConfirmationRequest(
                target: .customProviderAccount(
                    providerID: provider.id,
                    providerLabel: provider.displayName,
                    accountID: account.id,
                    accountLabel: account.label
                )
            )
        )
    }

    private func moveProvider(_ sourceID: String, before destinationID: String) {
        do {
            try self.store.moveProvider(sourceID, before: destinationID)
        } catch {
            self.coordinator.validationMessage = error.localizedDescription
        }
    }

    private func confirmDeleteProvider(provider: CodexBarProvider) {
        self.presentDeleteConfirmationSynchronously(
            SettingsDeleteConfirmationRequest(
                target: .customProvider(providerID: provider.id, providerLabel: provider.displayName)
            )
        )
    }

    private func confirmDeleteOpenRouterAccount(_ account: CodexBarProviderAccount) {
        self.presentDeleteConfirmationSynchronously(
            SettingsDeleteConfirmationRequest(
                target: .openRouterAccount(accountID: account.id, accountLabel: account.label)
            )
        )
    }

    private func performConfirmedDelete(_ request: SettingsDeleteConfirmationRequest) {
        do {
            switch request.target {
            case .openAIAccount(let account):
                try self.store.remove(account)
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

    private func presentDeleteConfirmationSynchronously(_ request: SettingsDeleteConfirmationRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        let deleteButton = alert.addButton(withTitle: L.deleteConfirm)
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: L.cancel)

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        self.performConfirmedDelete(request)
    }

    private func refreshImportedOpenAIAccounts(accountIDs: [String]) {
        let importedAccountIDs = Set(accountIDs)
        guard importedAccountIDs.isEmpty == false else { return }

        let importedAccounts = self.store.accounts.filter { importedAccountIDs.contains($0.accountId) }
        guard importedAccounts.isEmpty == false else { return }

        Task {
            await withTaskGroup(of: Void.self) { group in
                for account in importedAccounts {
                    group.addTask {
                        _ = await WhamService.shared.refreshOne(account: account, store: self.store)
                    }
                }
            }
            self.reloadSettingsState()
        }
    }

    private func reloadSettingsState() {
        self.store.load()
        self.coordinator.reconcileExternalState(
            config: self.store.config,
            accounts: self.store.accounts,
        )
    }
}

// Settings inherits the menu panel's surfaces; only the current choice uses active depth.
struct SettingsPageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.text) {
            Text(self.title).font(SettingsTypography.pageTitle)
            Text(self.detail)
                .font(SettingsTypography.pageHint)
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

extension View {
    func settingsDetailPagePadding() -> some View {
        self
            .padding(SettingsSpacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func settingsCardPadding() -> some View {
        self.padding(SettingsSpacing.card)
    }

    func settingsCardBackground(isHovering: Bool = false) -> some View {
        self
            .background { MenuPanelCardSurface() }
            .overlay {
                RoundedRectangle(cornerRadius: MenuPanelSurface.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.045 : 0))
                    .allowsHitTesting(false)
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
    static let horizontalPadding: CGFloat = 12
    static let iconWidth: CGFloat = 18
    static let iconTitleSpacing: CGFloat = 10
    static let titleFontSize: CGFloat = 13
    static let titleFontWeight: NSFont.Weight = .semibold
    static let rowHorizontalPadding: CGFloat = 6
    static let listRowHorizontalInset: CGFloat = 6
    static let widthSafetyPadding: CGFloat = 8

    let page: SettingsPage
    let isSelected: Bool

    @State private var isHovering = false

    static var minimumColumnWidth: CGFloat {
        let widestTitle = SettingsPage.allCases
            .map { self.measuredTitleWidth($0.title) }
            .max() ?? 0
        return (Self.listRowHorizontalInset * 2) +
            (Self.horizontalPadding * 2) +
            (Self.rowHorizontalPadding * 2) +
            Self.iconWidth +
            Self.iconTitleSpacing +
            ceil(widestTitle) +
            Self.widthSafetyPadding
    }

    static var idealColumnWidth: CGFloat {
        Self.minimumColumnWidth
    }

    static var maximumColumnWidth: CGFloat {
        Self.minimumColumnWidth
    }

    var body: some View {
        HStack(spacing: Self.iconTitleSpacing) {
            Image(systemName: self.page.iconName)
                .font(.system(size: Self.titleFontSize, weight: self.isSelected ? .semibold : .medium))
                .frame(width: Self.iconWidth, alignment: .center)
            Text(self.page.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
            .font(.system(size: 13, weight: self.isSelected ? .semibold : .medium))
            .foregroundColor(self.isSelected ? .accentColor : .primary)
            .padding(.horizontal, Self.rowHorizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if self.isSelected { MenuPanelSegmentSurface(selected: true) }
            }
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(self.isHovering ? Color.primary.opacity(0.05) : Color.clear)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { self.isHovering = $0 }
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
                .font(SettingsTypography.rowTitle)
                .foregroundColor(.red)
            Text(self.message)
                .font(SettingsTypography.sectionHint)
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
                Text(L.zh ? "有未保存的更改" : "Unsaved changes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsPalette.secondaryText)
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
            .padding(.horizontal, SettingsSpacing.page)
            .padding(.vertical, 12)
            .background { SettingsPanelBackdrop().allowsHitTesting(false) }
            .overlay(alignment: .top) { SettingsDivider() }
        }
    }
}

private struct SettingsGettingStartedFloatingActionPanel: View {
    let hasChanges: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
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
                .disabled(self.hasChanges == false)
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
                .disabled(self.hasChanges == false)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
    }
}

private struct SettingsGettingStartedQuickAccountItem: Identifiable {
    let id: String
    let title: String
    let target: SettingsRouteTarget

    // This list chooses accounts; an effective/default model does not change account identity.
    func matchesAccount(_ selected: SettingsRouteTarget?) -> Bool {
        switch (self.target, selected) {
        case let (.openAIAccount(accountID, _), .openAIAccount(selectedID, _)):
            return accountID == selectedID
        case let (.compatibleProvider(providerID, accountID, _, _), .compatibleProvider(selectedProviderID, selectedID, _, _)):
            return providerID == selectedProviderID && accountID == selectedID
        case let (.openRouter(accountID, _, _), .openRouter(selectedID, _, _)):
            return accountID == selectedID
        default:
            return false
        }
    }
}

private struct SettingsGettingStartedQuickAccountSwitchSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let items: [SettingsGettingStartedQuickAccountItem]

    private var currentItem: SettingsGettingStartedQuickAccountItem? {
        self.items.first { $0.matchesAccount(self.coordinator.selectedRouteTarget) }
    }

    private var otherItems: [SettingsGettingStartedQuickAccountItem] {
        self.items.filter { $0.matchesAccount(self.coordinator.selectedRouteTarget) == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.row) {
            Text(self.otherItems.isEmpty
                 ? (L.zh ? "当前连接" : "Current Connection")
                 : L.gettingStartedQuickAccountSwitchTitle)
                .font(SettingsTypography.sectionTitle)

            if let currentItem {
                HStack(spacing: 12) {
                    Text(currentItem.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    MenuPanelCurrentIndicator(width: 64)
                }
                .settingsCardPadding()
                .background { MenuPanelCardSurface(active: true) }
            }

            if self.otherItems.isEmpty == false {
                DisclosureGroup(L.zh ? "切换连接（\(self.otherItems.count)）" : "Switch connection (\(self.otherItems.count))") {
                    VStack(spacing: 0) {
                        ForEach(self.otherItems) { item in
                            SettingsGettingStartedQuickAccountRow(item: item, isSelected: false) {
                                self.coordinator.selectRouteTarget(item.target)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(SettingsTypography.rowTitle)
                .settingsCardPadding()
                .settingsCardBackground()
            }
        }
    }
}

private struct SettingsGettingStartedQuickAccountRow: View {
    let item: SettingsGettingStartedQuickAccountItem
    let isSelected: Bool
    let onSelect: () -> Void

    private let buttonWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: 12) {
            Text(self.item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(self.isSelected ? .accentColor : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if self.isSelected {
                MenuPanelCurrentIndicator(width: self.buttonWidth)
                    .accessibilityLabel(L.gettingStartedQuickAccountSelected)
            } else {
                Button {
                    self.onSelect()
                } label: {
                    Text(L.openAIAccountSwitchAction)
                        .frame(width: self.buttonWidth)
                        .frame(height: 26)
                }
                .buttonStyle(
                    SettingsHoverButtonStyle(
                        horizontalPadding: 0,
                        verticalPadding: 0,
                        minWidth: self.buttonWidth,
                        minHeight: 28
                    )
                )
                .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
        .background(self.isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct SettingsAccountsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    @Binding var isChinese: Bool
    let codexAppPathPanelService: CodexAppPathPanelService
    let onSetCodexAppPath: (String?) -> Void
    let onSelectRoutingStyle: (CodexRoutingStyle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.section) {
            SettingsPageHeader(
                title: SettingsPage.accounts.title,
                detail: L.zh ? "选择在哪里切换模型，以及 CodexBar 的启动方式。" : "Choose where to switch models and how CodexBar starts."
            )
            VStack(alignment: .leading, spacing: SettingsSpacing.row) {
                Text(L.zh ? "切换模型方式" : "Model switching").font(SettingsTypography.sectionTitle)
                SettingsModelSwitchingCard(
                    title: L.zh ? "在 CodexBar 中切换" : "Switch in CodexBar",
                    detail: L.zh ? "在 CodexBar 中选择要使用的模型。" : "Browse all available models and use the one selected in CodexBar.",
                    selected: self.coordinator.draft.route.style == .follow
                ) { self.onSelectRoutingStyle(.follow) }
                SettingsModelSwitchingCard(
                    title: L.zh ? "在 Codex 中切换" : "Switch in Codex",
                    detail: L.zh ? "直接在 Codex 会话中选择模型。" : "Choose the model you need directly in each Codex conversation.",
                    selected: self.coordinator.draft.route.style == .catalog
                ) { self.onSelectRoutingStyle(.catalog) }
            }

            VStack(alignment: .leading, spacing: SettingsSpacing.row) {
                Text(L.zh ? "启动与应用" : "Startup & application")
                    .font(SettingsTypography.sectionTitle)
                VStack(alignment: .leading, spacing: 0) {
                    SettingsLaunchAtLoginSection(
                        isEnabled: Binding(
                            get: { self.coordinator.draft.launchAtLoginEnabled },
                            set: self.coordinator.applyLaunchAtLogin
                        )
                    )
                    SettingsDivider().padding(.horizontal, 16)
                    SettingsCodexAppPathSettingsSection(
                        preferredCodexAppPath: Binding(
                            get: { self.coordinator.draft.preferredCodexAppPath },
                            set: self.onSetCodexAppPath
                        ),
                        validationMessage: self.$coordinator.validationMessage,
                        codexAppPathPanelService: self.codexAppPathPanelService
                    )
                    .padding(SettingsSpacing.card)
                    SettingsDivider().padding(.horizontal, SettingsSpacing.card)
                    HStack {
                        Text(L.zh ? "语言" : "Language")
                            .font(SettingsTypography.rowTitle)
                        Spacer(minLength: SettingsSpacing.row)
                        Picker(L.zh ? "语言" : "Language", selection: self.$isChinese) {
                            Text("简体中文").tag(true)
                            Text("English").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(SettingsSpacing.card)
                }
                .settingsCardBackground()
            }

            if self.coordinator.orderedAccounts.count > 1 {
                SettingsAccountOrderSection(coordinator: self.coordinator)
            }
        }
    }
}

private struct SettingsModelSwitchingCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().strokeBorder(self.selected ? Color.accentColor : Color.primary.opacity(0.54), lineWidth: 1.5)
                    if self.selected { Circle().fill(Color.accentColor).padding(5) }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 8) {
                    Text(self.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(self.detail).font(SettingsTypography.pageHint).foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background { MenuPanelCardSurface(active: self.selected) }
            .overlay {
                RoundedRectangle(cornerRadius: self.selected ? MenuPanelSurface.activeCornerRadius : MenuPanelSurface.cornerRadius)
                    .fill(Color.primary.opacity(self.hovering ? 0.045 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: MenuPanelSurface.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
        .accessibilityLabel(self.title + ", " + self.detail)
        .accessibilityAddTraits(self.selected ? .isSelected : [])
    }
}

private struct SettingsLaunchAtLoginSection: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: self.$isEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.launchAtLoginTitle).font(SettingsTypography.rowTitle)
                Text(L.zh ? "登录 Mac 后自动启动 CodexBar。" : "Start CodexBar automatically when you log in to your Mac.")
                    .font(SettingsTypography.pageHint)
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
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
    let onMoveProvider: (String, String) -> Void

    private var groupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.groupedAccounts(
            from: self.store.accounts,
            summary: .empty,
            preferredAccountOrder: self.store.config.openAI.accountOrder,
            highlightActiveAccount: self.coordinator.draft.route.mode == .switchAccount
        )
    }

    private var quickAccountItems: [SettingsGettingStartedQuickAccountItem] {
        let activationMode = self.quickSwitchActivationMode
        let openAIItems = self.store.accounts.map { account in
            SettingsGettingStartedQuickAccountItem(
                id: "openai-\(account.accountId)",
                title: "OpenAI · " + self.openAIAccountTitle(for: account),
                target: .openAIAccount(accountID: account.accountId, mode: activationMode)
            )
        }.filter { item in
            (self.store.accounts.count > 1 && !self.coordinator.draft.route.modelRoutingEnabled) ||
                item.matchesAccount(self.coordinator.selectedRouteTarget)
        }

        let compatibleProviderItems = self.store.customProviders.flatMap { provider in
            provider.accounts.map { account in
                SettingsGettingStartedQuickAccountItem(
                    id: "provider-\(provider.id)-\(account.id)",
                    title: self.providerAccountTitle(for: account, provider: provider),
                    target: .compatibleProvider(
                        providerID: provider.id,
                        accountID: account.id,
                        modelID: nil,
                        mode: activationMode
                    )
                )
            }
        }

        let thirdPartyProviderItems = self.store.thirdPartyModelProviders.flatMap { provider in
            provider.accounts.map { account in
                SettingsGettingStartedQuickAccountItem(
                    id: "third-party-\(provider.id)-\(account.id)",
                    title: self.providerAccountTitle(for: account, provider: provider),
                    target: .compatibleProvider(
                        providerID: provider.id,
                        accountID: account.id,
                        modelID: provider.thirdPartyEffectiveModelID(forAccountID: account.id),
                        mode: activationMode
                    )
                )
            }
        }

        let openRouterItems = self.store.openRouterProvider.map { provider in
            provider.accounts.map { account in
                SettingsGettingStartedQuickAccountItem(
                    id: "openrouter-\(account.id)",
                    title: self.providerAccountTitle(for: account, provider: provider),
                    target: .openRouter(
                        accountID: account.id,
                        modelID: provider.openRouterEffectiveModelID(forAccountID: account.id),
                        mode: activationMode
                    )
                )
            }
        } ?? []

        return openAIItems + compatibleProviderItems + thirdPartyProviderItems + openRouterItems
    }

    private var quickSwitchActivationMode: CodexBarOpenAIAccountUsageMode {
        self.coordinator.draft.route.modelRoutingEnabled ? .hybridProvider : .switchAccount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.section) {
            SettingsPageHeader(
                title: SettingsPage.gettingStarted.title,
                detail: L.zh ? "选择当前使用的账号与模型，或添加新的连接。" : "Choose the account and model to use, or add a connection."
            )
            if self.coordinator.draft.route.style == .follow && self.quickAccountItems.isEmpty == false {
                SettingsGettingStartedQuickAccountSwitchSection(
                    coordinator: self.coordinator,
                    items: self.quickAccountItems
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
                onDeleteOpenRouterAccount: self.onDeleteOpenRouterAccount,
                onMoveProvider: self.onMoveProvider
            )
        }
    }

    private func openAIAccountTitle(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? account.accountId : email
    }

    private func providerAccountTitle(for account: CodexBarProviderAccount, provider: CodexBarProvider) -> String {
        let modelID = provider.kind == .openRouter
            ? provider.openRouterEffectiveModelID(forAccountID: account.id)
            : provider.thirdPartyEffectiveModelID(forAccountID: account.id)
        return ([provider.displayName, self.providerAccountTitle(for: account)] + [modelID].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func providerAccountTitle(for account: CodexBarProviderAccount) -> String {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? account.id : label
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
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(SettingsPalette.secondaryText)
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
                .font(SettingsTypography.rowTitle)
                .monospacedDigit()
                .foregroundColor(SettingsPalette.secondaryText)
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
        VStack(alignment: .leading, spacing: SettingsSpacing.row) {
            Text(L.gettingStartedOpenAISectionTitle)
                .font(SettingsTypography.sectionTitle)

            VStack(alignment: .leading, spacing: SettingsSpacing.row) {
                if self.store.accounts.isEmpty {
                    SettingsGettingStartedEmptyHeader(
                        title: L.gettingStartedOpenAIEmptyTitle,
                        detail: L.gettingStartedOpenAIEmptyDetail
                    )
                } else {
                    VStack(alignment: .leading, spacing: SettingsSpacing.row) {
                        ForEach(self.groupedAccounts) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.email)
                                    .font(SettingsTypography.pageHint)
                                    .foregroundColor(SettingsPalette.secondaryText)
                                ForEach(group.accounts) { account in
                                    AccountRowView(
                                        account: account,
                                        rowState: self.rowState(for: account),
                                        isRefreshing: self.refreshingAccounts.contains(account.id),
                                        usageDisplayMode: self.coordinator.draft.usageDisplayMode
                                    ) {
                                        self.coordinator.selectRouteTarget(self.openAIAccountRouteTarget(for: account))
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
                }

                SettingsGettingStartedActionRow(
                    iconName: "globe",
                    title: L.gettingStartedOpenAIAuthActionTitle,
                    detail: L.gettingStartedOpenAIAuthActionDetail,
                    buttonTitle: L.gettingStartedOpenAIAuthButton,
                    buttonIconName: "arrow.up.right.square",
                    action: self.onAuthenticateOpenAI
                )

                SettingsGettingStartedActionRow(
                    iconName: "curlybraces",
                    title: L.gettingStartedOpenAIImportActionTitle,
                    detail: L.gettingStartedOpenAIImportActionDetail,
                    buttonTitle: L.gettingStartedOpenAIImportButton,
                    buttonIconName: "square.and.arrow.down",
                    action: self.onImportOpenAI
                )
            }
        }
    }

    private func rowState(for account: TokenAccount) -> OpenAIAccountRowState {
        OpenAIAccountPresentation.rowState(
            for: account,
            summary: OpenAIRunningThreadAttribution.Summary.empty,
            accountUsageMode: self.coordinator.draft.route.modelRoutingEnabled ? .hybridProvider : .switchAccount,
            isOAuthProviderActive: self.store.config.activeProvider()?.kind == .openAIOAuth,
            allowsSwitch: self.store.accounts.count > 1
        )
    }

    private func openAIAccountRouteTarget(for account: TokenAccount) -> SettingsRouteTarget {
        .openAIAccount(
            accountID: account.accountId,
            mode: .switchAccount
        )
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
    let onMoveProvider: (String, String) -> Void

    private var providers: [CodexBarProvider] {
        let providers = self.store.customProviders + self.store.genericThirdPartyModelProviders + self.store.openCodeProviders
            + (self.store.openRouterProvider.map { [$0] } ?? [])
        let order = self.store.config.openAI.providerDisplayOrder
        return providers.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.row) {
            Text(L.gettingStartedProviderSectionTitle)
                .font(SettingsTypography.sectionTitle)

            if self.providers.isEmpty {
                SettingsGettingStartedEmptyHeader(
                    title: L.gettingStartedProviderEmptyTitle,
                    detail: L.gettingStartedProviderEmptyDetail
                )
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: MenuPanelSurface.spacing) {
                        ForEach(self.providers) { provider in
                            self.providerCard(provider, now: context.date)
                                .menuPanelProviderReorder(providerID: provider.id, onMove: self.onMoveProvider)
                        }
                    }
                }
            }

            SettingsGettingStartedActionRow(
                iconName: "lock",
                iconForegroundColor: .secondary,
                iconBackgroundColor: Color.secondary.opacity(0.08),
                title: L.gettingStartedPrivacyNote,
                titleColor: .secondary,
                detail: "",
                buttonTitle: L.addProviderTitle,
                buttonIconName: "plus",
                action: self.onAddProvider
            )
        }
    }

    private func providerCard(_ provider: CodexBarProvider, now: Date) -> some View {
        MenuPanelProviderCard(
            browsingOnly: self.coordinator.draft.route.style == .catalog,
            provider: provider,
            accounts: provider.accounts,
            activeTarget: MenuPanelTarget.resolve(config: self.store.config),
            embedded: false,
            usageDisplayMode: self.coordinator.draft.usageDisplayMode,
            now: now,
            onActivate: { account, modelID in
                let mode = self.coordinator.draft.route.mode
                if provider.kind == .openRouter {
                    self.coordinator.selectRouteTarget(.openRouter(accountID: account.id, modelID: modelID, mode: mode))
                } else {
                    self.coordinator.selectRouteTarget(.compatibleProvider(
                        providerID: provider.id, accountID: account.id, modelID: modelID, mode: mode
                    ))
                }
            },
            actions: MenuPanelProviderActions(
                addAccount: {
                    if provider.kind == .openRouter { self.onAddOpenRouterAccount(provider) }
                    else { self.onAddProviderAccount(provider) }
                },
                editProvider: { self.onEditProvider(provider) },
                deleteProvider: { self.onDeleteProvider(provider) },
                editAccount: { account in
                    if provider.kind == .openRouter { self.onEditOpenRouterAccount(provider, account) }
                    else { self.onEditProviderAccount(provider, account) }
                },
                deleteAccount: { account in
                    if provider.kind == .openRouter { self.onDeleteOpenRouterAccount(account) }
                    else { self.onDeleteProviderAccount(provider, account) }
                }
            )
        )
    }
}

private struct SettingsGettingStartedEmptyHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: SettingsSpacing.row) {
            VStack(alignment: .leading, spacing: 6) {
                Text(self.title)
                    .font(SettingsTypography.rowTitle)
                Text(self.detail)
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(SettingsPalette.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, SettingsSpacing.row)
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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(self.iconForegroundColor)
                .frame(width: SettingsSpacing.controlHeight, height: SettingsSpacing.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(self.iconBackgroundColor)
                )

            VStack(alignment: .leading, spacing: SettingsSpacing.text) {
                Text(self.title)
                    .font(SettingsTypography.rowTitle)
                    .foregroundColor(self.titleColor)
                if self.detail.isEmpty == false {
                    Text(self.detail)
                        .font(SettingsTypography.pageHint)
                        .foregroundColor(SettingsPalette.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button {
                self.action()
            } label: {
                Label(self.buttonTitle, systemImage: self.buttonIconName)
                    .font(SettingsTypography.rowTitle)
                    .frame(minHeight: SettingsSpacing.controlHeight)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SettingsHoverButtonStyle(isOutlined: true, verticalPadding: 0))
        }
        .padding(.vertical, SettingsSpacing.row)
    }
}

private struct SettingsUsagePage: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let onSaveProviderUsage: (CodexBarProvider, CodexBarProviderUsageConfiguration) -> Void
    let onDisableProviderUsage: (CodexBarProvider) -> Void

    private var usageProviders: [CodexBarProvider] {
        self.store.config.providers.filter { $0.kind == .openAICompatible || $0.kind == .openRouter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.section) {
            SettingsPageHeader(
                title: SettingsPage.usage.title,
                detail: L.zh ? "设置额度的显示方式与刷新频率。" : "Set how quotas appear and how often they refresh."
            )

            SettingsLabeledBlock(title: L.usageDisplayModeTitle) {
                SettingsUsageDisplayModeSection(
                    usageDisplayMode: Binding(
                        get: { self.coordinator.draft.usageDisplayMode },
                        set: { self.applyUsageDisplayMode($0) }
                    )
                )
            }

            SettingsLabeledBlock(title: "OpenAI") {
                HStack(spacing: SettingsSpacing.card) {
                    VStack(alignment: .leading, spacing: SettingsSpacing.text) {
                        Text(L.providerUsageIntervalLabel).font(SettingsTypography.rowTitle)
                        Text(L.zh ? "0 关闭后台查询，最短 5 秒。" : "0 disables background queries. Minimum: 5 seconds.")
                            .font(SettingsTypography.pageHint)
                            .foregroundStyle(SettingsPalette.secondaryText)
                    }
                    Spacer(minLength: 0)
                    SettingsOpenAIRefreshIntervalField(coordinator: self.coordinator, sink: self.store)
                }
                .settingsCardPadding()
                .settingsCardBackground()
            }

            SettingsProviderUsageSection(
                providers: self.usageProviders,
                usageDisplayMode: self.coordinator.draft.usageDisplayMode,
                onSaveProviderUsage: self.onSaveProviderUsage,
                onDisableProviderUsage: self.onDisableProviderUsage
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
            )
        }
    }
}

private struct SettingsOpenAIRefreshIntervalField: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let sink: SettingsSaveRequestApplying
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var appliedText: String { String(self.coordinator.draft.usagePollingIntervalSeconds) }

    var body: some View {
        TextField(L.providerUsageIntervalLabel, text: self.$text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            .focused(self.$isFocused)
            .onAppear { self.text = self.appliedText }
            .onChange(of: self.appliedText) { value in
                if !self.isFocused { self.text = value }
            }
            .onChange(of: self.isFocused) { focused in
                if !focused { self.commit() }
            }
            .onSubmit { self.commit() }
            .onDisappear { self.commit() }
    }

    private func commit() {
        guard self.text != self.appliedText else { return }
        guard let seconds = Int(self.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            self.coordinator.validationMessage = L.openAIRefreshIntervalInvalid
            self.text = self.appliedText
            return
        }
        self.coordinator.applyUsagePollingInterval(seconds, using: self.sink)
        self.text = self.appliedText
    }
}

private struct SettingsProviderUsageSection: View {
    let providers: [CodexBarProvider]
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onSaveProviderUsage: (CodexBarProvider, CodexBarProviderUsageConfiguration) -> Void
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
                    .foregroundColor(SettingsPalette.secondaryText)
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
    let onDisable: () -> Void

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

    private var showsUsage: Bool { self.configuration != nil || self.state != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.card) {
            self.header

            if self.isEditing {
                self.editor
            } else if self.showsUsage {
                self.configuredBody
            } else {
                self.emptyBody
            }
        }
        .settingsCardPadding()
        .settingsCardBackground()
    }

    private var header: some View {
        HStack(spacing: SettingsSpacing.row) {
            Text(self.provider.displayName)
                .font(SettingsTypography.sectionTitle)
                .lineLimit(1)

            Spacer(minLength: SettingsSpacing.row)

            if self.showsUsage {
                Menu {
                    Button(L.providerUsageEditAPI) { self.beginEditing() }
                    if self.configuration != nil {
                        Button(L.providerUsageDisableAPI, role: .destructive, action: self.onDisable)
                    }
                    Button(L.providerUsageViewRawResponse) { self.showsRawResponse.toggle() }
                } label: {
                    MenuPanelMoreLabel()
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .menuPanelIconControl()
                .help(L.providerUsageMore)
                .accessibilityLabel(L.providerUsageMore)
            }
        }
    }

    private var configuredBody: some View {
        let records = ProviderUsageFormat.records(for: self.provider)

        return VStack(alignment: .leading, spacing: SettingsSpacing.card) {
            if let error = self.state?.lastError {
                self.usageError(error)
            }

            if records.isEmpty {
                Text(L.providerUsageEmptyTitle)
                    .font(SettingsTypography.pageHint)
                    .foregroundStyle(SettingsPalette.secondaryText)
            } else {
                ForEach(records) { record in
                    self.usageRecord(record)
                }
            }

            if self.showsRawResponse {
                Text(self.state?.rawResponse?.isEmpty == false ? self.state?.rawResponse ?? "" : L.providerUsageNoData)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SettingsSpacing.row)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: SettingsSpacing.controlRadius))
            }
        }
    }

    private func usageRecord(_ record: ProviderUsageDisplayRecord) -> some View {
        let accounts = self.provider.accounts.filter { record.accountIDs.contains($0.id) }

        return VStack(alignment: .leading, spacing: SettingsSpacing.row) {
            if accounts.isEmpty {
                self.usageAccountLine(label: record.title, key: record.subtitle, data: record.data)
            } else {
                ForEach(accounts) { account in
                    self.usageAccountLine(label: account.label, key: account.maskedAPIKey, data: record.data)
                }
            }

            if let error = record.lastError, error != self.state?.lastError {
                self.usageError(error)
            }

            if record.data.isBalanceOnly {
                Text(ProviderUsageFormat.balanceTitle(for: record.data) ?? "—")
                    .font(SettingsTypography.pageHint)
                    .foregroundStyle(SettingsPalette.secondaryText)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    MenuPanelProviderQuota(data: record.data, mode: self.usageDisplayMode, now: context.date)
                }
            }
        }
    }

    private func usageAccountLine(label: String, key: String?, data: CodexBarProviderUsageData) -> some View {
        HStack(spacing: SettingsSpacing.row) {
            Text(label)
                .font(SettingsTypography.rowTitle)
                .truncationMode(.middle)
            if let key, !key.isEmpty {
                Text(key)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .truncationMode(.middle)
            }
            if let isValid = data.isValid {
                SettingsProviderUsageStatusPill(
                    title: isValid ? L.providerUsageValid : L.providerUsageInvalid,
                    color: isValid ? .green : .red
                )
                .fixedSize()
            }
            if let planName = data.planName {
                Text(planName)
                    .font(SettingsTypography.sectionHint)
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .padding(.horizontal, SettingsSpacing.row)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageError(_ message: String) -> some View {
        Text(message)
            .font(SettingsTypography.pageHint)
            .foregroundStyle(.red)
            .lineLimit(2)
    }

    private var emptyBody: some View {
        HStack(alignment: .center, spacing: SettingsSpacing.row) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: SettingsSpacing.controlHeight, height: SettingsSpacing.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: SettingsSpacing.text) {
                Text(L.providerUsageEmptyTitle)
                    .font(SettingsTypography.rowTitle)
                    .foregroundColor(.primary)
                Text(L.providerUsageSectionHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SettingsPalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 20)

            Button(action: self.beginEditing) {
                Text(L.providerUsageAddAPI)
                    .font(SettingsTypography.rowTitle)
                    .frame(minWidth: 112, minHeight: SettingsSpacing.controlHeight)
            }
            .buttonStyle(SettingsHoverButtonStyle(isOutlined: true, verticalPadding: 0))
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
                            intervalSeconds: self.draftInterval
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
        let configuration = self.provider.usageConfiguration ?? CodexBarProviderUsageConfiguration(
            intervalSeconds: self.provider.effectiveOpenCodePlan == .go ? UsagePollingInterval.defaultOpenCode : 0
        )
        self.draftURL = configuration.requestURL ?? self.defaultUsageURLString()
        self.draftHeaders = self.headersText(from: configuration.requestHeaders)
        self.draftTimeout = configuration.timeoutSeconds
        self.draftInterval = configuration.intervalSeconds
    }

    private func defaultUsageURLString() -> String {
        let baseURL = self.provider.baseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        switch self.provider.thirdPartyModelProvider {
        case .deepSeek:
            return baseURL.isEmpty ? "https://api.deepseek.com/user/balance" : baseURL + "/user/balance"
        case .mimo:
            return "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
        case .openCode:
            return self.provider.effectiveOpenCodePlan?.usageURL?.absoluteString ?? ""
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
                .foregroundColor(SettingsPalette.secondaryText)
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
                .font(SettingsTypography.sectionHint)
                .foregroundColor(SettingsPalette.secondaryText)
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
                .foregroundColor(SettingsPalette.secondaryText)
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
                .foregroundColor(SettingsPalette.secondaryText)
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
                .foregroundColor(SettingsPalette.secondaryText)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minHeight: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
        VStack(alignment: .leading, spacing: SettingsSpacing.section) {
            SettingsPageHeader(title: SettingsPage.backup.title, detail: L.backupPageHint)

            VStack(alignment: .leading, spacing: 12) {
                Text(L.backupCodexBarCardTitle)
                    .font(SettingsTypography.sectionTitle)
                    .foregroundColor(.primary)

                SettingsBackupCard(
                    iconName: "externaldrive.fill",
                    accentColor: .accentColor,
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
                    }
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L.backupCodexCardTitle)
                    .font(SettingsTypography.sectionTitle)
                    .foregroundColor(.primary)

                SettingsBackupCard(
                    iconName: "doc.badge.gearshape.fill",
                    accentColor: .accentColor,
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
    let bulletItems: [String]
    let lastBackup: CodexBarBackupSummary?
    let showsSuccessCheck: Bool
    let footer: String
    let onBackup: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: SettingsSpacing.card) {
                    Image(systemName: self.iconName)
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(self.accentColor)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.accentColor.opacity(0.10))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(self.accentColor.opacity(0.14), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: SettingsSpacing.text) {
                        ForEach(self.bulletItems, id: \.self) { item in
                            Text("•  \(item)")
                                .font(SettingsTypography.pageHint)
                                .foregroundColor(SettingsPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text(L.backupLastBackupLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SettingsPalette.secondaryText)
                    Text(self.lastBackupText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SettingsPalette.secondaryText)
                    if self.showsSuccessCheck {
                        Image(systemName: "checkmark.circle.fill")
                            .font(SettingsTypography.rowTitle)
                            .foregroundColor(self.accentColor)
                            .accessibilityLabel(L.backupSucceededAccessibilityLabel)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        SettingsBackupActionButton(
                            title: L.backupNowAction,
                            iconName: "square.and.arrow.up",
                            isPrimary: true,
                            action: self.onBackup
                        )
                        SettingsBackupActionButton(
                            title: L.backupRestoreAction,
                            iconName: "folder",
                            isPrimary: false,
                            action: self.onRestore
                        )
                    }
                    VStack(spacing: 12) {
                        SettingsBackupActionButton(
                            title: L.backupNowAction,
                            iconName: "square.and.arrow.up",
                            isPrimary: true,
                            action: self.onBackup
                        )
                        SettingsBackupActionButton(
                            title: L.backupRestoreAction,
                            iconName: "folder",
                            isPrimary: false,
                            action: self.onRestore
                        )
                    }
                }
            }
            .settingsCardPadding()

            SettingsDivider()

            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SettingsPalette.secondaryText)
                Text(self.footer)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .settingsCardPadding()
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
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.iconName)
                .font(SettingsTypography.rowTitle)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: SettingsSpacing.controlHeight)
        }
        .buttonStyle(SettingsHoverButtonStyle(isPrimary: self.isPrimary, isOutlined: !self.isPrimary, verticalPadding: 0))
    }
}

private struct SettingsBackupManagementCard: View {
    let backupsDirectoryURL: URL
    let onOpenDirectory: () -> Void

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
        .settingsCardPadding()
        .settingsCardBackground()
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.row) {
            Text(L.backupManagementTitle)
                .font(SettingsTypography.sectionTitle)
            Text(L.backupManagementHint)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var openButton: some View {
        Button(action: self.onOpenDirectory) {
            Label(L.backupManageFilesAction, systemImage: "folder")
                .font(SettingsTypography.rowTitle)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(SettingsHoverButtonStyle(isOutlined: true, minHeight: SettingsSpacing.controlHeight))
    }
}

private struct SettingsUpdatesPage: View {
    @ObservedObject var updateCoordinator: UpdateCoordinator

    private static let githubPageURL = URL(string: "https://github.com/shingex/codexbar")!

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
        VStack(alignment: .leading, spacing: SettingsSpacing.section) {
            SettingsPageHeader(title: SettingsPage.updates.title, detail: L.settingsUpdatesPageHint)

            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    SettingsUpdatesInfoRow(
                        title: L.settingsUpdatesCurrentVersionTitle,
                        value: self.currentVersion
                    )
                    SettingsDivider().padding(.leading, 16)
                    SettingsUpdatesInfoRow(
                        title: L.settingsUpdatesLatestVersionTitle,
                        value: self.latestVersion
                    )
                    SettingsDivider().padding(.leading, 16)
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
                        .font(SettingsTypography.rowTitle)
                        .frame(minWidth: 112, minHeight: 30)
                }
                .buttonStyle(SettingsHoverButtonStyle(isOutlined: true))
                .disabled(self.updateCoordinator.isChecking)

                Button {
                    NSWorkspace.shared.open(Self.githubPageURL)
                } label: {
                    Label(L.settingsUpdatesGitHubPageAction, systemImage: "arrow.up.right.square")
                        .font(SettingsTypography.rowTitle)
                        .frame(minWidth: 112, minHeight: 30)
                }
                .buttonStyle(SettingsHoverButtonStyle(isOutlined: true))

                if self.updateCoordinator.pendingAvailability != nil {
                    Button {
                        Task { await self.updateCoordinator.handleToolbarAction() }
                    } label: {
                        Label(L.settingsUpdatesInstallAction, systemImage: "square.and.arrow.down")
                            .font(SettingsTypography.rowTitle)
                            .frame(minWidth: 112, minHeight: 30)
                    }
                    .buttonStyle(SettingsHoverButtonStyle(isPrimary: true))
                    .disabled(self.updateCoordinator.isChecking)
                }
            }

            if self.updateCoordinator.isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.settingsUpdatesChecking)
                        .font(SettingsTypography.sectionHint)
                        .foregroundColor(SettingsPalette.secondaryText)
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
                .font(SettingsTypography.rowTitle)
                .foregroundColor(.primary)
                .frame(width: 160, alignment: .leading)
            Text(self.value)
                .font(SettingsTypography.pageHint)
                .foregroundColor(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

private struct SettingsLabeledBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.row) {
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
                Text(L.zh ? "自动查找 Codex，也可手动选择要启动的应用。" : "Find Codex automatically, or choose the application to launch.")
                    .font(SettingsTypography.pageHint)
                    .foregroundColor(SettingsPalette.secondaryText)
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

private struct SettingsAccountOrderSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.accountOrderTitle)
                .font(.system(size: 16, weight: .semibold))

            if self.coordinator.orderedAccounts.isEmpty {
                Text(L.noOpenAIAccountsForOrdering)
                    .font(.system(size: 11))
                    .foregroundColor(SettingsPalette.secondaryText)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(self.coordinator.orderedAccounts.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(SettingsTypography.rowTitle)
                                Text(item.detail)
                                    .font(SettingsTypography.sectionHint)
                                    .foregroundColor(SettingsPalette.secondaryText)
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
                .font(SettingsTypography.rowTitle)
                .frame(width: 110, alignment: .leading)

            Group {
                switch self.status {
                case .automatic:
                    Text(self.displayedValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SettingsPalette.secondaryText)
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
                }
            }
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
    }
}

private struct SettingsUsageDisplayModeSection: View {
    @Binding var usageDisplayMode: CodexBarUsageDisplayMode

    var body: some View {
        HStack(spacing: SettingsSpacing.row) {
            ForEach(CodexBarUsageDisplayMode.allCases) { mode in
                let selected = self.usageDisplayMode == mode
                Button {
                    if !selected { self.usageDisplayMode = mode }
                } label: {
                    Text(mode.title)
                        .font(SettingsTypography.rowTitle)
                        .frame(maxWidth: .infinity, minHeight: SettingsSpacing.controlHeight)
                        .background {
                            if selected { MenuPanelSegmentSurface(selected: true) }
                        }
                }
                .buttonStyle(SettingsHoverButtonStyle(horizontalPadding: 0, verticalPadding: 0))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(SettingsSpacing.row)
        .frame(maxWidth: .infinity)
        .settingsCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.usageDisplayModeTitle)
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
        case .hybridProvider:
            return L.accountUsageModeHybrid
        }
    }

    var detail: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchHint
        case .hybridProvider:
            return L.accountUsageModeHybridHint
        }
    }

    var gettingStartedTitle: String {
        switch self {
        case .switchAccount:
            return L.gettingStartedModeSwitchTitle
        case .hybridProvider:
            return L.gettingStartedModeHybridTitle
        }
    }

    var gettingStartedDetail: String {
        switch self {
        case .switchAccount:
            return L.gettingStartedModeSwitchDetail
        case .hybridProvider:
            return L.gettingStartedModeHybridDetail
        }
    }
}
