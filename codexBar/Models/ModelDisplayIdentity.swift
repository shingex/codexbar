import Foundation

struct ModelDisplayIdentity: Equatable {
    var providerCode: String
    var compactModelCode: String
    var iconSource: MenuBarStatusItemIconSource?
}

enum ModelDisplayIdentityResolver {
    private enum ModelFamily: CaseIterable {
        case openAI
        case claude
        case gemini
        case deepSeek
        case xiaomiMiMo
        case qwen
        case kimi
        case mistral
        case grok
        case zai

        var providerCode: String {
            switch self {
            case .openAI: return "OA"
            case .claude: return "CL"
            case .gemini: return "GM"
            case .deepSeek: return "DS"
            case .xiaomiMiMo: return "MM"
            case .qwen: return "QW"
            case .kimi: return "KM"
            case .mistral: return "MS"
            case .grok: return "GX"
            case .zai: return "ZA"
            }
        }

        var iconSource: MenuBarStatusItemIconSource {
            switch self {
            case .openAI: return MenuBarModelIconLibrary.openAI
            case .claude: return MenuBarModelIconLibrary.claude
            case .gemini: return MenuBarModelIconLibrary.gemini
            case .deepSeek: return MenuBarModelIconLibrary.deepSeek
            case .xiaomiMiMo: return MenuBarModelIconLibrary.xiaomiMiMo
            case .qwen: return MenuBarModelIconLibrary.qwen
            case .kimi: return MenuBarModelIconLibrary.kimi
            case .mistral: return MenuBarModelIconLibrary.mistral
            case .grok: return MenuBarModelIconLibrary.grok
            case .zai: return MenuBarModelIconLibrary.zai
            }
        }
    }

    static func identity(for provider: CodexBarProvider) -> ModelDisplayIdentity? {
        switch provider.kind {
        case .openAIOAuth:
            return nil
        case .openRouter:
            guard let modelID = provider.openRouterEffectiveModelID(forAccountID: provider.activeAccountId) else {
                return ModelDisplayIdentity(
                    providerCode: "OR",
                    compactModelCode: "OR",
                    iconSource: MenuBarModelIconLibrary.openRouter
                )
            }
            return self.identity(modelID: modelID, fallbackProviderCode: "OR", fallbackIcon: MenuBarModelIconLibrary.openRouter)
        case .openAICompatible:
            if let thirdPartyModelProvider = provider.thirdPartyModelProvider {
                return self.identity(
                    thirdPartyProvider: thirdPartyModelProvider,
                    modelID: provider.thirdPartyEffectiveModelID
                )
            }
            guard let identity = self.verifiedModelIdentity(modelID: provider.defaultModel) else {
                return nil
            }
            return identity
        }
    }

    static func identity(
        thirdPartyProvider: CodexBarThirdPartyModelProvider,
        modelID: String?
    ) -> ModelDisplayIdentity {
        let normalizedModelID = self.normalizedModelID(modelID)
        switch thirdPartyProvider {
        case .deepSeek:
            return ModelDisplayIdentity(
                providerCode: "DS",
                compactModelCode: self.compactDeepSeekModelCode(normalizedModelID),
                iconSource: MenuBarModelIconLibrary.deepSeek
            )
        case .mimo:
            return ModelDisplayIdentity(
                providerCode: "MM",
                compactModelCode: self.compactMiMoModelCode(normalizedModelID),
                iconSource: MenuBarModelIconLibrary.xiaomiMiMo
            )
        case .custom:
            return self.identity(modelID: normalizedModelID, fallbackProviderCode: self.providerCode(from: normalizedModelID))
        }
    }

    private static func identity(
        modelID: String,
        fallbackProviderCode: String,
        fallbackIcon: MenuBarStatusItemIconSource?
    ) -> ModelDisplayIdentity {
        let normalized = self.normalizedModelID(modelID)
        if let family = self.modelFamily(for: normalized) {
            return self.identity(for: family, modelID: normalized)
        }
        return ModelDisplayIdentity(
            providerCode: fallbackProviderCode,
            compactModelCode: self.compactGenericModelCode(normalized, fallback: fallbackProviderCode),
            iconSource: fallbackIcon
        )
    }

    private static func identity(modelID: String?, fallbackProviderCode: String) -> ModelDisplayIdentity {
        let normalized = self.normalizedModelID(modelID)
        if let family = self.modelFamily(for: normalized) {
            return self.identity(for: family, modelID: normalized)
        }
        guard normalized.isEmpty == false else {
            return ModelDisplayIdentity(
                providerCode: fallbackProviderCode,
                compactModelCode: fallbackProviderCode,
                iconSource: nil
            )
        }
        return ModelDisplayIdentity(
            providerCode: self.providerCode(from: normalized),
            compactModelCode: self.compactGenericModelCode(normalized, fallback: fallbackProviderCode),
            iconSource: nil
        )
    }

