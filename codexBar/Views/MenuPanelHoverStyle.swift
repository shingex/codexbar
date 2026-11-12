import AppKit
import SwiftUI

enum MenuPanelLayout {
    static let horizontalInset: CGFloat = 16
    static let blockContentHorizontalInset: CGFloat = 10
    static let blockVerticalInset: CGFloat = 8
    static let compactSectionTopInset: CGFloat = 4
    static let sectionActionButtonSize: CGFloat = 20
    static let sectionCountSlotWidth: CGFloat = 44
    static let primaryActionWidth: CGFloat = 52
    static let primaryActionHeight: CGFloat = 24
    static let compactRowHeight: CGFloat = 24
    static let compactRowSpacing: CGFloat = 2
}

struct MenuPanelCurrentIndicator: View {
    var width: CGFloat = MenuPanelLayout.primaryActionWidth

    var body: some View {
        HStack(spacing: 3) {
            Hugeicons.check.image(size: 9)
                .accessibilityHidden(true)
            Text(L.thirdPartyCurrentModel)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(.accentColor)
        .frame(maxWidth: .infinity)
        .frame(height: MenuPanelLayout.primaryActionHeight)
        .frame(width: self.width, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

struct MenuPanelSectionAddIcon: View {
    var size: CGFloat = MenuPanelLayout.sectionActionButtonSize
    var fontSize: CGFloat = 12

    var body: some View {
        Hugeicons.addSquare.image(size: self.fontSize)
            .frame(width: self.size, height: self.size)
            .contentShape(Rectangle())
    }
}

struct MenuPanelPrimaryActionButtonStyle: ButtonStyle {
    var tint: Color = Color(white: 0.15)
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        MenuPanelPrimaryActionButtonBody(
            configuration: configuration,
            tint: self.tint,
            cornerRadius: self.cornerRadius
        )
    }
}

private struct MenuPanelPrimaryActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let cornerRadius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        self.configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .strokeBorder(self.borderColor, lineWidth: self.isHovering ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: self.cornerRadius))
            .opacity(self.isEnabled ? 1 : 0.48)
            .menuPanelHoverRegion { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        guard self.isEnabled else { return self.tint.opacity(0.45) }
        if self.configuration.isPressed {
            return self.tint.opacity(0.78)
        }
        if self.isHovering {
            return self.tint.opacity(0.88)
        }
        return self.tint
    }

    private var borderColor: Color {
        Color.white.opacity(self.configuration.isPressed ? 0.40 : 0.30)
    }
}

/// AppKit owns tracking even when a native Menu button handles the pointer.
final class MenuPanelHoverTrackingView: NSView {
    static let resetNotification = Notification.Name("codexbar.menuPanel.resetHover")
    private var resetObserver: NSObjectProtocol?
    var cornerRadius: CGFloat = 6
    var hoverOpacity: CGFloat = 0.12
    var isEnabled = true
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.resetObserver = NotificationCenter.default.addObserver(forName: Self.resetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clearHover()
        }
    }

    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.clearHover()
    }

    override func viewDidHide() {
        super.viewDidHide()
        self.clearHover()
    }

    private func clearHover() {
        self.isHovered = false
        self.updateAppearance()
        self.onHoverChanged?(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { self.removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard self.isEnabled else { return }
        self.isHovered = true
        self.updateAppearance()
        self.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        self.isHovered = false
        self.updateAppearance()
        self.onHoverChanged?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.updateAppearance()
    }

    func updateAppearance() {
        self.layer?.cornerRadius = self.cornerRadius
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = (self.isEnabled && self.isHovered
                ? NSColor.labelColor.withAlphaComponent(self.hoverOpacity) : .clear).cgColor
        }
    }
}

private struct MenuPanelHoverTracking: NSViewRepresentable {
    let cornerRadius: CGFloat
    let opacity: Double
    let isEnabled: Bool
    var onHoverChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> MenuPanelHoverTrackingView {
        let view = MenuPanelHoverTrackingView(frame: .zero)
        self.updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MenuPanelHoverTrackingView, context: Context) {
        view.cornerRadius = self.cornerRadius
        view.hoverOpacity = self.opacity
        view.isEnabled = self.isEnabled
        view.onHoverChanged = self.onHoverChanged
        view.updateAppearance()
    }
}

