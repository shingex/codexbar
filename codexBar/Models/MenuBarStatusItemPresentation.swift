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
        usageDisplayMode: CodexBarUsageDisplayMode,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        updateAvailable: Bool
    ) -> MenuBarStatusItemPresentation {
        let iconSource = MenuBarIconResolver.iconSource(
            accounts: accounts,
            activeProvider: activeProvider,
            accountUsageMode: accountUsageMode,
            updateAvailable: updateAvailable
        )

        if accountUsageMode == .hybridProvider {
            if activeProvider?.kind == .openAIOAuth,
               let activeAccountPresentation = self.activeOpenAIAccountPresentation(
                    accounts: accounts,
                    iconSource: iconSource,
                    usageDisplayMode: usageDisplayMode
               ) {
                return activeAccountPresentation
            }
            if let activeProvider,
               let title = self.providerStatusTitle(for: activeProvider, mode: usageDisplayMode) {
                return MenuBarStatusItemPresentation(
                    iconSource: iconSource,
                    title: title,
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
           let activeAccountPresentation = self.activeOpenAIAccountPresentation(
                account: active,
                iconSource: iconSource,
                usageDisplayMode: usageDisplayMode
           ) {
            return activeAccountPresentation
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

    private static func activeOpenAIAccountPresentation(
        accounts: [TokenAccount],
        iconSource: MenuBarStatusItemIconSource,
        usageDisplayMode: CodexBarUsageDisplayMode
    ) -> MenuBarStatusItemPresentation? {
        guard let active = accounts.first(where: { $0.isActive }) else {
            return nil
        }
        return self.activeOpenAIAccountPresentation(
            account: active,
            iconSource: iconSource,
            usageDisplayMode: usageDisplayMode
        )
    }

    private static func activeOpenAIAccountPresentation(
        account: TokenAccount,
        iconSource: MenuBarStatusItemIconSource,
        usageDisplayMode: CodexBarUsageDisplayMode
    ) -> MenuBarStatusItemPresentation? {
        return MenuBarStatusItemPresentation(
            iconSource: iconSource,
            title: account.usageWindowDisplays(mode: usageDisplayMode)
                .map { "\(Int($0.displayPercent))%" }
                .joined(separator: "/"),
            emphasis: account.secondaryExhausted ? .critical : (account.primaryExhausted ? .warning : .primary)
        )
    }

    private static func providerStatusTitle(
        for provider: CodexBarProvider,
        mode: CodexBarUsageDisplayMode
    ) -> String? {
        ProviderUsageFormat.quotaStatusTitle(for: provider, mode: mode)
            ?? ProviderUsageFormat.compactStatusTitle(for: provider, mode: mode)
    }

    private static func providerFallbackTitle(for provider: CodexBarProvider) -> String {
        let label = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.count <= 6 ? label : String(label.prefix(6))
    }
}
