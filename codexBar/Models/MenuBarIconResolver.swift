import Foundation

enum MenuBarIconResolver {
    static func iconSource(
        accounts: [TokenAccount],
        activeProvider: CodexBarProvider?,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount,
        updateAvailable: Bool = false
    ) -> MenuBarStatusItemIconSource {
        if updateAvailable {
            return .systemSymbol("arrow.down.circle.fill")
        }

        if let statusIcon = self.statusIconSource(accounts: accounts, activeProviderKind: activeProvider?.kind) {
            return statusIcon
        }

        if let activeProvider,
           let modelIcon = ModelDisplayIdentityResolver.identity(for: activeProvider)?.iconSource {
            return modelIcon
        }

        return .systemSymbol(self.modeFallbackIconName(for: accountUsageMode))
    }

    static func iconName(
        accounts: [TokenAccount],
        activeProviderKind: CodexBarProviderKind?,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount,
        updateAvailable: Bool = false
    ) -> String {
        self.iconSource(
            accounts: accounts,
            activeProvider: activeProviderKind.map {
                CodexBarProvider(id: "status-item-fallback", kind: $0, label: "")
            },
            accountUsageMode: accountUsageMode,
            updateAvailable: updateAvailable
        ).fallbackSystemSymbolName
    }

    private static func statusIconSource(
        accounts: [TokenAccount],
        activeProviderKind: CodexBarProviderKind?
    ) -> MenuBarStatusItemIconSource? {
        guard activeProviderKind == nil || activeProviderKind == .openAIOAuth else {
            return nil
        }

        let scopedAccounts: [TokenAccount]
        if activeProviderKind == .openAIOAuth,
           let active = accounts.first(where: { $0.isActive }) {
            scopedAccounts = [active]
        } else {
            scopedAccounts = accounts.filter(\.isActive)
        }

        guard scopedAccounts.isEmpty == false else {
            return nil
        }
        if scopedAccounts.contains(where: { $0.isBanned }) {
            return .systemSymbol("xmark.circle.fill")
        }
        if scopedAccounts.contains(where: { $0.secondaryExhausted }) {
            return .systemSymbol("exclamationmark.triangle.fill")
        }
        if scopedAccounts.contains(where: { $0.quotaExhausted || $0.isBelowVisualWarningThreshold() }) {
            return .systemSymbol("bolt.circle.fill")
        }
        return nil
    }

    private static func modeFallbackIconName(for mode: CodexBarOpenAIAccountUsageMode) -> String {
        switch mode {
        case .switchAccount:
            return "person.crop.circle"
        case .aggregateGateway:
            return "person.2.crop.square.stack"
        case .hybridProvider:
            return "arrow.triangle.branch"
        }
    }
}
