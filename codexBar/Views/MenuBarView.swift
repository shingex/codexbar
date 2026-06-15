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

    private let costPanelID = "cost-details-hover-panel"
    private let usageRefreshInterval = OpenAIUsagePollingService.defaultRefreshInterval
    private let visibleOpenAIAccountLimit = 5
    private let runningThreadAttributionService = OpenAIRunningThreadAttributionService()
    private let oauthAccountService = CodexBarOAuthAccountService()
    private let openAIAccountCSVService = OpenAIAccountCSVService()
    private let openAIAccountCSVPanelService = OpenAIAccountCSVPanelService()
    private let codexAppPathPanelService = CodexAppPathPanelService.shared
    private let codexDesktopLaunchProbeService = CodexDesktopLaunchProbeService()
    let menuHorizontalInset = MenuPanelLayout.horizontalInset
    let blockContentHorizontalInset = MenuPanelLayout.blockContentHorizontalInset
    let blockVerticalInset = MenuPanelLayout.blockVerticalInset
    private let compactSectionTopInset = MenuPanelLayout.compactSectionTopInset
    private let statusSummaryTopInset: CGFloat = 12
    let sectionActionButtonSize = MenuPanelLayout.sectionActionButtonSize
    let sectionCountSlotWidth = MenuPanelLayout.sectionCountSlotWidth
    let panelSectionSpacing: CGFloat = 8
    let panelRowSpacing: CGFloat = 6

    @State private var isRefreshing = false
    @State private var errorBanner: MenuBarErrorBannerState?
    @State var now = Date()
    @State var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State var refreshingAccounts: Set<String> = []
    @State var refreshingAllUsageAccountIDs: Set<String> = []
    @State var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var openRefreshGate = MenuBarOpenRefreshGate()
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State fileprivate var pendingCodexLaunchPrompt: CodexLaunchPrompt?
    @State private var statusItemAvailableContentHeight: CGFloat?
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?
    @State private var runningThreadRefreshController = CoalescedBackgroundRefreshController()
    @State var selectedModeTab: CodexBarOpenAIAccountUsageMode = .switchAccount
    @State fileprivate var pendingDeleteConfirmation: DeleteConfirmationRequest?

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
    private let runningThreadTimer = Timer.publish(
        every: OpenAIRunningThreadAttributionService.defaultRecentActivityWindow,
        on: .main,
        in: .common
    )
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    var groupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.groupedAccounts(
            from: store.accounts,
            summary: self.runningThreadSummary,
            quotaSortSettings: self.store.config.openAI.quotaSort,
            preferredAccountOrder: self.store.config.openAI.preferredDisplayAccountOrder,
            highlightActiveAccount: self.store.config.openAI.accountUsageMode == .switchAccount
        )
    }

    private var primaryStatusLabel: String {
        self.store.config.openAI.accountUsageMode == .hybridProvider ? "Request" : "Current"
    }

    private var currentModeContextLabel: String? {
        switch self.store.config.openAI.accountUsageMode {
        case .switchAccount:
            return L.accountUsageModeSwitch
        case .aggregateGateway:
            return L.accountUsageModeAggregate
        case .hybridProvider:
            return L.accountUsageModeHybrid
        }
    }

    var modeAccentColor: Color {
        Color(nsColor: self.store.config.openAI.accountUsageMode.themeAccentColor)
    }

    var runningThreadSummary: OpenAIRunningThreadAttribution.Summary {
        self.runningThreadAttribution.summary
    }

    private var openAIRuntimeRouteSnapshot: OpenAIRuntimeRouteSnapshot {
        self.store.openAIRuntimeRouteSnapshot(
            runningThreadAttribution: self.runningThreadAttribution,
            now: self.now
        )
    }

    func isAccountUsageRefreshing(_ account: TokenAccount) -> Bool {
        self.refreshingAccounts.contains(account.id) ||
            self.refreshingAllUsageAccountIDs.contains(account.id)
    }

    private var lockedMenuBodyHeight: CGFloat {
        MenuBarPopoverSizing.middleContentHeight(
            lockedContentHeight: self.lockedMenuContentHeight
        )
    }

    private var lockedMenuContentHeight: CGFloat {
        self.statusItemAvailableContentHeight ?? MenuBarPopoverSizing.defaultHeight
    }

    private var switchTargetAccount: TokenAccount? {
        if let selectedAccountID = self.store.config.openAI.switchModeSelection?.accountId,
           let account = self.store.oauthAccount(accountID: selectedAccountID) {
            return account
        }
        return self.store.activeAccount()
    }

    private var latestRoutedAccount: TokenAccount? {
        guard let accountID = self.openAIRuntimeRouteSnapshot.latestRoutedAccountID else {
            return nil
        }
        return self.store.oauthAccount(accountID: accountID)
    }

    var runtimeRouteBanner: OpenAIStatusBannerPresentation? {
        OpenAIAccountPresentation.runtimeRouteBanner(
            snapshot: self.openAIRuntimeRouteSnapshot,
            latestRoutedAccount: self.latestRoutedAccount,
            switchTargetAccount: self.switchTargetAccount
        )
    }

    private var visibleGroupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.visibleGroups(
            from: groupedAccounts,
            maxAccounts: visibleOpenAIAccountLimit
        )
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
        .frame(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: self.lockedMenuContentHeight,
            alignment: .topLeading
        )
        .onReceive(countdownTimer) { _ in
            now = Date()
        }
        .onReceive(runningThreadTimer) { _ in
            refreshRunningThreadAttribution()
        }
        .onReceive(store.$localCostSummary) { _ in
            guard isCostPanelPresented else { return }
            showCostPanel()
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
            self.selectedModeTab = self.store.config.openAI.accountUsageMode
        }
    }

    @ViewBuilder
    private var mainMenuContent: some View {
        self.menuContentStack(measuring: false)
            .overlay(alignment: .topLeading) {
                AdaptiveMenuHeightReportingContainer(
                    onMeasuredHeightChange: self.reportMeasuredMenuHeight
                ) {
                    self.menuContentStack(measuring: true)
                }
                .frame(width: MenuBarStatusItemIdentity.popoverContentWidth, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private func menuContentStack(measuring: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self.menuHeader
                .frame(height: MenuBarPopoverSizing.headerHeight)

            Divider()
                .frame(height: MenuBarPopoverSizing.headerDividerHeight)

            self.menuContentSection(measuring: measuring)

            Divider()
                .frame(height: MenuBarPopoverSizing.footerDividerHeight)

            self.menuFooter
                .frame(height: MenuBarPopoverSizing.footerHeight)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: measuring ? nil : max(
                self.lockedMenuContentHeight
                    - MenuBarPopoverSizing.topContentInset
                    - MenuBarPopoverSizing.bottomContentInset,
                MenuBarPopoverSizing.minimumHeight
            ),
            maxHeight: measuring ? nil : max(
                self.lockedMenuContentHeight
                    - MenuBarPopoverSizing.topContentInset
                    - MenuBarPopoverSizing.bottomContentInset,
                MenuBarPopoverSizing.minimumHeight
            ),
            alignment: .topLeading
        )
        .padding(.top, MenuBarPopoverSizing.topContentInset)
        .padding(.bottom, MenuBarPopoverSizing.bottomContentInset)
    }

    @ViewBuilder
    private func menuContentSection(measuring: Bool) -> some View {
        if measuring {
            self.menuContentScrollContent
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            AdaptiveMenuScrollContainer(
                maxHeight: self.lockedMenuBodyHeight,
                fillsHeightLimit: true
            ) {
                self.menuContentScrollContent
            }
            .frame(height: self.lockedMenuBodyHeight, alignment: .top)
            .clipped()
            .layoutPriority(1)
        }
    }

    private var menuHeader: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("codexbar")
                    .font(.system(size: 13, weight: .semibold))
                Text(AppVersionDisplay.versionAndBuild)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let currentModeContextLabel {
                Text(currentModeContextLabel)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(self.modeAccentColor.opacity(0.12))
                    .foregroundColor(self.modeAccentColor)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, self.menuHorizontalInset)
        .padding(.vertical, 8)
    }

    private var menuContentScrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.menuStatusSummaryView
            self.menuModeContentView
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var menuStatusSummaryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pendingAvailability = self.updateCoordinator.pendingAvailability {
                Divider()
                self.updateAvailableBanner(availability: pendingAvailability)
            }

            if self.store.config.openAI.disableLocalUsageStats == false {
                VStack(alignment: .leading, spacing: 0) {
                    CostSummaryRowView(
                        summary: store.localCostSummary,
                        currency: currency,
                        compactTokens: compactTokens,
                        isHovering: self.isCostSummaryHovered
                    )
                }
                .background(
                    ViewReferenceReader { view in
                        resolveCostSummaryAnchor(view)
                    }
                )
                .onHover { hovering in
                    setCostSummaryHover(hovering)
                }
                .frame(height: MenuBarPopoverSizing.usageSummaryHeight, alignment: .center)
                .padding(.top, self.statusSummaryTopInset)
                .padding(.bottom, self.panelSectionSpacing)
            }
        }
        .padding(.horizontal, self.menuHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var menuModeContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
                self.openAIModeTabsSection
            }
            .padding(.horizontal, self.menuHorizontalInset)
            .padding(.bottom, self.blockVerticalInset)

            if let error = self.errorBanner?.message {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        self.clearError()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .menuPanelHoverChrome(cornerRadius: 5)
                }
                .padding(.horizontal, self.menuHorizontalInset)
                .padding(.vertical, 6)
            }
        }
    }

    private var menuFooter: some View {
        HStack(spacing: 8) {
            Button {
                Task { await refresh(announceResult: true) }
            } label: {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text(self.refreshStatusTitle)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)
            .help(L.refreshUsage)
            .foregroundColor(isRefreshing ? .accentColor : .secondary)
            .disabled(isRefreshing)
            .menuPanelHoverChrome(cornerRadius: 6)

            Spacer()

            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(L.settings)
            .menuPanelHoverChrome(cornerRadius: 6)

            Button {
                switch L.languageOverride {
                case nil: L.languageOverride = true
                case true: L.languageOverride = false
                case false: L.languageOverride = nil
                }
                languageToggle.toggle()
            } label: {
                let label = languageToggle ? L.languageOverride : L.languageOverride
                Text(label == nil ? "AUTO" : (label == true ? "中" : "EN"))
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .menuPanelHoverChrome(cornerRadius: 6)

            Menu {
                Button(L.restart) {
                    self.restartAppFromCurrentBundle()
                }
                Button(L.quit) {
                    self.quitApp()
                }
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .help(L.powerMenu)
            .menuPanelHoverChrome(cornerRadius: 6)
        }
        .padding(.horizontal, self.menuHorizontalInset)
        .padding(.vertical, 5)
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

    private func currency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func compactTokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.2fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }

    private func shortDay(_ date: Date) -> String {
        Self.shortDayFormatter.string(from: date)
    }

    private func reportMeasuredMenuHeight(_ height: CGFloat) {
        NotificationCenter.default.post(
            name: .codexbarStatusItemMeasuredHeightDidChange,
            object: nil,
            userInfo: ["height": height]
        )
    }

    private func requestStatusItemLayoutRefresh() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .codexbarRequestStatusItemLayoutRefresh,
                object: nil
            )
        }
    }

    private func resolveCostSummaryAnchor(_ view: NSView) {
        if self.costSummaryAnchorView !== view {
            self.costSummaryAnchorView = view
        }
        guard isCostPanelPresented else { return }
        showCostPanel()
    }

    private func setCostSummaryHover(_ hovering: Bool) {
        isCostSummaryHovered = hovering
        if hovering {
            presentCostPanel()
        } else {
            scheduleCostPanelHideIfNeeded()
        }
    }

    private func setCostPanelHover(_ hovering: Bool) {
        isCostPanelHovered = hovering
        if hovering {
            presentCostPanel()
        } else {
            scheduleCostPanelHideIfNeeded()
        }
    }

    private func presentCostPanel() {
        pendingCostHide?.cancel()
        pendingCostHide = nil
        isCostPanelPresented = true
        showCostPanel()
    }

    private func scheduleCostPanelHideIfNeeded() {
        pendingCostHide?.cancel()
        let work = DispatchWorkItem {
            if !isCostSummaryHovered && !isCostPanelHovered {
                isCostPanelPresented = false
                DetachedWindowPresenter.shared.close(id: costPanelID)
            }
        }
        pendingCostHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func showCostPanel() {
        guard let anchorView = costSummaryAnchorView,
              let window = anchorView.window else { return }

        let frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = window.convertToScreen(frameInWindow)
        let panelSize = CGSize(
            width: CostDetailsPanelView.windowWidth,
            height: CostDetailsPanelView.windowHeight(hasHistory: !store.localCostSummary.dailyEntries.isEmpty)
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorFrame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let spacing: CGFloat = 12
        let margin: CGFloat = 8
        let shadowPadding = CostDetailsPanelView.shadowPadding

        var originX = anchorFrame.maxX + spacing - shadowPadding
        if originX + panelSize.width > visibleFrame.maxX - margin {
            originX = anchorFrame.minX - spacing - panelSize.width + shadowPadding
        }
        originX = min(max(originX, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin)

        var originY = anchorFrame.maxY - panelSize.height
        originY = min(max(originY, visibleFrame.minY + margin), visibleFrame.maxY - panelSize.height - margin)

        DetachedWindowPresenter.shared.showHoverPanel(
            id: costPanelID,
            size: panelSize,
            origin: CGPoint(x: originX, y: originY)
        ) {
            CostDetailsPanelView(
                summary: store.localCostSummary,
                currency: currency,
                compactTokens: compactTokens,
                shortDay: shortDay
            )
            .onHover { hovering in
                setCostPanelHover(hovering)
            }
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
            try await CompatibleProviderUseExecutor.execute {
                try self.store.activateCustomProvider(
                    providerID: providerID,
                    accountID: accountID,
                    modelID: modelID,
                    accountUsageMode: accountUsageMode
                )
            }

            self.presentCodexLaunchPrompt()
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
            try await CompatibleProviderUseExecutor.execute {
                try self.store.activateOpenRouterProvider(
                    accountID: accountID,
                    accountUsageMode: accountUsageMode
                )
            }

            self.presentCodexLaunchPrompt()
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    func useCurrentOAuthFromHybrid(_ account: TokenAccount) async {
        if self.store.config.openAI.accountUsageMode != .switchAccount ||
            self.store.config.activeProvider()?.kind != .openAIOAuth ||
            self.store.activeAccount()?.accountId != account.accountId {
            await self.activateAccount(account)
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

    func setOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) async {
        let previousMode = self.store.config.openAI.accountUsageMode

        do {
            let action = try await OpenAIAccountUsageModeTransitionExecutor.execute(
                targetMode: mode,
                currentMode: previousMode,
                applyMode: {
                    try self.store.updateOpenAIAccountUsageMode(mode)
                }
            )
            if action != nil {
                self.presentCodexLaunchPrompt()
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

    private func presentCodexLaunchPrompt() {
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

    func clearStaleAggregateStickyIfNeeded() {
        let snapshot = self.openAIRuntimeRouteSnapshot
        guard self.store.clearStaleAggregateSticky(using: snapshot) else { return }
        self.clearError()
        self.refreshRunningThreadAttribution()
    }

    private func activeProviderSummaryTitle(
        activeProvider: CodexBarProvider,
        activeAccount: CodexBarProviderAccount
    ) -> String {
        if activeProvider.kind == .openAIOAuth &&
            self.store.config.openAI.accountUsageMode == .aggregateGateway {
            let routedAccount = self.store.aggregateRoutedAccount ??
                activeAccount.asTokenAccount(isActive: false)
            return OpenAIAccountPresentation.aggregateSummaryTitle(
                providerLabel: activeProvider.label,
                routedAccount: routedAccount,
                usageDisplayMode: self.store.config.openAI.usageDisplayMode
            )
        }
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
                providerLabel: provider.label,
                accountID: account.id,
                accountLabel: account.label
            )
        )
    }

    func confirmDeleteProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .customProvider(providerID: provider.id, providerLabel: provider.label)
        )
    }

    func confirmDeleteOpenRouterAccount(_ account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .openRouterAccount(accountID: account.id, accountLabel: account.label)
        )
    }

    private func confirmDeleteOpenRouterProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .openRouterProvider(providerID: provider.id)
        )
    }

    fileprivate func performConfirmedDelete(_ request: DeleteConfirmationRequest) {
        switch request.target {
        case .openAIAccount(let account):
            store.remove(account)
            self.clearError()
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
        DetachedWindowPresenter.shared.show(
            id: "openai-settings",
            title: "\(L.settingsWindowTitle) \(AppVersionDisplay.versionAndBuild)",
            size: CGSize(width: 980, height: 720),
            configuration: .openAISettings
        ) {
            SettingsWindowView(
                store: self.store,
                codexAppPathPanelService: self.codexAppPathPanelService
            ) {
                DetachedWindowPresenter.shared.close(id: "openai-settings")
            }
        }
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
            size: CGSize(width: 520, height: 620)
        ) {
            AddProviderSheet(store: store, defaultPreset: defaultPreset) { preset, label, baseURL, accountLabel, apiKey, thirdPartySelection, openRouterSelection in
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
            size: CGSize(width: 400, height: 220)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey in
                do {
                    try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey)
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
        store.load()
        store.markActiveAccount()
        selectedModeTab = store.config.openAI.accountUsageMode
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
        pendingCostHide?.cancel()
        pendingCostHide = nil
        isCostPanelPresented = false
        isCostSummaryHovered = false
        isCostPanelHovered = false
        DetachedWindowPresenter.shared.close(id: costPanelID)
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
