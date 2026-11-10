import Foundation
import SQLite3

private let codexSyncSQLiteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws
}

enum CodexSyncError: LocalizedError {
    case missingActiveProvider
    case missingActiveAccount
    case missingOAuthTokens
    case missingAPIKey
    case missingOpenRouterModel

    var errorDescription: String? {
        switch self {
        case .missingActiveProvider: return "未找到当前激活的 provider"
        case .missingActiveAccount: return "未找到当前激活的账号"
        case .missingOAuthTokens: return "当前 OAuth 账号缺少必要 token"
        case .missingAPIKey: return "当前 API Key 账号缺少密钥"
        case .missingOpenRouterModel: return "OpenRouter 需要先选择或输入模型 ID"
        }
    }
}

struct CodexSyncService: CodexSynchronizing {
    private struct OpenAIModelSnapshot {
        var model: String
        var reviewModel: String?
    }

    private let ensureDirectories: () throws -> Void
    private let backupFileIfPresent: (URL, URL) throws -> Void
    private let writeSecureFile: (Data, URL) throws -> Void
    private let readString: (URL) -> String?
    private let readData: (URL) -> Data?
    private let fileExists: (URL) -> Bool
    private let removeFileIfPresent: (URL) throws -> Void
    private let historyProviderMergeService: CodexHistoryProviderMergeService
    private let openAIModelStateStore: OpenAIModelStateStore

    init(
        ensureDirectories: @escaping () throws -> Void = { try CodexPaths.ensureDirectories() },
        backupFileIfPresent: @escaping (URL, URL) throws -> Void = { source, destination in
            try CodexPaths.backupFileIfPresent(from: source, to: destination)
        },
        writeSecureFile: @escaping (Data, URL) throws -> Void = { data, url in
            try CodexPaths.writeSecureFile(data, to: url)
        },
        readString: @escaping (URL) -> String? = { url in
            try? String(contentsOf: url, encoding: .utf8)
        },
        readData: @escaping (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        },
        fileExists: @escaping (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        removeFileIfPresent: @escaping (URL) throws -> Void = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        },
        historyProviderMergeService: CodexHistoryProviderMergeService = CodexHistoryProviderMergeService(),
        openAIModelStateStore: OpenAIModelStateStore = OpenAIModelStateStore()
    ) {
        self.ensureDirectories = ensureDirectories
        self.backupFileIfPresent = backupFileIfPresent
        self.writeSecureFile = writeSecureFile
        self.readString = readString
        self.readData = readData
        self.fileExists = fileExists
        self.removeFileIfPresent = removeFileIfPresent
        self.historyProviderMergeService = historyProviderMergeService
        self.openAIModelStateStore = openAIModelStateStore
    }