    private static func verifiedModelIdentity(modelID: String?) -> ModelDisplayIdentity? {
        let normalized = self.normalizedModelID(modelID)
        guard let family = self.modelFamily(for: normalized) else {
            return nil
        }
        return self.identity(for: family, modelID: normalized)
    }

    private static func identity(for family: ModelFamily, modelID: String?) -> ModelDisplayIdentity {
        let normalized = self.normalizedModelID(modelID)
        return ModelDisplayIdentity(
            providerCode: family.providerCode,
            compactModelCode: self.compactModelCode(for: family, modelID: normalized),
            iconSource: family.iconSource
        )
    }

    private static func modelFamily(for modelID: String?) -> ModelFamily? {
        let lower = self.normalizedModelID(modelID).lowercased()
        guard lower.isEmpty == false else { return nil }
        if lower.contains("deepseek") { return .deepSeek }
        if lower.contains("mimo") { return .xiaomiMiMo }
        if lower.contains("claude") { return .claude }
        if lower.contains("gemini") { return .gemini }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("kimi") { return .kimi }
        if lower.contains("mistral") || lower.contains("codestral") || lower.contains("devstral") { return .mistral }
        if lower.contains("grok") { return .grok }
        if lower.contains("glm") { return .zai }
        if lower.contains("z-ai") || lower.contains("zhipu") || lower.contains("chatglm") { return .zai }
        if lower.contains("gpt") || lower.contains("openai") || lower.contains("codex") { return .openAI }
        return nil
    }

    private static func compactDeepSeekModelCode(_ modelID: String?) -> String {
        let model = self.normalizedModelID(modelID).isEmpty ? "deepseek" : self.normalizedModelID(modelID).lowercased()
        let generation = self.firstVersionNumber(in: model) ?? ""
        let suffix: String
        if model.contains("flash") {
            suffix = "F"
        } else if model.contains("pro") {
            suffix = "P"
        } else {
            suffix = ""
        }
        return "DS\(generation)\(suffix)"
    }

    private static func compactMiMoModelCode(_ modelID: String?) -> String {
        let model = self.normalizedModelID(modelID).isEmpty ? "mimo" : self.normalizedModelID(modelID).lowercased()
        let generation = self.firstVersionNumber(in: model) ?? ""
        let suffix = model.contains("pro") ? "P" : ""
        return "MM\(generation)\(suffix)"
    }

    private static func compactModelCode(for family: ModelFamily, modelID: String) -> String {
        let lower = modelID.lowercased()
        let generation = self.modelGeneration(for: lower, family: family)
        let suffix = self.modelSuffix(for: lower, family: family)
        return "\(family.providerCode)\(generation)\(suffix)"
    }

    private static func modelGeneration(for lowercasedModelID: String, family: ModelFamily) -> String {
        switch family {
        case .openAI:
            return self.openAIGenerationCode(lowercasedModelID)
        case .claude:
            return self.claudeGenerationCode(lowercasedModelID)
        case .gemini:
            return self.geminiGenerationCode(lowercasedModelID)
        case .deepSeek:
            return self.firstVersionNumber(in: lowercasedModelID) ?? ""
        case .xiaomiMiMo:
            return self.firstVersionNumber(in: lowercasedModelID) ?? ""
        case .qwen:
            return self.qwenGenerationCode(lowercasedModelID)
        case .kimi:
            return self.kimiGenerationCode(lowercasedModelID)
        case .mistral:
            return self.mistralGenerationCode(lowercasedModelID)
        case .grok:
            return self.grokGenerationCode(lowercasedModelID)
        case .zai:
            return self.zaiGenerationCode(lowercasedModelID)
        }
    }

