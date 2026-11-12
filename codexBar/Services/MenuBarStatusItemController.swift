import AppKit
import Carbon
import Combine
import SwiftUI

extension Notification.Name {
    static let codexbarRequestCloseStatusItemMenu = Notification.Name("lzl.codexbar.status-item-menu.close")
    static let codexbarStatusItemMeasuredHeightDidChange = Notification.Name("lzl.codexbar.status-item-menu.height-changed")
    static let codexbarStatusItemAvailableContentHeightDidChange = Notification.Name("lzl.codexbar.status-item-menu.available-content-height-changed")
    static let codexbarRequestStatusItemLayoutRefresh = Notification.Name("lzl.codexbar.status-item-menu.layout-refresh")
    static let codexbarStatusItemMenuWillOpen = Notification.Name("lzl.codexbar.status-item-menu.will-open")
    static let codexbarStatusItemMenuDidClose = Notification.Name("lzl.codexbar.status-item-menu.did-close")
}

private enum MenuBarGlobalShortcut {
    static let keyCode = UInt32(kVK_ANSI_B)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let signature: OSType = 0x43444252
    static let identifier: UInt32 = 1
}

enum MenuBarPopoverSizing {
    static let resizeTolerance: CGFloat = 2
    static let defaultHeight: CGFloat = 520
    static let minimumHeight: CGFloat = 1
    static let maximumHeight: CGFloat = 640
    static let maximumVisibleScreenHeightRatio: CGFloat = 0.8
    static let verticalMargin: CGFloat = 12
    static let topContentInset: CGFloat = 16
    static let bottomContentInset: CGFloat = 16
    static let headerHeight: CGFloat = 24
    static let headerDividerHeight: CGFloat = 0
    static let footerDividerHeight: CGFloat = 0
    static let footerHeight: CGFloat = 0
    static let usageSummaryHeight: CGFloat = 70

    static func contentHeightLimit(
        availableHeight: CGFloat?,
        visibleScreenHeight: CGFloat?
    ) -> CGFloat? {
        let normalizedAvailableHeight = availableHeight.map { max(self.minimumHeight, $0) }
        let screenHeightCap = visibleScreenHeight.map {
            max(self.minimumHeight, $0 * self.maximumVisibleScreenHeightRatio)
        }

        switch (normalizedAvailableHeight, screenHeightCap) {
        case let (availableHeight?, screenHeightCap?):
            return min(availableHeight, screenHeightCap)
        case let (availableHeight?, nil):
            return availableHeight
        case let (nil, screenHeightCap?):
            return screenHeightCap
        case (nil, nil):
            return nil
        }
    }

    static func clampedHeight(desiredHeight: CGFloat, availableHeight: CGFloat?) -> CGFloat {
        let maxHeight = max(self.minimumHeight, availableHeight ?? self.maximumHeight)
        return min(max(desiredHeight, self.minimumHeight), maxHeight)
    }

    static func targetHeight(
        measuredContentHeight: CGFloat,
        availableHeight: CGFloat?
    ) -> CGFloat {
        self.clampedHeight(
            desiredHeight: measuredContentHeight,
            availableHeight: availableHeight
        )
    }

    static func resizeHeight(measuredContentHeight: CGFloat, currentHeight: CGFloat, availableHeight: CGFloat?) -> CGFloat? {
        let target = self.targetHeight(measuredContentHeight: measuredContentHeight, availableHeight: availableHeight)
        return abs(target - currentHeight) > self.resizeTolerance ? target : nil
    }

    static func initialSize(availableHeight: CGFloat?) -> NSSize {
        NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: self.clampedHeight(
                desiredHeight: self.defaultHeight,
                availableHeight: availableHeight
            )
        )
    }

    static func initialContentHeight(measuredContentHeight: CGFloat?) -> CGFloat {
        guard let measuredContentHeight,
              measuredContentHeight > self.minimumHeight else {
            return self.defaultHeight
        }
        return measuredContentHeight
    }

    static func middleContentHeight(lockedContentHeight: CGFloat, fixedContentHeight: CGFloat = headerHeight) -> CGFloat {
        max(lockedContentHeight - topContentInset - bottomContentInset - fixedContentHeight, minimumHeight)
    }

    static func preservingTopScrollOriginY(
        topOffset: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        let maxOriginY = max(documentHeight - viewportHeight, 0)
        let originY = isFlipped
            ? topOffset
            : documentHeight - viewportHeight - topOffset
        return min(max(originY, 0), maxOriginY)
    }

    static func flexibleSectionHeightCap(
        totalContentHeight: CGFloat,
        flexibleSectionHeight: CGFloat,
        availableHeight: CGFloat?
    ) -> CGFloat? {
        guard let availableHeight,
              totalContentHeight > 0,
              flexibleSectionHeight > 0 else {
            return nil
        }

        let fixedHeight = max(totalContentHeight - flexibleSectionHeight, 0)
        return max(availableHeight - fixedHeight, self.minimumHeight)
    }
}

