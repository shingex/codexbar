import Foundation

/// Persistent identities contain no credentials; credentials are resolved for each incoming request.
struct CodexExportRegistry: Codable {
    struct Entry: Codable {
        var id: String
        var provider: String
        var account: String
        var model: String
    }
    var entries: [Entry] = []
    var legacy: Entry?
    var style: CodexRoutingStyle?
    static var url: URL { CodexPaths.openAIGatewayRootURL.appendingPathComponent("exported-models.json") }
    static func load() -> Self { (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? .init() }

    static func target(_ entry: Entry, config: CodexBarConfig) -> OpenAIAccountGatewayRouteTarget? {
        guard let provider = config.provider(id: entry.provider), provider.enabled,
              let account = provider.accounts.first(where: { $0.id == entry.account }) else { return nil }
        if provider.kind == .openAIOAuth { return .openAIAccount(accountID: account.id) }
        guard let key = account.apiKey, !key.isEmpty,
              account.modelSelection?.pinnedModelIDs.contains(entry.model) == true else { return nil }
        if provider.kind == .openRouter { return .openRouter(.init(providerID: provider.id, accountID: account.id, apiKey: key, modelID: entry.model)) }
        guard let base = provider.baseURL, !base.isEmpty else { return nil }
        return .compatibleProvider(.init(providerID: provider.id, providerLabel: provider.displayName, baseURL: base,
            accountID: account.id, apiKey: key, modelID: entry.model, thirdPartyModelProvider: provider.thirdPartyModelProvider))
    }

    static func catalog(config: CodexBarConfig, source: Data) throws -> Data {
        var registry = load()
        var object = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        var models = object["models"] as! [[String: Any]]
        guard let template = models.first(where: { $0["slug"] as? String == "codexbar" }) else { return source }
        let historical = Dictionary(uniqueKeysWithValues: models.compactMap { row -> (String, [String: Any])? in
            guard let id = row["slug"] as? String, id.hasPrefix("codexbar-") else { return nil }; return (id, row)
        })
        models.removeAll { ($0["slug"] as? String)?.hasPrefix("codexbar-") == true }
        var available: [(Entry, String, String, Int?)] = []
        for provider in config.providers where provider.enabled && provider.usesAPIKeyAuth {
            for account in provider.accounts where !(account.apiKey ?? "").isEmpty {
                for model in account.modelSelection?.pinnedModelIDs ?? [] {
                    var entry = registry.entries.first { $0.provider == provider.id && $0.account == account.id && $0.model == model }
                    if entry == nil {
                        entry = .init(id: "codexbar-" + UUID().uuidString.lowercased(), provider: provider.id, account: account.id, model: model)
                        registry.entries.append(entry!)
                    }
                    guard target(entry!, config: config) != nil else { continue }
                    let plan = provider.openCodePlan ?? CodexBarOpenCodePlan.inferred(from: provider.baseURL)
                    let cached = plan.flatMap { OpenCodeModelCatalogService().loadCachedCatalog(plan: $0)?.models.first { $0.id == model } }
                    available.append((entry!, provider.displayName, account.label, cached?.contextLimit))
                }
            }
        }
        if config.openAI.modelRoutingStyle == .catalog && registry.style != .catalog,
           let provider = config.activeProvider(), let account = config.active.accountId {
            let model = provider.kind == .openRouter ? provider.openRouterEffectiveModelID(forAccountID: account) : provider.thirdPartyEffectiveModelID(forAccountID: account)
            registry.legacy = .init(id: "codexbar", provider: provider.id, account: account, model: model ?? config.global.sanitizedDefaultModel)
        }
        var names: Set<String> = []
        for entry in registry.entries {
            let item = available.first { $0.0.id == entry.id }
            var row = historical[entry.id] ?? template
            row["slug"] = entry.id
            var name = entry.model
            if available.filter({ $0.0.model == entry.model }).count > 1, let item {
                name += " (" + item.1 + ")"
                if available.filter({ $0.0.model == entry.model && $0.1 == item.1 }).count > 1 { name = entry.model + " (" + item.1 + " · " + item.2 + ")" }
            }
            let original = name
            var n = 2
            while names.contains(name) { name = original + " \(n)"; n += 1 }
            names.insert(name)
            row["display_name"] = name
            row["visibility"] = config.openAI.modelRoutingStyle == .catalog && item != nil ? "list" : "hide"
            if let item {
                row["context_window"] = item.3.map { $0 as Any } ?? NSNull()
                row["max_context_window"] = item.3.map { $0 as Any } ?? NSNull()
            }
            row["auto_compact_token_limit"] = NSNull()
            models.append(row)
        }
        if config.openAI.modelRoutingStyle == .catalog, let index = models.firstIndex(where: { $0["slug"] as? String == "codexbar" }) { models[index]["visibility"] = "hide" }
        object["models"] = models
        registry.style = config.openAI.modelRoutingStyle
        let data = try JSONEncoder().encode(registry)
        if (try? Data(contentsOf: url)) != data { try CodexPaths.writeSecureFile(data, to: url) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
