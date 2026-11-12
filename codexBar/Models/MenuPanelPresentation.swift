import Foundation

/// Read-only identity of the configured request target. Browsing a tab never changes it.
struct MenuPanelTarget: Equatable {
    let providerID: String
    let accountID: String?
    let modelID: String?

    static func resolve(config: CodexBarConfig) -> MenuPanelTarget? {
        guard let provider = config.activeProvider() else { return nil }
        let accountID = config.active.accountId ?? provider.activeAccountId
        let modelID: String?
        if provider.kind == .openRouter {
            modelID = provider.openRouterEffectiveModelID(forAccountID: accountID)
        } else if provider.kind == .openAICompatible {
            modelID = provider.thirdPartyEffectiveModelID(forAccountID: accountID)
        } else {
            modelID = nil
        }
        return Self(providerID: provider.id, accountID: accountID, modelID: modelID)
    }

    func iconSource(for provider: CodexBarProvider) -> MenuBarStatusItemIconSource? {
        if provider.kind == .openAIOAuth { return MenuBarModelIconLibrary.openAI }
        var displayedProvider = provider
        displayedProvider.activeAccountId = self.accountID
        return ModelDisplayIdentityResolver.identity(for: displayedProvider)?.iconSource
    }

    func matches(providerID: String, accountID: String, modelID: String? = nil) -> Bool {
        self.providerID == providerID && self.accountID == accountID && self.modelID == modelID
    }
}

/// Resource identity is presentation-only and deliberately excludes a provider's key/model.
enum MenuPanelResourceID: Hashable {
    case account(providerID: String, accountID: String)
    case provider(String)
}

enum MenuPanelPresentation {
    static func activeResource(config: CodexBarConfig) -> MenuPanelResourceID? {
        if config.openAI.modelRoutingStyle == .catalog, let provider = config.oauthProvider(), let account = provider.activeAccount {
            return .account(providerID: provider.id, accountID: account.id)
        }
        guard let target = MenuPanelTarget.resolve(config: config),
              let provider = config.provider(id: target.providerID) else { return nil }
        if provider.kind == .openAIOAuth {
            guard let accountID = target.accountID else { return nil }
            return .account(providerID: provider.id, accountID: accountID)
        }
        return .provider(provider.id)
    }

    static func availableProviders(_ providers: [CodexBarProvider], activeResource: MenuPanelResourceID?) -> [CodexBarProvider] {
        providers.filter { activeResource != .provider($0.id) }
    }

    static func models(for provider: CodexBarProvider, account: CodexBarProviderAccount,
                       target: MenuPanelTarget?) -> [CodexBarOpenRouterModel] {
        var models = provider.kind == .openRouter
            ? provider.openRouterMenuModelOptions(forAccountID: account.id)
            : provider.thirdPartyMenuModelOptions(forAccountID: account.id)
        // Keep an externally selected model visible even when it is not pinned.
        if target?.providerID == provider.id, target?.accountID == account.id,
           let modelID = target?.modelID, !models.contains(where: { $0.id == modelID }) {
            models.append(CodexBarOpenRouterModel(id: modelID))
        }
        return models
    }

    static func accountTitle(_ account: TokenAccount) -> String {
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = email.firstIndex(of: "@") else {
            return email.isEmpty ? account.accountId : email
        }
        let name = email[..<separator]
        guard name.count > 6 else { return email }
        return "\(name.prefix(6))***\(email[separator...])"
    }
}
