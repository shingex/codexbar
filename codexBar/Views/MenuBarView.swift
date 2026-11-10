import AppKit
import Combine
import SwiftUI

enum MenuBarErrorSource: Equatable {
    case generic
    case refresh
}

struct MenuBarErrorBannerState: Equatable {
    let message: String
    let source: MenuBarErrorSource
}

private struct CodexLaunchPrompt: Identifiable, Equatable {
    let id = UUID()
}

private struct DeleteConfirmationRequest: Identifiable {
    enum Target {
        case openAIAccount(TokenAccount)
        case customProviderAccount(providerID: String, providerLabel: String, accountID: String, accountLabel: String)
        case customProvider(providerID: String, providerLabel: String)
        case openRouterAccount(accountID: String, accountLabel: String)
        case openRouterProvider(providerID: String)
    }

    let id = UUID()
    let target: Target

    var title: String {
        switch self.target {
        case .openAIAccount:
            return L.deleteOpenAIAccountConfirmTitle
        case .customProviderAccount, .openRouterAccount:
            return L.deleteProviderAccountConfirmTitle
        case .customProvider, .openRouterProvider:
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
        case .openRouterProvider:
            return L.deleteProviderConfirmMessage("OpenRouter")
        }
    }
}

enum MenuBarRefreshErrorResolver {
    static func nextBanner(
        current: MenuBarErrorBannerState?,
        announceResult: Bool,
        refreshMessage: String?
    ) -> MenuBarErrorBannerState? {
        if let refreshMessage {
            guard announceResult else { return current }
            return MenuBarErrorBannerState(message: refreshMessage, source: .refresh)
        }

        guard current?.source == .refresh else { return current }
        return nil
    }
}

enum MenuBarRefreshPresentation {
    static func shouldAnimateIcon(isOpenAIRefreshInProgress: Bool, isLocalCostRefreshInProgress: Bool) -> Bool {
        isOpenAIRefreshInProgress || isLocalCostRefreshInProgress
    }

    static func shouldShowFooterLoading(
        isOpenAIRefreshInProgress: Bool,
        initiatedByUser: Bool
    ) -> Bool {
        isOpenAIRefreshInProgress && initiatedByUser
    }
}

struct MenuBarOpenRefreshGate: Equatable {
    private(set) var lastTriggeredAt: Date?
    var cooldown: TimeInterval = 60

    mutating func shouldTriggerRefresh(isRefreshing: Bool, now: Date = Date()) -> Bool {
        if let lastTriggeredAt,
           now.timeIntervalSince(lastTriggeredAt) < self.cooldown {
            return false
        }
        self.lastTriggeredAt = now
        return isRefreshing == false
    }

    mutating func resetForClose() {
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @EnvironmentObject var updateCoordinator: UpdateCoordinator

    private let usageRefreshInterval = OpenAIUsagePollingService.defaultRefreshInterval
    private let runningThreadAttributionService = OpenAIRunningThreadAttributionService()
    private let oauthAccountService = CodexBarOAuthAccountService()
    private let openAIAccountCSVService = OpenAIAccountCSVService()
    private let openAIAccountCSVPanelService = OpenAIAccountCSVPanelService()
    private let codexAppPathPanelService = CodexAppPathPanelService.shared
    private let codexDesktopLaunchProbeService = CodexDesktopLaunchProbeService()
    let menuHorizontalInset = MenuPanelLayout.horizontalInset
    let blockContentHorizontalInset = MenuPanelLayout.blockContentHorizontalInset
    let blockVerticalInset = MenuPanelLayout.blockVerticalInset
    let sectionActionButtonSize = MenuPanelLayout.sectionActionButtonSize
    let sectionCountSlotWidth = MenuPanelLayout.sectionCountSlotWidth
    let panelSectionSpacing: CGFloat = 16
    let panelRowSpacing: CGFloat = 6

    var measuresNaturalHeight = false
    var versionDisplay = AppVersionDisplay.versionAndBuild
    @State var isPanelSwitching = false
    @State private var isRefreshing = false
    @State private var errorBanner: MenuBarErrorBannerState?
    @State var now = Date()
    @State var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State var refreshingAccounts: Set<String> = []
    @State var refreshingAllUsageAccountIDs: Set<String> = []
    @State var languageToggle = false
    @State private var openRefreshGate = MenuBarOpenRefreshGate()
    @State fileprivate var pendingCodexLaunchPrompt: CodexLaunchPrompt?
    @State private var statusItemAvailableContentHeight: CGFloat?
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?
    @State private var runningThreadRefreshController = CoalescedBackgroundRefreshController()
    @State fileprivate var pendingDeleteConfirmation: DeleteConfirmationRequest?

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
    private let runningThreadTimer = Timer.publish(
        every: OpenAIRunningThreadAttributionService.defaultRecentActivityWindow,
        on: .main,
        in: .common
    )
    var groupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.groupedAccounts(
            from: store.accounts,
            summary: self.runningThreadSummary,
            quotaSortSettings: self.store.config.openAI.quotaSort,
            preferredAccountOrder: self.store.config.openAI.preferredDisplayAccountOrder,
            highlightActiveAccount: self.store.config.openAI.accountUsageMode == .switchAccount
        )
    }