    private static func modelSuffix(for lowercasedModelID: String, family: ModelFamily) -> String {
        switch family {
        case .openAI:
            if lowercasedModelID.contains("mini") { return "M" }
            if lowercasedModelID.contains("nano") { return "N" }
            if lowercasedModelID.contains("codex") { return "C" }
            if lowercasedModelID.contains("pro") { return "P" }
            return ""
        case .claude:
            if lowercasedModelID.contains("sonnet") { return "S" }
            if lowercasedModelID.contains("opus") { return "O" }
            if lowercasedModelID.contains("haiku") { return "H" }
            return ""
        case .gemini:
            if lowercasedModelID.contains("flash") { return "F" }
            if lowercasedModelID.contains("pro") { return "P" }
            if lowercasedModelID.contains("thinking") { return "T" }
            return ""
        case .deepSeek:
            if lowercasedModelID.contains("flash") { return "F" }
            if lowercasedModelID.contains("pro") { return "P" }
            return ""
        case .xiaomiMiMo:
            if lowercasedModelID.contains("flash") { return "F" }
            if lowercasedModelID.contains("pro") { return "P" }
            return ""
        case .qwen:
            if lowercasedModelID.contains("coder") { return "C" }
            if lowercasedModelID.contains("thinking") { return "T" }
            if lowercasedModelID.contains("plus") { return "P" }
            if lowercasedModelID.contains("flash") { return "F" }
            return ""
        case .kimi:
            if lowercasedModelID.contains("thinking") { return "T" }
            if lowercasedModelID.contains("code") { return "C" }
            return ""
        case .mistral:
            if lowercasedModelID.contains("code") { return "C" }
            if lowercasedModelID.contains("small") { return "S" }
            if lowercasedModelID.contains("large") { return "L" }
            if lowercasedModelID.contains("dev") { return "D" }
            return ""
        case .grok:
            if lowercasedModelID.contains("code") { return "C" }
            if lowercasedModelID.contains("thinking") { return "T" }
            if lowercasedModelID.contains("mini") { return "M" }
            return ""
        case .zai:
            if lowercasedModelID.contains("code") { return "C" }
            if lowercasedModelID.contains("thinking") { return "T" }
            if lowercasedModelID.contains("pro") { return "P" }
            return ""
        }
    }

    private static func openAIGenerationCode(_ lowercasedModelID: String) -> String {
        let base = self.firstVersionNumber(in: lowercasedModelID) ?? ""
        if lowercasedModelID.contains("gpt-5") {
            return "5"
        }
        if lowercasedModelID.contains("gpt-4.1") {
            return "4.1"
        }
        return base
    }

    private static func claudeGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("4.8") { return "4.8" }
        if lowercasedModelID.contains("4.7") { return "4.7" }
        if lowercasedModelID.contains("4.6") { return "4.6" }
        if lowercasedModelID.contains("4.5") { return "4.5" }
        if lowercasedModelID.contains("4") { return "4" }
        if lowercasedModelID.contains("3.7") { return "3.7" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func geminiGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("3") { return "3" }
        if lowercasedModelID.contains("2.5") { return "2.5" }
        if lowercasedModelID.contains("2.0") { return "2" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func qwenGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("3.5") { return "3.5" }
        if lowercasedModelID.contains("3") { return "3" }
        if lowercasedModelID.contains("2.5") { return "2.5" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func kimiGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("2.7") { return "2.7" }
        if lowercasedModelID.contains("2.6") { return "2.6" }
        if lowercasedModelID.contains("2.5") { return "2.5" }
        if lowercasedModelID.contains("2") { return "2" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func mistralGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("2512") { return "2512" }
        if lowercasedModelID.contains("2508") { return "2508" }
        if lowercasedModelID.contains("2402") { return "2402" }
        if lowercasedModelID.contains("large") { return "" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func grokGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("4.20") { return "4.2" }
        if lowercasedModelID.contains("4.3") { return "4.3" }
        if lowercasedModelID.contains("4") { return "4" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func zaiGenerationCode(_ lowercasedModelID: String) -> String {
        if lowercasedModelID.contains("5.1") { return "5.1" }
        if lowercasedModelID.contains("4.7") { return "4.7" }
        if lowercasedModelID.contains("4.6") { return "4.6" }
        if lowercasedModelID.contains("5") { return "5" }
        if lowercasedModelID.contains("4") { return "4" }
        return self.firstVersionNumber(in: lowercasedModelID) ?? ""
    }

    private static func normalizedModelID(_ modelID: String?) -> String {
        modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func compactGenericModelCode(_ modelID: String?, fallback: String) -> String {
        let normalized = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalized.isEmpty == false else { return fallback }
        let tokens = normalized
            .replacingOccurrences(of: "/", with: "-")
            .split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .map(String.init)
            .filter { $0.isEmpty == false }
        guard tokens.isEmpty == false else { return fallback }
        let letters = tokens.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        let number = tokens.compactMap { self.firstVersionNumber(in: $0) }.first ?? ""
        let suffix = tokens.last?.first.map { String($0).uppercased() } ?? ""
        let code = "\(letters)\(number)\(suffix)"
        return code.isEmpty ? fallback : String(code.prefix(6))
    }

    private static func providerCode(from label: String) -> String {
        let tokens = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.isEmpty == false }
        let code = tokens.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        if code.isEmpty { return "AI" }
        return String(code.prefix(4))
    }

    private static func firstVersionNumber(in value: String) -> String? {
        let pattern = #"\d+(?:\.\d+)?"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }
}