private struct MenuPanelHoverRegion: ViewModifier {
    let onHoverChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.overlay {
            MenuPanelHoverTracking(cornerRadius: 0, opacity: 0, isEnabled: self.isEnabled,
                onHoverChanged: self.onHoverChanged)
        }
    }
}

struct MenuPanelHoverChrome: ViewModifier {
    var cornerRadius: CGFloat = 6
    var active: Bool = false
    var hoverOpacity: Double = 0.12
    var pressedOpacity: Double = 0.18
    var activeOpacity: Double = 0.10
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: self.cornerRadius)
                .fill(self.active && self.isEnabled ? Color.accentColor.opacity(self.activeOpacity) : .clear))
            .overlay {
                MenuPanelHoverTracking(cornerRadius: self.cornerRadius, opacity: self.hoverOpacity,
                    isEnabled: self.isEnabled)
            }
            .contentShape(RoundedRectangle(cornerRadius: self.cornerRadius))
            .opacity(self.isEnabled ? 1 : 0.48)
    }
}

extension View {
    /// Apply to the control itself, not its Menu label (which AppKit may rasterize).
    func menuPanelIconControl() -> some View {
        self.frame(width: 24, height: 24).menuPanelHoverChrome(cornerRadius: 6)
    }

    func menuPanelHoverRegion(_ onHoverChanged: @escaping (Bool) -> Void) -> some View {
        self.modifier(MenuPanelHoverRegion(onHoverChanged: onHoverChanged))
    }

    func menuPanelHoverChrome(
        cornerRadius: CGFloat = 6,
        active: Bool = false,
        hoverOpacity: Double = 0.12,
        pressedOpacity: Double = 0.18,
        activeOpacity: Double = 0.10
    ) -> some View {
        self.modifier(
            MenuPanelHoverChrome(
                cornerRadius: cornerRadius,
                active: active,
                hoverOpacity: hoverOpacity,
                pressedOpacity: pressedOpacity,
                activeOpacity: activeOpacity
            )
        )
    }
}

/// Surface layers are paint only: they never participate in popover sizing.
enum MenuPanelSurface {
    static let cornerRadius: CGFloat = 12
    static let activeCornerRadius: CGFloat = 16
    static let spacing: CGFloat = 16
}

