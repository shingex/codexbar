import AppKit
import SwiftUI

private final class HoverPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct DetachedWindowConfiguration {
    var isResizable = false
    var contentMinSize: CGSize?
    var resetsContentSizeOnReuse = true
    var level: NSWindow.Level = .floating
    var activatesApp = true
    var makesKey = true

    static let standard = Self()

    static let openAISettings = Self(
        isResizable: true,
        contentMinSize: CGSize(width: 700, height: 280),
        resetsContentSizeOnReuse: false,
        level: .normal
    )
}

final class DetachedWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = DetachedWindowPresenter()

    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        configuration: DetachedWindowConfiguration = .standard,
        @ViewBuilder content: () -> Content
    ) {
        let anyView = AnyView(content())

        if let existing = self.windows[id] {
            existing.title = title
            self.applyStandardWindowConfiguration(configuration, to: existing)
            if configuration.resetsContentSizeOnReuse {
                existing.setContentSize(size)
            }
            if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = anyView
            } else {
                existing.contentViewController = NSHostingController(rootView: anyView)
            }
            self.showWindow(existing, configuration: configuration)
            return
        }

        let controller = NSHostingController(rootView: anyView)
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.isReleasedWhenClosed = false
        self.applyStandardWindowConfiguration(configuration, to: window)
        window.setContentSize(size)
        window.center()
        window.delegate = self

        self.windows[id] = window
        self.showWindow(window, configuration: configuration)
    }

    func showHoverPanel<Content: View>(id: String, size: CGSize, origin: CGPoint, @ViewBuilder content: () -> Content) {
        let anyView = AnyView(content())

        if let existing = self.windows[id] {
            self.applyHoverPanelWindowConfiguration(to: existing)
            if existing.frame.size != size {
                existing.setContentSize(size)
            }
            if existing.frame.origin != origin {
                existing.setFrameOrigin(origin)
            }
            if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = anyView
            } else {
                existing.contentViewController = self.hoverPanelHostingController(rootView: anyView)
            }
            self.configureHoverPanelContent(in: existing)
            existing.orderFront(nil)
            return
        }

        let controller = self.hoverPanelHostingController(rootView: anyView)
        let window = HoverPanelWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.contentViewController = controller
        self.applyHoverPanelWindowConfiguration(to: window)
        self.configureHoverPanelContent(in: window)
        window.delegate = self

        self.windows[id] = window
        window.orderFront(nil)
    }

    func close(id: String) {
        guard let window = self.windows[id] else { return }
        window.close()
        self.windows.removeValue(forKey: id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        self.windows.removeValue(forKey: id)
    }

    private func applyStandardWindowConfiguration(
        _ configuration: DetachedWindowConfiguration,
        to window: NSWindow
    ) {
        window.styleMask = Self.styleMask(for: configuration)
        window.contentMinSize = configuration.contentMinSize ?? .zero
        window.level = configuration.level
    }

    private static func styleMask(for configuration: DetachedWindowConfiguration) -> NSWindow.StyleMask {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if configuration.isResizable {
            styleMask.insert(.resizable)
        }
        return styleMask
    }

    private func showWindow(_ window: NSWindow, configuration: DetachedWindowConfiguration) {
        if configuration.activatesApp {
            NSApp?.activate(ignoringOtherApps: true)
        }
        if configuration.makesKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func hoverPanelHostingController(rootView: AnyView) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: rootView)
        self.configureHoverPanelHostingView(controller.view)
        return controller
    }

    private func applyHoverPanelWindowConfiguration(to window: NSWindow) {
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func configureHoverPanelContent(in window: NSWindow) {
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.layer?.masksToBounds = false
        window.contentView?.clipsToBounds = false

        if let hostingView = window.contentViewController?.view {
            self.configureHoverPanelHostingView(hostingView)
        }
    }

    private func configureHoverPanelHostingView(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = false
        view.clipsToBounds = false
    }
}
