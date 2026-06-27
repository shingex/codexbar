import AppKit
import Foundation

private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(Value.self)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyStringEnum<T>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T
    ) throws -> T where T: RawRepresentable, T.RawValue == String {
        guard let rawValue = try self.decodeIfPresent(String.self, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false,
              let value = T(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }
}

enum CodexBarProviderKind: String, Codable {
    case openAIOAuth = "openai_oauth"
    case openAICompatible = "openai_compatible"
    case openRouter = "openrouter"
}

enum CodexBarThirdPartyModelProvider: String, Codable, CaseIterable, Identifiable {
    case deepSeek = "deepseek"
    case mimo = "mimo"
    case custom = "custom"

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .mimo: return "MiMo"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com"
        case .mimo: return "https://api.xiaomimimo.com/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: return "deepseek-v4-pro"
        case .mimo: return "mimo-v2.5-pro"
        case .custom: return ""
        }
    }

    var supportedModels: [String] {
        switch self {
        case .deepSeek:
            return ["deepseek-v4-pro", "deepseek-v4-flash"]
        case .mimo:
            return ["mimo-v2.5-pro", "mimo-v2.5"]
        case .custom:
            return []
        }
    }

    var snapshotModelIDs: [String] {
        [self.defaultModel] + self.supportedModels
    }

    static var knownSnapshotModelIDs: Set<String> {
        Set(Self.allCases.flatMap(\.snapshotModelIDs).filter { $0.isEmpty == false })
    }
}

enum CodexBarUsageDisplayMode: String, Codable, CaseIterable, Identifiable {
    case remaining
    case used

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .remaining:
            return L.remainingUsageDisplay
        case .used:
            return L.usedQuotaDisplay
        }
    }

    var badgeTitle: String {
        switch self {
        case .remaining:
            return L.remainingShort
        case .used:
            return L.usedShort
        }
    }
}

enum CodexBarAccountKind: String, Codable {
    case oauthTokens = "oauth_tokens"
    case apiKey = "api_key"
}

struct CodexBarGlobalSettings: Codable {
    static let defaultOpenAIModel = "gpt-5.4"

    var defaultModel: String
    var reviewModel: String
    var reasoningEffort: String

    init(defaultModel: String = Self.defaultOpenAIModel, reviewModel: String = Self.defaultOpenAIModel, reasoningEffort: String = "xhigh") {
        self.defaultModel = defaultModel
        self.reviewModel = reviewModel
        self.reasoningEffort = reasoningEffort
    }

    var sanitizedDefaultModel: String {
        let reviewFallback = Self.sanitizedOpenAIModel(self.reviewModel)
        return Self.sanitizedOpenAIModel(self.defaultModel, fallback: reviewFallback)
    }

    var sanitizedReviewModel: String {
        Self.sanitizedOpenAIModel(self.reviewModel, fallback: self.sanitizedDefaultModel)
    }

    static func sanitizedOpenAIModel(_ value: String?, fallback: String = Self.defaultOpenAIModel) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false,
              self.isProviderRoutedModelIdentifier(trimmed) == false else {
            return fallback
        }
        return trimmed
    }

    mutating func sanitizeOpenAIModels() -> Bool {
        let sanitizedDefault = self.sanitizedDefaultModel
        let sanitizedReview = Self.sanitizedOpenAIModel(self.reviewModel, fallback: sanitizedDefault)
        guard sanitizedDefault != self.defaultModel || sanitizedReview != self.reviewModel else {
            return false
        }
        self.defaultModel = sanitizedDefault
        self.reviewModel = sanitizedReview
        return true
    }

    private static func isProviderRoutedModelIdentifier(_ value: String) -> Bool {
        value.contains("/")
    }
}

struct CodexBarActiveSelection: Codable, Equatable {
    var providerId: String?
    var accountId: String?
}

struct CodexBarDesktopSettings: Codable, Equatable {
    var preferredCodexAppPath: String?

    enum CodingKeys: String, CodingKey {
        case preferredCodexAppPath
    }

    init(preferredCodexAppPath: String? = nil) {
        self.preferredCodexAppPath = Self.normalizedPreferredCodexAppPath(preferredCodexAppPath)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preferredCodexAppPath = Self.normalizedPreferredCodexAppPath(
            try container.decodeIfPresent(String.self, forKey: .preferredCodexAppPath)
        )
    }

    private static func normalizedPreferredCodexAppPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

struct CodexBarModelPricing: Codable, Equatable {
    var inputUSDPerToken: Double
    var cachedInputUSDPerToken: Double
    var outputUSDPerToken: Double

    enum CodingKeys: String, CodingKey {
        case inputUSDPerToken
        case cachedInputUSDPerToken
        case outputUSDPerToken
    }

    static let zero = CodexBarModelPricing(
        inputUSDPerToken: 0,
        cachedInputUSDPerToken: 0,
        outputUSDPerToken: 0
    )

    init(
        inputUSDPerToken: Double,
        cachedInputUSDPerToken: Double,
        outputUSDPerToken: Double
    ) {
        self.inputUSDPerToken = Self.sanitizedPrice(inputUSDPerToken)
        self.cachedInputUSDPerToken = Self.sanitizedPrice(cachedInputUSDPerToken)
        self.outputUSDPerToken = Self.sanitizedPrice(outputUSDPerToken)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputUSDPerToken: try container.decodeIfPresent(Double.self, forKey: .inputUSDPerToken) ?? 0,
            cachedInputUSDPerToken: try container.decodeIfPresent(Double.self, forKey: .cachedInputUSDPerToken) ?? 0,
            outputUSDPerToken: try container.decodeIfPresent(Double.self, forKey: .outputUSDPerToken) ?? 0
        )
    }

    private static func sanitizedPrice(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }
}

enum CodexBarOpenAIManualActivationBehavior: String, Codable, CaseIterable, Identifiable {
    case updateConfigOnly
    case launchNewInstance

    var id: String { self.rawValue }
}

enum CodexBarOpenAIAccountUsageMode: String, Codable, CaseIterable, Identifiable {
    case switchAccount = "switch"
    case aggregateGateway = "aggregate_gateway"
    case hybridProvider = "hybrid_provider"

    var id: String { self.rawValue }

    var menuToggleTitle: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchShort
        case .aggregateGateway:
            return L.accountUsageModeAggregateShort
        case .hybridProvider:
            return L.accountUsageModeHybridShort
        }
    }

    var themeAccentColor: NSColor {
        switch self {
        case .switchAccount:
            return Self.manualModeAccentColor
        case .aggregateGateway:
            return .systemGreen
        case .hybridProvider:
            return .systemBlue
        }
    }

    static var manualModeAccentColor: NSColor {
        NSColor(calibratedRed: 0x7c / 255.0, green: 0x38 / 255.0, blue: 0xe9 / 255.0, alpha: 1.0)
    }
}

enum CodexBarOpenAIAccountOrderingMode: String, Codable, CaseIterable, Identifiable {
    case quotaSort
    case manual

    var id: String { self.rawValue }
}

struct CodexBarOpenAISettings: Codable, Equatable {
    struct QuotaSortSettings: Codable, Equatable {
        static let plusRelativeWeightRange = 1.0...20.0
        static let proRelativeToPlusRange = 5.0...30.0
        static let teamRelativeToPlusRange = 1.0...3.0

        var plusRelativeWeight: Double
        var proRelativeToPlusMultiplier: Double
        var teamRelativeToPlusMultiplier: Double

        enum CodingKeys: String, CodingKey {
            case plusRelativeWeight
            case proRelativeToPlusMultiplier
            case teamRelativeToPlusMultiplier
        }