    func synchronize(config: CodexBarConfig) throws {
        if config.openAI.modelRoutingEnabled {
            try self.synchronizeModelRouting(config: config)
            return
        }
        if self.readData(CodexModelRouting.syncStateURL) != nil {
            try self.restoreModelRouting(config: config)
            return
        }
        guard let provider = config.activeProvider() else { throw CodexSyncError.missingActiveProvider }
        guard let account = config.activeAccount() else { throw CodexSyncError.missingActiveAccount }
        let currentTargetKey = self.modelStateTargetKey(
            for: provider,
            account: account,
            usageMode: config.openAI.accountUsageMode
        )
        let oauthLogin = self.oauthLoginAccount(in: config)
        let shouldUseOAuthLoginAuth = provider.kind == .openAIOAuth ||
            config.openAI.accountUsageMode == .hybridProvider
        let authProvider = oauthLogin?.provider ?? provider
        let authAccount = shouldUseOAuthLoginAuth ? (oauthLogin?.account ?? account) : account
        let resolvedAuthProvider = shouldUseOAuthLoginAuth ? authProvider : provider

        let previousAuthData = self.readData(CodexPaths.authURL)
        let previousTomlData = self.readData(CodexPaths.configTomlURL)
        let existingTomlText = self.readString(CodexPaths.configTomlURL) ?? ""

        try self.ensureDirectories()
        try self.backupFileIfPresent(CodexPaths.configTomlURL, CodexPaths.configBackupURL)
        try self.backupFileIfPresent(CodexPaths.authURL, CodexPaths.authBackupURL)

        if provider.kind == .openAIOAuth,
           let openAIModelSnapshot = self.openAIModelSnapshot(from: existingTomlText) {
            try self.openAIModelStateStore.saveSnapshot(
                model: openAIModelSnapshot.model,
                reviewModel: openAIModelSnapshot.reviewModel
            )
        }
        let shouldSaveOpenAIModelSnapshot = provider.kind == .openRouter ||
            (provider.isThirdPartyModelProvider && self.isOpenAIBackedTOML(existingTomlText))
        if let previousTargetKey = self.openAIModelStateStore.loadLastActiveTargetKey(),
           OpenAIModelStateStore.isOpenAITargetKey(previousTargetKey),
           let previousTargetSnapshot = self.modelSnapshot(
            from: existingTomlText,
            targetKey: previousTargetKey
           ) {
            try self.openAIModelStateStore.saveSnapshot(
                model: previousTargetSnapshot.model,
                reviewModel: previousTargetSnapshot.reviewModel,
                for: previousTargetKey
            )
            try self.openAIModelStateStore.saveSnapshot(
                model: previousTargetSnapshot.model,
                reviewModel: previousTargetSnapshot.reviewModel
            )
        }
        if shouldSaveOpenAIModelSnapshot,
           let openAIModelSnapshot = self.openAIModelSnapshot(from: existingTomlText) {
            try self.openAIModelStateStore.saveSnapshot(
                model: openAIModelSnapshot.model,
                reviewModel: openAIModelSnapshot.reviewModel
            )
        }

        let savedOpenAIModel = self.openAIModelStateStore.loadSnapshot()
        let savedTargetModel = self.openAIModelStateStore.loadSnapshot(for: currentTargetKey)
        let upstreamModel: String
        switch provider.kind {
        case .openRouter:
            guard let selectedModelID = provider.openRouterEffectiveModelID(forAccountID: account.id) else {
                throw CodexSyncError.missingOpenRouterModel
            }
            upstreamModel = selectedModelID
        case .openAICompatible:
            if let keyModel = account.modelSelection?.effectiveModelID {
                upstreamModel = keyModel
            } else if provider.isThirdPartyModelProvider {
                upstreamModel = provider.thirdPartyEffectiveModelID(forAccountID: account.id)
                    ?? provider.defaultModel
                    ?? config.global.sanitizedDefaultModel
            } else {
                upstreamModel = savedTargetModel?.model ?? provider.defaultModel ?? savedOpenAIModel?.model ?? config.global.sanitizedDefaultModel
            }
        case .openAIOAuth:
            upstreamModel = savedTargetModel?.model ?? savedOpenAIModel?.model ?? config.global.sanitizedDefaultModel
        }
        let locksCodexModelToOpenAI = self.shouldLockCodexModelToOpenAI(
            config: config,
            provider: provider,
            hasOAuthLogin: oauthLogin != nil
        )
        let codexVisibleModel = self.codexVisibleModel(
            provider: provider,
            upstreamModel: upstreamModel,
            global: config.global,
            savedTargetModel: savedTargetModel,
            savedOpenAIModel: savedOpenAIModel,
            locksCodexModelToOpenAI: locksCodexModelToOpenAI
        )
        let codexVisibleReviewModel = self.codexVisibleReviewModel(
            provider: provider,
            codexVisibleModel: codexVisibleModel,
            upstreamModel: upstreamModel,
            global: config.global,
            savedTargetModel: savedTargetModel,
            savedOpenAIModel: savedOpenAIModel,
            locksCodexModelToOpenAI: locksCodexModelToOpenAI
        )

        let authData = try self.renderAuthJSON(config: config, provider: resolvedAuthProvider, account: authAccount)
        let legacyProviderIDs = self.historyProviderMergeService.providerIDsToMerge(from: existingTomlText)
        let renderedToml = self.renderConfigTOML(
            config: config,
            existingText: existingTomlText,
            global: config.global,
            provider: provider,
            codexVisibleModel: codexVisibleModel,
            codexVisibleReviewModel: codexVisibleReviewModel,
            hasOAuthLogin: oauthLogin != nil
        )
        guard let tomlData = renderedToml.data(using: .utf8) else { return }

        do {
            try self.writeSecureFile(authData, CodexPaths.authURL)
            try self.writeSecureFile(tomlData, CodexPaths.configTomlURL)
            try self.openAIModelStateStore.saveSnapshot(
                model: provider.kind == .openAIOAuth ? codexVisibleModel : upstreamModel,
                reviewModel: provider.kind == .openAIOAuth ? codexVisibleReviewModel : savedTargetModel?.reviewModel,
                for: currentTargetKey
            )
            if provider.kind == .openAIOAuth {
                try self.openAIModelStateStore.saveSnapshot(
                    model: codexVisibleModel,
                    reviewModel: codexVisibleReviewModel
                )
            } else if locksCodexModelToOpenAI {
                try self.openAIModelStateStore.saveSnapshot(
                    model: codexVisibleModel,
                    reviewModel: codexVisibleReviewModel
                )
            }
            try self.openAIModelStateStore.recordActiveTargetKey(currentTargetKey)
            self.historyProviderMergeService.mergeProviderIDsIntoOpenAI(legacyProviderIDs)
        } catch {
            try? self.restoreSnapshot(previousAuthData, at: CodexPaths.authURL)
            try? self.restoreSnapshot(previousTomlData, at: CodexPaths.configTomlURL)
            throw error
        }
    }