private final class StatusItemHotKeyController {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        self.stop()
    }

    func start() {
        guard self.hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == MenuBarGlobalShortcut.signature,
                      hotKeyID.id == MenuBarGlobalShortcut.identifier else {
                    return noErr
                }

                let controller = Unmanaged<StatusItemHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.action()
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &self.eventHandler
        )
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(
            signature: MenuBarGlobalShortcut.signature,
            id: MenuBarGlobalShortcut.identifier
        )
        let registerStatus = RegisterEventHotKey(
            MenuBarGlobalShortcut.keyCode,
            MenuBarGlobalShortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &self.hotKeyRef
        )
        if registerStatus != noErr {
            if let eventHandler = self.eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.hotKeyRef = nil
        }
    }

    func stop() {
        if let hotKeyRef = self.hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = self.eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarStatusItemController()

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var lockedPopoverContentHeight: CGFloat?
    private var resizeWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private lazy var hotKeyController = StatusItemHotKeyController { [weak self] in
        self?.togglePopoverFromKeyboardShortcut()
    }

    private override init() {
        super.init()
        self.popover.behavior = .transient
        self.popover.delegate = self
    }

    func start() {
        guard self.statusItem == nil else {
            self.applyVisibilityPreference()
            self.updateAppearance()
            return
        }

        let userDefaults = UserDefaults.standard
        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: userDefaults)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = MenuBarStatusItemIdentity.statusItemAutosaveName
        item.behavior = MenuBarStatusItemIdentity.statusItemBehavior

        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        button.target = self
        button.action = #selector(self.togglePopover(_:))
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(MenuBarStatusItemIdentity.accessibilityLabel)
        button.setAccessibilityIdentifier(MenuBarStatusItemIdentity.accessibilityIdentifier)

        self.statusItem = item
        self.applyVisibilityPreference(userDefaults: userDefaults)
        self.popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(TokenStore.shared)
                .environmentObject(OAuthManager.shared)
                .environmentObject(UpdateCoordinator.shared)
        )

        self.bindState()
        self.updateAppearance()
        self.hotKeyController.start()
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_host_started",
            fields: ["pid": getpid()]
        )
    }

    func stop() {
        self.hotKeyController.stop()
        self.popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        self.cancellables.removeAll()
    }

    private func bindState() {
        guard self.cancellables.isEmpty else { return }

        TokenStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAppearanceRefresh()
            }
            .store(in: &self.cancellables)

        UpdateCoordinator.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAppearanceRefresh()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarRequestCloseStatusItemMenu)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.closePopover()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarStatusItemMeasuredHeightDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, self.popover.isShown,
                      let height = notification.userInfo?["height"] as? CGFloat else { return }
                self.schedulePopoverResize(measuredHeight: height)
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarRequestStatusItemLayoutRefresh)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.publishLockedPopoverContentHeight()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyVisibilityPreference()
            }
            .store(in: &self.cancellables)
    }

    private func scheduleAppearanceRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.updateAppearance()
        }
    }

    private func updateAppearance() {
        guard let button = self.statusItem?.button else { return }

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: TokenStore.shared.accounts,
            activeProvider: TokenStore.shared.activeProvider,
            usageDisplayMode: TokenStore.shared.config.openAI.usageDisplayMode,
            accountUsageMode: TokenStore.shared.config.openAI.accountUsageMode,
            updateAvailable: UpdateCoordinator.shared.pendingAvailability != nil
        )

        button.image = presentation.makeTemplateImage(accessibilityDescription: MenuBarStatusItemIdentity.accessibilityLabel)
        button.contentTintColor = nil
        button.attributedTitle = presentation.attributedTitle
    }

    private func applyVisibilityPreference(userDefaults: UserDefaults = .standard) {
        guard let statusItem = self.statusItem else { return }

        let visible = Self.resolvedVisibilityPreference(userDefaults: userDefaults)
        if visible == false {
            self.closePopover()
        }
        statusItem.isVisible = visible
    }

    nonisolated static func resolvedVisibilityPreference(userDefaults: UserDefaults = .standard) -> Bool {
        MenuBarStatusItemIdentity.resolvedVisibility(domain: userDefaults.dictionaryRepresentation())
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        if self.popover.isShown {
            self.closePopover(sender)
            return
        }
        self.showPopover(trigger: "button")
    }

    private func togglePopoverFromKeyboardShortcut() {
        if self.statusItem == nil {
            self.start()
        }
        if self.popover.isShown {
            self.closePopover()
            return
        }
        self.showPopover(trigger: "keyboard_shortcut")
    }

    private func showPopover(trigger: String) {
        guard let button = self.statusItem?.button else { return }

        self.updateAppearance()
        TokenStore.shared.load()
        TokenStore.shared.markActiveAccount()
        let availableHeight = self.availablePopoverHeightBelowStatusItem()
        // Measure the real composition at its final width, before opening. This value is
        // local to this opening and never enters the shown-menu measurement cache.
        let measurementHost = NSHostingView(rootView: MenuBarView(measuresNaturalHeight: true)
            .environmentObject(TokenStore.shared)
            .environmentObject(OAuthManager.shared)
            .environmentObject(UpdateCoordinator.shared))
        measurementHost.frame.size.width = MenuBarStatusItemIdentity.popoverContentWidth
        let naturalHeight = measurementHost.fittingSize.height
        let initialSize = NSSize(width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: MenuBarPopoverSizing.targetHeight(measuredContentHeight: naturalHeight, availableHeight: availableHeight))

        self.popover.contentSize = initialSize
        self.lockedPopoverContentHeight = initialSize.height
        self.publishLockedPopoverContentHeight()
        NSApp.activate(ignoringOtherApps: true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        self.popover.contentViewController?.view.window?.makeKey()
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_menu_opened",
            fields: [
                "pid": getpid(),
                "trigger": trigger,
            ]
        )
    }

    private func closePopover(_ sender: AnyObject? = nil) {
        guard self.popover.isShown else { return }
        self.popover.performClose(sender)
    }

    private func availablePopoverHeightBelowStatusItem() -> CGFloat? {
        guard let button = self.statusItem?.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        let visibleFrame = screen.visibleFrame
        return MenuBarPopoverSizing.contentHeightLimit(
            availableHeight: buttonFrameOnScreen.minY - visibleFrame.minY - MenuBarPopoverSizing.verticalMargin,
            visibleScreenHeight: visibleFrame.height
        )
    }

    func popoverWillShow(_ notification: Notification) {
        NotificationCenter.default.post(name: .codexbarStatusItemMenuWillOpen, object: self)
    }

    func popoverDidClose(_ notification: Notification) {
        self.statusItem?.button?.highlight(false)
        self.resizeWorkItem?.cancel()
        self.resizeWorkItem = nil
        self.lockedPopoverContentHeight = nil
        self.publishAvailableContentHeight(nil)
        NotificationCenter.default.post(name: .codexbarStatusItemMenuDidClose, object: self)
    }

    private func schedulePopoverResize(measuredHeight: CGFloat) {
        self.resizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.popover.isShown else { return }
            guard let height = MenuBarPopoverSizing.resizeHeight(
                measuredContentHeight: measuredHeight,
                currentHeight: self.popover.contentSize.height,
                availableHeight: self.availablePopoverHeightBelowStatusItem()
            ) else { return }
            self.lockedPopoverContentHeight = height
            self.publishLockedPopoverContentHeight()
            self.popover.contentSize = NSSize(width: MenuBarStatusItemIdentity.popoverContentWidth, height: height)
        }
        self.resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func publishLockedPopoverContentHeight() {
        self.publishAvailableContentHeight(
            self.lockedPopoverContentHeight ?? self.popover.contentSize.height
        )
    }

    private func publishAvailableContentHeight(_ height: CGFloat?) {
        var userInfo: [AnyHashable: Any]?
        if let height {
            userInfo = ["height": height]
        }
        NotificationCenter.default.post(
            name: .codexbarStatusItemAvailableContentHeightDidChange,
            object: self,
            userInfo: userInfo
        )
    }
}