        nonisolated init(
            plusRelativeWeight: Double = 10,
            proRelativeToPlusMultiplier: Double = 10,
            teamRelativeToPlusMultiplier: Double = 1.5
        ) {
            self.plusRelativeWeight = Self.clamped(
                plusRelativeWeight,
                to: Self.plusRelativeWeightRange
            )
            self.proRelativeToPlusMultiplier = Self.clamped(
                proRelativeToPlusMultiplier,
                to: Self.proRelativeToPlusRange
            )
            self.teamRelativeToPlusMultiplier = Self.clamped(
                teamRelativeToPlusMultiplier,
                to: Self.teamRelativeToPlusRange
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                plusRelativeWeight: try container.decodeIfPresent(Double.self, forKey: .plusRelativeWeight) ?? 10,
                proRelativeToPlusMultiplier: try container.decodeIfPresent(Double.self, forKey: .proRelativeToPlusMultiplier) ?? 10,
                teamRelativeToPlusMultiplier: try container.decodeIfPresent(Double.self, forKey: .teamRelativeToPlusMultiplier) ?? 1.5
            )
        }

        nonisolated var proAbsoluteWeight: Double {
            self.plusRelativeWeight * self.proRelativeToPlusMultiplier
        }

        nonisolated var teamAbsoluteWeight: Double {
            self.plusRelativeWeight * self.teamRelativeToPlusMultiplier
        }

        nonisolated private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }
    }

    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var switchModeSelection: CodexBarActiveSelection?
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
    var manualActivationBehavior: CodexBarOpenAIManualActivationBehavior
    var usageDisplayMode: CodexBarUsageDisplayMode
    var disableLocalUsageStats: Bool
    var quotaSort: QuotaSortSettings
    var interopProxiesJSON: String?

    enum CodingKeys: String, CodingKey {
        case accountOrder
        case accountUsageMode
        case switchModeSelection
        case accountOrderingMode
        case manualActivationBehavior
        case usageDisplayMode
        case disableLocalUsageStats
        case quotaSort
        case interopProxiesJSON
    }

    init(
        accountOrder: [String] = [],
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount,
        switchModeSelection: CodexBarActiveSelection? = nil,
        accountOrderingMode: CodexBarOpenAIAccountOrderingMode = .quotaSort,
        manualActivationBehavior: CodexBarOpenAIManualActivationBehavior = .updateConfigOnly,
        usageDisplayMode: CodexBarUsageDisplayMode = .used,
        disableLocalUsageStats: Bool = false,
        quotaSort: QuotaSortSettings = QuotaSortSettings(),
        interopProxiesJSON: String? = nil
    ) {
        self.accountOrder = accountOrder
        self.accountUsageMode = accountUsageMode
        self.switchModeSelection = switchModeSelection
        self.accountOrderingMode = accountOrderingMode
        self.manualActivationBehavior = manualActivationBehavior
        self.usageDisplayMode = usageDisplayMode
        self.disableLocalUsageStats = disableLocalUsageStats
        self.quotaSort = quotaSort
        self.interopProxiesJSON = interopProxiesJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountOrder = try container.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
        self.accountUsageMode = try container.decodeLossyStringEnum(
            CodexBarOpenAIAccountUsageMode.self,
            forKey: .accountUsageMode,
            default: .switchAccount
        )
        self.switchModeSelection = try container.decodeIfPresent(
            CodexBarActiveSelection.self,
            forKey: .switchModeSelection
        )
        self.accountOrderingMode = try container.decodeLossyStringEnum(
            CodexBarOpenAIAccountOrderingMode.self,
            forKey: .accountOrderingMode,
            default: .quotaSort
        )
        self.manualActivationBehavior = try container.decodeLossyStringEnum(
            CodexBarOpenAIManualActivationBehavior.self,
            forKey: .manualActivationBehavior,
            default: .updateConfigOnly
        )
        self.usageDisplayMode = try container.decodeLossyStringEnum(
            CodexBarUsageDisplayMode.self,
            forKey: .usageDisplayMode,
            default: .used
        )
        self.disableLocalUsageStats = try container.decodeIfPresent(Bool.self, forKey: .disableLocalUsageStats) ?? false
        self.quotaSort = try container.decodeIfPresent(QuotaSortSettings.self, forKey: .quotaSort) ?? QuotaSortSettings()
        self.interopProxiesJSON = try container.decodeIfPresent(String.self, forKey: .interopProxiesJSON)
    }

    var preferredDisplayAccountOrder: [String] {
        self.accountOrderingMode == .manual ? self.accountOrder : []
    }
}

struct CodexBarOpenRouterSelection: Codable, Equatable {
    var selectedModelID: String?
    var pinnedModelIDs: [String]
    var cachedModelCatalog: [CodexBarOpenRouterModel]
    var modelCatalogFetchedAt: Date?

    init(
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        modelCatalogFetchedAt: Date? = nil
    ) {
        let normalizedSelectedModelID = CodexBarProvider.normalizedOpenRouterModelID(selectedModelID)
        self.selectedModelID = normalizedSelectedModelID
        self.pinnedModelIDs = CodexBarProvider.resolvedPinnedModelIDs(
            pinnedModelIDs,
            selectedModelID: normalizedSelectedModelID
        )
        self.cachedModelCatalog = CodexBarConfig.uniqueOpenRouterModelCatalog(cachedModelCatalog)
        self.modelCatalogFetchedAt = modelCatalogFetchedAt
    }

    var effectiveModelID: String? {
        CodexBarProvider.normalizedOpenRouterModelID(self.selectedModelID)
    }

    func updating(
        selectedModelID: String?,
        pinnedModelIDs: [String]? = nil,
        cachedModelCatalog: [CodexBarOpenRouterModel]? = nil,
        fetchedAt: Date? = nil
    ) -> CodexBarOpenRouterSelection {
        return CodexBarOpenRouterSelection(
            selectedModelID: selectedModelID,
            pinnedModelIDs: pinnedModelIDs ?? self.pinnedModelIDs,
            cachedModelCatalog: cachedModelCatalog ?? self.cachedModelCatalog,
            modelCatalogFetchedAt: fetchedAt ?? self.modelCatalogFetchedAt
        )
    }

    var withoutCachedModelCatalog: CodexBarOpenRouterSelection {
        CodexBarOpenRouterSelection(
            selectedModelID: self.selectedModelID,
            pinnedModelIDs: self.pinnedModelIDs,
            cachedModelCatalog: [],
            modelCatalogFetchedAt: nil
        )
    }
}

struct CodexBarProviderAccount: Codable, Identifiable, Equatable {
    var id: String
    var kind: CodexBarAccountKind
    var label: String

    var email: String?
    var openAIAccountId: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var oauthClientID: String?
    var tokenLastRefreshAt: Date?
    var lastRefresh: Date?

    var apiKey: String?
    var addedAt: Date?
    var openRouterSelection: CodexBarOpenRouterSelection?
    var thirdPartyModelSelection: CodexBarOpenRouterSelection?

    // Runtime quota snapshot for OAuth accounts.
    var planType: String?
    var primaryUsedPercent: Double?
    var secondaryUsedPercent: Double?
    var primaryResetAt: Date?
    var secondaryResetAt: Date?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var lastChecked: Date?
    var isSuspended: Bool?
    var tokenExpired: Bool?
    var organizationName: String?
    var interopProxyKey: String?
    var interopNotes: String?
    var interopConcurrency: Int?
    var interopPriority: Int?
    var interopRateMultiplier: Double?
    var interopAutoPauseOnExpired: Bool?
    var interopCredentialsJSON: String?
    var interopExtraJSON: String?

