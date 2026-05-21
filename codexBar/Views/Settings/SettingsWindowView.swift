import Combine
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
                historicalModels: store.historicalModels
            )
        )
        self._recordsModel = StateObject(
            wrappedValue: SettingsRecordsModel(
                service: RecordsSnapshotService()
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                self.sidebar
            } detail: {
                self.detail
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let validationMessage = self.coordinator.validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()

                    Button(L.cancel) {
                        self.coordinator.cancelAndClose(onClose: self.onClose)
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(L.save) {
                        self.save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.coordinator.hasChanges == false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var detail: some View {
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
                        onDeleteOpenRouterAccount: self.confirmDeleteOpenRouterAccount
                    )
                    .settingsDetailPagePadding()
                }
            case .accounts:
                ScrollView {
                    SettingsAccountsPage(
                        coordinator: self.coordinator,
                        codexAppPathPanelService: self.codexAppPathPanelService
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
                    SettingsUsagePage(coordinator: self.coordinator)
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

    private func save() {
        do {
            let result = try self.coordinator.save(using: self.store)
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

    private func finishAfterLaunchPrompt() {
        self.pendingCodexLaunchPrompt = false
        if self.closeAfterLaunchPrompt {
            self.closeAfterLaunchPrompt = false
            self.onClose()
        }
    }

    private func launchCodexInstanceAfterPrompt() async {
        do {
            _ = try await self.codexDesktopLaunchProbeService.launchNewInstance()
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
            AddProviderSheet(store: store) { preset, label, baseURL, accountLabel, apiKey, openRouterSelection in
                do {
                    switch preset {
                    case .custom:
                        try store.addCustomProvider(label: label, baseURL: baseURL, accountLabel: accountLabel, apiKey: apiKey)
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
            size: CGSize(width: provider.kind == .openRouter ? 520 : 420, height: provider.kind == .openRouter ? 620 : 260)
        ) {
            AddProviderSheet(store: store, editingProvider: provider) { preset, label, baseURL, accountLabel, apiKey, openRouterSelection in
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

private extension View {
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

private struct SettingsAccountsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let codexAppPathPanelService: CodexAppPathPanelService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.accounts.title)
                .font(.system(size: 16, weight: .semibold))

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
                .font(.system(size: 16, weight: .semibold))

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
                    .foregroundColor(self.isSelected ? .accentColor : .secondary.opacity(0.45))
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
        switch self.mode {
        case .switchAccount:
            return .purple
        case .aggregateGateway:
            return .green
        case .hybridProvider:
            return .blue
        }
    }
}

private struct SettingsGettingStartedRequirementProgressCard: View {
    let progress: SettingsGettingStartedProgress

    private var isReady: Bool {
        self.progress.isComplete
    }

    private var accentColor: Color {
        self.isReady ? .green : .accentColor
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
                .font(.system(size: 16, weight: .semibold))

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
                                        usageDisplayMode: self.store.config.openAI.usageDisplayMode
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.gettingStartedProviderSectionTitle)
                .font(.system(size: 16, weight: .semibold))

            VStack(spacing: 0) {
                if self.store.customProviders.isEmpty && self.openRouterProvider == nil {
                    SettingsGettingStartedEmptyHeader(
                        title: L.gettingStartedProviderEmptyTitle,
                        detail: L.gettingStartedProviderEmptyDetail
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(self.store.customProviders) { provider in
                            CompatibleProviderRowView(
                                provider: provider,
                                isActiveProvider: self.isProviderSelected(provider),
                                activeAccountId: self.selectedAccountID(for: provider),
                                useActionTitle: self.providerUseActionTitle
                            ) { account in
                                guard let activationMode = self.activationMode else { return }
                                self.coordinator.selectRouteTarget(
                                    .compatibleProvider(
                                        providerID: provider.id,
                                        accountID: account.id,
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
        guard case .compatibleProvider(let providerID, _, let mode) = self.coordinator.selectedRouteTarget else {
            return false
        }
        return providerID == provider.id && mode == self.coordinator.draft.route.mode
    }

    private func selectedAccountID(for provider: CodexBarProvider) -> String? {
        guard case .compatibleProvider(let providerID, let accountID, let mode) = self.coordinator.selectedRouteTarget,
              providerID == provider.id,
              mode == self.coordinator.draft.route.mode else {
            return nil
        }
        return accountID
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

private struct SettingsUsagePage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.usage.title)
                .font(.system(size: 16, weight: .semibold))

            SettingsUsageDisplayModeSection(
                usageDisplayMode: Binding(
                    get: { self.coordinator.draft.usageDisplayMode },
                    set: { self.coordinator.update(\.usageDisplayMode, to: $0, field: .usageDisplayMode) }
                )
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
        }
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
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.updates.title)
                .font(.system(size: 16, weight: .semibold))

            Text(L.settingsUpdatesPageHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                SettingsUpdatesInfoRow(
                    title: L.settingsUpdatesCurrentVersionTitle,
                    value: self.currentVersion
                )
                SettingsUpdatesInfoRow(
                    title: L.settingsUpdatesLatestVersionTitle,
                    value: self.latestVersion
                )
                SettingsUpdatesInfoRow(
                    title: L.settingsUpdatesStatusTitle,
                    value: self.statusText
                )
            }

            HStack(spacing: 10) {
                Button(L.settingsUpdatesCheckAction) {
                    Task { await self.updateCoordinator.checkForUpdates(trigger: .manual) }
                }
                .disabled(self.updateCoordinator.isChecking)

                if self.updateCoordinator.pendingAvailability != nil {
                    Button(L.settingsUpdatesInstallAction) {
                        Task { await self.updateCoordinator.handleToolbarAction() }
                    }
                    .disabled(self.updateCoordinator.isChecking)
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
                .font(.system(size: 11, weight: .medium))
                .frame(width: 160, alignment: .leading)
            Text(self.value)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct SettingsAccountUsageModeSection: View {
    @Binding var mode: CodexBarOpenAIAccountUsageMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountUsageModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountUsageModeHint)
                .font(.system(size: 10))
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

private struct SettingsCodexAppPathSettingsSection: View {
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.codexAppPathSectionTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.codexAppPathHint)
                .font(.system(size: 10))
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

private struct SettingsAccountOrderingModeSection: View {
    @Binding var mode: CodexBarOpenAIAccountOrderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountOrderingModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountOrderingModeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
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

private struct SettingsSelectableOptionButton: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: self.isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(self.isSelected ? .accentColor : .secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(self.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                    Text(self.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(self.isHovering ? 0.12 : 0.08)
        }
        return Color.secondary.opacity(self.isHovering ? 0.12 : 0.06)
    }
}

private struct SettingsAccountOrderSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountOrderTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountOrderHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                                    .font(.system(size: 11, weight: .medium))
                                Text(item.detail)
                                    .font(.system(size: 10))
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.06))
                        )
                    }
                }
            }
        }
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
                .font(.system(size: 11, weight: .medium))
                .frame(width: 72, alignment: .leading)

            Group {
                switch self.status {
                case .automatic:
                    Text(self.displayedValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                case .manualValid, .manualInvalid:
                    Text(self.displayedValue)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
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
                .font(.system(size: 12, weight: .medium))

            Text(L.quotaSortSettingsHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortPlusWeightTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(L.quotaSortPlusWeightValue(self.plusRelativeWeight))
                        .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(
                        L.quotaSortProRatioValue(
                            self.proRelativeToPlusMultiplier,
                            absoluteProWeight: self.proAbsoluteWeight
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(
                        L.quotaSortTeamRatioValue(
                            self.teamRelativeToPlusMultiplier,
                            absoluteTeamWeight: self.teamAbsoluteWeight
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 12, weight: .medium))

            Text(L.modelPricingSectionHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.coordinator.historicalModels.isEmpty {
                Text(L.modelPricingSectionEmpty)
                    .font(.system(size: 11))
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
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 10, weight: .medium))
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
        case .records:
            return L.settingsRecordsPageTitle
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
        case .records:
            return "clock.arrow.circlepath"
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
