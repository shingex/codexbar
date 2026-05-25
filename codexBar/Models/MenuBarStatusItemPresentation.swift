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

    let iconName: String
    let title: String
    let emphasis: Emphasis

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
        let image = NSImage(
            systemSymbolName: self.iconName,
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        return image
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
        let iconName = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: activeProvider?.kind,
            accountUsageMode: accountUsageMode,
            updateAvailable: updateAvailable
        )

        if accountUsageMode == .hybridProvider {
            if let activeProvider,
               let title = ProviderUsageFormat.compactStatusTitle(
                for: activeProvider,
                mode: usageDisplayMode
               ) {
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: title,
                    emphasis: .primary
                )
            }
            if disableLocalUsageStats == false {
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: Self.compactTodayCostTitle(localCostSummary.todayCostUSD),
                    emphasis: .primary
                )
            }
            if let activeProvider {
                let label = activeProvider.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let shortLabel = label.count <= 6 ? label : String(label.prefix(6))
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: shortLabel,
                    emphasis: .secondary
                )
            }
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: "",
                emphasis: .primary
            )
        }

        if activeProvider?.kind == .openAIOAuth,
           accountUsageMode == .aggregateGateway,
           let aggregateRoutedAccount {
            let summary = aggregateRoutedAccount.compactPrimaryUsageSummary(mode: usageDisplayMode) ?? ""
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: summary.isEmpty ? summary : L.openAIRouteSummaryCompact(summary),
                emphasis: .primary
            )
        }

        if let activeProvider,
           activeProvider.kind != .openAIOAuth,
           let title = ProviderUsageFormat.compactStatusTitle(
            for: activeProvider,
            mode: usageDisplayMode
           ) {
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: title,
                emphasis: .primary
            )
        }

        if let active = accounts.first(where: { $0.isActive }),
           disableLocalUsageStats == false {
            if active.secondaryExhausted {
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: L.weeklyLimit,
                    emphasis: .critical
                )
            }
            if active.primaryExhausted {
                return MenuBarStatusItemPresentation(
                    iconName: iconName,
                    title: L.hourLimit,
                    emphasis: .warning
                )
            }
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: active.usageWindowDisplays(mode: usageDisplayMode)
                    .map { "\(Int($0.displayPercent))%" }
                    .joined(separator: "/"),
                emphasis: .primary
            )
        }

        if let activeProvider {
            let label = activeProvider.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortLabel = label.count <= 6 ? label : String(label.prefix(6))
            return MenuBarStatusItemPresentation(
                iconName: iconName,
                title: shortLabel,
                emphasis: .secondary
            )
        }

        return MenuBarStatusItemPresentation(iconName: iconName, title: "", emphasis: .primary)
    }

    private static func compactTodayCostTitle(_ costUSD: Double) -> String {
        self.usdFormatter.string(from: NSNumber(value: costUSD)) ?? String(format: "US$%.2f", costUSD)
    }
}