    init(
        id: String = UUID().uuidString,
        kind: CodexBarAccountKind,
        label: String,
        email: String? = nil,
        openAIAccountId: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        oauthClientID: String? = nil,
        tokenLastRefreshAt: Date? = nil,
        lastRefresh: Date? = nil,
        apiKey: String? = nil,
        addedAt: Date? = nil,
        openRouterSelection: CodexBarOpenRouterSelection? = nil,
        thirdPartyModelSelection: CodexBarOpenRouterSelection? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        primaryLimitWindowSeconds: Int? = nil,
        secondaryLimitWindowSeconds: Int? = nil,
        lastChecked: Date? = nil,
        isSuspended: Bool? = nil,
        tokenExpired: Bool? = nil,
        organizationName: String? = nil,
        interopProxyKey: String? = nil,
        interopNotes: String? = nil,
        interopConcurrency: Int? = nil,
        interopPriority: Int? = nil,
        interopRateMultiplier: Double? = nil,
        interopAutoPauseOnExpired: Bool? = nil,
        interopCredentialsJSON: String? = nil,
        interopExtraJSON: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.email = email
        self.openAIAccountId = openAIAccountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.oauthClientID = oauthClientID
        self.tokenLastRefreshAt = tokenLastRefreshAt
        self.lastRefresh = lastRefresh
        self.apiKey = apiKey
        self.addedAt = addedAt
        self.openRouterSelection = openRouterSelection
        self.thirdPartyModelSelection = thirdPartyModelSelection
        self.planType = planType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.primaryLimitWindowSeconds = primaryLimitWindowSeconds
        self.secondaryLimitWindowSeconds = secondaryLimitWindowSeconds
        self.lastChecked = lastChecked
        self.isSuspended = isSuspended
        self.tokenExpired = tokenExpired
        self.organizationName = organizationName
        self.interopProxyKey = interopProxyKey
        self.interopNotes = interopNotes
        self.interopConcurrency = interopConcurrency
        self.interopPriority = interopPriority
        self.interopRateMultiplier = interopRateMultiplier
        self.interopAutoPauseOnExpired = interopAutoPauseOnExpired
        self.interopCredentialsJSON = interopCredentialsJSON
        self.interopExtraJSON = interopExtraJSON
    }

    var maskedAPIKey: String {
        guard let apiKey, apiKey.count > 8 else { return apiKey ?? "" }
        return String(apiKey.prefix(6)) + "..." + String(apiKey.suffix(4))
    }

    func asTokenAccount(isActive: Bool) -> TokenAccount? {
        self.rawTokenAccount(isActive: isActive)?.normalizedQuotaSnapshot()
    }

    func sanitizedQuotaSnapshot(now: Date = Date()) -> CodexBarProviderAccount {
        guard let normalized = self.rawTokenAccount(isActive: false)?.normalizedQuotaSnapshot(now: now) else {
            return self
        }

        var sanitized = self
        sanitized.planType = normalized.planType
        sanitized.primaryUsedPercent = normalized.primaryUsedPercent
        sanitized.secondaryUsedPercent = normalized.secondaryUsedPercent
        sanitized.primaryResetAt = normalized.primaryResetAt
        sanitized.secondaryResetAt = normalized.secondaryResetAt
        sanitized.primaryLimitWindowSeconds = normalized.primaryLimitWindowSeconds
        sanitized.secondaryLimitWindowSeconds = normalized.secondaryLimitWindowSeconds
        sanitized.lastChecked = normalized.lastChecked
        sanitized.isSuspended = normalized.isSuspended
        sanitized.tokenExpired = normalized.tokenExpired
        sanitized.organizationName = normalized.organizationName
        return sanitized
    }

    private func rawTokenAccount(isActive: Bool) -> TokenAccount? {
        guard self.kind == .oauthTokens,
              let accessToken = self.accessToken,
              let refreshToken = self.refreshToken,
              let idToken = self.idToken else { return nil }

        let localAccountID = self.id
        let remoteAccountID = self.openAIAccountId ?? localAccountID

        return TokenAccount(
            email: self.email ?? self.label,
            accountId: localAccountID,
            openAIAccountId: remoteAccountID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: self.expiresAt,
            oauthClientID: self.oauthClientID,
            planType: self.planType ?? "free",
            primaryUsedPercent: self.primaryUsedPercent ?? 0,
            secondaryUsedPercent: self.secondaryUsedPercent ?? 0,
            primaryResetAt: self.primaryResetAt,
            secondaryResetAt: self.secondaryResetAt,
            primaryLimitWindowSeconds: self.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: self.secondaryLimitWindowSeconds,
            lastChecked: self.lastChecked,
            isActive: isActive,
            isSuspended: self.isSuspended ?? false,
            tokenExpired: self.tokenExpired ?? false,
            tokenLastRefreshAt: self.tokenLastRefreshAt ?? self.lastRefresh,
            organizationName: self.organizationName
        )
    }

    static func fromTokenAccount(_ account: TokenAccount, existingID: String? = nil) -> CodexBarProviderAccount {
        let normalizedAccount = account.normalizedQuotaSnapshot()
        return CodexBarProviderAccount(
            id: existingID ?? normalizedAccount.accountId,
            kind: .oauthTokens,
            label: normalizedAccount.email.isEmpty ? normalizedAccount.accountId : normalizedAccount.email,
            email: normalizedAccount.email,
            openAIAccountId: normalizedAccount.remoteAccountId,
            accessToken: normalizedAccount.accessToken,
            refreshToken: normalizedAccount.refreshToken,
            idToken: normalizedAccount.idToken,
            expiresAt: normalizedAccount.expiresAt,
            oauthClientID: normalizedAccount.oauthClientID,
            tokenLastRefreshAt: normalizedAccount.tokenLastRefreshAt,
            lastRefresh: normalizedAccount.tokenLastRefreshAt,
            addedAt: Date(),
            planType: normalizedAccount.planType,
            primaryUsedPercent: normalizedAccount.primaryUsedPercent,
            secondaryUsedPercent: normalizedAccount.secondaryUsedPercent,
            primaryResetAt: normalizedAccount.primaryResetAt,
            secondaryResetAt: normalizedAccount.secondaryResetAt,
            primaryLimitWindowSeconds: normalizedAccount.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: normalizedAccount.secondaryLimitWindowSeconds,
            lastChecked: normalizedAccount.lastChecked,
            isSuspended: normalizedAccount.isSuspended,
            tokenExpired: normalizedAccount.tokenExpired,
            organizationName: normalizedAccount.organizationName
        )
    }
}

struct CodexBarOpenRouterModel: Codable, Equatable, Identifiable {
    var id: String
    var name: String

    init(id: String, name: String? = nil) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = normalizedID
        self.name = normalizedName?.isEmpty == false ? normalizedName! : normalizedID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name)
        )
    }
}

struct CodexBarProviderUsageConfiguration: Codable, Equatable {
    var requestURL: String?
    var requestHeaders: [String: String]
    var timeoutSeconds: Double
    var intervalMinutes: Int

    init(
        requestURL: String? = nil,
        requestHeaders: [String: String] = [:],
        timeoutSeconds: Double = 30,
        intervalMinutes: Int = 0
    ) {
        self.requestURL = Self.normalizedURLString(requestURL)
        self.requestHeaders = Self.normalizedHeaders(requestHeaders)
        self.timeoutSeconds = Self.sanitizedTimeout(timeoutSeconds)
        self.intervalMinutes = Self.sanitizedInterval(intervalMinutes)
    }

    enum CodingKeys: String, CodingKey {
        case requestURL
        case requestHeaders
        case timeoutSeconds
        case intervalMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            requestURL: try container.decodeIfPresent(String.self, forKey: .requestURL),
            requestHeaders: try container.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:],
            timeoutSeconds: try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30,
            intervalMinutes: try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 0
        )
    }

    private static func normalizedURLString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            let name = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false, value.isEmpty == false else { return }
            result[name] = value
        }
    }

    private static func sanitizedTimeout(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 30 }
        return min(max(value, 1), 300)
    }

    private static func sanitizedInterval(_ value: Int) -> Int {
        max(value, 0)
    }
}

struct CodexBarProviderUsagePeriod: Codable, Equatable {
    var used: Double?
    var limit: Double?
    var remaining: Double?

    init(used: Double? = nil, limit: Double? = nil, remaining: Double? = nil) {
        self.used = Self.sanitizedNumber(used)
        self.limit = Self.sanitizedNumber(limit)
        self.remaining = Self.sanitizedNumber(remaining)

        if self.used == nil,
           let limit = self.limit,
           let remaining = self.remaining {
            self.used = max(limit - remaining, 0)
        }
        if self.remaining == nil,
           let used = self.used,
           let limit = self.limit {
            self.remaining = max(limit - used, 0)
        }
    }

    var hasAnyValue: Bool {
        self.used != nil || self.limit != nil || self.remaining != nil
    }

    var isUnlimited: Bool {
        guard let limit else { return true }
        return limit <= 0
    }