struct MenuPanelCardSurface: View {
    var active = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var dark: Bool { colorScheme == .dark }
    var body: some View {
        if active {
            MenuPanelActiveSurface()
        } else {
            let shape = RoundedRectangle(cornerRadius: MenuPanelSurface.cornerRadius, style: .continuous)
            ZStack {
                shape.fill(dark ? Color.black.opacity(0.16) : Color.white.opacity(0.32))
                shape.fill(LinearGradient(colors: [
                    Color.white.opacity(dark ? 0.035 : 0.24),
                    Color.white.opacity(dark ? 0.012 : 0.02)
                ], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(LinearGradient(colors: [
                    dark ? Color.white.opacity(0.085) : Color.black.opacity(0.07),
                    dark ? Color.white.opacity(0.035) : Color.black.opacity(0.035)
                ], startPoint: .top, endPoint: .bottom), lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A neutral inset surface lit locally by the running-state indicator.
private struct MenuPanelActiveSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MenuPanelSurface.activeCornerRadius, style: .continuous)
        GeometryReader { geometry in
            ZStack {
                shape.fill((dark ? Color.black.opacity(0.25) : Color.white.opacity(0.56))
                    .shadow(.inner(color: Color.black.opacity(dark ? 0.18 : 0.055), radius: 3, x: 0, y: 1)))
                shape.fill(RadialGradient(stops: [
                    .init(color: Color.accentColor.opacity(dark ? 0.16 : 0.07), location: 0),
                    .init(color: Color.accentColor.opacity(dark ? 0.13 : 0.055), location: 0.40),
                    .init(color: Color.accentColor.opacity(dark ? 0.045 : 0.02), location: 0.78),
                    .init(color: .clear, location: 1)
                ], center: UnitPoint(x: 20 / geometry.size.width, y: 20 / geometry.size.height),
                    startRadius: 0, endRadius: 185))
                shape.strokeBorder(LinearGradient(colors: [
                    dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10),
                    dark ? Color.white.opacity(0.045) : Color.black.opacity(0.045)
                ], startPoint: .top, endPoint: .bottom), lineWidth: contrast == .increased ? 1 : 0.5)
                // Light is confined to the top edge; the logo and other edges stay neutral.
                shape.strokeBorder(LinearGradient(stops: [
                    .init(color: Color.accentColor.opacity(dark ? 0.66 : 0.48), location: 0),
                    .init(color: dark ? Color.white.opacity(0.22) : Color.white.opacity(0.85), location: 0.25),
                    .init(color: dark ? Color.white.opacity(0.07) : Color.white.opacity(0.30), location: 0.65)
                ], startPoint: .leading, endPoint: .trailing), lineWidth: contrast == .increased ? 1 : 0.75)
                .mask(alignment: .top) { Rectangle().frame(height: 1) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MenuPanelSegmentSurface: View {
    var selected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: selected ? 8 : 12, style: .continuous)
        shape.fill(selected ? Color.accentColor.opacity(dark ? 0.23 : 0.12)
                            : Color.black.opacity(dark ? 0.14 : 0.045))
            .overlay {
                shape.strokeBorder(selected ? Color.accentColor.opacity(dark ? 0.48 : 0.32)
                    : (dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)),
                    lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .allowsHitTesting(false)
    }
}

struct MenuPanelSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
    }
}

struct MenuPanelMoreLabel: View {
    var tint: Color = .primary

    var body: some View {
        Image(systemName: "ellipsis")
            .foregroundColor(self.tint)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

private struct MenuPanelLogoBundleKey: EnvironmentKey {
    static let defaultValue: Bundle = .main
}

extension EnvironmentValues {
    var menuPanelLogoBundle: Bundle {
        get { self[MenuPanelLogoBundleKey.self] }
        set { self[MenuPanelLogoBundleKey.self] = newValue }
    }
}

struct MenuPanelLogo: View {
    let source: MenuBarStatusItemIconSource?
    var size: CGFloat = 16
    var usesBrandColors = false
    @Environment(\.menuPanelLogoBundle) private var logoBundle

    var body: some View {
        if usesBrandColors, let name = source?.brandAssetName,
           source?.makeBrandImage(bundle: logoBundle) != nil {
            // Resolve the asset in SwiftUI so appearance variants remain dynamic.
            Image(name, bundle: logoBundle)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .padding(size / 12)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if let icon = source?.makeTemplateImage(accessibilityDescription: "") {
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}


struct MenuPanelRefreshIcon: View {
    let isRefreshing: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isRefreshing && reduceMotion {
                ProgressView().controlSize(.small).tint(tint)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRefreshing)) { context in
                    Hugeicons.refresh04.image(size: 20)
                        .rotationEffect(.degrees(isRefreshing
                            ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                            : 0))
                }
            }
        }
        .foregroundColor(tint)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

struct MenuPanelHoverSwitchButton: View {
    let isHovered: Bool
    var title: String = L.openAIAccountSwitchAction
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var isVisible: Bool { isHovered || isFocused }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .frame(width: MenuPanelLayout.primaryActionWidth, height: MenuPanelLayout.primaryActionHeight)
        }
        .buttonStyle(MenuPanelPrimaryActionButtonStyle(tint: .accentColor))
        .focused($isFocused)
        .frame(width: MenuPanelLayout.primaryActionWidth, height: MenuPanelLayout.primaryActionHeight)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(false)
    }
}

/// The action slot and row height remain stable when the pointer enters or leaves.
struct MenuPanelSwitchRow<Content: View>: View {
    var showsSwitch = true
    var isCurrent = false
    let action: () -> Void
    let content: Content
    @State private var isHovered = false

    init(showsSwitch: Bool = true, isCurrent: Bool = false, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.showsSwitch = showsSwitch
        self.isCurrent = isCurrent
        self.action = action
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            content.layoutPriority(1)
            Spacer(minLength: 4)
            if isCurrent { MenuPanelCurrentIndicator() }
            else if showsSwitch { MenuPanelHoverSwitchButton(isHovered: isHovered, action: action) }
        }
        .frame(height: MenuPanelLayout.compactRowHeight)
        .contentShape(Rectangle())
        .menuPanelHoverRegion { isHovered = $0 }
    }
}
