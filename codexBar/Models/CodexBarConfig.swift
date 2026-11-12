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

enum CodexBarOpenCodePlan: String, Codable, CaseIterable, Identifiable {
    case go
    case zen

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .go: return "OpenCode Go"
        case .zen: return "OpenCode Zen"
        }
    }

    var shortTitle: String {
        switch self {
        case .go: return "Go"
        case .zen: return "Zen"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .go: return "https://opencode.ai/inference/go/openai/v1"
        case .zen: return "https://opencode.ai/inference/openai/v1"
        }
    }

    var modelCatalogURL: URL {
        switch self {
        case .go: return URL(string: "https://opencode.ai/inference/go/v1/models")!
        case .zen: return URL(string: "https://opencode.ai/inference/v1/models")!
        }
    }

    var usageURL: URL? {
        switch self {
        case .go: return URL(string: "https://opencode.ai/inference/go/v1/usage")!
        case .zen: return nil
        }
    }

    var defaultModel: String {
        switch self {
        case .go: return CodexBarThirdPartyModelProvider.openCode.defaultModel
        case .zen: return "gpt-6.1-sol"
        }
    }

    static func inferred(from baseURL: String?) -> CodexBarOpenCodePlan? {
        guard let baseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let host = URLComponents(string: baseURL)?.host?.lowercased(),
              host == "opencode.ai" else {
            return nil
        }
        let path = URLComponents(string: baseURL)?.path.lowercased() ?? ""
        if path.contains("/inference/go/") || path.contains("/zen/go/") {
            return .go
        }
        if path.contains("/inference/") || path.contains("/zen/") {
            return .zen
        }
        return nil
    }
}

enum CodexBarThirdPartyModelProvider: String, Codable, CaseIterable, Identifiable {
    case deepSeek = "deepseek"
    case mimo = "mimo"
    case custom = "custom"
    case openCode = "opencode"

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .mimo: return "MiMo"
        case .custom: return "自定义"
        case .openCode: return "OpenCode"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com"
        case .mimo: return "https://api.xiaomimimo.com/v1"
        case .custom: return ""
        case .openCode: return CodexBarOpenCodePlan.go.defaultBaseURL
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: return "deepseek-v4-pro"
        case .mimo: return "mimo-v2.5-pro"
        case .custom: return ""
        case .openCode: return "deepseek-v4.1-flash"
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
        case .openCode:
            return ["deepseek-v4.1-flash", "deepseek-v4-pro"]
        }
    }

    static var genericCases: [CodexBarThirdPartyModelProvider] {
        Self.allCases.filter { $0 != .openCode }
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


enum CodexBarOpenAIManualActivationBehavior: String, Codable, CaseIterable, Identifiable {
    case updateConfigOnly
    case launchNewInstance

    var id: String { self.rawValue }
}

enum CodexBarOpenAIAccountUsageMode: String, Codable, CaseIterable, Identifiable {
    case switchAccount = "switch"
    case hybridProvider = "hybrid_provider"

    var id: String { self.rawValue }

    var menuToggleTitle: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchShort
        case .hybridProvider:
            return L.accountUsageModeHybridShort
        }
    }

    var themeAccentColor: NSColor {
        switch self {
        case .switchAccount:
            return Self.manualModeAccentColor
        case .hybridProvider:
            return .systemBlue
        }
    }

    static var manualModeAccentColor: NSColor {
        NSColor(calibratedRed: 0x7c / 255.0, green: 0x38 / 255.0, blue: 0xe9 / 255.0, alpha: 1.0)
    }
}

struct CodexBarOpenAISettings: Codable, Equatable {
    enum ReasoningRetryStreamAction: String, Codable, CaseIterable, Identifiable {
        case strict502 = "strict_502"
        case disconnect

        var id: String { self.rawValue }
    }

    enum ReasoningRetryGuardMatchMode: String, Codable, CaseIterable, Identifiable {
        case strict
        case cautious

        var id: String { self.rawValue }
    }

    struct GatewayPromptPatchSettings: Codable, Equatable {
        static let defaultInstructions = "Spend time thinking through the task before finalizing. Do not send optional progress commentary unless it materially helps the user understand current work."
        static let maxInstructionsCharacterCount = 4_000