    var usageRatio: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return used / limit
    }

    var displayProgressRatio: Double? {
        guard let usageRatio else { return nil }
        return min(max(usageRatio, 0), 1)
    }

    func displayedAmount(mode: CodexBarUsageDisplayMode) -> Double? {
        switch mode {
        case .remaining:
            return self.remaining
        case .used:
            return self.used
        }
    }

    func displayedRatio(mode: CodexBarUsageDisplayMode) -> Double? {
        guard let usageRatio else { return nil }
        switch mode {
        case .remaining:
            return max(0, 1 - usageRatio)
        case .used:
            return usageRatio
        }
    }

    func displayedProgressRatio(mode: CodexBarUsageDisplayMode) -> Double? {
        guard let displayedRatio = self.displayedRatio(mode: mode) else { return nil }
        return min(max(displayedRatio, 0), 1)
    }

    private static func sanitizedNumber(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

struct CodexBarProviderUsageBalanceDetail: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var amount: Double

    var id: String { self.key }

    init(key: String, label: String, amount: Double) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = normalizedLabel.isEmpty ? self.key : normalizedLabel
        self.amount = amount.isFinite ? amount : 0
    }
}

struct CodexBarProviderUsageData: Codable, Equatable {
    var isValid: Bool?
    var unit: String
    var remaining: Double?
    var today: CodexBarProviderUsagePeriod
    var weekly: CodexBarProviderUsagePeriod
    var monthly: CodexBarProviderUsagePeriod
    var totalUsed: Double?
    var planName: String?
    var expiresAt: String?
    var balanceDetails: [CodexBarProviderUsageBalanceDetail]

    enum CodingKeys: String, CodingKey {
        case isValid
        case unit
        case remaining
        case today
        case weekly
        case monthly
        case totalUsed
        case planName
        case expiresAt
        case balanceDetails
    }

