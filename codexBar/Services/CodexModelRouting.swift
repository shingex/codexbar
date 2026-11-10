import Foundation

/// Stable Codex-facing identity; the upstream target lives only in CodexBar.
enum CodexModelRouting {
    static let modelID = "codexbar"
    static var catalogURL: URL { CodexPaths.openAIGatewayRootURL.appendingPathComponent("codex-models.json") }
    static var syncStateURL: URL { CodexPaths.openAIGatewayRootURL.appendingPathComponent("codex-routing-state.json") }

    static func catalogData(from data: Data, additionalCatalog: Data? = nil, contextWindow: Int? = nil) throws -> Data {
        guard var catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var models = catalog["models"] as? [[String: Any]],
              let template = models.first(where: { $0["slug"] as? String != modelID }) else {
            throw CodexModelRoutingError.missingCatalog
        }
        if let additionalCatalog,
           let additional = try JSONSerialization.jsonObject(with: additionalCatalog) as? [String: Any],
           let extraModels = additional["models"] as? [[String: Any]] {
            let existingSlugs = Set(models.compactMap { $0["slug"] as? String })
            models.append(contentsOf: extraModels.filter { model in
                guard let slug = model["slug"] as? String else { return false }
                return !existingSlugs.contains(slug)
            })
        }
        models.removeAll { $0["slug"] as? String == modelID }
        // This integration deliberately uses HTTP/SSE for both routes.
        models = models.map { original in
            var model = original
            model["prefer_websockets"] = false
            return model
        }
        var alias = template
        alias["slug"] = modelID
        alias["display_name"] = "CodexBar"
        alias["description"] = L.zh ? "使用 CodexBar 中选定的模型" : "Use the model selected in CodexBar"
        alias["visibility"] = "list"
        alias["supported_in_api"] = true
        alias["priority"] = 0
        alias["upgrade"] = NSNull()
        alias["prefer_websockets"] = false
        alias["tool_mode"] = "direct"
        alias["use_responses_lite"] = false
        alias["supports_parallel_tool_calls"] = false
        // Tool capabilities are conservative; context capacity must not be reduced to 32k.
        if let contextWindow {
            alias["context_window"] = contextWindow
            alias["max_context_window"] = contextWindow
        }
        // Do not inherit another model's compaction threshold.
        alias["auto_compact_token_limit"] = NSNull()
        alias.removeValue(forKey: "multi_agent_version")
        alias.removeValue(forKey: "multi_agent_reasoning_effort")
        alias.removeValue(forKey: "guardian")
        alias["additional_speed_tiers"] = []
        alias["service_tiers"] = []
        models.append(alias)
        catalog["models"] = models
        // Cache identity belongs to discovery, not the on-disk catalog schema.
        for key in ["fetched_at", "etag", "client_version", "identity"] { catalog.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    }
    static func targetContextWindow(config: CodexBarConfig) -> Int? {
        guard let provider = config.activeProvider(), provider.usesAPIKeyAuth else { return nil }
        let modelID = provider.kind == .openRouter
            ? provider.openRouterEffectiveModelID(forAccountID: config.active.accountId)
            : provider.thirdPartyEffectiveModelID(forAccountID: config.active.accountId)
        guard let modelID,
              let plan = provider.openCodePlan ?? CodexBarOpenCodePlan.inferred(from: provider.baseURL),
              let model = OpenCodeModelCatalogService().loadCachedCatalog(plan: plan)?.models.first(where: { $0.id == modelID }),
              let context = model.contextLimit, context > 0 else { return nil }
        return context
    }

    /// Refresh only the managed model catalog; never rewrite auth or Codex settings on a hot switch.
    static func refreshCatalogContext(config: CodexBarConfig) throws {
        guard config.openAI.modelRoutingEnabled,
              FileManager.default.fileExists(atPath: catalogURL.path) else { return }
        let old = try Data(contentsOf: catalogURL)
        let updated = try catalogData(from: old, contextWindow: targetContextWindow(config: config))
        if old != updated { try CodexPaths.writeSecureFile(updated, to: catalogURL) }
    }

}
enum CodexModelRoutingError: LocalizedError {
    case missingOAuth, missingCatalog, missingTarget

    var errorDescription: String? {
        switch self {
        case .missingOAuth: return L.zh ? "请先登录或导入 OpenAI 账号。" : "Sign in to or import an OpenAI account first."
        case .missingCatalog: return L.zh ? "请先打开已登录的 Codex，加载模型列表后重试。" : "Open signed-in Codex to load its models, then try again."
        case .missingTarget: return L.zh ? "请选择 CodexBar 要使用的账号或模型。" : "Select an account or model for CodexBar."
        }
    }
}

struct CodexModelRoutingSyncState: Codable {
    var settings: [String: String]
    var compression: String?
    var fallbackModel: String?
    var authWasReplaced: Bool?
    var previousAuth: Data?
}