    private let modelRoutingSettingKeys = ["model_provider", "openai_base_url", "model_catalog_json"]

    private func featureValue(_ text: String, key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var isFeatures = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { isFeatures = trimmed == "[features]" }
            if isFeatures && (trimmed.hasPrefix(key + " ") || trimmed.hasPrefix(key + "=")) {
                return line
            }
        }
        return nil
    }

    private func restoreCompression(_ text: String, line: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        var isFeatures = false
        lines.removeAll { current in
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { isFeatures = trimmed == "[features]" }
            return isFeatures && (trimmed.hasPrefix("enable_request_compression ") || trimmed.hasPrefix("enable_request_compression="))
        }
        var result = lines.joined(separator: "\n")
        if let line {
            let key = "[features]"
            if let range = result.range(of: key) { result.insert(contentsOf: "\n" + line, at: range.upperBound) }
        }
        return result
    }

    private func synchronizeModelRouting(config: CodexBarConfig) throws {
        guard let oauth = self.oauthLoginAccount(in: config) else { throw CodexModelRoutingError.missingOAuth }
        let existing = self.readString(CodexPaths.configTomlURL) ?? ""
        let oldConfig = self.readData(CodexPaths.configTomlURL)
        let oldAuth = self.readData(CodexPaths.authURL)
        let oldState = self.readData(CodexModelRouting.syncStateURL)
        let oldCatalog = self.readData(CodexModelRouting.catalogURL)
        let originalCatalogPath = oldState.flatMap { try? JSONDecoder().decode(CodexModelRoutingSyncState.self, from: $0) }?.settings["model_catalog_json"]
            ?? self.settingValue(for: "model_catalog_json", in: existing)
        let userCatalog = originalCatalogPath.flatMap { path -> Data? in
            guard path != CodexModelRouting.catalogURL.path else { return nil }
            return self.readData(URL(fileURLWithPath: path))
        }
        let sourceURLs = [CodexPaths.codexRoot.appendingPathComponent("models_cache.json"),
            CodexPaths.openAIGatewayModelsCacheURL, CodexModelRouting.catalogURL]
        let sources = sourceURLs.compactMap { self.readData($0) } + [userCatalog].compactMap { $0 }
        guard let catalog = sources.lazy.compactMap({ try? CodexModelRouting.catalogData(from: $0, additionalCatalog: userCatalog, contextWindow: CodexModelRouting.targetContextWindow(config: config)) }).first else {
            throw CodexModelRoutingError.missingCatalog
        }
        var text = existing
        let authObject = oldAuth.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let replacesAuth = authObject?["tokens"] == nil
        let state = CodexModelRoutingSyncState(
            settings: Dictionary(uniqueKeysWithValues: self.modelRoutingSettingKeys.compactMap { key in
                self.settingValue(for: key, in: existing).map { (key, $0) }
            }),
            compression: self.featureValue(existing, key: "enable_request_compression"),
            fallbackModel: self.settingValue(for: "model", in: existing),
            authWasReplaced: replacesAuth, previousAuth: replacesAuth ? oldAuth : nil
        )
        text = self.upsertSetting(text, key: "model_provider", value: self.quote("openai"))
        text = self.upsertSetting(text, key: "openai_base_url", value: self.quote(OpenAIAccountGatewayConfiguration.baseURLString))
        text = self.upsertSetting(text, key: "model_catalog_json", value: self.quote(CodexModelRouting.catalogURL.path))
        text = self.upsertFeatureFlag(text, key: "enable_request_compression", value: false)
        try self.ensureDirectories()
        do {
            if oldState == nil { try self.writeSecureFile(try JSONEncoder().encode(state), CodexModelRouting.syncStateURL) }
            if oldCatalog != catalog { try self.writeSecureFile(catalog, CodexModelRouting.catalogURL) }
            // Preserve the running client's OAuth identity, including refreshed tokens.
            if replacesAuth {
                try self.writeSecureFile(try self.renderAuthJSON(config: config, provider: oauth.provider, account: oauth.account), CodexPaths.authURL)
            }
            if text != existing { try self.writeSecureFile(Data(text.utf8), CodexPaths.configTomlURL) }
        } catch {
            try? self.restoreSnapshot(oldConfig, at: CodexPaths.configTomlURL)
            try? self.restoreSnapshot(oldAuth, at: CodexPaths.authURL)
            try? self.restoreSnapshot(oldState, at: CodexModelRouting.syncStateURL)
            try? self.restoreSnapshot(oldCatalog, at: CodexModelRouting.catalogURL)
            throw error
        }
    }

    private func restoreModelRouting(config: CodexBarConfig) throws {
        guard let data = self.readData(CodexModelRouting.syncStateURL) else { return }
        let state = try JSONDecoder().decode(CodexModelRoutingSyncState.self, from: data)
        let previous = self.readData(CodexPaths.configTomlURL)
        let previousAuth = self.readData(CodexPaths.authURL)
        var text = self.readString(CodexPaths.configTomlURL) ?? ""
        for key in self.modelRoutingSettingKeys {
            if let value = state.settings[key] { text = self.upsertSetting(text, key: key, value: self.quote(value)) }
            else { text = self.removeSetting(text, key: key) }
        }
        text = self.restoreCompression(text, line: state.compression)
        if config.activeProvider()?.kind == .openAIOAuth && config.openAI.accountUsageMode == .switchAccount {
            text = self.upsertSetting(text, key: "model_provider", value: self.quote("openai"))
            text = self.removeSetting(text, key: "openai_base_url")
        }
        for key in ["model", "review_model"] where self.settingValue(for: key, in: text) == CodexModelRouting.modelID {
            text = self.upsertSetting(text, key: key, value: self.quote(state.fallbackModel ?? config.global.sanitizedDefaultModel))
        }
        do {
            try self.writeSecureFile(Data(text.utf8), CodexPaths.configTomlURL)
            // Exiting integration always retains OAuth, including tokens refreshed by Codex.
            if let oauth = self.oauthLoginAccount(in: config),
               self.readData(CodexPaths.authURL).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["tokens"] == nil {
                try self.writeSecureFile(try self.renderAuthJSON(config: config, provider: oauth.provider, account: oauth.account), CodexPaths.authURL)
            }
            try self.removeFileIfPresent(CodexModelRouting.syncStateURL)
        } catch {
            try? self.restoreSnapshot(previous, at: CodexPaths.configTomlURL)
            try? self.restoreSnapshot(previousAuth, at: CodexPaths.authURL)
            throw error
        }
    }

    private func oauthLoginAccount(
        in config: CodexBarConfig
    ) -> (provider: CodexBarProvider, account: CodexBarProviderAccount)? {
        guard let provider = config.oauthProvider(),
              let account = provider.activeAccount,
              account.kind == .oauthTokens,
              account.accessToken?.isEmpty == false,
              account.refreshToken?.isEmpty == false,
              account.idToken?.isEmpty == false,
              account.openAIAccountId?.isEmpty == false else {
            return nil
        }
        return (provider, account)
    }

    private func restoreSnapshot(_ snapshot: Data?, at url: URL) throws {
        if let snapshot {
            try self.writeSecureFile(snapshot, url)
        } else if self.fileExists(url) {
            try self.removeFileIfPresent(url)
        }
    }

    private func renderAuthJSON(
        config: CodexBarConfig,
        provider: CodexBarProvider,
        account: CodexBarProviderAccount
    ) throws -> Data {
        let object: [String: Any]
        switch provider.kind {
        case .openAIOAuth:
            guard let accessToken = account.accessToken,
                  let refreshToken = account.refreshToken,
                  let idToken = account.idToken,
                  let accountId = account.openAIAccountId else {
                throw CodexSyncError.missingOAuthTokens
            }

            var authObject: [String: Any] = [
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": NSNull(),
                "last_refresh": ISO8601DateFormatter().string(from: account.tokenLastRefreshAt ?? account.lastRefresh ?? Date()),
                "tokens": [
                    "access_token": accessToken,
                    "refresh_token": refreshToken,
                    "id_token": idToken,
                    "account_id": accountId,
                ],
            ]
            if let clientID = account.oauthClientID, clientID.isEmpty == false {
                authObject["client_id"] = clientID
            }
            object = authObject

        case .openAICompatible:
            guard let apiKey = account.apiKey,
                  apiKey.isEmpty == false else {
                throw CodexSyncError.missingAPIKey
            }
            object = [
                "OPENAI_API_KEY": provider.isThirdPartyModelProvider
                    ? OpenAIAccountGatewayConfiguration.apiKey
                    : apiKey,
            ]
        case .openRouter:
            guard account.apiKey?.isEmpty == false else {
                throw CodexSyncError.missingAPIKey
            }
            object = [
                "OPENAI_API_KEY": OpenRouterGatewayConfiguration.apiKey,
            ]
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func renderConfigTOML(
        config: CodexBarConfig,
        existingText: String,
        global: CodexBarGlobalSettings,
        provider: CodexBarProvider,
        codexVisibleModel: String,
        codexVisibleReviewModel: String,
        hasOAuthLogin: Bool
    ) -> String {
        var text = existingText
        let modelProviderValue = "\"openai\""

        text = self.upsertSetting(text, key: "model_provider", value: modelProviderValue)
        text = self.upsertSetting(text, key: "model", value: self.quote(codexVisibleModel))
        text = self.upsertSetting(text, key: "review_model", value: self.quote(codexVisibleReviewModel))
        text = self.upsertSetting(text, key: "model_reasoning_effort", value: self.quote(global.reasoningEffort))

        // Preserve native OpenAI speed tiers so Codex fast/flex modes survive account sync.
        if provider.kind != .openAIOAuth {
            text = self.removeSetting(text, key: "service_tier")
        }
        text = self.removeSetting(text, key: "oss_provider")
        text = self.removeSetting(text, key: "openai_base_url")
        text = self.removeSetting(text, key: "preferred_auth_method")
        text = self.removeBlock(text, key: "OpenAI")
        text = self.removeBlock(text, key: "openai")

        var usesCustomBaseURL = false
        if hasOAuthLogin,
                  config.openAI.accountUsageMode == .hybridProvider,
                  provider.kind == .openAICompatible || provider.kind == .openRouter {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(OpenAIAccountGatewayConfiguration.baseURLString)
            )
            usesCustomBaseURL = true
        } else if provider.kind == .openRouter {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(OpenRouterGatewayConfiguration.baseURLString)
            )
            usesCustomBaseURL = true
        } else if provider.isThirdPartyModelProvider {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(OpenAIAccountGatewayConfiguration.baseURLString)
            )
            usesCustomBaseURL = true
        } else if provider.kind == .openAICompatible, let baseURL = provider.baseURL {
            text = self.upsertSetting(text, key: "openai_base_url", value: self.quote(baseURL))
            usesCustomBaseURL = true
        }

        if usesCustomBaseURL {
            text = self.upsertFeatureFlag(text, key: "enable_request_compression", value: false)
        }

        return text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func codexVisibleModel(
        provider: CodexBarProvider,
        upstreamModel: String,
        global: CodexBarGlobalSettings,
        savedTargetModel: OpenAIModelStateSnapshot?,
        savedOpenAIModel: OpenAIModelStateSnapshot?,
        locksCodexModelToOpenAI: Bool
    ) -> String {
        if locksCodexModelToOpenAI {
            return savedOpenAIModel?.model ?? global.sanitizedDefaultModel
        }
        if provider.kind == .openAIOAuth {
            return savedTargetModel?.model ?? savedOpenAIModel?.model ?? global.sanitizedDefaultModel
        }
        return upstreamModel
    }

    private func codexVisibleReviewModel(
        provider: CodexBarProvider,
        codexVisibleModel: String,
        upstreamModel: String,
        global: CodexBarGlobalSettings,
        savedTargetModel: OpenAIModelStateSnapshot?,
        savedOpenAIModel: OpenAIModelStateSnapshot?,
        locksCodexModelToOpenAI: Bool
    ) -> String {
        if locksCodexModelToOpenAI {
            return savedOpenAIModel?.reviewModel ?? savedOpenAIModel?.model ?? codexVisibleModel
        }
        if provider.kind == .openAIOAuth {
            return savedTargetModel?.reviewModel ?? savedOpenAIModel?.reviewModel ?? global.sanitizedReviewModel
        }
        return savedTargetModel?.reviewModel ?? savedOpenAIModel?.reviewModel ?? global.sanitizedReviewModel
    }

    private func shouldLockCodexModelToOpenAI(
        config: CodexBarConfig,
        provider: CodexBarProvider,
        hasOAuthLogin: Bool
    ) -> Bool {
        if provider.isThirdPartyModelProvider {
            return true
        }
        switch provider.kind {
        case .openAIOAuth:
            return config.openAI.accountUsageMode == .hybridProvider
        case .openAICompatible:
            return hasOAuthLogin && config.openAI.accountUsageMode == .hybridProvider
        case .openRouter:
            return true
        }
    }

    private func openAIModelSnapshot(from tomlText: String) -> OpenAIModelSnapshot? {
        guard self.isOpenAIBackedTOML(tomlText),
              let model = OpenAIModelStateStore.normalizedOpenAIModel(
                self.settingValue(for: "model", in: tomlText)
              ) else {
            return nil
        }
        return OpenAIModelSnapshot(
            model: model,
            reviewModel: OpenAIModelStateStore.normalizedOpenAIModel(
                self.settingValue(for: "review_model", in: tomlText)
            )
        )
    }

    private func modelSnapshot(from tomlText: String, targetKey: String) -> OpenAIModelSnapshot? {
        let normalizedModel: (String?) -> String?
        if OpenAIModelStateStore.isOpenAITargetKey(targetKey) {
            normalizedModel = OpenAIModelStateStore.normalizedOpenAIModel
        } else {
            normalizedModel = OpenAIModelStateStore.normalizedProviderModel
        }
        guard let model = normalizedModel(self.settingValue(for: "model", in: tomlText)) else {
            return nil
        }
        return OpenAIModelSnapshot(
            model: model,
            reviewModel: normalizedModel(self.settingValue(for: "review_model", in: tomlText))
        )
    }

    private func modelStateTargetKey(
        for provider: CodexBarProvider,
        account: CodexBarProviderAccount,
        usageMode: CodexBarOpenAIAccountUsageMode
    ) -> String {
        switch provider.kind {
        case .openAIOAuth:
            return "openai:oauth:\(account.id)"
        case .openAICompatible:
            return "provider:\(provider.id):\(account.id)"
        case .openRouter:
            return "openrouter:\(account.id)"
        }
    }

    private func isOpenAIBackedTOML(_ text: String) -> Bool {
        guard let baseURL = self.settingValue(for: "openai_base_url", in: text) else {
            return true
        }
        return baseURL == OpenAIAccountGatewayConfiguration.baseURLString
    }

    private func settingValue(for key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^#(key)\s*=\s*(?:"([^"]*)"|([^\n#]+))"#
                .replacingOccurrences(
                    of: "#(key)",
                    with: NSRegularExpression.escapedPattern(for: key)
                )
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound,
                  let swiftRange = Range(matchRange, in: text) else {
                continue
            }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func upsertSetting(_ text: String, key: String, value: String) -> String {
        let line = "\(key) = \(value)"
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^#(key)\s*=.*$"#.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: line)
        }
        return line + "\n" + text
    }

    private func removeSetting(_ text: String, key: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^#(key)\s*=.*$\n?"#.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func removeBlock(_ text: String, key: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?ms)^\[model_providers\.#(key)\]\n.*?(?=^\[|\Z)"#.replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Codex compresses streaming Responses request bodies with zstd when it talks to the
    /// built-in OpenAI provider through an OAuth backend auth. The local gateway cannot
    /// decode zstd request bodies, so synced configs must keep that transport compression
    /// disabled while a custom or gateway base URL is in use.
    private func upsertFeatureFlag(_ text: String, key: String, value: Bool) -> String {
        let literal = "\(key) = \(value ? "true" : "false")"
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let headerPattern = #"(?m)^\[features\][ \t]*$"#
        guard let headerRegex = try? NSRegularExpression(pattern: headerPattern),
              let headerMatch = headerRegex.firstMatch(in: text, range: fullRange) else {
            let separator = text.hasSuffix("\n") || text.isEmpty ? "" : "\n"
            return text + separator + "\n[features]\n" + literal + "\n"
        }

        let blockStart = headerMatch.range.upperBound
        let remainderRange = NSRange(location: blockStart, length: nsText.length - blockStart)
        let nextHeaderPattern = #"(?m)^\[[^\]]+\][ \t]*$"#
        let nextHeaderRegex = try? NSRegularExpression(pattern: nextHeaderPattern)
        let blockEnd = nextHeaderRegex?.firstMatch(in: text, range: remainderRange)?.range.location
            ?? nsText.length
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        let block = nsText.substring(with: blockRange)
        let blockNS = block as NSString
        let blockFullRange = NSRange(location: 0, length: blockNS.length)

        let settingPattern = #"(?m)^[ \t]*"#
            + NSRegularExpression.escapedPattern(for: key)
            + #"[ \t]*=.*$"#
        guard let settingRegex = try? NSRegularExpression(pattern: settingPattern) else {
            return text
        }
        if settingRegex.firstMatch(in: block, range: blockFullRange) != nil {
            let replaced = settingRegex.stringByReplacingMatches(
                in: block,
                range: blockFullRange,
                withTemplate: literal
            )
            return nsText.replacingCharacters(in: blockRange, with: replaced)
        }

        let updatedBlock = "\n" + literal + block
        return nsText.replacingCharacters(in: blockRange, with: updatedBlock)
    }
}