    init(
        isValid: Bool? = nil,
        unit: String = "USD",
        remaining: Double? = nil,
        today: CodexBarProviderUsagePeriod = CodexBarProviderUsagePeriod(),
        weekly: CodexBarProviderUsagePeriod = CodexBarProviderUsagePeriod(),
        monthly: CodexBarProviderUsagePeriod = CodexBarProviderUsagePeriod(),
        totalUsed: Double? = nil,
        planName: String? = nil,
        expiresAt: String? = nil,
        balanceDetails: [CodexBarProviderUsageBalanceDetail] = []
    ) {
        self.isValid = isValid
        self.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "USD" : unit.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remaining = Self.sanitizedNumber(remaining)
        self.today = today
        self.weekly = weekly
        self.monthly = monthly
        self.totalUsed = Self.sanitizedNumber(totalUsed)
        self.planName = Self.normalizedString(planName)
        self.expiresAt = Self.normalizedString(expiresAt)
        self.balanceDetails = balanceDetails.filter { $0.key.isEmpty == false }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isValid: try container.decodeIfPresent(Bool.self, forKey: .isValid),
            unit: try container.decodeIfPresent(String.self, forKey: .unit) ?? "USD",
            remaining: try container.decodeIfPresent(Double.self, forKey: .remaining),
            today: try container.decodeIfPresent(CodexBarProviderUsagePeriod.self, forKey: .today) ?? CodexBarProviderUsagePeriod(),
            weekly: try container.decodeIfPresent(CodexBarProviderUsagePeriod.self, forKey: .weekly) ?? CodexBarProviderUsagePeriod(),
            monthly: try container.decodeIfPresent(CodexBarProviderUsagePeriod.self, forKey: .monthly) ?? CodexBarProviderUsagePeriod(),
            totalUsed: try container.decodeIfPresent(Double.self, forKey: .totalUsed),
            planName: try container.decodeIfPresent(String.self, forKey: .planName),
            expiresAt: try container.decodeIfPresent(String.self, forKey: .expiresAt),
            balanceDetails: try container.decodeIfPresent([CodexBarProviderUsageBalanceDetail].self, forKey: .balanceDetails) ?? []
        )
    }

    var hasDetectedUsageFields: Bool {
        self.isValid != nil ||
            self.remaining != nil ||
            self.today.hasAnyValue ||
            self.weekly.hasAnyValue ||
            self.monthly.hasAnyValue ||
            self.totalUsed != nil ||
            self.planName != nil ||
            self.expiresAt != nil ||
            self.balanceDetails.isEmpty == false
    }

    var isBalanceOnly: Bool {
        self.remaining != nil &&
            self.today.hasAnyValue == false &&
            self.weekly.hasAnyValue == false &&
            self.monthly.hasAnyValue == false &&
            self.totalUsed == nil
    }

    func period(for window: ProviderUsageWindow) -> CodexBarProviderUsagePeriod {
        switch window {
        case .today:
            return self.today
        case .weekly:
            return self.weekly
        case .monthly:
            return self.monthly
        }
    }

    private static func sanitizedNumber(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

struct CodexBarProviderAccountUsageSnapshot: Codable, Equatable, Identifiable {
    var accountID: String
    var accountLabel: String
    var maskedAPIKey: String
    var data: CodexBarProviderUsageData?
    var lastUpdatedAt: Date?
    var lastError: String?
    var rawResponse: String?

    var id: String { self.accountID }

    init(
        accountID: String,
        accountLabel: String,
        maskedAPIKey: String = "",
        data: CodexBarProviderUsageData? = nil,
        lastUpdatedAt: Date? = nil,
        lastError: String? = nil,
        rawResponse: String? = nil
    ) {
        self.accountID = accountID
        self.accountLabel = Self.normalizedString(accountLabel) ?? accountID
        self.maskedAPIKey = maskedAPIKey
        self.data = data
        self.lastUpdatedAt = lastUpdatedAt
        self.lastError = Self.normalizedString(lastError)
        self.rawResponse = rawResponse
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

struct CodexBarProviderUsageState: Codable, Equatable {
    var data: CodexBarProviderUsageData?
    var accountSnapshots: [CodexBarProviderAccountUsageSnapshot]
    var lastUpdatedAt: Date?
    var lastError: String?
    var rawResponse: String?

    init(
        data: CodexBarProviderUsageData? = nil,
        accountSnapshots: [CodexBarProviderAccountUsageSnapshot] = [],
        lastUpdatedAt: Date? = nil,
        lastError: String? = nil,
        rawResponse: String? = nil
    ) {
        self.data = data
        self.accountSnapshots = accountSnapshots
        self.lastUpdatedAt = lastUpdatedAt
        self.lastError = Self.normalizedString(lastError)
        self.rawResponse = rawResponse
    }

    enum CodingKeys: String, CodingKey {
        case data
        case accountSnapshots
        case lastUpdatedAt
        case lastError
        case rawResponse
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.data = try container.decodeIfPresent(CodexBarProviderUsageData.self, forKey: .data)
        self.accountSnapshots = try container.decodeIfPresent(
            [CodexBarProviderAccountUsageSnapshot].self,
            forKey: .accountSnapshots
        ) ?? []
        self.lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.rawResponse = try container.decodeIfPresent(String.self, forKey: .rawResponse)
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

enum ProviderUsageWindow: String, Codable, CaseIterable, Identifiable {
    case today
    case weekly
    case monthly

    var id: String { self.rawValue }
}

struct CodexBarProvider: Codable, Identifiable, Equatable {
    var id: String
    var kind: CodexBarProviderKind
    var label: String
    var enabled: Bool
    var baseURL: String?
    var defaultModel: String?
    var thirdPartyModelProvider: CodexBarThirdPartyModelProvider?
    var selectedModelID: String?
    var pinnedModelIDs: [String]
    var cachedModelCatalog: [CodexBarOpenRouterModel]
    var modelCatalogFetchedAt: Date?
    var activeAccountId: String?
    var usageConfiguration: CodexBarProviderUsageConfiguration?
    var usageState: CodexBarProviderUsageState?
    var accounts: [CodexBarProviderAccount]

    init(
        id: String,
        kind: CodexBarProviderKind,
        label: String,
        enabled: Bool = true,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        thirdPartyModelProvider: CodexBarThirdPartyModelProvider? = nil,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        modelCatalogFetchedAt: Date? = nil,
        activeAccountId: String? = nil,
        usageConfiguration: CodexBarProviderUsageConfiguration? = nil,
        usageState: CodexBarProviderUsageState? = nil,
        accounts: [CodexBarProviderAccount] = []
    ) {
        let normalizedDefaultModel = Self.normalizedDefaultModel(defaultModel)
        let normalizedSelectedModelID = Self.normalizedOpenRouterModelID(selectedModelID) ?? normalizedDefaultModel
        let normalizedPinnedModelIDs = Self.normalizedOpenRouterModelIDs(pinnedModelIDs)
        let resolvedPinnedModelIDs = Self.resolvedPinnedModelIDs(
            normalizedPinnedModelIDs,
            selectedModelID: normalizedSelectedModelID
        )
        self.id = id
        self.kind = kind
        self.label = label
        self.enabled = enabled
        self.baseURL = baseURL
        self.defaultModel = kind == .openRouter ? nil : normalizedDefaultModel
        self.thirdPartyModelProvider = kind == .openAICompatible ? thirdPartyModelProvider : nil
        self.selectedModelID = normalizedSelectedModelID
        self.pinnedModelIDs = resolvedPinnedModelIDs
        self.cachedModelCatalog = cachedModelCatalog
        self.modelCatalogFetchedAt = modelCatalogFetchedAt
        self.activeAccountId = activeAccountId
        self.usageConfiguration = usageConfiguration
        self.usageState = usageState
        self.accounts = accounts
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case enabled
        case baseURL
        case defaultModel
        case thirdPartyModelProvider
        case selectedModelID
        case pinnedModelIDs
        case cachedModelCatalog
        case modelCatalogFetchedAt
        case activeAccountId
        case usageConfiguration
        case usageState
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try container.decode(CodexBarProviderKind.self, forKey: .kind)
        let decodedDefaultModel = Self.normalizedDefaultModel(
            try container.decodeIfPresent(String.self, forKey: .defaultModel)
        )
        let decodedSelectedModelID = Self.normalizedOpenRouterModelID(
            try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        ) ?? decodedDefaultModel
        let decodedPinnedModelIDs = Self.resolvedPinnedModelIDs(
            Self.normalizedOpenRouterModelIDs(
                try container.decodeIfPresent([String].self, forKey: .pinnedModelIDs) ?? []
            ),
            selectedModelID: decodedSelectedModelID
        )
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = decodedKind
        self.label = try container.decode(String.self, forKey: .label)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.defaultModel = decodedKind == .openRouter ? nil : decodedDefaultModel
        if decodedKind == .openAICompatible {
            self.thirdPartyModelProvider = try container.decodeIfPresent(
                CodexBarThirdPartyModelProvider.self,
                forKey: .thirdPartyModelProvider
            )
        } else {
            self.thirdPartyModelProvider = nil
        }
        self.selectedModelID = decodedSelectedModelID
        self.pinnedModelIDs = decodedPinnedModelIDs
        self.cachedModelCatalog = try container.decodeIfPresent([CodexBarOpenRouterModel].self, forKey: .cachedModelCatalog) ?? []
        self.modelCatalogFetchedAt = try container.decodeIfPresent(Date.self, forKey: .modelCatalogFetchedAt)
        self.activeAccountId = try container.decodeIfPresent(String.self, forKey: .activeAccountId)
        self.usageConfiguration = try container.decodeIfPresent(CodexBarProviderUsageConfiguration.self, forKey: .usageConfiguration)
        self.usageState = try container.decodeIfPresent(CodexBarProviderUsageState.self, forKey: .usageState)
        self.accounts = (try container.decodeIfPresent(
            [FailableDecodable<CodexBarProviderAccount>].self,
            forKey: .accounts
        ) ?? []).compactMap(\.value)
    }

    var activeAccount: CodexBarProviderAccount? {
        if let activeAccountId, let found = self.accounts.first(where: { $0.id == activeAccountId }) {
            return found
        }
        return self.accounts.first
    }

    var hostLabel: String {
        if self.kind == .openRouter {
            return "openrouter.ai"
        }
        guard let baseURL,
              let host = URL(string: baseURL)?.host,
              !host.isEmpty else { return self.label }
        return host
    }

    var usesAPIKeyAuth: Bool {
        self.kind == .openAICompatible || self.kind == .openRouter
    }

    var isThirdPartyModelProvider: Bool {
        self.kind == .openAICompatible && self.thirdPartyModelProvider != nil
    }

    var isCustomRelayProvider: Bool {
        self.kind == .openAICompatible && self.thirdPartyModelProvider == nil
    }

    var openRouterEffectiveModelID: String? {
        guard self.kind == .openRouter else { return nil }
        return self.openRouterEffectiveModelID(forAccountID: self.activeAccountId)
    }

    func openRouterEffectiveModelID(forAccountID accountID: String?) -> String? {
        guard self.kind == .openRouter else { return nil }
        if let account = self.openRouterAccount(for: accountID),
           let selection = account.openRouterSelection {
            return selection.effectiveModelID
        }
        return Self.normalizedOpenRouterModelID(self.selectedModelID)
    }

    func openRouterSelection(forAccountID accountID: String?) -> CodexBarOpenRouterSelection {
        guard self.kind == .openRouter else {
            return CodexBarOpenRouterSelection()
        }
        if let selection = self.openRouterAccount(for: accountID)?.openRouterSelection {
            return selection
        }
        return self.openRouterProviderLevelSelection
    }

    var openRouterProviderLevelSelection: CodexBarOpenRouterSelection {
        CodexBarOpenRouterSelection(
            selectedModelID: self.selectedModelID,
            pinnedModelIDs: self.pinnedModelIDs,
            cachedModelCatalog: self.cachedModelCatalog,
            modelCatalogFetchedAt: self.modelCatalogFetchedAt
        )
    }

    var openRouterServiceableSelection: (account: CodexBarProviderAccount, modelID: String)? {
        guard self.kind == .openRouter,
              let account = self.activeAccount,
              let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              apiKey.isEmpty == false,
              let modelID = self.openRouterEffectiveModelID(forAccountID: account.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
              modelID.isEmpty == false else {
            return nil
        }
        return (account, modelID)
    }

    var thirdPartyEffectiveModelID: String? {
        guard self.isThirdPartyModelProvider else { return nil }
        return self.thirdPartyEffectiveModelID(forAccountID: self.activeAccountId)
    }

    func thirdPartyEffectiveModelID(forAccountID accountID: String?) -> String? {
        guard self.isThirdPartyModelProvider else { return nil }
        if let account = self.thirdPartyAccount(for: accountID),
           let selection = account.thirdPartyModelSelection,
           let modelID = selection.effectiveModelID {
            return modelID
        }
        return Self.normalizedOpenRouterModelID(self.defaultModel)
    }

    func thirdPartySelection(forAccountID accountID: String?) -> CodexBarOpenRouterSelection {
        guard self.isThirdPartyModelProvider else {
            return CodexBarOpenRouterSelection()
        }
        if let selection = self.thirdPartyAccount(for: accountID)?.thirdPartyModelSelection {
            return selection
        }
        return CodexBarOpenRouterSelection(
            selectedModelID: self.defaultModel,
            pinnedModelIDs: self.defaultModel.map { [$0] } ?? []
        )
    }

    func thirdPartyMenuModelOptions(forAccountID accountID: String?) -> [CodexBarOpenRouterModel] {
        guard self.isThirdPartyModelProvider else { return [] }
        let selection = self.thirdPartySelection(forAccountID: accountID)
        let orderedIDs = Self.orderedOpenRouterModelIDs(
            selection.pinnedModelIDs,
            cachedModelCatalog: selection.cachedModelCatalog
        )
        return orderedIDs.map { CodexBarOpenRouterModel(id: $0) }
    }

    func openRouterMenuModelOptions(forAccountID accountID: String?) -> [CodexBarOpenRouterModel] {
        guard self.kind == .openRouter else { return [] }
        let selection = self.openRouterSelection(forAccountID: accountID)
        let catalogByID = Dictionary(uniqueKeysWithValues: selection.cachedModelCatalog.map { ($0.id, $0) })
        let orderedIDs = Self.orderedOpenRouterModelIDs(
            selection.pinnedModelIDs,
            cachedModelCatalog: selection.cachedModelCatalog
        )
        return orderedIDs.map { modelID in
            catalogByID[modelID] ?? CodexBarOpenRouterModel(id: modelID)
        }
    }

    private func openRouterAccount(for accountID: String?) -> CodexBarProviderAccount? {
        if let accountID,
           let found = self.accounts.first(where: { $0.id == accountID }) {
            return found
        }
        return self.activeAccount
    }

    private func thirdPartyAccount(for accountID: String?) -> CodexBarProviderAccount? {
        if let accountID,
           let found = self.accounts.first(where: { $0.id == accountID }) {
            return found
        }
        return self.activeAccount
    }

    fileprivate static func normalizedDefaultModel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    static func normalizedOpenRouterModelID(_ value: String?) -> String? {
        self.normalizedDefaultModel(value)
    }

    static func normalizedOpenRouterModelIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let normalized = self.normalizedOpenRouterModelID(value),
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    static func resolvedPinnedModelIDs(
        _ pinnedModelIDs: [String],
        selectedModelID: String?
    ) -> [String] {
        var normalized = self.normalizedOpenRouterModelIDs(pinnedModelIDs)
        if let selectedModelID = self.normalizedOpenRouterModelID(selectedModelID),
           normalized.contains(selectedModelID) == false {
            normalized.insert(selectedModelID, at: 0)
        }
        return normalized
    }

    static func orderedOpenRouterModelIDs(
        _ modelIDs: [String],
        cachedModelCatalog: [CodexBarOpenRouterModel]
    ) -> [String] {
        let normalizedModelIDs = self.normalizedOpenRouterModelIDs(modelIDs)
        let selected = Set(normalizedModelIDs)
        let orderedFromCatalog = cachedModelCatalog.map(\.id).filter { selected.contains($0) }
        let remaining = normalizedModelIDs.filter { orderedFromCatalog.contains($0) == false }
        return orderedFromCatalog + remaining
    }

    mutating func applyOpenRouterCompatibilityMirror(selection: CodexBarOpenRouterSelection) {
        guard self.kind == .openRouter else { return }
        self.selectedModelID = selection.selectedModelID
        self.pinnedModelIDs = selection.pinnedModelIDs
        self.cachedModelCatalog = selection.cachedModelCatalog
        self.modelCatalogFetchedAt = selection.modelCatalogFetchedAt
    }

    mutating func removeOpenRouterCachedModelCatalogs() -> Bool {
        guard self.kind == .openRouter || self.kind == .openAICompatible else {
            return false
        }

        var changed = false
        if self.cachedModelCatalog.isEmpty == false {
            self.cachedModelCatalog = []
            changed = true
        }
        if self.modelCatalogFetchedAt != nil {
            self.modelCatalogFetchedAt = nil
            changed = true
        }

        for index in self.accounts.indices {
            guard let selection = self.accounts[index].openRouterSelection else {
                continue
            }
            if selection.cachedModelCatalog.isEmpty == false || selection.modelCatalogFetchedAt != nil {
                self.accounts[index].openRouterSelection = selection.withoutCachedModelCatalog
                changed = true
            }
        }

        return changed
    }
}

struct CodexBarConfig: Codable {
    var version: Int
    var global: CodexBarGlobalSettings
    var active: CodexBarActiveSelection
    var desktop: CodexBarDesktopSettings
    var modelPricing: [String: CodexBarModelPricing]
    var openAI: CodexBarOpenAISettings
    var providers: [CodexBarProvider]

    init(
        version: Int = 1,
        global: CodexBarGlobalSettings = CodexBarGlobalSettings(),
        active: CodexBarActiveSelection = CodexBarActiveSelection(),
        desktop: CodexBarDesktopSettings = CodexBarDesktopSettings(),
        modelPricing: [String: CodexBarModelPricing] = [:],
        openAI: CodexBarOpenAISettings = CodexBarOpenAISettings(),
        providers: [CodexBarProvider] = []
    ) {
        self.version = version
        self.global = global
        self.active = active
        self.desktop = desktop
        self.modelPricing = modelPricing
        self.openAI = openAI
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case version
        case global
        case active
        case desktop
        case modelPricing
        case openAI
        case providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.global = try container.decodeIfPresent(CodexBarGlobalSettings.self, forKey: .global) ?? CodexBarGlobalSettings()
        self.active = try container.decodeIfPresent(CodexBarActiveSelection.self, forKey: .active) ?? CodexBarActiveSelection()
        self.desktop = try container.decodeIfPresent(CodexBarDesktopSettings.self, forKey: .desktop) ?? CodexBarDesktopSettings()
        self.modelPricing = try container.decodeIfPresent([String: CodexBarModelPricing].self, forKey: .modelPricing) ?? [:]
        self.openAI = try container.decodeIfPresent(CodexBarOpenAISettings.self, forKey: .openAI) ?? CodexBarOpenAISettings()
        self.providers = (try container.decodeIfPresent(
            [FailableDecodable<CodexBarProvider>].self,
            forKey: .providers
        ) ?? []).compactMap(\.value)
    }

    func provider(id: String?) -> CodexBarProvider? {
        guard let id else { return nil }
        return self.providers.first(where: { $0.id == id })
    }

    func activeProvider() -> CodexBarProvider? {
        self.provider(id: self.active.providerId)
    }

    func activeAccount() -> CodexBarProviderAccount? {
        self.activeProvider()?.accounts.first(where: { $0.id == self.active.accountId }) ?? self.activeProvider()?.activeAccount
    }

    func oauthProvider() -> CodexBarProvider? {
        self.providers.first(where: { $0.kind == .openAIOAuth })
    }

    func openRouterProvider() -> CodexBarProvider? {
        self.providers.first(where: { $0.kind == .openRouter })
    }
}

extension CodexBarConfig {
    mutating func upsertOAuthAccount(_ account: TokenAccount, activate: Bool) -> (storedAccount: CodexBarProviderAccount, syncCodex: Bool) {
        var provider = self.ensureOAuthProvider()
        let existingStoredAccount = provider.accounts.first(where: { $0.id == account.accountId })
        let storedAccountID: String

        if let index = provider.accounts.firstIndex(where: { $0.id == account.accountId }) {
            let existing = provider.accounts[index]
            var updated = CodexBarProviderAccount.fromTokenAccount(account, existingID: existing.id)
            updated.addedAt = existing.addedAt ?? Date()
            updated.label = existing.label
            updated.expiresAt = updated.expiresAt ?? existing.expiresAt
            updated.oauthClientID = updated.oauthClientID ?? existing.oauthClientID
            updated.tokenLastRefreshAt = updated.tokenLastRefreshAt ?? existing.tokenLastRefreshAt ?? existing.lastRefresh
            updated.lastRefresh = updated.tokenLastRefreshAt ?? existing.lastRefresh
            updated.interopProxyKey = existing.interopProxyKey
            updated.interopNotes = existing.interopNotes
            updated.interopConcurrency = existing.interopConcurrency
            updated.interopPriority = existing.interopPriority
            updated.interopRateMultiplier = existing.interopRateMultiplier
            updated.interopAutoPauseOnExpired = existing.interopAutoPauseOnExpired
            updated.interopCredentialsJSON = existing.interopCredentialsJSON
            updated.interopExtraJSON = existing.interopExtraJSON
            provider.accounts[index] = updated
            storedAccountID = updated.id
        } else {
            let created = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
            provider.accounts.append(created)
            storedAccountID = created.id
            self.appendOpenAIAccountOrderIfNeeded(accountID: created.id)
        }

        if provider.activeAccountId == nil {
            provider.activeAccountId = storedAccountID
        }

        if activate {
            provider.activeAccountId = storedAccountID
            self.active.providerId = provider.id
            self.active.accountId = storedAccountID
        }

        self.upsertProvider(provider)
        _ = self.normalizeSharedOpenAITeamOrganizationNames()
        self.normalizeOpenAIAccountOrder()

        let storedAccount = self.oauthProvider()?.accounts.first(where: { $0.id == storedAccountID })
            ?? provider.accounts.first(where: { $0.id == storedAccountID })
            ?? CodexBarProviderAccount.fromTokenAccount(account, existingID: storedAccountID)

        let credentialsChanged = self.oauthCredentialsChanged(
            existing: existingStoredAccount,
            updated: storedAccount
        )
        let syncCodex = activate || (
            self.active.providerId == provider.id &&
            self.active.accountId == storedAccount.id &&
            credentialsChanged
        )
        return (storedAccount, syncCodex)
    }

    mutating func activateOAuthAccount(accountID: String) throws -> CodexBarProviderAccount {
        guard var provider = self.oauthProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let stored = self.oauthStoredAccount(in: provider, matching: accountID) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = stored.id
        self.upsertProvider(provider)
        self.active.providerId = provider.id
        self.active.accountId = stored.id
        return stored
    }

    mutating func setOAuthPreferredAccount(accountID: String) throws {
        guard var provider = self.oauthProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let stored = self.oauthStoredAccount(in: provider, matching: accountID) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = stored.id
        self.upsertProvider(provider)
    }

    func oauthTokenAccounts() -> [TokenAccount] {
        guard let provider = self.oauthProvider() else { return [] }
        let isOAuthActive = self.active.providerId == provider.id

        return provider.accounts.compactMap { stored in
            stored.asTokenAccount(isActive: isOAuthActive && self.active.accountId == stored.id)
        }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.email < rhs.email
        }
    }

    mutating func setOpenAIAccountOrder(_ accountOrder: [String]) {
        self.openAI.accountOrder = Self.uniqueAccountIDs(from: accountOrder)
        self.normalizeOpenAIAccountOrder()
    }

    mutating func upsertOpenRouterProvider(
        accountLabel: String,
        apiKey: String,
        activate: Bool
    ) throws -> CodexBarProviderAccount {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        var provider = self.ensureOpenRouterProvider()

        let trimmedLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel: String
        if trimmedLabel.isEmpty == false {
            resolvedLabel = trimmedLabel
        } else {
            let suffix = trimmedAPIKey.suffix(4)
            resolvedLabel = suffix.isEmpty ? "OpenRouter Key" : "Key ...\(suffix)"
        }
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: resolvedLabel,
            apiKey: trimmedAPIKey,
            addedAt: Date(),
            openRouterSelection: CodexBarOpenRouterSelection(
                cachedModelCatalog: provider.cachedModelCatalog,
                modelCatalogFetchedAt: provider.modelCatalogFetchedAt
            )
        )

        provider.accounts.append(account)
        provider.activeAccountId = account.id
        if let selection = account.openRouterSelection {
            provider.applyOpenRouterCompatibilityMirror(selection: selection)
        }
        self.upsertProvider(provider)

        if activate {
            self.active.providerId = provider.id
            self.active.accountId = account.id
        } else if self.active.providerId == provider.id, self.active.accountId == nil {
            self.active.accountId = account.id
        }

        return account
    }

    mutating func activateOpenRouterAccount(accountID: String) throws -> CodexBarProviderAccount {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let stored = provider.accounts.first(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = stored.id
        self.upsertProvider(provider)
        self.active.providerId = provider.id
        self.active.accountId = stored.id
        return stored
    }

    mutating func setOpenRouterDefaultModel(_ value: String?) throws {
        try self.setOpenRouterSelectedModel(value)
    }

    mutating func setOpenRouterSelectedModel(_ value: String?, accountID: String? = nil) throws {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        let resolvedAccountID = accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == resolvedAccountID }) else {
            throw TokenStoreError.accountNotFound
        }
        let currentSelection = provider.openRouterSelection(forAccountID: resolvedAccountID)
        let updatedSelection = currentSelection.updating(selectedModelID: value)
        provider.accounts[accountIndex].openRouterSelection = updatedSelection
        provider.activeAccountId = provider.accounts[accountIndex].id
        provider.applyOpenRouterCompatibilityMirror(selection: updatedSelection)
        self.upsertProvider(provider)
    }

    mutating func setOpenRouterModelSelection(
        accountID: String? = nil,
        selectedModelID: String?,
        pinnedModelIDs: [String],
        cachedModelCatalog: [CodexBarOpenRouterModel]? = nil,
        fetchedAt: Date? = nil
    ) throws {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        let resolvedAccountID = accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == resolvedAccountID }) else {
            throw TokenStoreError.accountNotFound
        }

        let normalizedPinnedModelIDs = CodexBarProvider.normalizedOpenRouterModelIDs(pinnedModelIDs)
        let normalizedSelectedModelID = CodexBarProvider.normalizedOpenRouterModelID(selectedModelID).flatMap {
            normalizedPinnedModelIDs.contains($0) ? $0 : nil
        }
        let currentSelection = provider.openRouterSelection(forAccountID: resolvedAccountID)
        let updatedSelection = currentSelection.updating(
            selectedModelID: normalizedSelectedModelID,
            pinnedModelIDs: normalizedPinnedModelIDs,
            cachedModelCatalog: cachedModelCatalog,
            fetchedAt: fetchedAt
        )
        provider.accounts[accountIndex].openRouterSelection = updatedSelection
        provider.activeAccountId = provider.accounts[accountIndex].id
        provider.applyOpenRouterCompatibilityMirror(selection: updatedSelection)
        self.upsertProvider(provider)
    }

    mutating func updateOpenRouterModelCatalog(
        accountID: String? = nil,
        _ models: [CodexBarOpenRouterModel],
        fetchedAt: Date
    ) throws {
        guard var provider = self.openRouterProvider() else {
            throw TokenStoreError.providerNotFound
        }
        let resolvedAccountID = accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == resolvedAccountID }) else {
            throw TokenStoreError.accountNotFound
        }
        let currentSelection = provider.openRouterSelection(forAccountID: resolvedAccountID)
        let updatedSelection = CodexBarOpenRouterSelection(
            selectedModelID: currentSelection.selectedModelID,
            pinnedModelIDs: currentSelection.pinnedModelIDs,
            cachedModelCatalog: models,
            modelCatalogFetchedAt: fetchedAt
        )
        provider.accounts[accountIndex].openRouterSelection = updatedSelection
        if provider.activeAccountId == provider.accounts[accountIndex].id {
            provider.applyOpenRouterCompatibilityMirror(selection: updatedSelection)
        }
        self.upsertProvider(provider)
    }

    mutating func setOpenAIManualActivationBehavior(_ behavior: CodexBarOpenAIManualActivationBehavior) {
        self.openAI.manualActivationBehavior = behavior
    }

    mutating func setOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) {
        self.openAI.accountUsageMode = mode
    }

    mutating func captureSwitchModeSelection() {
        guard let providerId = self.active.providerId,
              let accountId = self.active.accountId else {
            self.openAI.switchModeSelection = nil
            return
        }

        self.openAI.switchModeSelection = CodexBarActiveSelection(
            providerId: providerId,
            accountId: accountId
        )
    }

    mutating func restoreSwitchModeSelectionIfAvailable() {
        guard let selection = self.openAI.switchModeSelection,
              let provider = self.provider(id: selection.providerId),
              provider.accounts.contains(where: { $0.id == selection.accountId }) else {
            return
        }

        self.active = selection
    }

    mutating func setOpenAIAccountOrderingMode(_ mode: CodexBarOpenAIAccountOrderingMode) {
        self.openAI.accountOrderingMode = mode
    }

    mutating func configureProviderUsage(
        providerID: String,
        configuration: CodexBarProviderUsageConfiguration
    ) throws {
        guard let providerIndex = self.providers.firstIndex(where: { $0.id == providerID }) else {
            throw TokenStoreError.providerNotFound
        }
        self.providers[providerIndex].usageConfiguration = configuration
        self.providers[providerIndex].usageState = nil
    }

    mutating func disableProviderUsage(providerID: String) throws {
        guard let providerIndex = self.providers.firstIndex(where: { $0.id == providerID }) else {
            throw TokenStoreError.providerNotFound
        }
        self.providers[providerIndex].usageConfiguration = nil
        self.providers[providerIndex].usageState = nil
    }

    mutating func updateProviderUsageState(
        providerID: String,
        state: CodexBarProviderUsageState
    ) throws {
        guard let providerIndex = self.providers.firstIndex(where: { $0.id == providerID }) else {
            throw TokenStoreError.providerNotFound
        }
        self.providers[providerIndex].usageState = state
    }

    mutating func removeOpenAIAccountOrder(accountID: String) {
        self.openAI.accountOrder.removeAll { $0 == accountID }
    }

    mutating func normalizeOpenAIAccountOrder() {
        let availableAccountIDs = self.oauthProvider()?.accounts.map(\.id) ?? []
        let availableAccountIDSet = Set(availableAccountIDs)

        var normalized: [String] = []
        var seen: Set<String> = []

        for accountID in self.openAI.accountOrder where availableAccountIDSet.contains(accountID) {
            guard seen.insert(accountID).inserted else { continue }
            normalized.append(accountID)
        }

        for accountID in availableAccountIDs where seen.insert(accountID).inserted {
            normalized.append(accountID)
        }

        self.openAI.accountOrder = normalized
    }

    @discardableResult
    mutating func normalizeSharedOpenAITeamOrganizationNames() -> Bool {
        guard let providerIndex = self.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return false
        }

        var provider = self.providers[providerIndex]
        let groupedIndices = Dictionary(
            grouping: provider.accounts.indices.compactMap { index -> (String, Int)? in
                let account = provider.accounts[index]
                guard Self.isSharedOpenAITeamAccount(account),
                      let sharedAccountID = Self.normalizedSharedOpenAIAccountID(for: account) else {
                    return nil
                }
                return (sharedAccountID, index)
            },
            by: \.0
        )

        var changed = false
        for indices in groupedIndices.values.map({ $0.map(\.1) }) {
            let sharedNames = Set(
                indices.compactMap { index in
                    Self.normalizedSharedOrganizationName(provider.accounts[index].organizationName)
                }
            )
            guard sharedNames.count == 1,
                  let sharedName = sharedNames.first else {
                continue
            }

            for index in indices {
                let account = provider.accounts[index]
                let normalizedName = Self.normalizedSharedOrganizationName(account.organizationName)

                if normalizedName == sharedName {
                    if account.organizationName != sharedName {
                        provider.accounts[index].organizationName = sharedName
                        changed = true
                    }
                    continue
                }

                guard normalizedName == nil else { continue }
                provider.accounts[index].organizationName = sharedName
                changed = true
            }
        }

        guard changed else { return false }
        self.providers[providerIndex] = provider
        return true
    }

    mutating func remapOAuthAccountReferences(using accountIDMapping: [String: String]) {
        guard accountIDMapping.isEmpty == false else { return }

        if let providerIndex = self.providers.firstIndex(where: { $0.kind == .openAIOAuth }) {
            var provider = self.providers[providerIndex]
            provider.accounts = provider.accounts.map { stored in
                var updated = stored
                if let remappedID = accountIDMapping[stored.id] {
                    updated.id = remappedID
                }
                return updated
            }
            if let activeAccountId = provider.activeAccountId,
               let remappedID = accountIDMapping[activeAccountId] {
                provider.activeAccountId = remappedID
            }
            self.providers[providerIndex] = provider

            if self.active.providerId == provider.id,
               let activeAccountId = self.active.accountId,
               let remappedID = accountIDMapping[activeAccountId] {
                self.active.accountId = remappedID
            }
        }

        self.openAI.accountOrder = Self.uniqueAccountIDs(
            from: self.openAI.accountOrder.map { accountIDMapping[$0] ?? $0 }
        )
        self.normalizeOpenAIAccountOrder()
    }

    private mutating func ensureOAuthProvider() -> CodexBarProvider {
        if let provider = self.oauthProvider() {
            return provider
        }
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            baseURL: nil
        )
        self.providers.append(provider)
        return provider
    }

    private mutating func ensureOpenRouterProvider() -> CodexBarProvider {
        if let provider = self.openRouterProvider() {
            return provider
        }
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true
        )
        self.providers.append(provider)
        return provider
    }

    private mutating func upsertProvider(_ provider: CodexBarProvider) {
        if let index = self.providers.firstIndex(where: { $0.id == provider.id }) {
            self.providers[index] = provider
        } else {
            self.providers.append(provider)
        }
    }

    private mutating func appendOpenAIAccountOrderIfNeeded(accountID: String) {
        guard self.openAI.accountOrder.contains(accountID) == false else { return }
        self.openAI.accountOrder.append(accountID)
    }

    private func oauthStoredAccount(in provider: CodexBarProvider, matching accountID: String) -> CodexBarProviderAccount? {
        if let stored = provider.accounts.first(where: { $0.id == accountID }) {
            return stored
        }

        let remoteMatches = provider.accounts.filter { $0.openAIAccountId == accountID }
        if remoteMatches.count == 1 {
            return remoteMatches[0]
        }
        return nil
    }

    private func oauthCredentialsChanged(
        existing: CodexBarProviderAccount?,
        updated: CodexBarProviderAccount
    ) -> Bool {
        guard let existing else { return true }
        return existing.accessToken != updated.accessToken ||
            existing.refreshToken != updated.refreshToken ||
            existing.idToken != updated.idToken ||
            existing.expiresAt != updated.expiresAt ||
            existing.oauthClientID != updated.oauthClientID ||
            existing.tokenLastRefreshAt != updated.tokenLastRefreshAt ||
            existing.openAIAccountId != updated.openAIAccountId
    }

    private static func uniqueAccountIDs(from accountIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return accountIDs.filter { seen.insert($0).inserted }
    }

    static func uniqueOpenRouterModelCatalog(
        _ models: [CodexBarOpenRouterModel]
    ) -> [CodexBarOpenRouterModel] {
        var seen: Set<String> = []
        return models.compactMap { model in
            guard let normalizedID = CodexBarProvider.normalizedOpenRouterModelID(model.id),
                  seen.insert(normalizedID).inserted else {
                return nil
            }
            return CodexBarOpenRouterModel(id: normalizedID, name: model.name)
        }
    }

    mutating func normalizeOpenRouterAccountSelections() -> Bool {
        guard let providerIndex = self.providers.firstIndex(where: { $0.kind == .openRouter }) else {
            return false
        }

        var provider = self.providers[providerIndex]
        let providerSelection = provider.openRouterProviderLevelSelection
        var changed = false
        provider.accounts = provider.accounts.map { account in
            var updated = account
            if updated.openRouterSelection == nil {
                updated.openRouterSelection = providerSelection
                changed = true
            }
            return updated
        }
        if let activeSelection = provider.activeAccount?.openRouterSelection {
            provider.applyOpenRouterCompatibilityMirror(selection: activeSelection)
        }
        self.providers[providerIndex] = provider
        return changed
    }

    mutating func removeOpenRouterCachedModelCatalogs() -> Bool {
        var changed = false
        for index in self.providers.indices {
            if self.providers[index].removeOpenRouterCachedModelCatalogs() {
                changed = true
            }
        }
        return changed
    }

    private static func isSharedOpenAITeamAccount(_ account: CodexBarProviderAccount) -> Bool {
        guard account.kind == .oauthTokens else { return false }
        return self.normalizedPlanType(account.planType) == "team"
    }

    private static func normalizedPlanType(_ planType: String?) -> String {
        planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedSharedOpenAIAccountID(
        for account: CodexBarProviderAccount
    ) -> String? {
        let accountID = (account.openAIAccountId ?? account.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return accountID.isEmpty ? nil : accountID
    }

    private static func normalizedSharedOrganizationName(_ organizationName: String?) -> String? {
        guard let organizationName = organizationName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              organizationName.isEmpty == false else {
            return nil
        }
        return organizationName
    }
}
