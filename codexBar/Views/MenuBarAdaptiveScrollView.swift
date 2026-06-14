import AppKit
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

enum AdaptiveScrollHeightLimit {
    case fixed(CGFloat)
    case measured(AnyView)
}
struct AdaptiveMenuScrollContainer<Content: View>: NSViewRepresentable {
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

struct AdaptiveMenuHeightReportingContainer: NSViewRepresentable {
    let onMeasuredHeightChange: ((CGFloat) -> Void)?
    let measurementContent: AnyView

    init(
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder measurementContent: () -> some View
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.measurementContent = AnyView(measurementContent())
    }

    func makeNSView(context: Context) -> AdaptiveMenuHeightReportingHost {
        AdaptiveMenuHeightReportingHost(
            measurementRootView: measurementContent,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    func updateNSView(_ nsView: AdaptiveMenuHeightReportingHost, context: Context) {
        nsView.update(
            measurementRootView: measurementContent,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }
}

struct ViewReferenceReader: NSViewRepresentable {
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

final class AdaptiveMenuHeightReportingHost: NSView {
    private let measurementHostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var measuredHeight: CGFloat = 1
    private var lastReportedHeight: CGFloat?
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var measurementWorkItem: DispatchWorkItem?
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?
    private let measurementDebounceInterval: TimeInterval = 0.04
    private let measurementNoiseTolerance: CGFloat = 1.5

    init(
        measurementRootView: AnyView,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        super.init(frame: .zero)
        self.measurementHostingView.rootView = measurementRootView
        self.measurementHostingView.isHidden = true
        self.addSubview(self.measurementHostingView)
        self.scheduleMeasurement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.measurementWorkItem?.cancel()
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 0)
    }

    override func layout() {
        super.layout()
        let width = max(self.bounds.width, 1)
        self.measurementHostingView.frame = NSRect(x: 0, y: 0, width: width, height: max(self.measuredHeight, 1))

        guard abs(self.lastMeasuredWidth - width) > 1 else { return }
        self.lastMeasuredWidth = width
        self.scheduleMeasurement()
    }

    func update(
        measurementRootView: AnyView,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.measurementHostingView.rootView = measurementRootView
        self.scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        self.measurementWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.recalculateLayout()
        }
        self.measurementWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + self.measurementDebounceInterval,
            execute: workItem
        )
    }

    private func recalculateLayout() {
        guard self.isMeasuring == false else { return }
        self.isMeasuring = true
        defer { self.isMeasuring = false }

        let width = max(self.bounds.width, 1)
        self.measurementHostingView.setFrameSize(
            NSSize(width: width, height: max(self.measurementHostingView.frame.height, 1))
        )

        let fittingHeight = max(self.measurementHostingView.fittingSize.height, 1)

        if abs((self.lastReportedHeight ?? 0) - fittingHeight) > self.measurementNoiseTolerance {
            self.lastReportedHeight = fittingHeight
            self.onMeasuredHeightChange?(fittingHeight)
        }

        guard abs(self.measuredHeight - fittingHeight) > 1 else { return }
        self.measuredHeight = fittingHeight
        self.measurementHostingView.frame = NSRect(x: 0, y: 0, width: width, height: fittingHeight)
        self.needsLayout = true
    }
}

final class AdaptiveMenuScrollHost: NSView {
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
    private var measurementWorkItem: DispatchWorkItem?
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?

    private let idleScrollerAlpha: CGFloat = 0
    private let visibleScrollerAlpha: CGFloat = 0.95
    private let scrollerHideDelay: TimeInterval = 0.9
    private let measurementDebounceInterval: TimeInterval = 0.04

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
        self.measurementWorkItem?.cancel()
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
        self.measurementWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.recalculateLayout()
        }
        self.measurementWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + self.measurementDebounceInterval,
            execute: workItem
        )
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
        let previousTopOffset = self.currentVisibleTopOffset()

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

    private func currentVisibleTopOffset() -> CGFloat {
        let visibleRect = self.scrollView.contentView.bounds
        return self.displayHostingView.isFlipped
            ? visibleRect.minY
            : max(self.displayHostingView.bounds.height - visibleRect.maxY, 0)
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