        var isEnabled: Bool
        var instructions: String

        enum CodingKeys: String, CodingKey {
            case isEnabled
            case instructions
        }

        init(
            isEnabled: Bool = false,
            instructions: String = Self.defaultInstructions
        ) {
            self.isEnabled = isEnabled
            self.instructions = Self.normalizedInstructions(instructions)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                instructions: try container.decodeIfPresent(String.self, forKey: .instructions) ?? Self.defaultInstructions
            )
        }

        static func normalizedInstructions(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > Self.maxInstructionsCharacterCount else { return trimmed }
            let index = trimmed.index(trimmed.startIndex, offsetBy: Self.maxInstructionsCharacterCount)
            return String(trimmed[..<index])
        }
    }

    struct ReasoningRetryGuardSettings: Codable, Equatable {
        var isEnabled: Bool
        var matchMode: ReasoningRetryGuardMatchMode
        var reasoningEquals: [Int]
        var interceptStreaming: Bool
        var interceptNonStreaming: Bool
        var routeTargetRetryAttempts: Int
        var retryableStatusCodes: [Int]
        var retryUpstreamCapacityErrors: Bool
        var nonStreamStatusCode: Int
        var streamAction: ReasoningRetryStreamAction
        var logMatch: Bool
        var endpoints: [String]

        enum CodingKeys: String, CodingKey {
            case isEnabled
            case matchMode
            case reasoningEquals
            case interceptStreaming
            case interceptNonStreaming
            case routeTargetRetryAttempts
            case retryableStatusCodes
            case retryUpstreamCapacityErrors
            case nonStreamStatusCode
            case streamAction
            case logMatch
            case endpoints
        }

        static let defaultReasoningEquals = [516, 1034, 1552]
        static let supportedRetryableStatusCodes = [429, 500, 502, 503, 504]
        static let defaultRetryableStatusCodes = [502]
        static let routeTargetRetryAttemptsRange = 0...20

        static let defaultEndpoints = [
            "/responses",
            "/v1/responses",
            "/responses/compact",
            "/v1/responses/compact",
        ]

        init(
            isEnabled: Bool = false,
            matchMode: ReasoningRetryGuardMatchMode = .strict,
            reasoningEquals: [Int] = Self.defaultReasoningEquals,
            interceptStreaming: Bool = true,
            interceptNonStreaming: Bool = true,
            routeTargetRetryAttempts: Int = 5,
            retryableStatusCodes: [Int] = Self.defaultRetryableStatusCodes,
            retryUpstreamCapacityErrors: Bool = true,
            nonStreamStatusCode: Int = 502,
            streamAction: ReasoningRetryStreamAction = .strict502,
            logMatch: Bool = true,
            endpoints: [String] = Self.defaultEndpoints
        ) {
            let normalizedReasoningEquals = Self.normalizedReasoningEquals(reasoningEquals)
            self.isEnabled = isEnabled
            self.matchMode = matchMode
            self.reasoningEquals = normalizedReasoningEquals.isEmpty ? Self.defaultReasoningEquals : normalizedReasoningEquals
            if interceptStreaming == false, interceptNonStreaming == false {
                self.interceptStreaming = true
                self.interceptNonStreaming = true
            } else {
                self.interceptStreaming = interceptStreaming
                self.interceptNonStreaming = interceptNonStreaming
            }
            self.routeTargetRetryAttempts = Self.clampedRouteTargetRetryAttempts(routeTargetRetryAttempts)
            self.retryableStatusCodes = Self.normalizedRetryableStatusCodes(retryableStatusCodes)
            self.retryUpstreamCapacityErrors = retryUpstreamCapacityErrors
            self.nonStreamStatusCode = Self.clampedStatusCode(nonStreamStatusCode)
            self.streamAction = streamAction
            self.logMatch = logMatch
            self.endpoints = Self.normalizedEndpoints(endpoints)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                matchMode: try container.decodeIfPresent(ReasoningRetryGuardMatchMode.self, forKey: .matchMode) ?? .strict,
                reasoningEquals: try container.decodeIfPresent([Int].self, forKey: .reasoningEquals) ?? Self.defaultReasoningEquals,
                interceptStreaming: try container.decodeIfPresent(Bool.self, forKey: .interceptStreaming) ?? true,
                interceptNonStreaming: try container.decodeIfPresent(Bool.self, forKey: .interceptNonStreaming) ?? true,
                routeTargetRetryAttempts: try container.decodeIfPresent(Int.self, forKey: .routeTargetRetryAttempts) ?? 5,
                retryableStatusCodes: try container.decodeIfPresent([Int].self, forKey: .retryableStatusCodes) ?? Self.defaultRetryableStatusCodes,
                retryUpstreamCapacityErrors: try container.decodeIfPresent(Bool.self, forKey: .retryUpstreamCapacityErrors) ?? true,
                nonStreamStatusCode: try container.decodeIfPresent(Int.self, forKey: .nonStreamStatusCode) ?? 502,
                streamAction: try container.decodeIfPresent(ReasoningRetryStreamAction.self, forKey: .streamAction) ?? .strict502,
                logMatch: try container.decodeIfPresent(Bool.self, forKey: .logMatch) ?? true,
                endpoints: try container.decodeIfPresent([String].self, forKey: .endpoints) ?? Self.defaultEndpoints
            )
        }

        static func normalizedReasoningEquals(_ values: [Int]) -> [Int] {
            var normalized: [Int] = []
            var seen: Set<Int> = []
            for value in values where value >= 0 && seen.insert(value).inserted {
                normalized.append(value)
            }
            return normalized
        }

        static func normalizedEndpoints(_ values: [String]) -> [String] {
            var normalized: [String] = []
            var seen: Set<String> = []
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { continue }
                let endpoint = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
                guard seen.insert(endpoint).inserted else { continue }
                normalized.append(endpoint)
            }
            return normalized.isEmpty ? Self.defaultEndpoints : normalized
        }

        static func normalizedRetryableStatusCodes(_ values: [Int]) -> [Int] {
            let selected = Set(values)
            return Self.supportedRetryableStatusCodes.filter(selected.contains)
        }

        static func clampedStatusCode(_ value: Int) -> Int {
            min(max(value, 100), 599)
        }

        static func clampedRouteTargetRetryAttempts(_ value: Int) -> Int {
            min(max(value, Self.routeTargetRetryAttemptsRange.lowerBound), Self.routeTargetRetryAttemptsRange.upperBound)
        }
    }

    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var usagePollingIntervalSeconds: Int = UsagePollingInterval.defaultOpenAI
    var providerDisplayOrder: [String] = []
    var modelRoutingStyle: CodexRoutingStyle = .catalog
    var lastModelRoutingSelection: CodexBarActiveSelection? = nil
    var modelRoutingPreviousMode: CodexBarOpenAIAccountUsageMode? = nil
    var modelRoutingEnabled: Bool = false
    var switchModeSelection: CodexBarActiveSelection?
    var manualActivationBehavior: CodexBarOpenAIManualActivationBehavior
    var usageDisplayMode: CodexBarUsageDisplayMode
    var reasoningRetryGuard: ReasoningRetryGuardSettings
    var gatewayPromptPatch: GatewayPromptPatchSettings
    var interopProxiesJSON: String?

    enum CodingKeys: String, CodingKey {
        case accountOrder
        case accountUsageMode
        case usagePollingIntervalSeconds
        case providerDisplayOrder
        case modelRoutingStyle
        case lastModelRoutingSelection
        case modelRoutingPreviousMode
        case modelRoutingEnabled
        case switchModeSelection
        case manualActivationBehavior
        case usageDisplayMode
        case reasoningRetryGuard
        case gatewayPromptPatch
        case interopProxiesJSON
    }

    init(
        accountOrder: [String] = [],
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount,
        switchModeSelection: CodexBarActiveSelection? = nil,
        manualActivationBehavior: CodexBarOpenAIManualActivationBehavior = .updateConfigOnly,
        usageDisplayMode: CodexBarUsageDisplayMode = .used,
        reasoningRetryGuard: ReasoningRetryGuardSettings = ReasoningRetryGuardSettings(),
        gatewayPromptPatch: GatewayPromptPatchSettings = GatewayPromptPatchSettings(),
        interopProxiesJSON: String? = nil
    ) {
        self.accountOrder = accountOrder
        self.accountUsageMode = accountUsageMode
        self.switchModeSelection = switchModeSelection
        self.manualActivationBehavior = manualActivationBehavior
        self.usageDisplayMode = usageDisplayMode
        self.reasoningRetryGuard = reasoningRetryGuard
        self.gatewayPromptPatch = gatewayPromptPatch
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
        self.usagePollingIntervalSeconds = UsagePollingInterval.normalized(try container.decodeIfPresent(Int.self, forKey: .usagePollingIntervalSeconds) ?? UsagePollingInterval.defaultOpenAI)
        self.providerDisplayOrder = try container.decodeIfPresent([String].self, forKey: .providerDisplayOrder) ?? []
        self.modelRoutingStyle = try container.decodeIfPresent(CodexRoutingStyle.self, forKey: .modelRoutingStyle) ?? .follow
        self.lastModelRoutingSelection = try container.decodeIfPresent(CodexBarActiveSelection.self, forKey: .lastModelRoutingSelection)
        self.modelRoutingPreviousMode = try container.decodeIfPresent(CodexBarOpenAIAccountUsageMode.self, forKey: .modelRoutingPreviousMode)
        self.modelRoutingEnabled = try container.decodeIfPresent(Bool.self, forKey: .modelRoutingEnabled) ?? false
        self.switchModeSelection = try container.decodeIfPresent(
            CodexBarActiveSelection.self,
            forKey: .switchModeSelection
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
        self.reasoningRetryGuard = try container.decodeIfPresent(ReasoningRetryGuardSettings.self, forKey: .reasoningRetryGuard) ?? ReasoningRetryGuardSettings()
        self.gatewayPromptPatch = try container.decodeIfPresent(GatewayPromptPatchSettings.self, forKey: .gatewayPromptPatch) ?? GatewayPromptPatchSettings()
        self.interopProxiesJSON = try container.decodeIfPresent(String.self, forKey: .interopProxiesJSON)
    }

}