    var currentModeContextLabel: String? {
        if self.store.config.openAI.modelRoutingEnabled { return L.zh ? "CodexBar 目标" : "CodexBar target" }
        return L.zh ? "OpenAI 账号" : "OpenAI accounts"
    }

    var modeAccentColor: Color {
        Color(nsColor: self.store.config.openAI.accountUsageMode.themeAccentColor)
    }

    var runningThreadSummary: OpenAIRunningThreadAttribution.Summary {
        self.runningThreadAttribution.summary
    }

    func isAccountUsageRefreshing(_ account: TokenAccount) -> Bool {
        self.refreshingAccounts.contains(account.id) ||
            self.refreshingAllUsageAccountIDs.contains(account.id)
    }

    private var lockedMenuContentHeight: CGFloat {
        self.statusItemAvailableContentHeight ?? MenuBarPopoverSizing.defaultHeight
    }

    // Bound only the resource body; the popover itself keeps its locked height.
    var activeResourceContentHeightLimit: CGFloat {
        max(84, self.lockedMenuContentHeight * 0.4)
    }

    private var switchTargetAccount: TokenAccount? {
        if let selectedAccountID = self.store.config.openAI.switchModeSelection?.accountId,
           let account = self.store.oauthAccount(accountID: selectedAccountID) {
            return account
        }
        return self.store.activeAccount()
    }

    var availableCount: Int {
        store.accounts.filter { $0.usageStatus == .ok }.count
    }

    var openAIAvailabilityBadgeTitle: String? {
        OpenAIAccountPresentation.headerAvailabilityBadgeTitle(
            availableCount: self.availableCount,
            totalCount: self.store.accounts.count
        )
    }

    var visibleOpenRouterProvider: CodexBarProvider? {
        guard let provider = store.openRouterProvider,
              provider.accounts.isEmpty == false else {
            return nil
        }
        return provider
    }

    var visibleCompatibleProviderCount: Int {
        self.store.customProviders.count + self.store.thirdPartyModelProviders.count
    }

    private var isCompletelyEmpty: Bool {
        store.accounts.isEmpty &&
        store.customProviders.isEmpty &&
        store.thirdPartyModelProviders.isEmpty &&
        self.visibleOpenRouterProvider == nil
    }

