import AppKit
import Foundation

struct MenuBarStatusItemPresentation: Equatable {
    enum Emphasis: Equatable {
        case primary
        case secondary
        case warning
        case critical

        var fontWeight: NSFont.Weight {
            switch self {
            case .primary, .secondary:
                return .medium
            case .warning, .critical:
                return .semibold
            }
        }
    }

    let iconSource: MenuBarStatusItemIconSource
    let title: String
    let emphasis: Emphasis

    var iconName: String {
        self.iconSource.fallbackSystemSymbolName
    }

    init(
        iconSource: MenuBarStatusItemIconSource,
        title: String,
        emphasis: Emphasis
    ) {
        self.iconSource = iconSource
        self.title = title
        self.emphasis = emphasis
    }

    init(
        iconName: String,
        title: String,
        emphasis: Emphasis
    ) {
        self.init(
            iconSource: .systemSymbol(iconName),
            title: title,
            emphasis: emphasis
        )
    }

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    var font: NSFont { .systemFont(ofSize: 12, weight: self.emphasis.fontWeight) }
    var attributedTitle: NSAttributedString {
        guard self.title.isEmpty == false else {
            return NSAttributedString(string: "")
        }

        return NSAttributedString(
            string: " " + self.title,
            attributes: [
                .font: self.font,
            ]
        )
    }

    func makeTemplateImage(accessibilityDescription: String) -> NSImage? {
        self.iconSource.makeTemplateImage(accessibilityDescription: accessibilityDescription)
    }

    static func make(
        accounts: [TokenAccount],
        activeProvider: CodexBarProvider?,
        aggregateRoutedAccount: TokenAccount?,
        localCostSummary: LocalCostSummary,
        usageDisplayMode: CodexBarUsageDisplayMode,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        disableLocalUsageStats: Bool,
        updateAvailable: Bool
    ) -> MenuBarStatusItemPresentation {
        let iconSource = MenuBarIconResolver.iconSource(
            accounts: accounts,
            activeProvider: activeProvider,
            accountUsageMode: accountUsageMode,
            updateAvailable: updateAvailable
        )

        if accountUsageMode == .hybridProvider {
            if let activeProvider,
               let title = self.providerStatusTitle(for: activeProvider, mode: usageDisplayMode) {
                return MenuBarStatusItemPresentation(
                    iconSource: iconSource,
                    title: title,
                    emphasis: .primary
                )
            }
            if disableLocalUsageStats == false {
                return MenuBarStatusItemPresentation(
                    iconSource: iconSource,
                    title: Self.compactTodayCostTitle(localCostSummary.todayCostUSD),
                    emphasis: .primary
                )
            }
            if let activeProvider {
                return MenuBarStatusItemPresentation(
                    iconSource: iconSource,
                    title: self.providerFallbackTitle(for: activeProvider),
                    emphasis: .secondary
                )
            }
            return MenuBarStatusItemPresentation(
                iconSource: iconSource,
                title: "",
                emphasis: .primary
            )
        }

        if activeProvider?.kind == .openAIOAuth,
           accountUsageMode == .aggregateGateway,
           let aggregateRoutedAccount {
            let summary = aggregateRoutedAccount.compactPrimaryUsageSummary(mode: usageDisplayMode) ?? ""
            return MenuBarStatusItemPresentation(
                iconSource: iconSource,
                title: summary.isEmpty ? summary : L.openAIRouteSummaryCompact(summary),
                emphasis: .primary
            )
        }

        if let activeProvider,
           activeProvider.kind != .openAIOAuth,
           let title = self.providerStatusTitle(for: activeProvider, mode: usageDisplayMode) {
            return MenuBarStatusItemPresentation(
                iconSource: iconSource,
                title: title,
                emphasis: .primary
            )
        }

        if let active = accounts.first(where: { $0.isActive }),
           disableLocalUsageStats == false {
            if active.secondaryExhausted {
                return MenuBarStatusItemPresentation(
                    iconSource: iconSource,
                    title: L.weeklyLimit,
                    emphasis: .critical
                )
            }
            if active.primaryExhausted {
                return MenuBarStatusItemPresentation(
                    iconSource: iconSource,
                    title: L.hourLimit,
                    emphasis: .warning
                )
            }
            return MenuBarStatusItemPresentation(
                iconSource: iconSource,
                title: active.usageWindowDisplays(mode: usageDisplayMode)
                    .map { "\(Int($0.displayPercent))%" }
                    .joined(separator: "/"),
                emphasis: .primary
            )
        }

        if let activeProvider {
            return MenuBarStatusItemPresentation(
                iconSource: iconSource,
                title: self.providerFallbackTitle(for: activeProvider),
                emphasis: .secondary
            )
        }

        return MenuBarStatusItemPresentation(iconSource: iconSource, title: "", emphasis: .primary)
    }

    private static func compactTodayCostTitle(_ costUSD: Double) -> String {
        self.usdFormatter.string(from: NSNumber(value: costUSD)) ?? String(format: "US$%.2f", costUSD)
    }

    private static func providerStatusTitle(
        for provider: CodexBarProvider,
        mode: CodexBarUsageDisplayMode
    ) -> String? {
        guard let usageTitle = ProviderUsageFormat.compactStatusTitle(for: provider, mode: mode) else {
            return nil
        }
        guard let identity = ModelDisplayIdentityResolver.identity(for: provider),
              identity.providerCode.isEmpty == false else {
            return usageTitle
        }
        return "\(identity.providerCode)\(usageTitle)"
    }

    private static func providerFallbackTitle(for provider: CodexBarProvider) -> String {
        if let identity = ModelDisplayIdentityResolver.identity(for: provider),
           identity.compactModelCode.isEmpty == false {
            return identity.compactModelCode
        }
        let label = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.count <= 6 ? label : String(label.prefix(6))
    }
}