struct CodexBarKeyModelSelection: Codable, Equatable {
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

typealias CodexBarOpenRouterSelection = CodexBarKeyModelSelection

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
    var modelSelection: CodexBarKeyModelSelection?
    // Source-compatible accessors; serialized Key data has one canonical field.
    var openRouterSelection: CodexBarOpenRouterSelection? {
        get { self.modelSelection }
        set { self.modelSelection = newValue }
    }
    var thirdPartyModelSelection: CodexBarOpenRouterSelection? {
        get { self.modelSelection }
        set { self.modelSelection = newValue }
    }

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
        modelSelection: CodexBarKeyModelSelection? = nil,
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
        self.modelSelection = modelSelection ?? thirdPartyModelSelection ?? openRouterSelection
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

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case email
        case openAIAccountId
        case accessToken
        case refreshToken
        case idToken
        case expiresAt
        case oauthClientID
        case tokenLastRefreshAt
        case lastRefresh
        case apiKey
        case addedAt
        case modelSelection
        case planType
        case primaryUsedPercent
        case secondaryUsedPercent
        case primaryResetAt
        case secondaryResetAt
        case primaryLimitWindowSeconds
        case secondaryLimitWindowSeconds
        case lastChecked
        case isSuspended
        case tokenExpired
        case organizationName
        case interopProxyKey
        case interopNotes
        case interopConcurrency
        case interopPriority
        case interopRateMultiplier
        case interopAutoPauseOnExpired
        case interopCredentialsJSON
        case interopExtraJSON
        case openRouterSelection
        case thirdPartyModelSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = try container.decode(CodexBarAccountKind.self, forKey: .kind)
        self.label = try container.decode(String.self, forKey: .label)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.openAIAccountId = try container.decodeIfPresent(String.self, forKey: .openAIAccountId)
        self.accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        self.idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID)
        self.tokenLastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .tokenLastRefreshAt)
        self.lastRefresh = try container.decodeIfPresent(Date.self, forKey: .lastRefresh)
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt)
        self.modelSelection = try container.decodeIfPresent(CodexBarKeyModelSelection.self, forKey: .modelSelection)
            ?? container.decodeIfPresent(CodexBarKeyModelSelection.self, forKey: .thirdPartyModelSelection)
            ?? container.decodeIfPresent(CodexBarKeyModelSelection.self, forKey: .openRouterSelection)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.primaryUsedPercent = try container.decodeIfPresent(Double.self, forKey: .primaryUsedPercent)
        self.secondaryUsedPercent = try container.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent)
        self.primaryResetAt = try container.decodeIfPresent(Date.self, forKey: .primaryResetAt)
        self.secondaryResetAt = try container.decodeIfPresent(Date.self, forKey: .secondaryResetAt)
        self.primaryLimitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .primaryLimitWindowSeconds)
        self.secondaryLimitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .secondaryLimitWindowSeconds)
        self.lastChecked = try container.decodeIfPresent(Date.self, forKey: .lastChecked)
        self.isSuspended = try container.decodeIfPresent(Bool.self, forKey: .isSuspended)
        self.tokenExpired = try container.decodeIfPresent(Bool.self, forKey: .tokenExpired)
        self.organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        self.interopProxyKey = try container.decodeIfPresent(String.self, forKey: .interopProxyKey)
        self.interopNotes = try container.decodeIfPresent(String.self, forKey: .interopNotes)
        self.interopConcurrency = try container.decodeIfPresent(Int.self, forKey: .interopConcurrency)
        self.interopPriority = try container.decodeIfPresent(Int.self, forKey: .interopPriority)
        self.interopRateMultiplier = try container.decodeIfPresent(Double.self, forKey: .interopRateMultiplier)
        self.interopAutoPauseOnExpired = try container.decodeIfPresent(Bool.self, forKey: .interopAutoPauseOnExpired)
        self.interopCredentialsJSON = try container.decodeIfPresent(String.self, forKey: .interopCredentialsJSON)
        self.interopExtraJSON = try container.decodeIfPresent(String.self, forKey: .interopExtraJSON)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.label, forKey: .label)
        try container.encodeIfPresent(self.email, forKey: .email)
        try container.encodeIfPresent(self.openAIAccountId, forKey: .openAIAccountId)
        try container.encodeIfPresent(self.accessToken, forKey: .accessToken)
        try container.encodeIfPresent(self.refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(self.idToken, forKey: .idToken)
        try container.encodeIfPresent(self.expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(self.oauthClientID, forKey: .oauthClientID)
        try container.encodeIfPresent(self.tokenLastRefreshAt, forKey: .tokenLastRefreshAt)
        try container.encodeIfPresent(self.lastRefresh, forKey: .lastRefresh)
        try container.encodeIfPresent(self.apiKey, forKey: .apiKey)
        try container.encodeIfPresent(self.addedAt, forKey: .addedAt)
        try container.encodeIfPresent(self.modelSelection, forKey: .modelSelection)
        try container.encodeIfPresent(self.planType, forKey: .planType)
        try container.encodeIfPresent(self.primaryUsedPercent, forKey: .primaryUsedPercent)
        try container.encodeIfPresent(self.secondaryUsedPercent, forKey: .secondaryUsedPercent)
        try container.encodeIfPresent(self.primaryResetAt, forKey: .primaryResetAt)
        try container.encodeIfPresent(self.secondaryResetAt, forKey: .secondaryResetAt)
        try container.encodeIfPresent(self.primaryLimitWindowSeconds, forKey: .primaryLimitWindowSeconds)
        try container.encodeIfPresent(self.secondaryLimitWindowSeconds, forKey: .secondaryLimitWindowSeconds)
        try container.encodeIfPresent(self.lastChecked, forKey: .lastChecked)
        try container.encodeIfPresent(self.isSuspended, forKey: .isSuspended)
        try container.encodeIfPresent(self.tokenExpired, forKey: .tokenExpired)
        try container.encodeIfPresent(self.organizationName, forKey: .organizationName)
        try container.encodeIfPresent(self.interopProxyKey, forKey: .interopProxyKey)
        try container.encodeIfPresent(self.interopNotes, forKey: .interopNotes)
        try container.encodeIfPresent(self.interopConcurrency, forKey: .interopConcurrency)
        try container.encodeIfPresent(self.interopPriority, forKey: .interopPriority)
        try container.encodeIfPresent(self.interopRateMultiplier, forKey: .interopRateMultiplier)
        try container.encodeIfPresent(self.interopAutoPauseOnExpired, forKey: .interopAutoPauseOnExpired)
        try container.encodeIfPresent(self.interopCredentialsJSON, forKey: .interopCredentialsJSON)
        try container.encodeIfPresent(self.interopExtraJSON, forKey: .interopExtraJSON)
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
    var intervalSeconds: Int

    init(
        requestURL: String? = nil,
        requestHeaders: [String: String] = [:],
        timeoutSeconds: Double = 30,
        intervalSeconds: Int = 0
    ) {
        self.requestURL = Self.normalizedURLString(requestURL)
        self.requestHeaders = Self.normalizedHeaders(requestHeaders)
        self.timeoutSeconds = Self.sanitizedTimeout(timeoutSeconds)
        self.intervalSeconds = UsagePollingInterval.normalized(intervalSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case requestURL
        case requestHeaders
        case timeoutSeconds
        case intervalSeconds
    }

    private enum LegacyCodingKeys: String, CodingKey { case intervalMinutes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seconds: Int
        if let value = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds) {
            seconds = value
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let minutes = try legacy.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 0
            seconds = min(max(0, minutes), Int.max / 60) * 60
        }
        self.init(
            requestURL: try container.decodeIfPresent(String.self, forKey: .requestURL),
            requestHeaders: try container.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:],
            timeoutSeconds: try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30,
            intervalSeconds: seconds
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

}

struct CodexBarProviderUsagePeriod: Codable, Equatable {
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var resetAt: Date?

    init(
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        resetAt: Date? = nil
    ) {
        self.used = Self.sanitizedNumber(used)
        self.limit = Self.sanitizedNumber(limit)
        self.remaining = Self.sanitizedNumber(remaining)
        self.resetAt = resetAt

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
        self.used != nil || self.limit != nil || self.remaining != nil || self.resetAt != nil
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
    var openCodePlan: CodexBarOpenCodePlan?
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
        openCodePlan: CodexBarOpenCodePlan? = nil,
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
        let resolvedThirdParty = kind == .openAICompatible ? thirdPartyModelProvider : nil
        let resolvedOpenCodePlan = resolvedThirdParty == .openCode
            ? (openCodePlan ?? CodexBarOpenCodePlan.inferred(from: baseURL) ?? .go)
            : nil
        self.id = id
        self.kind = kind
        self.label = label
        self.enabled = enabled
        self.baseURL = baseURL
        self.defaultModel = kind == .openRouter ? nil : normalizedDefaultModel
        self.thirdPartyModelProvider = resolvedThirdParty
        self.openCodePlan = resolvedOpenCodePlan
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
        case openCodePlan
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
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.defaultModel = decodedKind == .openRouter ? nil : decodedDefaultModel
        let decodedOpenCodePlan = try container.decodeIfPresent(CodexBarOpenCodePlan.self, forKey: .openCodePlan)
        if decodedKind == .openAICompatible {
            var decodedThirdParty = try container.decodeIfPresent(
                CodexBarThirdPartyModelProvider.self,
                forKey: .thirdPartyModelProvider
            )
            if decodedOpenCodePlan != nil,
               decodedThirdParty == nil || decodedThirdParty == .custom {
                decodedThirdParty = .openCode
            }
            self.thirdPartyModelProvider = decodedThirdParty
            if decodedThirdParty == .openCode {
                self.openCodePlan = decodedOpenCodePlan
                    ?? CodexBarOpenCodePlan.inferred(from: self.baseURL)
                    ?? .go
            } else {
                self.openCodePlan = nil
            }
        } else {
            self.thirdPartyModelProvider = nil
            self.openCodePlan = nil
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

    var displayName: String {
        let name = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if self.kind == .openRouter { return "OpenRouter" }
        if let preset = self.thirdPartyModelProvider, preset != .custom { return preset.title }
        return self.baseURL.flatMap { URL(string: $0)?.host } ?? (self.kind == .openAIOAuth ? "OpenAI" : "Provider")
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

    var isOpenCodeProvider: Bool {
        self.kind == .openAICompatible && self.thirdPartyModelProvider == .openCode
    }

    var effectiveOpenCodePlan: CodexBarOpenCodePlan? {
        guard self.isOpenCodeProvider else { return nil }
        return self.openCodePlan ?? CodexBarOpenCodePlan.inferred(from: self.baseURL) ?? .go
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
        guard self.kind == .openAICompatible else { return nil }
        if let account = self.thirdPartyAccount(for: accountID),
           let selection = account.thirdPartyModelSelection,
           let modelID = selection.effectiveModelID {
            return modelID
        }
        return Self.normalizedOpenRouterModelID(self.defaultModel)
    }

    func thirdPartySelection(forAccountID accountID: String?) -> CodexBarOpenRouterSelection {
        guard self.kind == .openAICompatible else {
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
        guard self.kind == .openAICompatible else { return [] }
        let selection = self.thirdPartySelection(forAccountID: accountID)
        let catalogByID = Dictionary(uniqueKeysWithValues: selection.cachedModelCatalog.map { ($0.id, $0) })
        let orderedIDs = Self.orderedOpenRouterModelIDs(
            selection.pinnedModelIDs,
            cachedModelCatalog: selection.cachedModelCatalog
        )
        return orderedIDs.map { modelID in
            catalogByID[modelID] ?? CodexBarOpenRouterModel(id: modelID)
        }
    }

    mutating func updateThirdPartyModelCatalog(
        _ models: [CodexBarOpenRouterModel],
        fetchedAt: Date
    ) -> Bool {
        guard self.isThirdPartyModelProvider else { return false }
        let normalizedModels = CodexBarConfig.uniqueOpenRouterModelCatalog(models)
        var changed = false
        if self.cachedModelCatalog != normalizedModels || self.modelCatalogFetchedAt != fetchedAt {
            self.cachedModelCatalog = normalizedModels
            self.modelCatalogFetchedAt = fetchedAt
            changed = true
        }
        for index in self.accounts.indices {
            let selection = self.accounts[index].thirdPartyModelSelection
                ?? self.thirdPartySelection(forAccountID: self.accounts[index].id)
            let updated = selection.updating(
                selectedModelID: selection.selectedModelID,
                pinnedModelIDs: selection.pinnedModelIDs,
                cachedModelCatalog: normalizedModels,
                fetchedAt: fetchedAt
            )
            if self.accounts[index].thirdPartyModelSelection != updated {
                self.accounts[index].thirdPartyModelSelection = updated
                changed = true
            }
        }
        return changed
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
            if let selection = self.accounts[index].openRouterSelection,
               selection.cachedModelCatalog.isEmpty == false || selection.modelCatalogFetchedAt != nil {
                self.accounts[index].openRouterSelection = selection.withoutCachedModelCatalog
                changed = true
            }
            if let selection = self.accounts[index].thirdPartyModelSelection,
               selection.cachedModelCatalog.isEmpty == false || selection.modelCatalogFetchedAt != nil {
                self.accounts[index].thirdPartyModelSelection = selection.withoutCachedModelCatalog
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
    var openAI: CodexBarOpenAISettings
    var providers: [CodexBarProvider]

    init(
        version: Int = 1,
        global: CodexBarGlobalSettings = CodexBarGlobalSettings(),
        active: CodexBarActiveSelection = CodexBarActiveSelection(),
        desktop: CodexBarDesktopSettings = CodexBarDesktopSettings(),
        openAI: CodexBarOpenAISettings = CodexBarOpenAISettings(),
        providers: [CodexBarProvider] = []
    ) {
        self.version = version
        self.global = global
        self.active = active
        self.desktop = desktop
        self.openAI = openAI
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case version
        case global
        case active
        case desktop
        case openAI
        case providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.global = try container.decodeIfPresent(CodexBarGlobalSettings.self, forKey: .global) ?? CodexBarGlobalSettings()
        self.active = try container.decodeIfPresent(CodexBarActiveSelection.self, forKey: .active) ?? CodexBarActiveSelection()
        self.desktop = try container.decodeIfPresent(CodexBarDesktopSettings.self, forKey: .desktop) ?? CodexBarDesktopSettings()
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

    var hasAnyConfiguredAccount: Bool {
        self.providers.contains { provider in
            provider.accounts.isEmpty == false
        }
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

enum CodexRoutingStyle: String, Codable, CaseIterable { case follow, catalog }