struct CodexHistoryProviderMergeService {
    private let stateDBURLProvider: () -> URL
    private let fileExists: (URL) -> Bool

    init(
        stateDBURL: @autoclosure @escaping () -> URL = CodexPaths.stateSQLiteURL,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.stateDBURLProvider = stateDBURL
        self.fileExists = fileExists
    }

    func providerIDsToMerge(from tomlText: String) -> [String] {
        var candidates = Set<String>()
        if let activeProviderID = self.settingValue(for: "model_provider", in: tomlText) {
            candidates.insert(activeProviderID)
        }
        for providerID in self.modelProviderBlockIDs(in: tomlText) {
            candidates.insert(providerID)
        }
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { self.shouldMergeProviderID($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func mergeProviderIDsIntoOpenAI(_ providerIDs: [String]) {
        let providerIDs = providerIDs.filter(self.shouldMergeProviderID(_:))
        guard providerIDs.isEmpty == false else { return }

        let stateDBURL = self.stateDBURLProvider()
        guard self.fileExists(stateDBURL) else { return }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(stateDBURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let database else {
            sqlite3_close(database)
            return
        }
        defer { sqlite3_close(database) }

        guard self.tableHasModelProviderColumn(database) else { return }

        var preparedStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE threads SET model_provider = ? WHERE model_provider = ?",
            -1,
            &preparedStatement,
            nil
        ) == SQLITE_OK else {
            return
        }
        guard let statement = preparedStatement else { return }
        defer { sqlite3_finalize(statement) }

        for providerID in providerIDs {
            guard sqlite3_reset(statement) == SQLITE_OK,
                  sqlite3_clear_bindings(statement) == SQLITE_OK,
                  sqlite3_bind_text(statement, 1, "openai", -1, codexSyncSQLiteTransientDestructor) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, providerID, -1, codexSyncSQLiteTransientDestructor) == SQLITE_OK else {
                continue
            }
            _ = sqlite3_step(statement)
        }
    }

    private func shouldMergeProviderID(_ providerID: String) -> Bool {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        return trimmed != "openai"
    }

    private func settingValue(for key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^#(key)\s*=\s*(?:"([^"]*)"|([^\n#]+))"#
                .replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound,
                  let swiftRange = Range(matchRange, in: text) else {
                continue
            }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func modelProviderBlockIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\[model_providers\.([^\]\s]+)\]"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func tableHasModelProviderColumn(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnNamePointer = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: columnNamePointer) == "model_provider" {
                return true
            }
        }
        return false
    }
}
