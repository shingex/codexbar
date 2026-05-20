import AppKit
import Combine
import SwiftUI

private final class ThinOverlayScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        min(6, super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle))
    }
}

private final class ActivityAwareScrollView: NSScrollView {
    var onUserScrollActivity: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        self.onUserScrollActivity?()
        super.scrollWheel(with: event)
    }
}

private enum AdaptiveScrollHeightLimit {
    case fixed(CGFloat)
    case measured(AnyView)
}

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

struct MenuBarOpenRefreshGate: Equatable {
    private(set) var didTriggerOpenRefresh = false

    mutating func shouldTriggerRefresh(isRefreshing: Bool) -> Bool {
        guard self.didTriggerOpenRefresh == false else { return false }
        self.didTriggerOpenRefresh = true
        return isRefreshing == false
    }

    mutating func resetForClose() {
        self.didTriggerOpenRefresh = false
    }
}

private struct AdaptiveMenuScrollContainer<Content: View>: NSViewRepresentable {
    let heightLimit: AdaptiveScrollHeightLimit
    let initialHeight: CGFloat
    let maxHeightCap: CGFloat?
    let fillsHeightLimit: Bool
    let onMeasuredHeightChange: ((CGFloat) -> Void)?
    let content: Content

    init(
        maxHeight: CGFloat,
        maxHeightCap: CGFloat? = nil,
        fillsHeightLimit: Bool = false,
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .fixed(maxHeight)
        self.initialHeight = MenuBarPopoverSizing.minimumHeight
        self.maxHeightCap = maxHeightCap
        self.fillsHeightLimit = fillsHeightLimit
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    init<MeasurementContent: View>(
        initialHeight: CGFloat,
        measuredHeight: @escaping () -> MeasurementContent,
        maxHeightCap: CGFloat? = nil,
        fillsHeightLimit: Bool = false,
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .measured(AnyView(measuredHeight()))
        self.initialHeight = initialHeight
        self.maxHeightCap = maxHeightCap
        self.fillsHeightLimit = fillsHeightLimit
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    func makeNSView(context: Context) -> AdaptiveMenuScrollHost {
        AdaptiveMenuScrollHost(
            rootView: AnyView(content),
            heightLimit: heightLimit,
            initialHeight: initialHeight,
            maxHeightCap: maxHeightCap,
            fillsHeightLimit: fillsHeightLimit,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    func updateNSView(_ nsView: AdaptiveMenuScrollHost, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            heightLimit: heightLimit,
            maxHeightCap: maxHeightCap,
            fillsHeightLimit: fillsHeightLimit,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }
}

private struct AdaptiveMenuHeightReportingContainer<Content: View>: NSViewRepresentable {
    let onMeasuredHeightChange: ((CGFloat) -> Void)?
    let content: Content

    init(
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    func makeNSView(context: Context) -> AdaptiveMenuHeightReportingHost {
        AdaptiveMenuHeightReportingHost(
            rootView: AnyView(content),
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    func updateNSView(_ nsView: AdaptiveMenuHeightReportingHost, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }
}

private struct ViewReferenceReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> ReporterView {
        ReporterView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfAttached()
    }

    final class ReporterView: NSView {
        var onResolve: (NSView) -> Void

        init(onResolve: @escaping (NSView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfAttached()
        }

        override func layout() {
            super.layout()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onResolve(self)
            }
        }
    }
}

private final class AdaptiveMenuHeightReportingHost: NSView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var measuredHeight: CGFloat = 1
    private var lastReportedHeight: CGFloat?
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?

    init(
        rootView: AnyView,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        super.init(frame: .zero)
        self.hostingView.rootView = rootView
        self.addSubview(self.hostingView)
        self.scheduleMeasurement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(self.bounds.width, 1)
        self.hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(self.measuredHeight, self.bounds.height, 1)
        )

        guard abs(self.lastMeasuredWidth - width) > 1 else { return }
        self.lastMeasuredWidth = width
        self.scheduleMeasurement()
    }

    func update(
        rootView: AnyView,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.hostingView.rootView = rootView
        self.scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateLayout()
        }
    }

    private func recalculateLayout() {
        guard self.isMeasuring == false else { return }
        self.isMeasuring = true
        defer { self.isMeasuring = false }

        let width = max(self.bounds.width, 1)
        self.hostingView.setFrameSize(
            NSSize(width: width, height: max(self.hostingView.frame.height, self.measuredHeight, 1))
        )

        let fittingHeight = max(self.hostingView.fittingSize.height, 1)
        self.hostingView.setFrameSize(NSSize(width: width, height: fittingHeight))

        if abs((self.lastReportedHeight ?? 0) - fittingHeight) > 1 {
            self.lastReportedHeight = fittingHeight
            self.onMeasuredHeightChange?(fittingHeight)
        }

        guard abs(self.measuredHeight - fittingHeight) > 1 else { return }
        self.measuredHeight = fittingHeight
        self.invalidateIntrinsicContentSize()
        self.superview?.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }
}

private final class AdaptiveMenuScrollHost: NSView {
    private let scrollView = ActivityAwareScrollView()
    private let displayHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let measuringHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let limitHostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var heightLimit: AdaptiveScrollHeightLimit
    private var measuredHeight: CGFloat
    private var maxHeightCap: CGFloat?
    private var fillsHeightLimit: Bool
    private var lastReportedHeight: CGFloat?
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var hideScrollerWorkItem: DispatchWorkItem?
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?

    private let idleScrollerAlpha: CGFloat = 0
    private let visibleScrollerAlpha: CGFloat = 0.95
    private let scrollerHideDelay: TimeInterval = 0.9

    init(
        rootView: AnyView,
        heightLimit: AdaptiveScrollHeightLimit,
        initialHeight: CGFloat,
        maxHeightCap: CGFloat?,
        fillsHeightLimit: Bool,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.heightLimit = heightLimit
        self.measuredHeight = max(initialHeight, 1)
        self.maxHeightCap = maxHeightCap
        self.fillsHeightLimit = fillsHeightLimit
        self.onMeasuredHeightChange = onMeasuredHeightChange
        super.init(frame: .zero)

        self.scrollView.drawsBackground = false
        self.scrollView.borderType = .noBorder
        self.scrollView.autohidesScrollers = true
        self.scrollView.scrollerStyle = .overlay
        self.scrollView.verticalScroller = ThinOverlayScroller()
        self.scrollView.verticalScroller?.controlSize = .mini
        self.scrollView.verticalScroller?.alphaValue = self.idleScrollerAlpha
        self.scrollView.hasVerticalScroller = false
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.documentView = self.displayHostingView
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.onUserScrollActivity = { [weak self] in
            self?.showScrollerTemporarily()
        }

        self.addSubview(self.scrollView)
        self.update(
            rootView: rootView,
            heightLimit: heightLimit,
            maxHeightCap: maxHeightCap,
            fillsHeightLimit: fillsHeightLimit,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.hideScrollerWorkItem?.cancel()
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        self.scrollView.frame = self.bounds

        let width = max(self.bounds.width, 1)
        guard abs(self.lastMeasuredWidth - width) > 1 else { return }
        self.lastMeasuredWidth = width
        self.scheduleMeasurement()
    }

    func update(
        rootView: AnyView,
        heightLimit: AdaptiveScrollHeightLimit,
        maxHeightCap: CGFloat?,
        fillsHeightLimit: Bool,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.heightLimit = heightLimit
        self.maxHeightCap = maxHeightCap
        self.fillsHeightLimit = fillsHeightLimit
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.displayHostingView.rootView = rootView
        self.measuringHostingView.rootView = rootView
        if case let .measured(limitView) = heightLimit {
            self.limitHostingView.rootView = limitView
        } else {
            self.limitHostingView.rootView = AnyView(EmptyView())
        }
        self.scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateLayout()
        }
    }

    private func recalculateLayout() {
        guard self.isMeasuring == false else { return }
        self.isMeasuring = true
        defer { self.isMeasuring = false }

        let width = max(self.bounds.width, 1)
        self.measuringHostingView.setFrameSize(NSSize(width: width, height: max(self.measuringHostingView.frame.height, 1)))

        let fittingHeight = max(self.measuringHostingView.fittingSize.height, 1)
        let limitHeight = self.resolveHeightLimit(for: width)
        let effectiveLimitHeight = min(limitHeight, max(self.maxHeightCap ?? limitHeight, 1))
        let targetHeight = self.fillsHeightLimit ? effectiveLimitHeight : min(effectiveLimitHeight, fittingHeight)
        let needsScroller = fittingHeight > effectiveLimitHeight + 1
        let visibleRect = self.scrollView.contentView.bounds
        let previousTopOffset = self.displayHostingView.isFlipped
            ? visibleRect.minY
            : max(self.displayHostingView.bounds.height - visibleRect.maxY, 0)

        self.displayHostingView.setFrameSize(NSSize(width: width, height: fittingHeight))
        self.preserveVisibleTopOffset(previousTopOffset)
        self.scrollView.hasVerticalScroller = needsScroller
        if needsScroller {
            self.hideScrollerImmediately()
        } else {
            self.hideScrollerWorkItem?.cancel()
            self.scrollView.verticalScroller?.alphaValue = self.idleScrollerAlpha
        }

        if abs((self.lastReportedHeight ?? 0) - targetHeight) > 1 {
            self.lastReportedHeight = targetHeight
            self.onMeasuredHeightChange?(targetHeight)
        }

        guard abs(self.measuredHeight - targetHeight) > 1 else { return }
        self.measuredHeight = targetHeight
        self.invalidateIntrinsicContentSize()
        self.superview?.invalidateIntrinsicContentSize()
    }

    private func resolveHeightLimit(for width: CGFloat) -> CGFloat {
        switch self.heightLimit {
        case let .fixed(maxHeight):
            return max(maxHeight, 1)
        case .measured:
            self.limitHostingView.setFrameSize(NSSize(width: width, height: max(self.limitHostingView.frame.height, 1)))
            return max(self.limitHostingView.fittingSize.height, 1)
        }
    }

    private func preserveVisibleTopOffset(_ topOffset: CGFloat) {
        let viewportHeight = self.scrollView.contentView.bounds.height
        let documentHeight = self.displayHostingView.bounds.height
        let originY = MenuBarPopoverSizing.preservingTopScrollOriginY(
            topOffset: topOffset,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight,
            isFlipped: self.displayHostingView.isFlipped
        )
        let origin = NSPoint(x: self.scrollView.contentView.bounds.origin.x, y: originY)
        self.scrollView.contentView.scroll(to: origin)
        self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
    }

    private func showScrollerTemporarily() {
        guard self.scrollView.hasVerticalScroller else { return }
        self.hideScrollerWorkItem?.cancel()
        self.animateScroller(to: self.visibleScrollerAlpha)

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideScrollerImmediately()
        }
        self.hideScrollerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + self.scrollerHideDelay, execute: workItem)
    }

    private func hideScrollerImmediately() {
        guard self.scrollView.hasVerticalScroller else { return }
        self.hideScrollerWorkItem?.cancel()
        self.animateScroller(to: self.idleScrollerAlpha)
    }

    private func animateScroller(to alpha: CGFloat) {
        guard let scroller = self.scrollView.verticalScroller else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scroller.animator().alphaValue = alpha
        }
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
    private let menuHorizontalInset = MenuPanelLayout.horizontalInset
    private let blockContentHorizontalInset = MenuPanelLayout.blockContentHorizontalInset
    private let blockVerticalInset = MenuPanelLayout.blockVerticalInset
    private let compactSectionTopInset = MenuPanelLayout.compactSectionTopInset
    private let sectionActionButtonSize = MenuPanelLayout.sectionActionButtonSize
    private let sectionCountSlotWidth = MenuPanelLayout.sectionCountSlotWidth
    private let panelSectionSpacing: CGFloat = 8
    private let panelRowSpacing: CGFloat = 6

    @State private var isRefreshing = false
    @State private var errorBanner: MenuBarErrorBannerState?
    @State private var now = Date()
    @State private var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State private var refreshingAccounts: Set<String> = []
    @State private var copiedOpenAIAccountGroupEmail: String?
    @State private var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var openRefreshGate = MenuBarOpenRefreshGate()
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var pendingCopiedOpenAIAccountGroupEmailHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State private var pendingCodexLaunchPrompt: CodexLaunchPrompt?
    @State private var statusItemAvailableContentHeight: CGFloat?
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?
    @State private var runningThreadRefreshController = CoalescedBackgroundRefreshController()
    @State private var selectedModeTab: CodexBarOpenAIAccountUsageMode = .switchAccount
    @State private var pendingDeleteConfirmation: DeleteConfirmationRequest?

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

    private var groupedAccounts: [OpenAIAccountGroup] {
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

    private var runningThreadSummary: OpenAIRunningThreadAttribution.Summary {
        self.runningThreadAttribution.summary
    }

    private var openAIRuntimeRouteSnapshot: OpenAIRuntimeRouteSnapshot {
        self.store.openAIRuntimeRouteSnapshot(
            runningThreadAttribution: self.runningThreadAttribution,
            now: self.now
        )
    }

    private var lockedMenuBodyHeight: CGFloat {
        MenuBarPopoverSizing.middleContentHeight(
            lockedContentHeight: self.statusItemAvailableContentHeight ?? MenuBarPopoverSizing.defaultHeight
        )
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

    private var runtimeRouteBanner: OpenAIStatusBannerPresentation? {
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

    private var availableCount: Int {
        store.accounts.filter { $0.usageStatus == .ok }.count
    }

    private var openAIAvailabilityBadgeTitle: String? {
        OpenAIAccountPresentation.headerAvailabilityBadgeTitle(
            availableCount: self.availableCount,
            totalCount: self.store.accounts.count
        )
    }

    private var visibleOpenRouterProvider: CodexBarProvider? {
        guard let provider = store.openRouterProvider,
              provider.accounts.isEmpty == false else {
            return nil
        }
        return provider
    }

    private var visibleCompatibleProviderCount: Int {
        self.store.customProviders.count
    }

    private var isCompletelyEmpty: Bool {
        store.accounts.isEmpty &&
        store.customProviders.isEmpty &&
        self.visibleOpenRouterProvider == nil
    }

    var body: some View {
        mainMenuContent
        .frame(width: MenuBarStatusItemIdentity.popoverContentWidth)
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
        .onAppear {
            self.selectedModeTab = self.store.config.openAI.accountUsageMode
        }
    }

    @ViewBuilder
    private var mainMenuContent: some View {
        AdaptiveMenuHeightReportingContainer(onMeasuredHeightChange: self.reportMeasuredMenuHeight) {
            menuContentStack
        }
    }

    private var menuContentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.menuHeader
                .frame(height: MenuBarPopoverSizing.headerHeight)

            AdaptiveMenuScrollContainer(
                maxHeight: max(
                    MenuBarPopoverSizing.minimumHeight,
                    self.lockedMenuBodyHeight
                ),
                fillsHeightLimit: self.statusItemAvailableContentHeight != nil
            ) {
                self.scrollableMenuBody
            }

            Divider()
                .frame(height: MenuBarPopoverSizing.footerDividerHeight)

            self.menuFooter
                .frame(height: MenuBarPopoverSizing.footerHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, MenuBarPopoverSizing.topContentInset)
        .padding(.bottom, MenuBarPopoverSizing.bottomContentInset)
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
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, self.menuHorizontalInset)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var scrollableMenuBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activeAccount = store.activeProviderAccount {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("OAuth: \(self.oauthLoginSummaryTitle() ?? activeAccount.label)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Model: \(store.activeModel)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, self.menuHorizontalInset)
                .padding(.top, self.blockVerticalInset)
                .padding(.bottom, self.compactSectionTopInset)
            }

            if let pendingAvailability = self.updateCoordinator.pendingAvailability {
                Divider()
                self.updateAvailableBanner(availability: pendingAvailability)
            }

            VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
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

                openAIModeTabsSection

            }
            .padding(.horizontal, self.menuHorizontalInset)
            .padding(.top, self.compactSectionTopInset)
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

            Menu {
                Button(L.exportOpenAICSVAction) {
                    exportOpenAIAccountsCSV()
                }
                Button(L.importOpenAICSVAction) {
                    importOpenAIAccountsCSV()
                }
            } label: {
                Image(systemName: OpenAIAccountCSVToolbarUI.symbolName)
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L.openAICSVToolbar)
            .accessibilityIdentifier(OpenAIAccountCSVToolbarUI.accessibilityIdentifier)
            .help(L.openAICSVToolbar)
            .menuPanelHoverChrome(cornerRadius: 6)

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
        if let lastUpdate = store.accounts.compactMap({ $0.lastChecked }).max() {
            return relativeTime(lastUpdate)
        }
        if let provider = store.activeProvider {
            return provider.hostLabel
        }
        return L.refreshUsage
    }

    private func updateAvailableBanner(availability: AppUpdateAvailability) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.menuUpdateAvailableTitle(availability.release.version))
                    .font(.system(size: 11, weight: .medium))
                Text(L.menuUpdateAvailableSubtitle(availability.currentVersion, availability.release.version))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(L.menuUpdateAction) {
                Task { await self.updateCoordinator.handleToolbarAction() }
            }
            .disabled(self.updateCoordinator.isChecking)
            .menuPanelHoverChrome(cornerRadius: 6)
        }
        .padding(.horizontal, self.menuHorizontalInset)
        .padding(.vertical, self.blockVerticalInset)
    }

    private func openAIAvailabilityBadge(title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(availableCount > 0 ? Color.green.opacity(0.10) : Color.red.opacity(0.10))
            .foregroundColor(availableCount > 0 ? Color.green.opacity(0.82) : Color.red.opacity(0.82))
            .cornerRadius(4)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: self.sectionCountSlotWidth, alignment: .trailing)
    }

    private func openAISectionLabel<Actions: View>(
        _ title: String,
        count: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let count {
                Text(count)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: self.sectionCountSlotWidth, alignment: .trailing)
            }

            actions()
        }
    }

    private func openAISectionLabel(_ title: String, count: String? = nil) -> some View {
        self.openAISectionLabel(title, count: count) {
            EmptyView()
        }
    }

    private var openAIAccountsSectionLabel: some View {
        HStack(spacing: 6) {
            Text("OpenAI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let openAIAvailabilityBadgeTitle {
                self.openAIAvailabilityBadge(title: openAIAvailabilityBadgeTitle)
            }

            self.openAIAddAccountButton
        }
    }

    private var openAIAddAccountButton: some View {
        Button {
            startOAuthLogin()
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 12))
                .frame(width: self.sectionActionButtonSize, height: self.sectionActionButtonSize)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("login toolbar button")
        .accessibilityIdentifier("codexbar.login-openai.toolbar")
        .menuPanelHoverChrome(cornerRadius: 6)
    }

    private var providerAddButton: some View {
        self.sectionAddButton {
            openAddProviderWindow()
        }
    }

    private func openRouterAddButton(provider: CodexBarProvider) -> some View {
        self.sectionAddButton {
            openAddOpenRouterAccountWindow(provider: provider)
        }
    }

    private func sectionAddButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 12))
                .frame(width: self.sectionActionButtonSize, height: self.sectionActionButtonSize)
        }
        .buttonStyle(.borderless)
        .menuPanelHoverChrome(cornerRadius: 6)
    }

    @ViewBuilder
    private var openAIModeTabsSection: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIModeTabsControl

            if let runtimeRouteBanner,
               let actionTitle = runtimeRouteBanner.actionTitle {
                HStack(spacing: 0) {
                    Spacer()

                    Button(actionTitle) {
                        self.clearStaleAggregateStickyIfNeeded()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(runtimeRouteBanner.tone == .warning ? .orange : .secondary)
                    .help(L.aggregateRuntimeClearStaleStickyHint)
                    .menuPanelHoverChrome(cornerRadius: 6)
                }
                .padding(.horizontal, 0)
            }

            switch self.selectedModeTab {
            case .switchAccount:
                self.openAISwitchTabPanel
            case .aggregateGateway:
                self.openAIAggregateTabPanel
            case .hybridProvider:
                self.openAIHybridTabPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: self.store.config.openAI.accountUsageMode) { mode in
            self.selectedModeTab = mode
        }
    }

    private var openAIModeTabsControl: some View {
        HStack(spacing: 0) {
            ForEach(CodexBarOpenAIAccountUsageMode.allCases) { mode in
                Button {
                    self.selectedModeTab = mode
                } label: {
                    Text(mode.menuToggleTitle)
                        .font(.system(size: 10, weight: self.selectedModeTab == mode ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(self.selectedModeTab == mode ? .white : .secondary)
                .menuPanelHoverChrome(
                    cornerRadius: 6,
                    active: self.selectedModeTab == mode,
                    pressedOpacity: 1,
                    activeOpacity: 1
                )
                .accessibilityIdentifier("codexbar.openai-mode-tab.\(mode.rawValue)")

                if mode != CodexBarOpenAIAccountUsageMode.allCases.last {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 14)
                        .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.16))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexbar.openai-mode-picker")
    }

    @ViewBuilder
    private var openAISwitchTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIAccountsSectionLabel

            if store.accounts.isEmpty {
                if self.visibleCompatibleProviderCount == 0 {
                    self.emptyOpenAIAccountsView
                }
            } else {
                openAIAccountGroupsView(groupedAccounts, actionMode: .switchAccount)
            }

            self.compatibleRequestTargetsSection(
                activationMode: .switchAccount,
                showsEmptyMessage: self.visibleCompatibleProviderCount == 0
            )
        }
    }

    @ViewBuilder
    private var openAIAggregateTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIAccountsSectionLabel

            VStack(alignment: .leading, spacing: 4) {
                Text(L.openAIAggregatePanelTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(L.openAIAggregatePanelHint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            if store.accounts.isEmpty {
                self.emptyOpenAIAccountsView
            } else {
                openAIAccountGroupsView(groupedAccounts, actionMode: .aggregateGateway)
            }

            HStack {
                Spacer()
                Button(
                    self.store.config.openAI.accountUsageMode == .aggregateGateway
                        ? L.openAIAggregateEnabledAction
                        : L.openAIAggregateEnableAction
                ) {
                    Task { await self.setOpenAIAccountUsageMode(.aggregateGateway) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(self.store.config.openAI.accountUsageMode == .aggregateGateway || self.store.accounts.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var openAIHybridTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.hybridOAuthLoginSection
            self.hybridRequestTargetsSection
        }
    }

    @ViewBuilder
    private var emptyOpenAIAccountsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No OpenAI account added.")
                .font(.system(size: 11, weight: .medium))
            Text("Use the toolbar plus button to add OpenAI OAuth accounts.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, self.blockContentHorizontalInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var hybridOAuthLoginSection: some View {
        VStack(alignment: .leading, spacing: self.panelRowSpacing) {
            self.openAIAccountsSectionLabel

            if let account = self.store.config.oauthProvider()?.activeAccount?.asTokenAccount(isActive: self.store.config.activeProvider()?.kind == .openAIOAuth) {
                let isCurrentOAuthRequestTarget = self.store.config.activeProvider()?.kind == .openAIOAuth &&
                    self.store.config.openAI.accountUsageMode == .switchAccount
                AccountRowView(
                    account: account,
                    rowState: OpenAIAccountRowState(
                        isNextUseTarget: isCurrentOAuthRequestTarget,
                        runningThreadCount: self.runningThreadSummary.runningThreadCount(for: account.accountId),
                        accountUsageMode: .switchAccount,
                        actionTitle: L.openAIAccountSwitchAction
                    ),
                    isRefreshing: refreshingAccounts.contains(account.id),
                    usageDisplayMode: self.store.config.openAI.usageDisplayMode
                ) {
                    Task {
                        await self.useCurrentOAuthFromHybrid(account)
                    }
                } onRefresh: {
                    Task { await refreshAccount(account, announceResult: true) }
                } onReauth: {
                    reauthAccount(account)
                } onDelete: {
                    confirmDeleteOpenAIAccount(account)
                }

                Text(L.openAIHybridCurrentOAuthHint)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No OpenAI account added.")
                        .font(.system(size: 11, weight: .medium))
                    Text("Use the toolbar plus button to add OpenAI OAuth accounts.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, self.blockContentHorizontalInset)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
        }
    }

    @ViewBuilder
    private var hybridRequestTargetsSection: some View {
        self.compatibleRequestTargetsSection(
            activationMode: .hybridProvider,
            showsEmptyMessage: true
        )
    }

    @ViewBuilder
    private func compatibleRequestTargetsSection(
        activationMode: CodexBarOpenAIAccountUsageMode,
        showsEmptyMessage: Bool
    ) -> some View {
        let providerCount = self.visibleCompatibleProviderCount
        let openRouterProvider = self.visibleOpenRouterProvider

        if providerCount > 0 || openRouterProvider != nil || showsEmptyMessage {
            VStack(alignment: .leading, spacing: self.panelRowSpacing) {
                self.openAISectionLabel(L.openAIHybridTargetsTitle, count: "\(providerCount)") {
                    self.providerAddButton
                }

                if providerCount == 0 && openRouterProvider == nil {
                    Text(L.openAIHybridNoTargets)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, self.blockContentHorizontalInset)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.customProviders) { provider in
                        CompatibleProviderRowView(
                            provider: provider,
                            isActiveProvider: store.activeProvider?.id == provider.id &&
                                store.config.openAI.accountUsageMode == activationMode,
                            activeAccountId: provider.activeAccountId,
                            useActionTitle: activationMode == .hybridProvider ? L.providerUseAction : L.openAIAccountSwitchAction
                        ) { account in
                            Task {
                                await activateCompatibleProvider(
                                    providerID: provider.id,
                                    accountID: account.id,
                                    accountUsageMode: activationMode
                                )
                            }
                        } onAddAccount: {
                            openAddProviderAccountWindow(provider: provider)
                        } onEditProvider: {
                            openEditProviderWindow(provider: provider)
                        } onDeleteAccount: { account in
                            confirmDeleteCompatibleAccount(provider: provider, account: account)
                        } onDeleteProvider: {
                            confirmDeleteProvider(provider: provider)
                        }
                    }
                }

                if let provider = openRouterProvider {
                    self.openAISectionLabel("OpenRouter", count: "\(provider.accounts.count)") {
                        self.openRouterAddButton(provider: provider)
                    }

                    ForEach(provider.accounts) { account in
                        OpenRouterKeyRowView(
                            provider: provider,
                            account: account,
                            isActiveProvider: store.activeProvider?.id == provider.id &&
                                store.config.openAI.accountUsageMode == activationMode,
                            activeAccountId: store.config.active.providerId == provider.id ? store.config.active.accountId : provider.activeAccountId,
                            useActionTitle: activationMode == .hybridProvider ? L.providerUseAction : L.openAIAccountSwitchAction
                        ) {
                            Task {
                                await activateOpenRouterProvider(
                                    accountID: account.id,
                                    accountUsageMode: activationMode
                                )
                            }
                        } onSelectModel: { modelID in
                            Task {
                                await selectOpenRouterModel(
                                    modelID,
                                    accountID: account.id,
                                    accountUsageMode: activationMode
                                )
                            }
                        } onEditModel: {
                            openEditOpenRouterWindow(provider: provider, account: account)
                        } onDeleteAccount: {
                            confirmDeleteOpenRouterAccount(account)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func openAIAccountGroupsView(
        _ groups: [OpenAIAccountGroup],
        actionMode: CodexBarOpenAIAccountUsageMode
    ) -> some View {
        VStack(alignment: .leading, spacing: self.panelRowSpacing) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: self.panelRowSpacing) {
                    if let copyableEmail = OpenAIAccountPresentation.copyableAccountGroupEmail(group.email) {
                        Button {
                            self.copyOpenAIAccountGroupEmail(copyableEmail)
                        } label: {
                            self.openAIAccountGroupHeaderLabel(group)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .menuPanelHoverChrome(cornerRadius: 6)
                    } else {
                        self.openAIAccountGroupHeaderLabel(group)
                    }

                    ForEach(group.accounts) { account in
                        let rowState = OpenAIAccountPresentation.rowState(
                            for: account,
                            summary: self.runningThreadSummary,
                            accountUsageMode: actionMode
                        )
                        AccountRowView(
                            account: account,
                            rowState: rowState,
                            isRefreshing: refreshingAccounts.contains(account.id),
                            usageDisplayMode: self.store.config.openAI.usageDisplayMode
                        ) {
                            Task {
                                await activateAccount(account)
                            }
                        } onRefresh: {
                            Task { await refreshAccount(account, announceResult: true) }
                        } onReauth: {
                            reauthAccount(account)
                        } onDelete: {
                            confirmDeleteOpenAIAccount(account)
                        }
                    }
                }
            }
        }
    }

    private func openAIAccountGroupHeaderLabel(_ group: OpenAIAccountGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(group.email)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if let copiedConfirmation = OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: group.email,
                copiedEmail: self.copiedOpenAIAccountGroupEmail
            ) {
                Text(copiedConfirmation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .lineLimit(1)
            } else if let remark = group.headerQuotaRemark(now: now) {
                Text(remark)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, self.blockContentHorizontalInset)
    }

    private func openAIStatusBanner(
        _ banner: OpenAIStatusBannerPresentation,
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        let accentColor: Color = banner.tone == .warning ? .orange : .accentColor
        let iconName = banner.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Text(banner.message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = banner.actionTitle,
                   let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                }
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .menuPanelHoverChrome(cornerRadius: 5)
            }
        }
        .padding(.horizontal, self.blockContentHorizontalInset)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accentColor.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func copyOpenAIAccountGroupEmail(_ email: String) {
        guard let copiedEmail = OpenAIAccountGroupEmailCopyAction.perform(email: email) else {
            return
        }

        self.copiedOpenAIAccountGroupEmail = copiedEmail
        self.pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        let hideWorkItem = DispatchWorkItem {
            self.copiedOpenAIAccountGroupEmail = nil
            self.pendingCopiedOpenAIAccountGroupEmailHide = nil
        }
        self.pendingCopiedOpenAIAccountGroupEmailHide = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWorkItem)
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

    private func activateAccount(_ account: TokenAccount) async {
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

    private func activateCompatibleProvider(
        providerID: String,
        accountID: String,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) async {
        do {
            try await CompatibleProviderUseExecutor.execute {
                try self.store.activateCustomProvider(
                    providerID: providerID,
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

    private func activateOpenRouterProvider(
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

    private func useCurrentOAuthFromHybrid(_ account: TokenAccount) async {
        if self.store.config.openAI.accountUsageMode != .switchAccount ||
            self.store.config.activeProvider()?.kind != .openAIOAuth ||
            self.store.activeAccount()?.accountId != account.accountId {
            await self.activateAccount(account)
        }
    }

    private func selectOpenRouterModel(
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

    private func setOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) async {
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
            _ = try await self.codexDesktopLaunchProbeService.launchNewInstance()
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func clearStaleAggregateStickyIfNeeded() {
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

    private func confirmDeleteOpenAIAccount(_ account: TokenAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(target: .openAIAccount(account))
    }

    private func confirmDeleteCompatibleAccount(provider: CodexBarProvider, account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .customProviderAccount(
                providerID: provider.id,
                providerLabel: provider.label,
                accountID: account.id,
                accountLabel: account.label
            )
        )
    }

    private func confirmDeleteProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .customProvider(providerID: provider.id, providerLabel: provider.label)
        )
    }

    private func confirmDeleteOpenRouterAccount(_ account: CodexBarProviderAccount) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .openRouterAccount(accountID: account.id, accountLabel: account.label)
        )
    }

    private func confirmDeleteOpenRouterProvider(provider: CodexBarProvider) {
        self.pendingDeleteConfirmation = DeleteConfirmationRequest(
            target: .openRouterProvider(providerID: provider.id)
        )
    }

    private func performConfirmedDelete(_ request: DeleteConfirmationRequest) {
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

    private func startOAuthLogin() {
        self.requestCloseStatusItemMenu()
        OpenAILoginCoordinator.shared.start()
    }

    private func exportOpenAIAccountsCSV() {
        do {
            let snapshot = try self.oauthAccountService.exportAccountsForInterchange()
            guard snapshot.accounts.isEmpty == false else {
                self.setGenericError(L.noOpenAIAccountsToExport)
                return
            }

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

    private func importOpenAIAccountsCSV() {
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

    private func openSettingsWindow() {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "openai-settings",
            title: "\(L.settingsWindowTitle) \(AppVersionDisplay.versionAndBuild)",
            size: CGSize(width: 820, height: 620),
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

    private func openAddProviderWindow(defaultPreset: AddProviderPreset = .custom) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider",
            title: L.addProviderTitle,
            size: CGSize(width: 520, height: 620)
        ) {
            AddProviderSheet(store: store, defaultPreset: defaultPreset) { preset, label, baseURL, accountLabel, apiKey, openRouterSelection in
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

    private func openEditProviderWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "edit-provider-\(provider.id)",
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

    private func openAddProviderAccountWindow(provider: CodexBarProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider-account-\(provider.id)",
            title: "Add Account",
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

    private func openAddOpenRouterAccountWindow(provider: CodexBarProvider) {
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

    private func openEditOpenRouterWindow(provider: CodexBarProvider, account: CodexBarProviderAccount) {
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
        pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        pendingCopiedOpenAIAccountGroupEmailHide = nil
        copiedOpenAIAccountGroupEmail = nil
        isCostPanelPresented = false
        isCostSummaryHovered = false
        isCostPanelHovered = false
        DetachedWindowPresenter.shared.close(id: costPanelID)
    }

    private func triggerRefreshOnOpenIfNeeded() {
        guard openRefreshGate.shouldTriggerRefresh(isRefreshing: isRefreshing) else { return }
        Task { await refresh(force: true, announceResult: false) }
    }

    private func refresh(force: Bool = true, announceResult: Bool = false) async {
        let shouldRefreshOAuth = force || store.hasStaleOAuthUsageSnapshot(maxAge: usageRefreshInterval)
        let shouldRefreshLocalCost = force || store.localCostSummary.updatedAt == nil

        guard shouldRefreshOAuth || shouldRefreshLocalCost else {
            return
        }

        var didRequestLocalCostRefresh = false
        if shouldRefreshLocalCost {
            now = Date()
            didRequestLocalCostRefresh = true
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
        isRefreshing = true
        defer {
            store.endAllUsageRefresh()
            isRefreshing = false
        }
        let outcomes = await WhamService.shared.refreshAll(store: store)
        store.load()
        now = Date()
        if didRequestLocalCostRefresh == false {
            store.refreshLocalCostSummary(
                force: false,
                minimumInterval: usageRefreshInterval,
                refreshSessionCache: true
            )
        }
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(from: outcomes)
        )
    }

    private func refreshAccount(_ account: TokenAccount, announceResult: Bool) async {
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

    private func reauthAccount(_: TokenAccount) {
        self.startOAuthLogin()
    }

    private func requestCloseStatusItemMenu() {
        NotificationCenter.default.post(name: .codexbarRequestCloseStatusItemMenu, object: nil)
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

private enum AddProviderPreset: String, CaseIterable, Identifiable {
    case custom
    case openRouter

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .custom:
            return "Custom"
        case .openRouter:
            return "OpenRouter"
        }
    }
}

private struct OpenRouterSelectionPayload: Equatable {
    let apiKey: String
    let selectedModelID: String?
    let pinnedModelIDs: [String]
    let cachedModelCatalog: [CodexBarOpenRouterModel]
    let fetchedAt: Date?
}

private func normalizedOpenRouterModelID(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func orderedPinnedOpenRouterModelIDs(
    selectedModelIDs: Set<String>,
    cachedModels: [CodexBarOpenRouterModel]
) -> [String] {
    CodexBarProvider.orderedOpenRouterModelIDs(
        Array(selectedModelIDs),
        cachedModelCatalog: cachedModels
    )
}

private func makeOpenRouterSelectionPayload(
    apiKey: String,
    selectedModelIDs: Set<String>,
    currentSelectedModelID: String?,
    cachedModels: [CodexBarOpenRouterModel],
    fetchedAt: Date?
) -> OpenRouterSelectionPayload? {
    guard let normalizedAPIKey = normalizedOpenRouterModelID(apiKey) else {
        return nil
    }

    let orderedPinnedModelIDs = orderedPinnedOpenRouterModelIDs(
        selectedModelIDs: selectedModelIDs,
        cachedModels: cachedModels
    )
    let normalizedCurrentModelID = normalizedOpenRouterModelID(currentSelectedModelID ?? "")
    let selectedModelID: String?
    if let normalizedCurrentModelID,
       orderedPinnedModelIDs.contains(normalizedCurrentModelID) {
        selectedModelID = normalizedCurrentModelID
    } else {
        selectedModelID = nil
    }

    return OpenRouterSelectionPayload(
        apiKey: normalizedAPIKey,
        selectedModelID: selectedModelID,
        pinnedModelIDs: orderedPinnedModelIDs,
        cachedModelCatalog: cachedModels,
        fetchedAt: fetchedAt
    )
}

struct OpenRouterModelPickerDisplay: Equatable {
    static func models(
        cachedModels: [CodexBarOpenRouterModel],
        selectedModelIDs: Set<String>,
        initiallyPinnedModelIDs: [String],
        searchText: String
    ) -> [CodexBarOpenRouterModel] {
        let catalogByID = Dictionary(uniqueKeysWithValues: cachedModels.map { ($0.id, $0) })
        let initialPinnedSet = Set(initiallyPinnedModelIDs)
        let initiallyPinnedModels: [CodexBarOpenRouterModel] = initiallyPinnedModelIDs.compactMap { modelID in
            guard selectedModelIDs.contains(modelID) else { return nil }
            return catalogByID[modelID]
        }
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearch.isEmpty == false else {
            let laterSelectedModels = cachedModels.filter {
                selectedModelIDs.contains($0.id) && initialPinnedSet.contains($0.id) == false
            }
            return initiallyPinnedModels + laterSelectedModels
        }

        let matchedModels = cachedModels.filter { model in
            initialPinnedSet.contains(model.id) == false &&
                (
                    model.id.localizedCaseInsensitiveContains(trimmedSearch) ||
                    model.name.localizedCaseInsensitiveContains(trimmedSearch)
                )
        }
        return initiallyPinnedModels + matchedModels
    }
}

private struct OpenRouterModelPickerSection: View {
    @ObservedObject var store: TokenStore
    @Binding var apiKey: String
    @Binding var selectedModelIDs: Set<String>
    @Binding var cachedModels: [CodexBarOpenRouterModel]
    @Binding var fetchedAt: Date?

    let initiallyPinnedModelIDs: [String]
    let refreshAction: (String) async throws -> OpenRouterModelCatalogSnapshot

    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var note: String?
    @State private var autoRefreshAttemptedAPIKey: String?

    private var visibleModels: [CodexBarOpenRouterModel] {
        OpenRouterModelPickerDisplay.models(
            cachedModels: self.cachedModels,
            selectedModelIDs: self.selectedModelIDs,
            initiallyPinnedModelIDs: self.initiallyPinnedModelIDs,
            searchText: self.searchText
        )
    }

    private var statusText: String {
        if self.cachedModels.isEmpty {
            return L.openRouterModelPickerNoCache
        }
        return L.openRouterModelPickerCacheStatus(count: self.cachedModels.count, fetchedAt: self.fetchedAt)
    }

    private var selectedCountText: String {
        L.openRouterModelPickerSelectedCount(self.selectedModelIDs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(self.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Button(isRefreshing ? L.openRouterModelPickerRefreshing : L.openRouterModelPickerRefresh) {
                    Task {
                        await self.refreshModels()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                TextField(L.openRouterModelPickerSearchPlaceholder, text: $searchText)
                Text(self.selectedCountText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(self.visibleModels) { model in
                        Toggle(isOn: self.bindingForModel(model.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(model.id)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 7)
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if model.id != self.visibleModels.last?.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }

                    if self.visibleModels.isEmpty {
                        Text(self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.openRouterModelPickerSearchPrompt : L.openRouterModelPickerNoMatches)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 260)

            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            self.refreshIfNeededForEmptyCache()
        }
        .onChange(of: apiKey) { _ in
            self.refreshIfNeededForEmptyCache()
        }
        .onChange(of: cachedModels) { _ in
            self.refreshIfNeededForEmptyCache()
        }
    }

    private func toggleModel(_ modelID: String) {
        if self.selectedModelIDs.contains(modelID) {
            self.selectedModelIDs.remove(modelID)
        } else {
            self.selectedModelIDs.insert(modelID)
        }
    }

    private func bindingForModel(_ modelID: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedModelIDs.contains(modelID) },
            set: { isSelected in
                if isSelected {
                    self.selectedModelIDs.insert(modelID)
                } else {
                    self.selectedModelIDs.remove(modelID)
                }
            }
        )
    }

    private func refreshIfNeededForEmptyCache() {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.cachedModels.isEmpty,
              trimmedAPIKey.isEmpty == false,
              self.isRefreshing == false,
              self.autoRefreshAttemptedAPIKey != trimmedAPIKey else {
            return
        }

        self.autoRefreshAttemptedAPIKey = trimmedAPIKey
        Task {
            await self.refreshModels()
        }
    }

    private func refreshModels() async {
        self.isRefreshing = true
        self.note = nil
        defer {
            self.isRefreshing = false
        }

        do {
            let snapshot = try await self.refreshAction(self.apiKey)
            self.cachedModels = snapshot.models
            self.fetchedAt = snapshot.fetchedAt
            self.note = nil
        } catch {
            self.note = L.openRouterModelPickerRefreshFailure
        }
    }
}

private struct AddProviderSheet: View {
    @ObservedObject var store: TokenStore

    private let isEditing: Bool
    @State private var preset: AddProviderPreset
    @State private var label = ""
    @State private var baseURL = ""
    @State private var accountLabel = ""
    @State private var apiKey = ""
    @State private var openRouterSelectedModelIDs: Set<String>
    @State private var openRouterSelectedModelID: String?
    @State private var openRouterCachedModels: [CodexBarOpenRouterModel]
    @State private var openRouterFetchedAt: Date?
    private let openRouterSelectionInitialPinnedModelIDs: [String]

    let onSave: (AddProviderPreset, String, String, String, String, OpenRouterSelectionPayload?) -> Void
    let onCancel: () -> Void

    init(
        store: TokenStore,
        defaultPreset: AddProviderPreset = .custom,
        onSave: @escaping (AddProviderPreset, String, String, String, String, OpenRouterSelectionPayload?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._preset = State(initialValue: defaultPreset)
        self.store = store
        self.isEditing = false
        self.onSave = onSave
        self.onCancel = onCancel
        self._openRouterSelectedModelIDs = State(initialValue: [])
        self._openRouterSelectedModelID = State(initialValue: nil)
        self._openRouterCachedModels = State(initialValue: [])
        self._openRouterFetchedAt = State(initialValue: nil)
        self.openRouterSelectionInitialPinnedModelIDs = []
        if defaultPreset == .openRouter {
            self._label = State(initialValue: "OpenRouter")
        }
    }

    init(
        store: TokenStore,
        editingProvider provider: CodexBarProvider,
        onSave: @escaping (AddProviderPreset, String, String, String, String, OpenRouterSelectionPayload?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let activeAccount = provider.activeAccount
        let openRouterSelection = activeAccount.map { provider.openRouterSelection(forAccountID: $0.id) } ??
            provider.openRouterProviderLevelSelection
        self.store = store
        self.isEditing = true
        self.onSave = onSave
        self.onCancel = onCancel
        self._preset = State(initialValue: provider.kind == .openRouter ? .openRouter : .custom)
        self._label = State(initialValue: provider.label)
        self._baseURL = State(initialValue: provider.baseURL ?? "")
        self._accountLabel = State(initialValue: activeAccount?.label ?? "")
        self._apiKey = State(initialValue: activeAccount?.apiKey ?? "")
        self._openRouterSelectedModelIDs = State(initialValue: Set(openRouterSelection.pinnedModelIDs))
        self._openRouterSelectedModelID = State(initialValue: openRouterSelection.effectiveModelID)
        self._openRouterCachedModels = State(initialValue: openRouterSelection.cachedModelCatalog)
        self._openRouterFetchedAt = State(initialValue: openRouterSelection.modelCatalogFetchedAt)
        self.openRouterSelectionInitialPinnedModelIDs = openRouterSelection.pinnedModelIDs
    }

    private var isOpenRouter: Bool {
        self.preset == .openRouter
    }

    private var canSave: Bool {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return false }

        if self.isOpenRouter {
            return true
        }

        return self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var openRouterSelectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.apiKey,
            selectedModelIDs: self.openRouterSelectedModelIDs,
            currentSelectedModelID: self.openRouterSelectedModelID,
            cachedModels: self.openRouterCachedModels,
            fetchedAt: self.openRouterFetchedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.isEditing == false {
                Picker("Preset", selection: $preset) {
                    ForEach(AddProviderPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            if isOpenRouter {
                OpenRouterKeyFormFields(apiKey: $apiKey, accountLabel: $accountLabel)
                OpenRouterModelPickerSection(
                    store: self.store,
                    apiKey: $apiKey,
                    selectedModelIDs: $openRouterSelectedModelIDs,
                    cachedModels: $openRouterCachedModels,
                    fetchedAt: $openRouterFetchedAt,
                    initiallyPinnedModelIDs: openRouterSelectionInitialPinnedModelIDs,
                    refreshAction: { apiKey in
                        try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                    }
                )
            } else {
                ProviderFormRow(label: L.providerNameLabel) {
                    TextField(L.providerNameLabel, text: $label)
                }
                ProviderFormRow(label: L.providerBaseURLLabel) {
                    TextField(L.providerBaseURLLabel, text: $baseURL)
                }
                ProviderFormRow(label: L.providerAccountLabel) {
                    TextField(L.providerAccountLabel, text: $accountLabel)
                }
                ProviderFormRow(label: L.providerAPIKeyLabel) {
                    SecureField(L.providerAPIKeyLabel, text: $apiKey)
                }
            }

            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
                Button(self.isEditing ? L.saveProviderAction : L.addProviderAction) {
                    onSave(
                        preset,
                        label,
                        baseURL,
                        accountLabel,
                        apiKey,
                        self.isOpenRouter ? self.openRouterSelectionPayload : nil
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: self.isOpenRouter ? 460 : 360)
        .onChange(of: preset) { newValue in
            if newValue == .openRouter {
                self.label = "OpenRouter"
                self.baseURL = ""
            }
        }
    }
}

private struct OpenRouterKeyFormFields: View {
    @Binding var apiKey: String
    @Binding var accountLabel: String

    var body: some View {
        ProviderFormRow(label: L.providerAPIKeyLabel) {
            SecureField(L.providerAPIKeyLabel, text: $apiKey)
        }
        ProviderFormRow(label: L.openRouterKeyLabelOptional) {
            TextField(L.openRouterKeyLabelPlaceholder, text: $accountLabel)
        }
    }
}

private struct ProviderFormRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct AddProviderAccountSheet: View {
    let provider: CodexBarProvider
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var label = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account · \(provider.label)")
                .font(.headline)

            TextField("Account label", text: $label)
            SecureField("API key", text: $apiKey)

            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
                Button(L.saveProviderAction) {
                    onSave(label, apiKey)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct OpenRouterKeyEditorSheet: View {
    let provider: CodexBarProvider
    @ObservedObject var store: TokenStore
    let onSave: (String, OpenRouterSelectionPayload) -> Void
    let onCancel: () -> Void

    @State private var apiKey = ""
    @State private var accountLabel = ""
    @State private var selectedModelIDs: Set<String>
    @State private var selectedModelID: String?
    @State private var cachedModels: [CodexBarOpenRouterModel]
    @State private var fetchedAt: Date?
    private let initialPinnedModelIDs: [String]

    init(
        provider: CodexBarProvider,
        store: TokenStore,
        onSave: @escaping (String, OpenRouterSelectionPayload) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        let inheritedCache = provider.openRouterProviderLevelSelection
        self._selectedModelIDs = State(initialValue: [])
        self._selectedModelID = State(initialValue: nil)
        self._cachedModels = State(initialValue: inheritedCache.cachedModelCatalog)
        self._fetchedAt = State(initialValue: inheritedCache.modelCatalogFetchedAt)
        self.initialPinnedModelIDs = []
    }

    init(
        provider: CodexBarProvider,
        store: TokenStore,
        account: CodexBarProviderAccount,
        onSave: @escaping (String, OpenRouterSelectionPayload) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        let selection = provider.openRouterSelection(forAccountID: account.id)
        self._apiKey = State(initialValue: account.apiKey ?? "")
        self._accountLabel = State(initialValue: account.label)
        self._selectedModelID = State(initialValue: selection.effectiveModelID)
        self._selectedModelIDs = State(initialValue: Set(selection.pinnedModelIDs))
        self._cachedModels = State(initialValue: selection.cachedModelCatalog)
        self._fetchedAt = State(initialValue: selection.modelCatalogFetchedAt)
        self.initialPinnedModelIDs = selection.pinnedModelIDs
    }

    private var canSave: Bool {
        normalizedOpenRouterModelID(self.apiKey) != nil
    }

    private var selectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.apiKey,
            selectedModelIDs: self.selectedModelIDs,
            currentSelectedModelID: self.selectedModelID,
            cachedModels: self.cachedModels,
            fetchedAt: self.fetchedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OpenRouterKeyFormFields(apiKey: $apiKey, accountLabel: $accountLabel)

            OpenRouterModelPickerSection(
                store: self.store,
                    apiKey: $apiKey,
                    selectedModelIDs: $selectedModelIDs,
                    cachedModels: $cachedModels,
                    fetchedAt: $fetchedAt,
                    initiallyPinnedModelIDs: initialPinnedModelIDs,
                    refreshAction: { apiKey in
                        try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                    }
            )

            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
                Button(L.saveProviderAction) {
                    if let selectionPayload {
                        onSave(accountLabel, selectionPayload)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct OpenRouterKeyRowView: View {
    let provider: CodexBarProvider
    let account: CodexBarProviderAccount
    let isActiveProvider: Bool
    let activeAccountId: String?
    var useActionTitle: String = L.useBtn
    let onActivate: () -> Void
    let onSelectModel: (String) -> Void
    let onEditModel: () -> Void
    let onDeleteAccount: () -> Void
    @State private var isHoveringProvider = false
    @State private var hoveringModelID: String?
    private let primaryActionWidth = MenuPanelLayout.primaryActionWidth

    private var isCurrentAccount: Bool {
        self.isActiveProvider && self.account.id == self.activeAccountId
    }

    private var modelOptions: [CodexBarOpenRouterModel] {
        self.provider.openRouterMenuModelOptions(forAccountID: self.account.id)
    }

    private func displayName(for modelID: String) -> String {
        self.modelOptions.first(where: { $0.id == modelID })?.name ?? modelID
    }

    private func modelRowBackground(for modelID: String) -> Color {
        self.hoveringModelID == modelID ? Color.secondary.opacity(0.08) : Color.clear
    }

    private func isCurrentModel(_ model: CodexBarOpenRouterModel) -> Bool {
        self.isCurrentAccount &&
            self.provider.openRouterEffectiveModelID(forAccountID: self.account.id) == model.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.isCurrentAccount ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                Text(account.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(self.isCurrentAccount ? .accentColor : .primary)

                Text(account.maskedAPIKey)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: onEditModel) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .menuPanelHoverChrome(cornerRadius: 5)
            }

            if self.modelOptions.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(self.modelOptions) { model in
                        self.modelActionRow(model)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(L.openRouterNoModelsSelected)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(L.openRouterManageModelsAction) {
                        self.onEditModel()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .font(.system(size: 9, weight: .medium))
                    .menuPanelHoverChrome(cornerRadius: 6)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    self.isCurrentAccount
                        ? Color.accentColor.opacity(self.isHoveringProvider ? 0.11 : 0.07)
                        : Color.secondary.opacity(self.isHoveringProvider ? 0.08 : 0.04)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    self.isCurrentAccount ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.055),
                    lineWidth: 0.6
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { self.isHoveringProvider = $0 }
        .contextMenu {
            Button {
                onEditModel()
            } label: {
                Label(L.editBtn, systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDeleteAccount()
            } label: {
                Label(L.deleteBtn, systemImage: "trash")
            }
        }
    }

    private func modelActionRow(_ model: CodexBarOpenRouterModel) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if model.name != model.id {
                    Text(model.id)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if self.isCurrentModel(model) {
                MenuPanelCurrentIndicator(width: self.primaryActionWidth)
            } else {
                Button {
                    self.onSelectModel(model.id)
                } label: {
                    Text(useActionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .font(.system(size: 9, weight: .medium))
                .frame(width: self.primaryActionWidth, alignment: .center)
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(self.modelRowBackground(for: model.id))
        )
        .onHover { hovering in
            self.hoveringModelID = hovering ? model.id : nil
        }
    }
}