    var body: some View {
        mainMenuContent
        .background {
            if !self.measuresNaturalHeight {
                AdaptiveMenuHeightReportingContainer(onMeasuredHeightChange: { height in
                    NotificationCenter.default.post(
                        name: .codexbarStatusItemMeasuredHeightDidChange,
                        object: nil,
                        userInfo: ["height": height]
                    )
                }) {
                    self.naturalMenuContent
                        .environmentObject(self.store)
                        .environmentObject(self.oauth)
                        .environmentObject(self.updateCoordinator)
                }
            }
        }
        .frame(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: self.measuresNaturalHeight ? nil : self.lockedMenuContentHeight,
            alignment: .topLeading
        )
        .onReceive(countdownTimer) { _ in
            now = Date()
        }
        .onReceive(runningThreadTimer) { _ in
            refreshRunningThreadAttribution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidSucceed)) { _ in
            self.clearError()
            refreshRunningThreadAttribution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidFail)) { notification in
            self.setGenericError(
                notification.userInfo?["message"] as? String ?? "OpenAI login failed."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemMenuWillOpen)) { _ in
            self.handleMenuPresentationOpened()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemMenuDidClose)) { _ in
            self.handleMenuPresentationClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarStatusItemAvailableContentHeightDidChange)) { notification in
            self.statusItemAvailableContentHeight = notification.userInfo?["height"] as? CGFloat
        }
        .onChange(of: self.errorBanner) { _ in
            self.requestStatusItemLayoutRefresh()
        }
        .onChange(of: self.pendingCodexLaunchPrompt) { _ in
            self.requestStatusItemLayoutRefresh()
        }
        .alert(
            L.launchCodexPromptTitle,
            isPresented: Binding(
                get: { self.pendingCodexLaunchPrompt != nil },
                set: { isPresented in
                    if isPresented == false {
                        self.pendingCodexLaunchPrompt = nil
                    }
                }
            )
        ) {
            Button(L.launchCodexPromptConfirm) {
                self.pendingCodexLaunchPrompt = nil
                Task {
                    await self.launchCodexInstanceAfterPrompt()
                }
            }

            Button(L.launchCodexPromptCancel, role: .cancel) {
                self.pendingCodexLaunchPrompt = nil
            }
        } message: {
            Text(L.launchCodexPromptMessage)
        }
        .alert(item: $pendingDeleteConfirmation) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text(L.deleteConfirm)) {
                    self.performConfirmedDelete(request)
                },
                secondaryButton: .cancel(Text(L.cancel))
            )
        }
        .tint(self.modeAccentColor)
        .accentColor(self.modeAccentColor)
        .onAppear {
            self.consumeCodexReloadPrompt()
            if let error = self.store.routingError { self.setGenericError(error) }
        }
    }

    private var mainMenuContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.fixedMenuContent

            if self.measuresNaturalHeight {
                self.menuModeContentView.fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { geometry in
                    AdaptiveMenuScrollContainer(maxHeight: geometry.size.height, fillsHeightLimit: true) {
                        self.menuModeContentView
                    }
                    .frame(height: geometry.size.height, alignment: .top)
                }
            }
        }
        .padding(16)

    }

    private var fixedMenuContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.menuHeader
            self.activePanelCard
            if self.hasPanelNotices { self.panelNotices }
            self.codexIntegrationControl
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var naturalMenuContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.fixedMenuContent
            self.menuModeContentView.fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: MenuBarStatusItemIdentity.popoverContentWidth)
    }

    private var isHeaderRefreshing: Bool {
        MenuBarRefreshPresentation.shouldAnimateIcon(
            isOpenAIRefreshInProgress: self.isRefreshing,
            isLocalCostRefreshInProgress: self.store.isRefreshingLocalCostSummaryInBackground
        )
    }

    private var menuHeader: some View {
        HStack(spacing: 12) {
            Text(self.versionDisplay)
                .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            Spacer(minLength: 4)
            Button { Task { await refresh(announceResult: true) } } label: {
                MenuPanelRefreshIcon(isRefreshing: isHeaderRefreshing, tint: modeAccentColor)
            }
            .buttonStyle(.plain).menuPanelIconControl().disabled(isHeaderRefreshing)
            .accessibilityLabel(L.refreshUsage).help("\(L.refreshUsage) · \(refreshStatusTitle)")

            Menu {
                MenuPanelAction(title: L.gettingStartedOpenAIAuthButton, icon: .addSquare) { startOAuthLogin() }
                MenuPanelAction(title: L.gettingStartedOpenAIImportButton, icon: .downloadCircle) { importOpenAIAccountsCSV() }
                Divider()
                MenuPanelAction(title: L.addProviderTitle, icon: .addSquare) { openAddProviderWindow() }
                MenuPanelAction(title: L.addOpenCodeTitle, icon: .addSquare) { openAddProviderWindow(defaultPreset: .openCode) }
                if let provider = visibleOpenRouterProvider {
                    MenuPanelAction(title: L.addOpenRouterKeyTitle, icon: .addSquare) { openAddOpenRouterAccountWindow(provider: provider) }
                } else {
                    MenuPanelAction(title: L.addOpenRouterKeyTitle, icon: .addSquare) { openAddProviderWindow(defaultPreset: .openRouter) }
                }
            } label: { Hugeicons.addSquare.originalImage(size: 20, color: NSColor(modeAccentColor))
                    .frame(width: 24, height: 24) }
            .tint(modeAccentColor).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().menuPanelIconControl()
            .help(L.addProviderTitle)
            .accessibilityLabel(L.addProviderTitle)

            Button { openSettingsWindow() } label: { Hugeicons.settings.image(size: 20).frame(width: 24, height: 24) }
                .buttonStyle(.plain).menuPanelIconControl()
                .help(L.settings).accessibilityLabel(L.settings)
            Menu {
                MenuPanelAction(title: L.zh ? "切换为英文" : "Switch to Chinese", icon: .languages) {
                    L.languageOverride = !L.zh
                    languageToggle.toggle()
                }
                Divider()
                MenuPanelAction(title: L.restart, icon: .refresh04) { restartAppFromCurrentBundle() }
                MenuPanelAction(title: L.quit, icon: .power) { quitApp() }
            } label: { MenuPanelMoreLabel(tint: modeAccentColor) }
            .tint(modeAccentColor).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().menuPanelIconControl()
            .help(L.zh ? "更多" : "More").accessibilityLabel(L.zh ? "更多" : "More")
        }
        .foregroundColor(modeAccentColor)
        .frame(height: 24)
    }

    private var hasPanelNotices: Bool {
        self.updateCoordinator.pendingAvailability != nil || self.errorBanner != nil
    }

    private var hasModeNotices: Bool {
        self.visibleCompatibleProviderCount == 0 && self.visibleOpenRouterProvider == nil
    }

    private var panelNotices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let availability = updateCoordinator.pendingAvailability {
                self.updateAvailableBanner(availability: availability)
            }
            if let error = self.errorBanner?.message {
                HStack(alignment: .top) {
                    Hugeicons.warning.image(size: 13).foregroundColor(.orange)
                    Text(error).font(.caption).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { self.clearError() } label: { Hugeicons.cancel.image(size: 12).frame(width: 20, height: 20) }
                        .buttonStyle(.plain).menuPanelHoverChrome(cornerRadius: 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("codexbar.panel-notices")
    }

    @ViewBuilder
    private var modeNotices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.visibleCompatibleProviderCount == 0 && self.visibleOpenRouterProvider == nil {
                Text(L.openAIHybridNoTargets).font(.caption).foregroundColor(.secondary)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuModeContentView: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIModeTabsSection
            if self.hasModeNotices { self.modeNotices }
        }
        .disabled(self.isPanelSwitching)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func performPanelSwitch(_ action: @escaping @MainActor () async -> Void) {
        guard !self.isPanelSwitching else { return }
        self.isPanelSwitching = true
        Task { @MainActor in
            defer { self.isPanelSwitching = false }
            await action()
        }
    }

    private var refreshStatusTitle: String {
        if isRefreshing { return L.refreshUsage }
        if let lastUpdate = store.localCostSummary.updatedAt {
            return relativeTime(lastUpdate)
        }
        return L.refreshUsage
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        return L.hoursAgo(seconds / 3600)
    }

    private func requestStatusItemLayoutRefresh() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .codexbarRequestStatusItemLayoutRefresh,
                object: nil
            )
        }
    }

    func activateAccount(_ account: TokenAccount) async {
        do {
            let result = try await OpenAIManualActivationExecutor.execute(
                targetAccountID: account.accountId,
                targetMode: .switchAccount
            ) {
                try self.store.activate(
                    account,
                    reason: .manual,
                    automatic: false,
                    forced: false,
                    protectedByManualGrace: false
                )
            }

            self.presentCodexLaunchPromptIfNeeded(for: result)
            self.refreshRunningThreadAttribution()
            self.clearError()
            Task { @MainActor in
                OpenAIUsagePollingService.shared.refreshNow()
            }
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func activateCompatibleProvider(
        providerID: String,
        accountID: String,
        modelID: String? = nil,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) async {
        do {
            try self.store.setCodexIntegrationEnabled(true, selection: .init(providerId: providerID, accountId: accountID))
            if let modelID { try self.store.updateThirdPartySelectedModel(modelID, providerID: providerID, accountID: accountID) }
            self.consumeCodexReloadPrompt()
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func activateOpenRouterProvider(
        accountID: String,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) async {
        do {
            guard let provider = self.store.openRouterProvider else { throw TokenStoreError.providerNotFound }
            try self.store.setCodexIntegrationEnabled(true, selection: .init(providerId: provider.id, accountId: accountID))
            self.consumeCodexReloadPrompt()
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func useCurrentOAuthFromHybrid(_ account: TokenAccount) async {
        if self.store.config.openAI.accountUsageMode != .hybridProvider ||
            self.store.config.activeProvider()?.kind != .openAIOAuth ||
            self.store.activeAccount()?.accountId != account.accountId {
            await self.activateOAuthAccountFromHybrid(account)
        }
    }

    private func activateOAuthAccountFromHybrid(_ account: TokenAccount) async {
        do {
            try self.store.activateOpenAIAccount(
                account,
                accountUsageMode: .hybridProvider,
                reason: .manual,
                automatic: false,
                forced: false,
                protectedByManualGrace: false
            )

            self.presentCodexLaunchPrompt()
            self.refreshRunningThreadAttribution()
            self.clearError()
            Task { @MainActor in
                OpenAIUsagePollingService.shared.refreshNow()
            }
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func selectOpenRouterModel(
        _ modelID: String,
        accountID: String,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) async {
        do {
            try self.store.updateOpenRouterSelectedModel(modelID, accountID: accountID)
            if let provider = self.store.openRouterProvider,
               self.store.activeProvider?.id != provider.id ||
                self.store.config.active.accountId != accountID ||
                self.store.config.openAI.accountUsageMode != accountUsageMode {
                await self.activateOpenRouterProvider(
                    accountID: accountID,
                    accountUsageMode: accountUsageMode
                )
                return
            }
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func selectThirdPartyModel(
        _ modelID: String,
        providerID: String,
        accountID: String,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) async {
        do {
            try self.store.updateThirdPartySelectedModel(modelID, providerID: providerID, accountID: accountID)
            if self.store.activeProvider?.id != providerID ||
                self.store.config.active.accountId != accountID ||
                self.store.config.openAI.accountUsageMode != accountUsageMode {
                await self.activateCompatibleProvider(
                    providerID: providerID,
                    accountID: accountID,
                    modelID: modelID,
                    accountUsageMode: accountUsageMode
                )
                return
            }
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func presentCodexLaunchPromptIfNeeded(for result: OpenAIManualSwitchResult) {
        guard result.launchedNewInstance == false else { return }
        self.presentCodexLaunchPrompt()
    }

    func setCodexIntegrationFromPanel(_ enabled: Bool) {
        do {
            try self.store.setCodexIntegrationEnabled(enabled)
            self.consumeCodexReloadPrompt()
            self.clearError()
        } catch { self.setGenericError(error.localizedDescription) }
    }

    func consumeCodexReloadPrompt() {
        guard self.store.codexReloadRequired else { return }
        self.store.codexReloadRequired = false
        self.pendingCodexLaunchPrompt = CodexLaunchPrompt()
    }

    private func presentCodexLaunchPrompt() {
        guard !self.store.config.openAI.modelRoutingEnabled else { return }
        self.pendingCodexLaunchPrompt = CodexLaunchPrompt()
    }

    private func launchCodexInstanceAfterPrompt() async {
        do {
            _ = try await self.codexDesktopLaunchProbeService.restartCodex()
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func activeProviderSummaryTitle(
        activeProvider: CodexBarProvider,
        activeAccount: CodexBarProviderAccount
    ) -> String {
        return "\(activeProvider.label) · \(activeAccount.label)"
    }

    private func oauthLoginSummaryTitle() -> String? {
        guard let provider = self.store.config.oauthProvider(),
              let account = provider.activeAccount else {
            return nil
        }
        return "\(account.label)"
    }

    func confirmDeleteOpenAIAccount(_ account: TokenAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(target: .openAIAccount(account))
    }

    func confirmDeleteCompatibleAccount(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .customProviderAccount(
                providerID: provider.id,
                providerLabel: provider.displayName,
                accountID: account.id,
                accountLabel: account.label
            )
        )
    }

    func confirmDeleteProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .customProvider(providerID: provider.id, providerLabel: provider.displayName)
        )
    }

    func confirmDeleteOpenRouterAccount(_ account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .openRouterAccount(accountID: account.id, accountLabel: account.label)
        )
    }

    func confirmDeleteOpenRouterProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .openRouterProvider(providerID: provider.id)
        )
    }

    fileprivate func performConfirmedDelete(_ request: DeleteConfirmationRequest) {
        switch request.target {
        case .openAIAccount(let account):
            do {
                try store.remove(account)
                self.clearError()
            } catch {
                self.setGenericError(error.localizedDescription)
            }
        case .customProviderAccount(let providerID, _, let accountID, _):
            self.deleteCompatibleAccount(providerID: providerID, accountID: accountID)
        case .customProvider(let providerID, _):
            self.deleteProvider(providerID: providerID)
        case .openRouterAccount(let accountID, _):
            self.deleteOpenRouterAccount(accountID: accountID)
        case .openRouterProvider(let providerID):
            self.deleteProvider(providerID: providerID)
        }
    }

    private func deleteCompatibleAccount(providerID: String, accountID: String) {
        do {
            try store.removeCustomProviderAccount(providerID: providerID, accountID: accountID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func deleteProvider(providerID: String) {
        do {
            if providerID == self.store.openRouterProvider?.id {
                let accountIDs = self.store.openRouterProvider?.accounts.map(\.id) ?? []
                for accountID in accountIDs {
                    try store.removeOpenRouterProviderAccount(accountID: accountID)
                }
            } else {
                try store.removeCustomProvider(providerID: providerID)
            }
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func deleteOpenRouterAccount(accountID: String) {
        do {
            try store.removeOpenRouterProviderAccount(accountID: accountID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func startOAuthLogin() {
        self.requestCloseStatusItemMenu()
        OpenAILoginCoordinator.shared.start()
    }

    func exportOpenAIAccountsCSV() {
        do {
            let snapshot = try self.oauthAccountService.exportAccountsForInterchange()
            guard snapshot.accounts.isEmpty == false else {
                self.setGenericError(L.noOpenAIAccountsToExport)
                return
            }

            self.presentSystemFilePanelAfterClosingMenu {
                do {
                    guard let exportURL = self.openAIAccountCSVPanelService.requestExportURL() else {
                        return
                    }

                    let exportText = try self.openAIAccountCSVService.makeCSV(
                        from: snapshot.accounts,
                        metadataByAccountID: snapshot.metadataByAccountID,
                        proxiesJSON: snapshot.proxiesJSON
                    )
                    try exportText.write(to: exportURL, atomically: true, encoding: .utf8)
                    self.clearError()
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            }
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func exportOpenAIAccountCSV(_ account: TokenAccount) {
        do {
            let snapshot = try self.oauthAccountService.exportAccountsForInterchange()
            guard let exportText = try self.openAIAccountCSVService.makeCSV(
                forAccountID: account.accountId,
                from: snapshot
            ) else {
                self.setGenericError(L.noOpenAIAccountsToExport)
                return
            }

            self.presentSystemFilePanelAfterClosingMenu {
                do {
                    guard let exportURL = self.openAIAccountCSVPanelService.requestExportURL() else {
                        return
                    }

                    try exportText.write(to: exportURL, atomically: true, encoding: .utf8)
                    self.clearError()
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            }
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func importOpenAIAccountsCSV() {
        self.presentSystemFilePanelAfterClosingMenu {
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

                self.store.load()
                self.refreshRunningThreadAttribution()
                self.clearError()
                self.refreshImportedAccounts(accountIDs: result.importedAccountIDs)
            } catch {
                self.setGenericError(error.localizedDescription)
            }
        }
    }

    private func openSettingsWindow() {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.showOpenAISettings(
            store: self.store,
            codexAppPathPanelService: self.codexAppPathPanelService,
            selectedPage: .gettingStarted
        )
    }

    private func quitApp() {
        AppLifecycleDiagnostics.shared.markTermination(reason: "quit_button")
        NSApplication.shared.terminate(nil)
    }

    private func restartAppFromCurrentBundle() {
        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.5; /usr/bin/open -n \"$1\"",
            "codexbar-restart",
            bundlePath,
        ]

        do {
            try process.run()
            AppLifecycleDiagnostics.shared.markTermination(reason: "restart_button")
            NSApplication.shared.terminate(nil)
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func openAddProviderWindow(defaultPreset: AddProviderPreset = .custom) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider",
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
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider")
            }
        }
    }

    func openEditProviderWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "edit-provider-\(provider.id)",
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
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "edit-provider-\(provider.id)")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "edit-provider-\(provider.id)")
            }
        }
    }

    func openAddProviderAccountWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider-account-\(provider.id)",
            title: L.addProviderAccountTitle,
            size: CGSize(width: 480, height: 420)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey, models in
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey, selectedModelID: models.selectedModelID, pinnedModelIDs: models.pinnedModelIDs)
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
            }
        }
    }

    func openEditProviderAccountWindow(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        self.requestCloseStatusItemMenu()
        if provider.isThirdPartyModelProvider {
            DetachedWindowPresenter.shared.show(
                id: "edit-provider-account-\(account.id)",
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
                        self.clearError()
                        DetachedWindowPresenter.shared.close(id: "edit-provider-account-\(account.id)")
                    } catch {
                        self.setGenericError(error.localizedDescription)
                    }
                } onCancel: {
                    DetachedWindowPresenter.shared.close(id: "edit-provider-account-\(account.id)")
                }
            }
            return
        }
        DetachedWindowPresenter.shared.show(
            id: "edit-provider-account-\(account.id)",
            title: "\(L.editProviderAccountTitle) · \(account.label)",
            size: CGSize(width: 480, height: 420)
        ) {
            AddProviderAccountSheet(provider: provider, account: account) { label, apiKey, models in
                do {
                    try store.updateCustomProviderAccount(
                        providerID: provider.id,
                        accountID: account.id,
                        label: label,
                        apiKey: apiKey,
                        selectedModelID: models.selectedModelID, pinnedModelIDs: models.pinnedModelIDs
                    )
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "edit-provider-account-\(account.id)")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "edit-provider-account-\(account.id)")
            }
        }
    }

    func openAddOpenRouterAccountWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-openrouter-key",
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
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-openrouter-key")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-openrouter-key")
            }
        }
    }

    func openEditOpenRouterWindow(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "edit-openrouter-key-\(account.id)",
            title: "\(L.editOpenRouterKeyTitle) · \(account.label)",
            size: CGSize(width: 500, height: 520)
        ) {
            OpenRouterKeyEditorSheet(
                provider: provider,
                store: store,
                account: account
            ) { accountLabel, selection in
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
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "edit-openrouter-key-\(account.id)")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "edit-openrouter-key-\(account.id)")
            }
        }
    }

    private func handleMenuPresentationOpened() {
        countdownTimerConnection?.cancel()
        countdownTimerConnection = countdownTimer.connect()
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = runningThreadTimer.connect()
        refreshRunningThreadAttribution()
        triggerRefreshOnOpenIfNeeded()
    }

    private func handleMenuPresentationClosed() {
        runningThreadRefreshController.reset()
        countdownTimerConnection?.cancel()
        countdownTimerConnection = nil
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = nil
        openRefreshGate.resetForClose()
    }

    private func triggerRefreshOnOpenIfNeeded() {
        guard openRefreshGate.shouldTriggerRefresh(isRefreshing: isRefreshing, now: now) else { return }
        Task {
            await refresh(
                force: true,
                announceResult: false,
                includeLocalCost: false,
                showFooterLoading: false
            )
        }
    }

    private func refresh(
        force: Bool = true,
        announceResult: Bool = false,
        includeLocalCost: Bool = true,
        showFooterLoading: Bool = true
    ) async {
        let shouldRefreshOAuth = force || store.hasStaleOAuthUsageSnapshot(maxAge: usageRefreshInterval)
        let shouldRefreshLocalCost = includeLocalCost && self.store.config.openAI.disableLocalUsageStats == false

        guard shouldRefreshOAuth || shouldRefreshLocalCost else {
            return
        }

        if shouldRefreshLocalCost {
            now = Date()
            store.refreshLocalCostSummary(
                force: true,
                minimumInterval: 0,
                refreshSessionCache: true
            )
            refreshRunningThreadAttribution()
        }

        if shouldRefreshOAuth == false {
            return
        }

        guard store.beginAllUsageRefresh() else { return }
        let showsFooterLoading = MenuBarRefreshPresentation.shouldShowFooterLoading(
            isOpenAIRefreshInProgress: true,
            initiatedByUser: showFooterLoading
        )
        let refreshingAccountIDs = Set(store.accounts.map(\.id))
        refreshingAllUsageAccountIDs.formUnion(refreshingAccountIDs)
        if showsFooterLoading {
            isRefreshing = true
        }
        defer {
            store.endAllUsageRefresh()
            refreshingAllUsageAccountIDs.subtract(refreshingAccountIDs)
            if showsFooterLoading {
                isRefreshing = false
            }
        }
        let outcomes = await WhamService.shared.refreshAll(store: store)
        store.load()
        now = Date()
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(from: outcomes)
        )
    }

    func refreshAccount(_ account: TokenAccount, announceResult: Bool) async {
        refreshingAccounts.insert(account.id)
        let outcome = await WhamService.shared.refreshOne(account: account, store: store)
        refreshingAccounts.remove(account.id)
        store.load()
        now = Date()
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(for: account, outcome: outcome)
        )
    }

    func reauthAccount(_: TokenAccount) {
        self.startOAuthLogin()
    }

    private func requestCloseStatusItemMenu() {
        NotificationCenter.default.post(name: .codexbarRequestCloseStatusItemMenu, object: nil)
    }

    private func presentSystemFilePanelAfterClosingMenu(_ action: @escaping () -> Void) {
        self.requestCloseStatusItemMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            action()
        }
    }

    private func refreshFailureMessage(from outcomes: [WhamRefreshOutcome]) -> String? {
        let failures = outcomes.compactMap(\.errorMessage)
        guard failures.isEmpty == false else { return nil }
        if outcomes.contains(.updated) || outcomes.contains(.skipped) {
            return failures.first
        }
        return failures.first ?? "Refresh failed."
    }

    private func refreshFailureMessage(for account: TokenAccount, outcome: WhamRefreshOutcome) -> String? {
        guard let message = outcome.errorMessage else { return nil }
        let label = account.email.isEmpty ? account.accountId : account.email
        return "\(label): \(message)"
    }

    private func clearError() {
        self.errorBanner = nil
    }

    private func setGenericError(_ message: String?) {
        guard let message else {
            self.clearError()
            return
        }
        self.errorBanner = MenuBarErrorBannerState(message: message, source: .generic)
    }

    private func applyRefreshFeedback(announceResult: Bool, message: String?) {
        self.errorBanner = MenuBarRefreshErrorResolver.nextBanner(
            current: self.errorBanner,
            announceResult: announceResult,
            refreshMessage: message
        )
    }

    private func refreshImportedAccounts(accountIDs: [String]) {
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
        }
    }

    private func refreshRunningThreadAttribution() {
        let now = Date()
        let service = self.runningThreadAttributionService

        self.runningThreadRefreshController.requestRefresh(now: now) { refreshDate in
            service.load(now: refreshDate)
        } apply: { attribution in
            self.runningThreadAttribution = attribution
        }
    }
}
