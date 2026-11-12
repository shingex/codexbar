import AppKit
import Combine
import Foundation

struct OpenAIAccountSettingsUpdate: Equatable {
    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
}

struct OpenAIUsageSettingsUpdate: Equatable {
    var pollingIntervalSeconds: Int? = nil
    var usageDisplayMode: CodexBarUsageDisplayMode? = nil
}

struct DesktopSettingsUpdate: Equatable {
    var preferredCodexAppPath: String?
}

struct CustomProviderUpdate: Equatable {
    var label: String
    var baseURL: String
    var accountID: String?
    var accountLabel: String
    var apiKey: String
    var selectedModelID: String? = nil
    var pinnedModelIDs: [String] = []
}

struct ThirdPartyModelProviderUpdate: Equatable {
    var provider: CodexBarThirdPartyModelProvider
    var label: String
    var baseURL: String
    var selectedModelID: String?
    var pinnedModelIDs: [String]
    var accountID: String?
    var accountLabel: String
    var apiKey: String
    var openCodePlan: CodexBarOpenCodePlan? = nil
    var cachedModelCatalog: [CodexBarOpenRouterModel] = []
    var fetchedAt: Date? = nil
}

struct OpenRouterProviderUpdate: Equatable {
    var accountID: String?
    var accountLabel: String
    var apiKey: String
    var selectedModelID: String?
    var pinnedModelIDs: [String]
    var cachedModelCatalog: [CodexBarOpenRouterModel]
    var fetchedAt: Date?
}

struct SettingsSaveRequests: Equatable {
    var openAIAccount: OpenAIAccountSettingsUpdate?
    var openAIUsage: OpenAIUsageSettingsUpdate?
    var desktop: DesktopSettingsUpdate?

    init(
        openAIAccount: OpenAIAccountSettingsUpdate? = nil,
        openAIUsage: OpenAIUsageSettingsUpdate? = nil,
        desktop: DesktopSettingsUpdate? = nil
    ) {
        self.openAIAccount = openAIAccount
        self.openAIUsage = openAIUsage
        self.desktop = desktop
    }

    var isEmpty: Bool {
        self.openAIAccount == nil &&
        self.openAIUsage == nil &&
        self.desktop == nil
    }

}

enum SettingsRouteTarget: Equatable {
    case openAIAccount(accountID: String, mode: CodexBarOpenAIAccountUsageMode)
    case compatibleProvider(providerID: String, accountID: String, modelID: String?, mode: CodexBarOpenAIAccountUsageMode)
    case openRouter(accountID: String, modelID: String?, mode: CodexBarOpenAIAccountUsageMode)
}

struct OpenRouterModelCatalogSnapshot: Equatable {
    var models: [CodexBarOpenRouterModel]
    var fetchedAt: Date
}

protocol OpenRouterModelCatalogFetching {
    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot
}

struct OpenRouterModelCatalogService: OpenRouterModelCatalogFetching {
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let name: String?
        }

        let data: [Model]
    }

    private let urlSession: URLSession
    private let now: () -> Date

    init(
        urlSession: URLSession? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
        self.now = now
    }

    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let models = decoded.data
            .map { CodexBarOpenRouterModel(id: $0.id, name: $0.name) }
            .filter { $0.id.isEmpty == false }
            .sorted { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                if left == right {
                    return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
                }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }

        return OpenRouterModelCatalogSnapshot(models: models, fetchedAt: self.now())
    }
}

final class TokenStore: ObservableObject {
    static let shared = TokenStore()

    @Published var catalogReloadPending = FileManager.default.fileExists(atPath: CodexPaths.openAIGatewayRootURL.appendingPathComponent("reload-pending").path)
    @Published var codexReloadRequired = false
    @Published var routingError: String?
    @Published var accounts: [TokenAccount] = []
    @Published private(set) var config: CodexBarConfig
    @Published private(set) var gatewayRoutedAccountID: String?

    private let configStore: CodexBarConfigStore
    private let syncService: any CodexSynchronizing
    private let switchJournalStore = SwitchJournalStore()
    private let openAIAccountGatewayService: OpenAIAccountGatewayControlling
    private let openRouterGatewayService: OpenRouterGatewayControlling
    private let openRouterModelCatalogService: any OpenRouterModelCatalogFetching
    private let openCodeModelCatalogService: any OpenCodeModelCatalogFetching
    private let openCodeUsageService: any OpenCodeUsageFetching
    private let openCodePlanDetectionService: any OpenCodePlanDetecting
    private let providerUsageService: ProviderUsageService
    private let openRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring
    private let gatewayRouteJournalStore: OpenAIGatewayRouteJournalStoring
    private let codexRunningProcessIDs: () -> Set<pid_t>
    private let usageRefreshStateQueue = DispatchQueue(label: "lzl.codexbar.usage-refresh-state")
    private var isRefreshingAllUsage = false
    private var refreshingUsageAccountIDs: Set<String> = []
    private var providerUsageRefreshTasks: [String: Task<Void, Never>] = [:]
    private var providerUsagePollingTasks: [String: Task<Void, Never>] = [:]
    private var providerUsagePollingKeys: [String: String] = [:]
    private var providerUsageRefreshStartedAt: [String: Date] = [:]
    private var providerUsageRefreshInFlight: Set<String> = []
    private var pendingProviderUsageRefreshRequests: [String: (force: Bool, minimumInterval: TimeInterval)] = [:]
    private var didRefreshConfiguredProviderUsageOnStartup = false
    private var cancellables: Set<AnyCancellable> = []
    private var openRouterGatewayLeaseSnapshot: OpenRouterGatewayLeaseSnapshot?
    private var openRouterGatewayLeaseTimer: Timer?
    private var lastPublishedOpenRouterSelected = false

    init(
        configStore: CodexBarConfigStore = CodexBarConfigStore(),
        syncService: any CodexSynchronizing = CodexSyncService(),
        openAIAccountGatewayService: OpenAIAccountGatewayControlling = OpenAIAccountGatewayService.shared,
        openRouterGatewayService: OpenRouterGatewayControlling = OpenRouterGatewayService(),
        openRouterModelCatalogService: any OpenRouterModelCatalogFetching = OpenRouterModelCatalogService(),
        openCodeModelCatalogService: any OpenCodeModelCatalogFetching = OpenCodeModelCatalogService(),
        openCodeUsageService: any OpenCodeUsageFetching = OpenCodeUsageService(),
        openCodePlanDetectionService: any OpenCodePlanDetecting = OpenCodePlanDetectionService(),
        providerUsageService: ProviderUsageService = ProviderUsageService(),
        openRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring = OpenRouterGatewayLeaseStore(),
        gatewayRouteJournalStore: OpenAIGatewayRouteJournalStoring = OpenAIGatewayRouteJournalStore(),
        codexRunningProcessIDs: @escaping () -> Set<pid_t> = {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier))
        }
    ) {
        self.configStore = configStore
        self.syncService = syncService
        self.openAIAccountGatewayService = openAIAccountGatewayService
        self.openRouterGatewayService = openRouterGatewayService
        self.openRouterModelCatalogService = openRouterModelCatalogService
        self.openCodeModelCatalogService = openCodeModelCatalogService
        self.openCodeUsageService = openCodeUsageService
        self.openCodePlanDetectionService = openCodePlanDetectionService
        self.providerUsageService = providerUsageService
        self.openRouterGatewayLeaseStore = openRouterGatewayLeaseStore
        self.gatewayRouteJournalStore = gatewayRouteJournalStore
        self.codexRunningProcessIDs = codexRunningProcessIDs
        self.openRouterGatewayLeaseSnapshot = openRouterGatewayLeaseStore.loadLease()

        let initialConfig: CodexBarConfig
        if let loaded = try? self.configStore.loadOrMigrate() {
            initialConfig = loaded
        } else {
            initialConfig = CodexBarConfig()
        }
        self.config = initialConfig
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter
        self.hydrateOpenCodeModelCatalogs()

        NotificationCenter.default.publisher(for: .openAIAccountGatewayDidRouteAccount)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.gatewayRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
            }
            .store(in: &self.cancellables)

        self.publishState()
        self.seedSwitchJournalIfNeeded()
        self.refreshConfiguredProviderUsageOnStartupIfNeeded()
        self.reconcileProviderUsagePolling(refreshImmediately: true)
        if !self.config.openAI.modelRoutingEnabled && self.config.openAI.accountUsageMode == .hybridProvider {
            do { try self.setCodexIntegrationEnabled(true, selection: self.config.active) }
            catch { self.routingError = error.localizedDescription }
        } else {
            try? self.syncService.synchronize(config: self.config)
        }
    }

    var customProviders: [CodexBarProvider] {
        self.config.providers.filter { $0.isCustomRelayProvider }
    }

    var thirdPartyModelProviders: [CodexBarProvider] {
        self.config.providers.filter { $0.isThirdPartyModelProvider }
    }

    var openCodeProviders: [CodexBarProvider] {
        self.thirdPartyModelProviders.filter { $0.isOpenCodeProvider }
    }

    var genericThirdPartyModelProviders: [CodexBarProvider] {
        self.thirdPartyModelProviders.filter { $0.isOpenCodeProvider == false }
    }

    var openRouterProvider: CodexBarProvider? {
        self.config.openRouterProvider()
    }

    var activeProvider: CodexBarProvider? {
        self.config.activeProvider()
    }

    var activeProviderAccount: CodexBarProviderAccount? {
        self.config.activeAccount()
    }

    var activeModel: String {
        if let activeProvider = self.config.activeProvider(),
           activeProvider.kind == .openRouter,
           let selectedModelID = activeProvider.openRouterEffectiveModelID(forAccountID: self.config.active.accountId) {
            return selectedModelID
        }
        if let activeProvider = self.config.activeProvider(),
           activeProvider.kind == .openAICompatible {
            if activeProvider.isThirdPartyModelProvider,
               let modelID = activeProvider.thirdPartyEffectiveModelID(forAccountID: self.config.active.accountId) {
                return modelID
            }
            if let defaultModel = activeProvider.defaultModel {
                return defaultModel
            }
        }
        return self.config.global.defaultModel
    }

    var gatewayRoutedAccount: TokenAccount? {
        guard let gatewayRoutedAccountID else { return nil }
        return self.accounts.first(where: { $0.accountId == gatewayRoutedAccountID })
    }

    var hasAnyConfiguredAccount: Bool {
        self.accounts.isEmpty == false || self.config.hasAnyConfiguredAccount
    }

    func load() {
        if let loaded = try? self.configStore.loadOrMigrate() {
            self.config = loaded
            self.hydrateOpenCodeModelCatalogs()
            self.publishState()
            self.reconcileProviderUsagePolling()
        }
    }

    func addOrUpdate(_ account: TokenAccount) {
        let result = self.config.upsertOAuthAccount(account, activate: false)
        self.persistIgnoringErrors(syncCodex: result.syncCodex)
    }

    func remove(_ account: TokenAccount) throws {
        guard var provider = self.oauthProvider() else {
            throw TokenStoreError.providerNotFound
        }
        guard let removedAccount = self.oauthStoredAccount(in: provider, matching: account) else {
            throw TokenStoreError.accountNotFound
        }

        let removedAccountID = removedAccount.id
        let removedWasActiveSelection = self.config.active.providerId == provider.id &&
            self.config.active.accountId == removedAccountID
        let removedWasOAuthLoginAccount = provider.activeAccountId == removedAccountID

        provider.accounts.removeAll { $0.id == removedAccountID }
        self.config.removeOpenAIAccountOrder(accountID: removedAccountID)

        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
            if self.config.active.providerId == provider.id {
                let fallback = self.config.providers.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
            }
        } else {
            if provider.activeAccountId == removedAccountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if removedWasActiveSelection {
                self.config.active.accountId = provider.activeAccountId
            }
            self.upsertProvider(provider)
        }

        self.config.normalizeOpenAIAccountOrder()
        let shouldSyncCodex = removedWasActiveSelection ||
            (removedWasOAuthLoginAccount && self.config.openAI.accountUsageMode == .hybridProvider)
        try self.persist(syncCodex: shouldSyncCodex && self.config.activeProvider() != nil)
        self.reconcileProviderUsagePolling()
    }

    func activate(
        _ account: TokenAccount,
        reason: AutoRoutingSwitchReason = .manual,
        automatic: Bool = false,
        forced: Bool = false,
        protectedByManualGrace: Bool = false
    ) throws {
        try self.activateOpenAIAccount(
            account,
            accountUsageMode: .switchAccount,
            reason: reason,
            automatic: automatic,
            forced: forced,
            protectedByManualGrace: protectedByManualGrace
        )
    }

    func activateOpenAIAccount(
        _ account: TokenAccount,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        reason: AutoRoutingSwitchReason = .manual,
        automatic: Bool = false,
        forced: Bool = false,
        protectedByManualGrace: Bool = false
    ) throws {
        if self.config.openAI.modelRoutingEnabled && self.config.openAI.modelRoutingStyle == .catalog {
            _ = try self.config.activateOAuthAccount(accountID: account.accountId)
            try self.syncService.synchronize(config: self.config)
            self.requireCodexReload()
            try self.persist(syncCodex: false)
            return
        }
        if self.config.openAI.modelRoutingEnabled, let provider = self.oauthProvider() {
            try self.selectHybridRouteTarget(providerID: provider.id, accountID: account.accountId, modelID: nil)
            return
        }
        _ = try self.reconcileAuthJSONIfNeeded(accountID: account.accountId)
        let previousAccountID = self.activeAccount()?.accountId
        _ = try self.config.activateOAuthAccount(accountID: account.accountId)
        self.config.openAI.accountUsageMode = accountUsageMode
        if accountUsageMode == .switchAccount {
            self.config.captureSwitchModeSelection()
        }
        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(
            previousAccountID: previousAccountID,
            reason: reason,
            automatic: automatic,
            forced: forced,
            protectedByManualGrace: protectedByManualGrace
        )
    }

    func activeAccount() -> TokenAccount? {
        self.accounts.first(where: { $0.isActive })
    }

    func activateCustomProvider(
        providerID: String,
        accountID: String,
        modelID: String? = nil,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) throws {
        if self.config.openAI.modelRoutingEnabled {
            try self.selectHybridRouteTarget(providerID: providerID, accountID: accountID, modelID: modelID)
            return
        }
        let previousSelection = self.config.active
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        guard provider.accounts.contains(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        if provider.kind == .openAICompatible,
           let modelID {
            try Self.applyThirdPartyModelSelection(
                modelID: modelID,
                accountID: accountID,
                provider: &provider
            )
        }

        provider.activeAccountId = accountID
        self.upsertProvider(provider)
        self.config.openAI.accountUsageMode = accountUsageMode
        self.config.active.providerId = provider.id
        self.config.active.accountId = accountID
        if accountUsageMode == .switchAccount {
            if provider.isThirdPartyModelProvider {
                self.config.openAI.switchModeSelection = previousSelection
            } else {
                self.config.captureSwitchModeSelection()
            }
        }

        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(previousAccountID: previousSelection.accountId)
    }

    func activateOpenRouterProvider(
        accountID: String,
        accountUsageMode: CodexBarOpenAIAccountUsageMode = .hybridProvider
    ) throws {
        if self.config.openAI.modelRoutingEnabled, let provider = self.openRouterProvider {
            try self.selectHybridRouteTarget(providerID: provider.id, accountID: accountID, modelID: nil)
            return
        }
        let previousSelection = self.config.active
        self.config.openAI.accountUsageMode = accountUsageMode
        _ = try self.config.activateOpenRouterAccount(accountID: accountID)
        if accountUsageMode == .switchAccount {
            self.config.captureSwitchModeSelection()
        }
        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(previousAccountID: previousSelection.accountId)
    }

    private func cleanupThirdPartySelectionIfLeavingThirdParty(to target: SettingsRouteTarget) {
        guard let activeProvider = self.config.activeProvider(),
              activeProvider.isThirdPartyModelProvider else {
            return
        }

        switch target {
        case .compatibleProvider(let providerID, _, _, _):
            if providerID == activeProvider.id {
                return
            }
        case .openRouter:
            break
        case .openAIAccount:
            break
        }

        self.config.openAI.switchModeSelection = nil
    }

    func addCustomProvider(label: String, baseURL: String, accountLabel: String, apiKey: String, selectedModelID: String? = nil, pinnedModelIDs: [String] = []) throws {
        let models = try Self.validatedKeyModels(selectedModelID, pinned: pinnedModelIDs)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBaseURL.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let providerID = self.slug(from: trimmedLabel.isEmpty ? (URL(string: trimmedBaseURL)?.host ?? "provider") : trimmedLabel)
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel,
            apiKey: trimmedAPIKey,
            addedAt: Date(),
            modelSelection: models
        )
        let provider = CodexBarProvider(
            id: providerID,
            kind: .openAICompatible,
            label: trimmedLabel,
            enabled: true,
            baseURL: trimmedBaseURL,
            thirdPartyModelProvider: nil,
            activeAccountId: account.id,
            accounts: [account]
        )

        self.config.providers.removeAll { $0.id == provider.id }
        self.config.providers.append(provider)

        try self.persist(syncCodex: false)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: provider.id)
    }

    func addThirdPartyModelProvider(
        provider thirdPartyProvider: CodexBarThirdPartyModelProvider,
        label: String,
        baseURL: String,
        selectedModelID: String?,
        pinnedModelIDs: [String],
        accountLabel: String,
        apiKey: String,
        openCodePlan: CodexBarOpenCodePlan? = nil,
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        fetchedAt: Date? = nil
    ) throws {
        let keyModels = try Self.validatedKeyModels(selectedModelID, pinned: pinnedModelIDs)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPinnedModelIDs = keyModels.pinnedModelIDs
        let normalizedSelectedModelID = keyModels.selectedModelID
        guard trimmedBaseURL.isEmpty == false,
              normalizedPinnedModelIDs.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel,
            apiKey: trimmedAPIKey,
            addedAt: Date(),
            thirdPartyModelSelection: CodexBarOpenRouterSelection(
                selectedModelID: normalizedSelectedModelID,
                pinnedModelIDs: normalizedPinnedModelIDs,
                cachedModelCatalog: cachedModelCatalog,
                modelCatalogFetchedAt: fetchedAt
            )
        )
        let providerLabel = trimmedLabel.isEmpty ? thirdPartyProvider.title : trimmedLabel
        let providerID = self.slug(from: providerLabel)
        if let providerIndex = self.config.providers.firstIndex(where: {
            $0.id == providerID &&
                $0.isThirdPartyModelProvider &&
                $0.thirdPartyModelProvider == thirdPartyProvider
        }) {
            self.config.providers[providerIndex].label = providerLabel
            self.config.providers[providerIndex].baseURL = trimmedBaseURL
            self.config.providers[providerIndex].defaultModel = normalizedSelectedModelID ?? normalizedPinnedModelIDs.first
            self.config.providers[providerIndex].thirdPartyModelProvider = thirdPartyProvider
            self.config.providers[providerIndex].openCodePlan = thirdPartyProvider == .openCode
                ? (openCodePlan ?? CodexBarOpenCodePlan.inferred(from: trimmedBaseURL) ?? .go)
                : nil
            self.config.providers[providerIndex].accounts.append(account)
            self.config.providers[providerIndex].activeAccountId = account.id
        } else {
            let provider = CodexBarProvider(
                id: providerID,
                kind: .openAICompatible,
                label: providerLabel,
                enabled: true,
                baseURL: trimmedBaseURL,
                defaultModel: normalizedSelectedModelID ?? normalizedPinnedModelIDs.first,
                thirdPartyModelProvider: thirdPartyProvider,
                openCodePlan: thirdPartyProvider == .openCode
                    ? (openCodePlan ?? CodexBarOpenCodePlan.inferred(from: trimmedBaseURL) ?? .go)
                    : nil,
                activeAccountId: account.id,
                accounts: [account]
            )
            self.config.providers.removeAll { $0.id == provider.id }
            self.config.providers.append(provider)
        }

        if thirdPartyProvider == .openCode,
           let providerIndex = self.config.providers.firstIndex(where: {
               $0.id == providerID && $0.isOpenCodeProvider
           }) {
            let plan = openCodePlan ?? CodexBarOpenCodePlan.inferred(from: trimmedBaseURL) ?? .go
            if let cached = self.openCodeModelCatalogService.loadCachedCatalog(plan: plan) {
                _ = self.config.providers[providerIndex].updateThirdPartyModelCatalog(
                    cached.models.map(\.selectionModel),
                    fetchedAt: cached.fetchedAt
                )
            }
        }

        try self.persist(syncCodex: false)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func addOpenRouterProvider(
        accountLabel: String = "",
        apiKey: String,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        fetchedAt: Date? = nil
    ) throws {
        _ = try Self.validatedKeyModels(selectedModelID, pinned: pinnedModelIDs)
        _ = try self.config.upsertOpenRouterProvider(
            accountLabel: accountLabel,
            apiKey: apiKey,
            activate: false
        )
        if selectedModelID != nil ||
            pinnedModelIDs.isEmpty == false ||
            cachedModelCatalog.isEmpty == false ||
            fetchedAt != nil {
            try self.config.setOpenRouterModelSelection(
                accountID: self.config.openRouterProvider()?.activeAccountId,
                selectedModelID: selectedModelID,
                pinnedModelIDs: pinnedModelIDs,
                cachedModelCatalog: cachedModelCatalog,
                fetchedAt: fetchedAt
            )
        }
        try self.persist(syncCodex: false)
        if let providerID = self.config.openRouterProvider()?.id {
            self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
        }
    }

    func addOpenRouterProviderAccount(
        label: String = "",
        apiKey: String,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        fetchedAt: Date? = nil
    ) throws {
        _ = try Self.validatedKeyModels(selectedModelID, pinned: pinnedModelIDs)
        _ = try self.config.upsertOpenRouterProvider(
            accountLabel: label,
            apiKey: apiKey,
            activate: false
        )
        if selectedModelID != nil ||
            pinnedModelIDs.isEmpty == false ||
            cachedModelCatalog.isEmpty == false ||
            fetchedAt != nil {
            try self.config.setOpenRouterModelSelection(
                accountID: self.config.openRouterProvider()?.activeAccountId,
                selectedModelID: selectedModelID,
                pinnedModelIDs: pinnedModelIDs,
                cachedModelCatalog: cachedModelCatalog,
                fetchedAt: fetchedAt
            )
        }
        try self.persist(syncCodex: false)
        if let providerID = self.config.openRouterProvider()?.id {
            self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
        }
    }

    func updateOpenRouterDefaultModel(_ value: String?) throws {
        try self.updateOpenRouterSelectedModel(value)
    }

    func updateOpenRouterSelectedModel(_ value: String?, accountID: String? = nil) throws {
        guard value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TokenStoreError.invalidInput
        }
        try self.config.setOpenRouterSelectedModel(value, accountID: accountID)
        let shouldSyncCodex = self.config.activeProvider()?.kind == .openRouter
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func updateOpenRouterModelSelection(
        accountID: String? = nil,
        selectedModelID: String?,
        pinnedModelIDs: [String],
        cachedModelCatalog: [CodexBarOpenRouterModel],
        fetchedAt: Date?
    ) throws {
        _ = try Self.validatedKeyModels(selectedModelID, pinned: pinnedModelIDs)
        try self.config.setOpenRouterModelSelection(
            accountID: accountID,
            selectedModelID: selectedModelID,
            pinnedModelIDs: pinnedModelIDs,
            cachedModelCatalog: cachedModelCatalog,
            fetchedAt: fetchedAt
        )
        let shouldSyncCodex = self.config.activeProvider()?.kind == .openRouter
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func refreshOpenRouterModelCatalog() async throws {
        guard let provider = self.openRouterProvider,
              let account = self.config.active.providerId == provider.id ?
                (provider.accounts.first(where: { $0.id == self.config.active.accountId }) ?? provider.activeAccount) :
                provider.activeAccount,
              let apiKey = account.apiKey else {
            throw TokenStoreError.accountNotFound
        }

        let snapshot = try await self.openRouterModelCatalogService.fetchCatalog(apiKey: apiKey)
        try self.config.updateOpenRouterModelCatalog(accountID: account.id, snapshot.models, fetchedAt: snapshot.fetchedAt)
        try self.persist(syncCodex: false)
    }

    func refreshOpenRouterModelCatalog(accountID: String) async throws {
        guard let provider = self.openRouterProvider,
              let account = provider.accounts.first(where: { $0.id == accountID }),
              let apiKey = account.apiKey else {
            throw TokenStoreError.accountNotFound
        }

        let snapshot = try await self.openRouterModelCatalogService.fetchCatalog(apiKey: apiKey)
        try self.config.updateOpenRouterModelCatalog(accountID: account.id, snapshot.models, fetchedAt: snapshot.fetchedAt)
        try self.persist(syncCodex: self.config.active.providerId == provider.id && self.config.active.accountId == account.id)
    }

    func saveProviderUsageConfiguration(
        providerID: String,
        configuration: CodexBarProviderUsageConfiguration
    ) throws {
        try self.config.configureProviderUsage(providerID: providerID, configuration: configuration)
        try self.persist(syncCodex: false)
        self.reconcileProviderUsagePolling(refreshImmediately: configuration.intervalSeconds > 0)
        if configuration.intervalSeconds == 0 {
            self.refreshProviderUsage(providerID: providerID)
        }
    }

    func disableProviderUsage(providerID: String) throws {
        try self.config.disableProviderUsage(providerID: providerID)
        try self.persist(syncCodex: false)
        self.clearProviderUsageRefreshState(providerID: providerID)
        self.reconcileProviderUsagePolling()
    }

    func refreshProviderUsage(providerID: String) {
        self.scheduleProviderUsageRefresh(
            providerID: providerID,
            force: true,
            minimumInterval: 0,
            enqueueIfInFlight: false
        )
    }

    func previewOpenRouterModelCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        try await self.openRouterModelCatalogService.fetchCatalog(apiKey: apiKey)
    }

    func refreshOpenCodeModelCatalog(
        providerID: String,
        accountID: String? = nil,
        force: Bool = false
    ) async throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.isOpenCodeProvider }),
              let plan = provider.effectiveOpenCodePlan else {
            throw TokenStoreError.providerNotFound
        }
        let account = accountID.flatMap { id in provider.accounts.first(where: { $0.id == id }) } ?? provider.activeAccount
        guard let account, let apiKey = account.apiKey else {
            throw TokenStoreError.accountNotFound
        }

        if force == false,
           let cached = self.openCodeModelCatalogService.loadCachedCatalog(plan: plan),
           cached.fetchedAt.addingTimeInterval(OpenCodeModelCatalogService.cacheTTL) > Date() {
            if provider.updateThirdPartyModelCatalog(
                cached.models.map(\.selectionModel),
                fetchedAt: cached.fetchedAt
            ) {
                self.upsertProvider(provider)
                try self.persist(syncCodex: false)
            }
            return
        }

        let snapshot = try await self.openCodeModelCatalogService.fetchCatalog(plan: plan, apiKey: apiKey)
        guard var latest = self.config.providers.first(where: { $0.id == providerID && $0.isOpenCodeProvider }) else {
            throw TokenStoreError.providerNotFound
        }
        if latest.updateThirdPartyModelCatalog(
            snapshot.models.map(\.selectionModel),
            fetchedAt: snapshot.fetchedAt
        ) {
            self.upsertProvider(latest)
        }
        try self.persist(syncCodex: false)
    }

    func previewOpenCodeModelCatalog(
        plan: CodexBarOpenCodePlan,
        apiKey: String
    ) async throws -> OpenCodeModelCatalogSnapshot {
        try await self.openCodeModelCatalogService.fetchCatalog(plan: plan, apiKey: apiKey)
    }

    func cachedOpenCodeModelCatalog(plan: CodexBarOpenCodePlan) -> OpenCodeModelCatalogSnapshot? {
        self.openCodeModelCatalogService.loadCachedCatalog(plan: plan)
    }

    func detectOpenCodePlan(apiKey: String) async throws -> CodexBarOpenCodePlan {
        try await self.openCodePlanDetectionService.detectPlan(apiKey: apiKey)
    }

    func addCustomProviderAccount(providerID: String, label: String, apiKey: String, selectedModelID: String? = nil, pinnedModelIDs: [String] = []) throws {
        let models = try Self.validatedKeyModels(selectedModelID, pinned: pinnedModelIDs)
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty, !(provider.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TokenStoreError.invalidInput }

        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Account \(provider.accounts.count + 1)" : label.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            addedAt: Date(),
            modelSelection: models
        )
        provider.accounts.append(account)
        if provider.activeAccountId == nil {
            provider.activeAccountId = account.id
        }
        self.upsertProvider(provider)
        try self.persist(syncCodex: false)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func updateCustomProvider(providerID: String, request: CustomProviderUpdate, preserveActiveAccount: Bool = false) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.isCustomRelayProvider }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedLabel = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = request.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBaseURL.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let accountID = request.accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        let existing = provider.accounts[accountIndex].modelSelection
        let models = try Self.validatedKeyModels(request.selectedModelID ?? existing?.selectedModelID,
            pinned: request.selectedModelID == nil ? (existing?.pinnedModelIDs ?? []) : request.pinnedModelIDs)
        provider.accounts[accountIndex].modelSelection = models
        provider.label = trimmedLabel
        provider.baseURL = trimmedBaseURL
        provider.thirdPartyModelProvider = nil
        provider.accounts[accountIndex].label = trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel
        provider.accounts[accountIndex].apiKey = trimmedAPIKey
        if !preserveActiveAccount {
            provider.activeAccountId = provider.accounts[accountIndex].id
        }
        self.upsertProvider(provider)

        let shouldSyncCodex = self.config.active.providerId == providerID
        if shouldSyncCodex && !preserveActiveAccount {
            self.config.active.accountId = provider.accounts[accountIndex].id
        }
        try self.persist(syncCodex: shouldSyncCodex)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func updateThirdPartyModelProvider(
        providerID: String,
        request: ThirdPartyModelProviderUpdate
    ) throws {
        let keyModels = try Self.validatedKeyModels(request.selectedModelID, pinned: request.pinnedModelIDs)
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.isThirdPartyModelProvider }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedBaseURL = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = request.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPinnedModelIDs = keyModels.pinnedModelIDs
        let normalizedSelectedModelID = keyModels.selectedModelID
        guard trimmedBaseURL.isEmpty == false,
              normalizedPinnedModelIDs.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let accountID = request.accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        let trimmedLabel = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.label = trimmedLabel
        provider.baseURL = trimmedBaseURL
        provider.thirdPartyModelProvider = request.provider
        provider.openCodePlan = request.provider == .openCode
            ? (request.openCodePlan ?? CodexBarOpenCodePlan.inferred(from: trimmedBaseURL) ?? .go)
            : nil
        provider.accounts[accountIndex].label = trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel
        provider.accounts[accountIndex].apiKey = trimmedAPIKey
        if request.provider == .openCode {
            provider.cachedModelCatalog = request.cachedModelCatalog
            provider.modelCatalogFetchedAt = request.fetchedAt
            provider.accounts[accountIndex].thirdPartyModelSelection = CodexBarOpenRouterSelection(
                selectedModelID: normalizedSelectedModelID,
                pinnedModelIDs: normalizedPinnedModelIDs,
                cachedModelCatalog: request.cachedModelCatalog,
                modelCatalogFetchedAt: request.fetchedAt
            )
        } else {
            provider.accounts[accountIndex].thirdPartyModelSelection = CodexBarOpenRouterSelection(
                selectedModelID: normalizedSelectedModelID,
                pinnedModelIDs: normalizedPinnedModelIDs
            )
        }
        provider.activeAccountId = provider.accounts[accountIndex].id
        self.upsertProvider(provider)

        let shouldSyncCodex = self.config.active.providerId == providerID
        if shouldSyncCodex {
            self.config.active.accountId = provider.accounts[accountIndex].id
        }
        try self.persist(syncCodex: shouldSyncCodex)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func updateThirdPartyProviderMetadata(
        providerID: String,
        provider thirdPartyProvider: CodexBarThirdPartyModelProvider,
        label: String,
        baseURL: String
    ) throws {
        guard var storedProvider = self.config.providers.first(where: { $0.id == providerID && $0.isThirdPartyModelProvider }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBaseURL.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        storedProvider.label = trimmedLabel
        storedProvider.baseURL = trimmedBaseURL
        storedProvider.thirdPartyModelProvider = thirdPartyProvider
        storedProvider.openCodePlan = thirdPartyProvider == .openCode
            ? (CodexBarOpenCodePlan.inferred(from: trimmedBaseURL) ?? .go)
            : nil
        self.upsertProvider(storedProvider)

        let shouldSyncCodex = self.config.active.providerId == providerID && storedProvider.thirdPartyEffectiveModelID(forAccountID: self.config.active.accountId) != nil
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func updateThirdPartySelectedModel(
        _ modelID: String,
        providerID: String,
        accountID: String
    ) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        try Self.applyThirdPartyModelSelection(
            modelID: modelID,
            accountID: accountID,
            provider: &provider
        )
        self.upsertProvider(provider)
        let shouldSyncCodex = self.config.active.providerId == providerID &&
            self.config.active.accountId == accountID
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func updateCustomProviderAccount(providerID: String, accountID: String, label: String, apiKey: String, selectedModelID: String? = nil, pinnedModelIDs: [String] = []) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty, !(provider.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TokenStoreError.invalidInput }

        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        let existing = provider.accounts[accountIndex].modelSelection
        provider.accounts[accountIndex].modelSelection = try Self.validatedKeyModels(selectedModelID ?? existing?.selectedModelID,
            pinned: selectedModelID == nil ? (existing?.pinnedModelIDs ?? []) : pinnedModelIDs)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.accounts[accountIndex].label = trimmedLabel.isEmpty ? provider.accounts[accountIndex].label : trimmedLabel
        provider.accounts[accountIndex].apiKey = trimmedAPIKey
        self.upsertProvider(provider)

        let shouldSyncCodex = self.config.active.providerId == providerID &&
            self.config.active.accountId == accountID
        try self.persist(syncCodex: shouldSyncCodex)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func updateOpenRouterProvider(request: OpenRouterProviderUpdate) throws {
        _ = try Self.validatedKeyModels(request.selectedModelID, pinned: request.pinnedModelIDs)
        guard var provider = self.openRouterProvider else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedAPIKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { throw TokenStoreError.invalidInput }
        let trimmedAccountLabel = request.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        let accountID = request.accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        let normalizedSelectedModelID = CodexBarProvider.normalizedOpenRouterModelID(request.selectedModelID)
        let pinnedModelIDs = CodexBarProvider.normalizedOpenRouterModelIDs(request.pinnedModelIDs)

        provider.accounts[accountIndex].label = trimmedAccountLabel.isEmpty ?
            provider.accounts[accountIndex].label :
            trimmedAccountLabel
        provider.accounts[accountIndex].apiKey = trimmedAPIKey
        provider.accounts[accountIndex].openRouterSelection = CodexBarOpenRouterSelection(
            selectedModelID: normalizedSelectedModelID,
            pinnedModelIDs: pinnedModelIDs,
            cachedModelCatalog: request.cachedModelCatalog,
            modelCatalogFetchedAt: request.fetchedAt
        )
        provider.activeAccountId = provider.accounts[accountIndex].id
        if let selection = provider.accounts[accountIndex].openRouterSelection {
            provider.applyOpenRouterCompatibilityMirror(selection: selection)
        }
        self.upsertProvider(provider)

        let shouldSyncCodex = self.config.active.providerId == provider.id
        if shouldSyncCodex {
            self.config.active.accountId = provider.accounts[accountIndex].id
        }
        try self.persist(syncCodex: shouldSyncCodex)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: provider.id)
    }

    func removeCustomProviderAccount(providerID: String, accountID: String) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        provider.accounts.removeAll { $0.id == accountID }
        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == providerID }
            self.clearProviderUsageRefreshState(providerID: providerID)
            if self.config.active.providerId == providerID {
                let fallback = self.config.providers.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
                try self.persist(syncCodex: fallback != nil)
                self.reconcileProviderUsagePolling()
                return
            }
        } else {
            if provider.activeAccountId == accountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if self.config.active.providerId == providerID && self.config.active.accountId == accountID {
                self.upsertProvider(provider)
                self.config.active.accountId = provider.activeAccountId
                try self.persist(syncCodex: true)
                self.reconcileProviderUsagePolling()
                return
            }
            self.upsertProvider(provider)
        }
        try self.persist(syncCodex: false)
        self.reconcileProviderUsagePolling()
    }

    func removeCustomProvider(providerID: String) throws {
        self.providerUsageRefreshTasks[providerID]?.cancel()
        self.providerUsageRefreshTasks[providerID] = nil
        self.clearProviderUsageRefreshState(providerID: providerID)
        self.config.providers.removeAll { $0.id == providerID }
        if self.config.active.providerId == providerID {
            let fallback = self.oauthProvider() ?? self.openRouterProvider ?? self.customProviders.first
            self.config.active.providerId = fallback?.id
            self.config.active.accountId = fallback?.activeAccount?.id
            try self.persist(syncCodex: fallback != nil)
            self.reconcileProviderUsagePolling()
            return
        }
        try self.persist(syncCodex: false)
        self.reconcileProviderUsagePolling()
    }

    func removeOpenRouterProviderAccount(accountID: String) throws {
        guard var provider = self.openRouterProvider else {
            throw TokenStoreError.providerNotFound
        }

        provider.accounts.removeAll { $0.id == accountID }
        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
            if self.config.active.providerId == provider.id {
                let fallback = self.oauthProvider() ?? self.customProviders.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
                try self.persist(syncCodex: fallback != nil)
                self.reconcileProviderUsagePolling()
                return
            }
        } else {
            if provider.activeAccountId == accountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if self.config.active.providerId == provider.id && self.config.active.accountId == accountID {
                self.upsertProvider(provider)
                self.config.active.accountId = provider.activeAccountId
                try self.persist(syncCodex: true)
                self.reconcileProviderUsagePolling()
                return
            }
            self.upsertProvider(provider)
        }

        try self.persist(syncCodex: false)
        self.reconcileProviderUsagePolling()
    }

    func markActiveAccount() {
        self.publishState()
    }

    func saveOpenAIAccountSettings(_ request: OpenAIAccountSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(openAIAccount: request)
        )
    }

    func updateOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) throws {
        guard self.config.openAI.accountUsageMode != mode else { return }

        self.config.setOpenAIAccountUsageMode(mode)
        if mode == .switchAccount {
            let restoredSelectionWasThirdParty = self.config.openAI.switchModeSelection.flatMap { selection in
                self.config.provider(id: selection.providerId)?.isThirdPartyModelProvider
            } == true
            if restoredSelectionWasThirdParty {
                self.config.openAI.switchModeSelection = nil
                self.selectOAuthActiveAccountIfNeeded()
            } else {
                self.config.restoreSwitchModeSelectionIfAvailable()
            }
        }

        try self.persist(
            syncCodex: mode == .hybridProvider ||
                self.config.active.providerId == self.oauthProvider()?.id
        )
    }

    func restoreOpenAIAccountUsageMode(
        _ mode: CodexBarOpenAIAccountUsageMode,
        activeProviderID: String?,
        activeAccountID: String?
    ) throws {
        self.config.setOpenAIAccountUsageMode(mode)
        self.config.active.providerId = activeProviderID
        self.config.active.accountId = activeAccountID
        if mode == .switchAccount {
            _ = self.clearThirdPartySwitchModeSelectionIfNeeded()
        }
        try self.persist(syncCodex: activeProviderID != nil)
    }

    func restoreActiveSelection(
        activeProviderID: String?,
        activeAccountID: String?
    ) throws {
        let wasThirdPartyProviderActive = self.config.activeProvider()?.isThirdPartyModelProvider == true
        self.config.active.providerId = activeProviderID
        self.config.active.accountId = activeAccountID
        if self.config.openAI.accountUsageMode == .switchAccount {
            if wasThirdPartyProviderActive &&
                self.config.activeProvider()?.isThirdPartyModelProvider != true {
                self.config.openAI.switchModeSelection = nil
            } else {
                _ = self.clearThirdPartySwitchModeSelectionIfNeeded()
            }
        }
        try self.persist(syncCodex: activeProviderID != nil)
    }

    func saveOpenAIUsageSettings(_ request: OpenAIUsageSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(openAIUsage: request)
        )
    }

    func saveUsageDisplayMode(_ mode: CodexBarUsageDisplayMode) throws {
        guard self.config.openAI.usageDisplayMode != mode else {
            self.publishState()
            return
        }

        self.config.openAI.usageDisplayMode = mode
        try self.persist(syncCodex: false)
    }

    func saveDesktopSettings(_ request: DesktopSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(desktop: request)
        )
    }

    func saveSettings(_ requests: SettingsSaveRequests) throws {
        guard requests.isEmpty == false else { return }

        var updatedConfig = self.config
        try SettingsSaveRequestApplier.apply(requests, to: &updatedConfig)
        try self.configStore.save(updatedConfig)
        self.config = updatedConfig
        self.publishState()
    }

    func applySettingsRoute(_ route: SettingsRouteDraft) throws -> Bool {
        var route = route
        if let target = route.target {
            switch target {
            case .compatibleProvider, .openRouter: route.modelRoutingEnabled = true
            case .openAIAccount: break
            }
        }
        if route.modelRoutingEnabled || self.config.openAI.modelRoutingEnabled || route.style != self.config.openAI.modelRoutingStyle {
            return try self.applyModelRoutingSettings(route)
        }
        var targetApplied = false
        if let target = route.target {
            targetApplied = try self.applySettingsRouteTarget(target)
        }

        return targetApplied
    }

    func applySettingsRouteTarget(_ target: SettingsRouteTarget) throws -> Bool {
        switch target {
        case .openAIAccount(let accountID, let mode):
            guard let account = self.accounts.first(where: { $0.accountId == accountID }) else {
                throw TokenStoreError.accountNotFound
            }
            guard self.config.openAI.accountUsageMode != mode ||
                    self.config.activeProvider()?.kind != .openAIOAuth ||
                    self.activeAccount()?.accountId != accountID else {
                return false
            }
            self.cleanupThirdPartySelectionIfLeavingThirdParty(to: target)
            try self.activateOpenAIAccount(
                account,
                accountUsageMode: mode,
                reason: .manual,
                automatic: false,
                forced: false,
                protectedByManualGrace: false
            )
            return true

        case let .compatibleProvider(providerID, accountID, modelID, mode):
            var didChange = false
            if let provider = self.config.provider(id: providerID),
               provider.isThirdPartyModelProvider,
               let modelID,
               provider.thirdPartyEffectiveModelID(forAccountID: accountID) != modelID {
                try self.updateThirdPartySelectedModel(modelID, providerID: providerID, accountID: accountID)
                didChange = true
            }
            guard self.config.active.providerId != providerID ||
                    self.config.active.accountId != accountID ||
                    self.config.openAI.accountUsageMode != mode else {
                return didChange
            }
            self.cleanupThirdPartySelectionIfLeavingThirdParty(to: target)
            try self.activateCustomProvider(providerID: providerID, accountID: accountID, modelID: modelID, accountUsageMode: mode)
            return true

        case let .openRouter(accountID, modelID, mode):
            var didChange = false
            if let modelID,
               self.openRouterProvider?.openRouterEffectiveModelID(forAccountID: accountID) != modelID {
                try self.updateOpenRouterSelectedModel(modelID, accountID: accountID)
                didChange = true
            }
            guard self.config.active.providerId != self.openRouterProvider?.id ||
                    self.config.active.accountId != accountID ||
                    self.config.openAI.accountUsageMode != mode else {
                return didChange
            }
            self.cleanupThirdPartySelectionIfLeavingThirdParty(to: target)
            try self.activateOpenRouterProvider(accountID: accountID, accountUsageMode: mode)
            return true
        }
    }

    func selectHybridRouteTarget(providerID: String, accountID: String, modelID: String?) throws {
        if self.config.openAI.modelRoutingStyle == .catalog { throw CodexModelRoutingError.selectInCodex }
        let previous = self.config
        do {
            try self.setHybridRouteTarget(providerID: providerID, accountID: accountID, modelID: modelID)
            try self.persist(syncCodex: false)
        } catch { self.config = previous; throw error }
    }

    private func setHybridRouteTarget(providerID: String, accountID: String, modelID: String?) throws {
        guard var provider = self.config.provider(id: providerID),
              let index = provider.accounts.firstIndex(where: { $0.id == accountID }) else { throw TokenStoreError.accountNotFound }
        let current = provider.kind == .openRouter ? provider.openRouterEffectiveModelID(forAccountID: accountID)
            : provider.thirdPartyEffectiveModelID(forAccountID: accountID)
        if provider.usesAPIKeyAuth, let modelID, modelID != current {
            let selection = provider.accounts[index].modelSelection ?? .init()
            provider.accounts[index].modelSelection = selection.updating(selectedModelID: modelID)
        }
        if provider.usesAPIKeyAuth { provider.activeAccountId = accountID }
        self.upsertProvider(provider)
        self.config.active = .init(providerId: providerID, accountId: accountID)
        self.config.openAI.accountUsageMode = .hybridProvider
        self.config.openAI.lastModelRoutingSelection = self.config.active
    }

    func moveProvider(_ source: String, before destination: String) throws {
        var order = self.config.openAI.providerDisplayOrder
        for provider in self.config.providers where !order.contains(provider.id) { order.append(provider.id) }
        guard source != destination, order.contains(source), order.contains(destination) else { return }
        order.removeAll { $0 == source }
        guard let target = order.firstIndex(of: destination) else { return }
        order.insert(source, at: target)
        self.config.openAI.providerDisplayOrder = order
        try self.persist(syncCodex: false)
    }

    func requireCodexReload() {
        self.codexReloadRequired = true
        self.catalogReloadPending = true
        try? CodexPaths.writeSecureFile(Data(), to: CodexPaths.openAIGatewayRootURL.appendingPathComponent("reload-pending"))
    }

    func acknowledgeCodexReload() {
        self.catalogReloadPending = false
        try? FileManager.default.removeItem(at: CodexPaths.openAIGatewayRootURL.appendingPathComponent("reload-pending"))
    }

    func setCodexIntegrationEnabled(_ enabled: Bool, selection: CodexBarActiveSelection? = nil) throws {
        if selection != nil && self.config.openAI.modelRoutingStyle == .catalog { throw CodexModelRoutingError.selectInCodex }
        var route = SettingsRouteDraft(config: self.config)
        route.modelRoutingEnabled = enabled
        if enabled {
            let selected = selection ?? self.config.openAI.lastModelRoutingSelection ?? self.config.active
            guard let provider = self.config.provider(id: selected.providerId),
                  let id = selected.accountId, provider.accounts.contains(where: { $0.id == id }) else {
                throw CodexModelRoutingError.missingTarget
            }
            switch provider.kind {
            case .openAIOAuth: route.target = .openAIAccount(accountID: id, mode: .hybridProvider)
            case .openAICompatible: route.target = .compatibleProvider(providerID: provider.id, accountID: id,
                modelID: provider.thirdPartyEffectiveModelID(forAccountID: id), mode: .hybridProvider)
            case .openRouter: route.target = .openRouter(accountID: id, modelID: provider.openRouterEffectiveModelID(forAccountID: id), mode: .hybridProvider)
            }
        }
        _ = try self.applyModelRoutingSettings(route)
    }

    private func applyModelRoutingSettings(_ route: SettingsRouteDraft) throws -> Bool {
        let previous = self.config
        var synchronized = false
        do {
            self.config.openAI.modelRoutingStyle = route.style
            if !route.modelRoutingEnabled && !previous.openAI.modelRoutingEnabled {
                try self.configStore.save(self.config)
                self.publishState()
                return previous.openAI != self.config.openAI
            }
            if route.modelRoutingEnabled {
                guard self.hasOAuthLoginAccount else { throw CodexModelRoutingError.missingOAuth }
                if let target = route.target {
                    switch target {
                    case .openAIAccount(let id, _) where route.style == .catalog:
                        _ = try self.config.activateOAuthAccount(accountID: id)
                    case .openAIAccount(let id, _):
                        guard let provider = self.oauthProvider() else { throw CodexModelRoutingError.missingOAuth }
                        try self.setHybridRouteTarget(providerID: provider.id, accountID: id, modelID: nil)
                    case .compatibleProvider(let provider, let id, let model, _):
                        try self.setHybridRouteTarget(providerID: provider, accountID: id, modelID: model)
                    case .openRouter(let id, let model, _):
                        guard let provider = self.openRouterProvider else { throw TokenStoreError.providerNotFound }
                        try self.setHybridRouteTarget(providerID: provider.id, accountID: id, modelID: model)
                    }
                }
                guard let provider = self.config.activeProvider(), let id = self.config.active.accountId,
                      provider.accounts.contains(where: { $0.id == id }),
                      !provider.usesAPIKeyAuth || (provider.kind == .openRouter
                        ? provider.openRouterEffectiveModelID(forAccountID: id)
                        : provider.thirdPartyEffectiveModelID(forAccountID: id)) != nil else { throw CodexModelRoutingError.missingTarget }
                self.config.openAI.accountUsageMode = .hybridProvider
                self.config.openAI.lastModelRoutingSelection = self.config.active
            } else {
                if previous.openAI.modelRoutingEnabled { self.config.openAI.lastModelRoutingSelection = previous.active }
                guard let oauth = self.oauthProvider(), let id = oauth.activeAccount?.id else { throw CodexModelRoutingError.missingOAuth }
                self.config.active = .init(providerId: oauth.id, accountId: id)
                self.config.openAI.accountUsageMode = .switchAccount
            }
            self.config.openAI.modelRoutingPreviousMode = nil
            self.config.openAI.modelRoutingEnabled = route.modelRoutingEnabled
            if previous.openAI.modelRoutingEnabled != route.modelRoutingEnabled || previous.openAI.modelRoutingStyle != route.style ||
                (route.style == .catalog && previous.oauthProvider()?.activeAccountId != self.config.oauthProvider()?.activeAccountId) ||
                (!route.modelRoutingEnabled && previous.active != self.config.active) {
                try self.syncService.synchronize(config: self.config)
                synchronized = true
            }
            try self.configStore.save(self.config)
            if synchronized { self.requireCodexReload() }
            self.routingError = nil
            self.publishState()
        } catch {
            self.config = previous
            if synchronized { try? self.syncService.synchronize(config: previous) }
            self.publishState()
            throw error
        }
        return previous.openAI != self.config.openAI || previous.active != self.config.active || previous.providers != self.config.providers
    }

    func hasStaleOAuthUsageSnapshot(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        self.accounts.contains {
            $0.isSuspended == false &&
            $0.tokenExpired == false &&
            $0.isUsageSnapshotStale(maxAge: maxAge, now: now)
        }
    }

    func beginUsageRefresh(accountID: String) -> Bool {
        self.usageRefreshStateQueue.sync {
            self.refreshingUsageAccountIDs.insert(accountID).inserted
        }
    }

    func endUsageRefresh(accountID: String) {
        _ = self.usageRefreshStateQueue.sync {
            self.refreshingUsageAccountIDs.remove(accountID)
        }
    }

    func beginAllUsageRefresh() -> Bool {
        self.usageRefreshStateQueue.sync {
            guard self.isRefreshingAllUsage == false else { return false }
            self.isRefreshingAllUsage = true
            return true
        }
    }

    func reconcileAuthJSONIfNeeded(accountID: String? = nil) throws -> Bool {
        let changed = self.absorbNewerAuthJSONIfNeeded(accountID: accountID)
        guard changed else { return false }
        try self.configStore.save(self.config)
        self.publishState()
        return true
    }

    func oauthAccount(accountID: String) -> TokenAccount? {
        self.accounts.first(where: { $0.accountId == accountID })
    }

    private func oauthStoredAccount(
        in provider: CodexBarProvider,
        matching account: TokenAccount
    ) -> CodexBarProviderAccount? {
        if let stored = provider.accounts.first(where: { $0.id == account.accountId }) {
            return stored
        }

        let remoteCandidates = Set(
            [account.openAIAccountId, account.remoteAccountId, account.accountId]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
        let remoteMatches = provider.accounts.filter { stored in
            guard let openAIAccountId = stored.openAIAccountId else { return false }
            return remoteCandidates.contains(openAIAccountId)
        }
        return remoteMatches.count == 1 ? remoteMatches[0] : nil
    }

    func endAllUsageRefresh() {
        self.usageRefreshStateQueue.sync {
            self.isRefreshingAllUsage = false
        }
    }

    private func reconcileProviderUsagePolling(refreshImmediately: Bool = false) {
        let configuredProviders = self.config.providers.filter { provider in
            if provider.isOpenCodeProvider {
                return provider.effectiveOpenCodePlan == .go && (provider.usageConfiguration?.intervalSeconds ?? UsagePollingInterval.defaultOpenCode) > 0
            }
            return (provider.usageConfiguration?.intervalSeconds ?? 0) > 0
        }
        let configuredIDs = Set(configuredProviders.map(\.id))

        for providerID in self.providerUsagePollingTasks.keys where configuredIDs.contains(providerID) == false {
            self.providerUsagePollingTasks[providerID]?.cancel()
            self.providerUsagePollingTasks[providerID] = nil
            self.providerUsagePollingKeys[providerID] = nil
        }

        for provider in configuredProviders {
            let configuration = provider.usageConfiguration ?? CodexBarProviderUsageConfiguration(
                requestURL: provider.effectiveOpenCodePlan?.usageURL?.absoluteString,
                intervalSeconds: UsagePollingInterval.defaultOpenCode
            )
            let intervalSeconds = UsagePollingInterval.normalized(configuration.intervalSeconds)
            let headersKey = configuration.requestHeaders
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "&")
            let accountsKey = provider.accounts.map(\.id).joined(separator: "|")
            let taskKey = "\(provider.id):\(configuration.requestURL ?? ""):\(headersKey):\(configuration.timeoutSeconds):\(intervalSeconds):\(accountsKey)"
            if self.providerUsagePollingKeys[provider.id] == taskKey {
                if refreshImmediately {
                    self.refreshProviderUsageIfDue(providerID: provider.id, minimumInterval: TimeInterval(intervalSeconds))
                }
                continue
            }

            self.providerUsagePollingTasks[provider.id]?.cancel()
            self.providerUsagePollingKeys[provider.id] = taskKey
            self.providerUsagePollingTasks[provider.id] = Task { [weak self] in
                let sleepNanoseconds = UsagePollingInterval.nanoseconds(intervalSeconds)
                var didRunImmediateRefresh = false
                while Task.isCancelled == false {
                    if didRunImmediateRefresh {
                        do {
                            try await Task.sleep(nanoseconds: sleepNanoseconds)
                        } catch {
                            break
                        }
                    }
                    await self?.refreshProviderUsageNow(providerID: provider.id, force: false, minimumInterval: TimeInterval(intervalSeconds))
                    didRunImmediateRefresh = true
                }
            }
        }
    }

    private func refreshConfiguredProviderUsageOnStartupIfNeeded() {
        guard self.didRefreshConfiguredProviderUsageOnStartup == false else { return }
        self.didRefreshConfiguredProviderUsageOnStartup = true
        for provider in self.config.providers {
            if provider.isOpenCodeProvider {
                guard provider.effectiveOpenCodePlan == .go else { continue }
                self.scheduleProviderUsageRefresh(
                    providerID: provider.id,
                    force: true,
                    minimumInterval: 0,
                    enqueueIfInFlight: false
                )
                continue
            }
            guard provider.usageConfiguration != nil,
                  (provider.usageConfiguration?.intervalSeconds ?? 0) <= 0 else {
                continue
            }
            self.scheduleProviderUsageRefresh(
                providerID: provider.id,
                force: true,
                minimumInterval: 0,
                enqueueIfInFlight: false
            )
        }
    }

    private func refreshProviderUsageAfterProviderCredentialsChanged(providerID: String) {
        guard let provider = self.config.provider(id: providerID) else {
            return
        }
        if provider.isOpenCodeProvider {
            guard provider.effectiveOpenCodePlan == .go else { return }
            self.scheduleProviderUsageRefresh(
                providerID: providerID,
                force: true,
                minimumInterval: 0,
                enqueueIfInFlight: true
            )
            self.reconcileProviderUsagePolling(refreshImmediately: true)
            return
        }
        guard let configuration = provider.usageConfiguration else {
            return
        }
        if configuration.intervalSeconds <= 0 {
            self.scheduleProviderUsageRefresh(
                providerID: providerID,
                force: true,
                minimumInterval: 0,
                enqueueIfInFlight: true
            )
        }
        self.reconcileProviderUsagePolling(refreshImmediately: true)
    }

    func refreshProviderUsageOnPanelOpen() {
        for provider in self.config.providers where provider.enabled && (provider.usageConfiguration != nil || provider.effectiveOpenCodePlan == .go) {
            self.refreshProviderUsageIfDue(providerID: provider.id, minimumInterval: UsageHTTPRefreshClient.minimumInterval)
        }
    }

    private func refreshProviderUsageIfDue(providerID: String, minimumInterval: TimeInterval) {
        self.scheduleProviderUsageRefresh(
            providerID: providerID,
            force: false,
            minimumInterval: minimumInterval,
            enqueueIfInFlight: false
        )
    }

    private func clearProviderUsageRefreshState(providerID: String) {
        let tasksToCancel = self.usageRefreshStateQueue.sync {
            let refreshTask = self.providerUsageRefreshTasks[providerID]
            let pollingTask = self.providerUsagePollingTasks[providerID]
            self.providerUsageRefreshTasks[providerID] = nil
            self.providerUsagePollingTasks[providerID] = nil
            self.providerUsagePollingKeys[providerID] = nil
            self.providerUsageRefreshStartedAt[providerID] = nil
            self.providerUsageRefreshInFlight.remove(providerID)
            self.pendingProviderUsageRefreshRequests[providerID] = nil
            return (refreshTask, pollingTask)
        }
        tasksToCancel.0?.cancel()
        tasksToCancel.1?.cancel()
    }

    private func scheduleProviderUsageRefresh(
        providerID: String,
        force: Bool,
        minimumInterval: TimeInterval,
        enqueueIfInFlight: Bool
    ) {
        self.usageRefreshStateQueue.sync {
            if self.providerUsageRefreshInFlight.contains(providerID) {
                if enqueueIfInFlight {
                    self.pendingProviderUsageRefreshRequests[providerID] = (force: force, minimumInterval: minimumInterval)
                }
                return
            }

            if self.providerUsageRefreshTasks[providerID] != nil {
                return
            }

            self.providerUsageRefreshTasks[providerID]?.cancel()
            self.providerUsageRefreshTasks[providerID] = Task { [weak self] in
                await self?.refreshProviderUsageNow(
                    providerID: providerID,
                    force: force,
                    minimumInterval: minimumInterval
                )
            }
        }
    }

    private func shouldStartProviderUsageRefresh(
        providerID: String,
        force: Bool,
        minimumInterval: TimeInterval,
        now: Date
    ) -> Bool {
        self.usageRefreshStateQueue.sync {
            if self.providerUsageRefreshInFlight.contains(providerID) {
                return false
            }
            if force == false,
               let lastStartedAt = self.providerUsageRefreshStartedAt[providerID],
               now.timeIntervalSince(lastStartedAt) < minimumInterval {
                return false
            }
            self.providerUsageRefreshInFlight.insert(providerID)
            self.providerUsageRefreshStartedAt[providerID] = now
            return true
        }
    }

    private func finishProviderUsageRefresh(providerID: String) {
        let pendingRequest = self.usageRefreshStateQueue.sync {
            self.providerUsageRefreshInFlight.remove(providerID)
            self.providerUsageRefreshTasks[providerID] = nil
            defer { self.pendingProviderUsageRefreshRequests[providerID] = nil }
            return self.pendingProviderUsageRefreshRequests[providerID]
        }
        guard let pendingRequest else { return }
        self.scheduleProviderUsageRefresh(
            providerID: providerID,
            force: pendingRequest.force,
            minimumInterval: pendingRequest.minimumInterval,
            enqueueIfInFlight: false
        )
    }

    private func refreshProviderUsageNow(
        providerID: String,
        force: Bool,
        minimumInterval: TimeInterval = 0
    ) async {
        let refreshStarted = self.shouldStartProviderUsageRefresh(
            providerID: providerID,
            force: force,
            minimumInterval: minimumInterval,
            now: Date()
        )
        guard refreshStarted else { return }
        defer {
            self.finishProviderUsageRefresh(providerID: providerID)
        }

        guard let provider = self.config.provider(id: providerID) else {
            return
        }
        if provider.isOpenCodeProvider {
            await self.refreshOpenCodeProviderUsage(provider: provider)
            return
        }
        guard let configuration = provider.usageConfiguration else {
            return
        }
        let accounts = provider.accounts.filter {
            ($0.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        guard accounts.isEmpty == false else {
            await self.saveProviderUsageState(
                providerID: providerID,
                data: nil,
                accountSnapshots: [],
                rawResponse: nil,
                errorMessage: TokenStoreError.accountNotFound.localizedDescription
            )
            return
        }

        var snapshots: [CodexBarProviderAccountUsageSnapshot] = []
        for account in accounts {
            if Task.isCancelled { return }
            do {
                let result = try await self.providerUsageService.fetch(
                    provider: provider,
                    account: account,
                    configuration: configuration
                )
                snapshots.append(
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: account.id,
                        accountLabel: account.label,
                        maskedAPIKey: account.maskedAPIKey,
                        data: result.data,
                        lastUpdatedAt: Date(),
                        lastError: result.errorMessage,
                        rawResponse: result.rawResponse
                    )
                )
            } catch {
                let previousSnapshot = provider.usageState?.accountSnapshots.first { $0.accountID == account.id }
                snapshots.append(
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: account.id,
                        accountLabel: account.label,
                        maskedAPIKey: account.maskedAPIKey,
                        data: previousSnapshot?.data,
                        lastUpdatedAt: Date(),
                        lastError: error.localizedDescription,
                        rawResponse: previousSnapshot?.rawResponse
                    )
                )
            }
        }

        await self.saveProviderUsageState(
            providerID: providerID,
            data: snapshots.first(where: { $0.data != nil })?.data,
            accountSnapshots: snapshots,
            rawResponse: snapshots.map(\.rawResponse).compactMap { $0 }.joined(separator: "\n\n"),
            errorMessage: self.providerUsageErrorMessage(from: snapshots)
        )
    }

    private func refreshOpenCodeProviderUsage(provider: CodexBarProvider) async {
        guard provider.effectiveOpenCodePlan == .go else {
            return
        }
        let accounts = provider.accounts.filter {
            ($0.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        guard accounts.isEmpty == false else {
            await self.saveProviderUsageState(
                providerID: provider.id,
                data: nil,
                accountSnapshots: [],
                rawResponse: nil,
                errorMessage: TokenStoreError.accountNotFound.localizedDescription
            )
            return
        }

        var snapshots: [CodexBarProviderAccountUsageSnapshot] = []
        for account in accounts {
            if Task.isCancelled { return }
            do {
                let snapshot = try await self.openCodeUsageService.fetchGoUsage(apiKey: account.apiKey ?? "")
                snapshots.append(
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: account.id,
                        accountLabel: account.label,
                        maskedAPIKey: account.maskedAPIKey,
                        data: snapshot.providerUsageData,
                        lastUpdatedAt: Date(),
                        lastError: nil,
                        rawResponse: nil
                    )
                )
            } catch {
                let previousSnapshot = provider.usageState?.accountSnapshots.first { $0.accountID == account.id }
                snapshots.append(
                    CodexBarProviderAccountUsageSnapshot(
                        accountID: account.id,
                        accountLabel: account.label,
                        maskedAPIKey: account.maskedAPIKey,
                        data: previousSnapshot?.data,
                        lastUpdatedAt: Date(),
                        lastError: error.localizedDescription,
                        rawResponse: previousSnapshot?.rawResponse
                    )
                )
            }
        }

        await self.saveProviderUsageState(
            providerID: provider.id,
            data: snapshots.first(where: { $0.data != nil })?.data,
            accountSnapshots: snapshots,
            rawResponse: nil,
            errorMessage: self.providerUsageErrorMessage(from: snapshots)
        )
    }

    private func saveProviderUsageState(
        providerID: String,
        data: CodexBarProviderUsageData?,
        accountSnapshots: [CodexBarProviderAccountUsageSnapshot],
        rawResponse: String?,
        errorMessage: String?
    ) async {
        let state = CodexBarProviderUsageState(
            data: data,
            accountSnapshots: accountSnapshots,
            lastUpdatedAt: Date(),
            lastError: errorMessage,
            rawResponse: rawResponse
        )
        do {
            try self.config.updateProviderUsageState(providerID: providerID, state: state)
            try self.persist(syncCodex: false)
        } catch {
            NSLog("codexbar provider usage state save failed: %@", error.localizedDescription)
        }
    }

    private func providerUsageErrorMessage(from snapshots: [CodexBarProviderAccountUsageSnapshot]) -> String? {
        let messages = snapshots.compactMap(\.lastError)
        guard messages.isEmpty == false else { return nil }
        if messages.count == snapshots.count {
            return Array(Set(messages)).sorted().joined(separator: " · ")
        }
        return nil
    }

    // MARK: - Private

    private func hydrateOpenCodeModelCatalogs() {
        var updated = self.config
        var changed = false
        for index in updated.providers.indices where updated.providers[index].isOpenCodeProvider {
            guard let plan = updated.providers[index].effectiveOpenCodePlan,
                  let snapshot = self.openCodeModelCatalogService.loadCachedCatalog(plan: plan) else {
                continue
            }
            if updated.providers[index].updateThirdPartyModelCatalog(
                snapshot.models.map(\.selectionModel),
                fetchedAt: snapshot.fetchedAt
            ) {
                changed = true
            }
        }
        if changed {
            self.config = updated
        }
    }

    private func oauthProvider() -> CodexBarProvider? {
        self.config.providers.first(where: { $0.kind == .openAIOAuth })
    }

    private func upsertProvider(_ provider: CodexBarProvider) {
        if let index = self.config.providers.firstIndex(where: { $0.id == provider.id }) {
            self.config.providers[index] = provider
        } else {
            self.config.providers.append(provider)
        }
    }

    static func validatedKeyModels(_ selected: String?, pinned: [String]) throws -> CodexBarKeyModelSelection {
        guard let model = CodexBarProvider.normalizedOpenRouterModelID(selected) else {
            throw TokenStoreError.missingRequestModel
        }
        return .init(selectedModelID: model, pinnedModelIDs: pinned)
    }

    func updateCustomProviderMetadata(providerID: String, label: String, baseURL: String) throws {
        guard var provider = self.config.provider(id: providerID), provider.isCustomRelayProvider,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TokenStoreError.invalidInput }
        provider.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.upsertProvider(provider)
        try self.persist(syncCodex: self.config.active.providerId == providerID && provider.thirdPartyEffectiveModelID(forAccountID: self.config.active.accountId) != nil)
    }

    private static func applyThirdPartyModelSelection(
        modelID: String,
        accountID: String,
        provider: inout CodexBarProvider
    ) throws {
        guard provider.kind == .openAICompatible else {
            throw TokenStoreError.providerNotFound
        }
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }
        guard let normalizedModelID = CodexBarProvider.normalizedOpenRouterModelID(modelID) else {
            throw TokenStoreError.invalidInput
        }

        let currentSelection = provider.thirdPartySelection(forAccountID: accountID)
        let pinnedModelIDs = CodexBarProvider.resolvedPinnedModelIDs(
            currentSelection.pinnedModelIDs,
            selectedModelID: normalizedModelID
        )
        let updatedSelection = CodexBarOpenRouterSelection(
            selectedModelID: normalizedModelID,
            pinnedModelIDs: pinnedModelIDs,
            cachedModelCatalog: currentSelection.cachedModelCatalog,
            modelCatalogFetchedAt: currentSelection.modelCatalogFetchedAt
        )
        provider.accounts[accountIndex].thirdPartyModelSelection = updatedSelection
        provider.activeAccountId = provider.accounts[accountIndex].id
    }

    private func persist(syncCodex: Bool) throws {
        if syncCodex,
           self.config.activeProvider()?.kind == .openAIOAuth {
            _ = self.absorbNewerAuthJSONIfNeeded(accountID: self.config.active.accountId)
        }
        try self.configStore.save(self.config)
        if syncCodex && !self.config.openAI.modelRoutingEnabled {
            try self.syncService.synchronize(config: self.config)
        }
        self.publishState()
    }

    private func persistIgnoringErrors(syncCodex: Bool) {
        do {
            try self.persist(syncCodex: syncCodex)
        } catch {
            self.publishState()
        }
    }

    private func clearThirdPartySwitchModeSelectionIfNeeded() -> Bool {
        guard let selection = self.config.openAI.switchModeSelection,
              let provider = self.config.provider(id: selection.providerId),
              provider.isThirdPartyModelProvider else {
            return false
        }

        self.config.openAI.switchModeSelection = nil
        return true
    }

    private func publishState() {
        _ = self.refreshOpenRouterGatewayLeaseState()
        self.pushPublishedState()
    }

    private func absorbNewerAuthJSONIfNeeded(accountID: String? = nil) -> Bool {
        let reconciled = self.configStore.reconcileAuthJSON(
            in: self.config,
            onlyAccountIDs: accountID.map { Set([$0]) }
        )
        guard reconciled.changed else { return false }
        self.config = reconciled.config
        return true
    }

    private func pushPublishedState() {
        do {
            let before = try? Data(contentsOf: CodexModelRouting.catalogURL)
            try CodexModelRouting.refreshCatalogContext(config: self.config)
            if self.config.openAI.modelRoutingEnabled, let before,
               before != (try? Data(contentsOf: CodexModelRouting.catalogURL)) { self.requireCodexReload() }
        } catch {
            AppLifecycleDiagnostics.shared.recordEvent(type: "model_catalog_refresh_failed", fields: ["error": error.localizedDescription])
        }
        self.accounts = self.config.oauthTokenAccounts()
        let effectiveGatewayMode = self.effectiveGatewayMode
        self.openAIAccountGatewayService.updateModelRoutingState(
            accounts: self.accounts,
            accountUsageMode: effectiveGatewayMode,
            routeTarget: self.openAIAccountGatewayRouteTarget(effectiveMode: effectiveGatewayMode),
            enabled: self.config.openAI.modelRoutingEnabled,
            openAIModelID: self.config.openAI.modelRoutingEnabled ? (OpenAIModelStateStore().loadSnapshot()?.model ?? self.config.global.sanitizedDefaultModel) : self.config.global.sanitizedDefaultModel
        )
        // Legacy experimental settings remain readable but never affect live routing.
        self.openAIAccountGatewayService.setGatewayPromptPatchConfiguration(.init())
        self.openAIAccountGatewayService.setReasoningRetryGuardConfiguration(.disabled)
        self.openRouterGatewayService.updateState(
            provider: self.config.openRouterProvider(),
            isActiveProvider: self.config.activeProvider()?.kind == .openRouter
        )
        self.reconcileOpenAIAccountGatewayLifecycle(effectiveMode: effectiveGatewayMode)
        self.reconcileOpenRouterGatewayLifecycle()
        self.gatewayRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter
    }

    private func openAIAccountGatewayRouteTarget(
        effectiveMode: CodexBarOpenAIAccountUsageMode
    ) -> OpenAIAccountGatewayRouteTarget {

        guard let provider = self.config.activeProvider(),
              let account = self.config.activeAccount() else {
            return .none
        }

        guard self.hasOAuthLoginAccount else {
            guard provider.isThirdPartyModelProvider else {
                return .none
            }
            return self.compatibleProviderRouteTarget(provider: provider, account: account)
        }

        switch provider.kind {
        case .openAIOAuth:
            return self.config.openAI.modelRoutingEnabled ? .openAIAccount(accountID: account.id) : .none
        case .openAICompatible:
            guard self.config.openAI.accountUsageMode == .hybridProvider ||
                    provider.isThirdPartyModelProvider else {
                return .none
            }
            return self.compatibleProviderRouteTarget(provider: provider, account: account)
        case .openRouter:
            guard self.config.openAI.accountUsageMode == .hybridProvider else {
                return .none
            }
            guard let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  apiKey.isEmpty == false,
                  let modelID = provider.openRouterEffectiveModelID(forAccountID: account.id) else {
                return .none
            }
            return .openRouter(
                .init(
                    providerID: provider.id,
                    accountID: account.id,
                    apiKey: apiKey,
                    modelID: modelID
                )
            )
        }
    }

    private func compatibleProviderRouteTarget(
        provider: CodexBarProvider,
        account: CodexBarProviderAccount
    ) -> OpenAIAccountGatewayRouteTarget {
        guard let baseURL = provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              baseURL.isEmpty == false,
              let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              apiKey.isEmpty == false,
              let modelID = provider.thirdPartyEffectiveModelID(forAccountID: account.id) else {
            return .none
        }
        return .compatibleProvider(
            .init(
                providerID: provider.id,
                providerLabel: provider.displayName,
                baseURL: baseURL,
                accountID: account.id,
                apiKey: apiKey,
                modelID: modelID,
                thirdPartyModelProvider: provider.thirdPartyModelProvider
            )
        )
    }

    private var hasOAuthLoginAccount: Bool {
        guard let provider = self.oauthProvider(),
              let account = provider.activeAccount else {
            return false
        }
        return account.kind == .oauthTokens &&
            account.accessToken?.isEmpty == false &&
            account.refreshToken?.isEmpty == false &&
            account.idToken?.isEmpty == false &&
            account.openAIAccountId?.isEmpty == false
    }

    private var effectiveGatewayMode: CodexBarOpenAIAccountUsageMode {
        if self.config.openAI.accountUsageMode == .hybridProvider {
            return .hybridProvider
        }
        return .switchAccount
    }

    private func selectOAuthActiveAccountIfNeeded() {
        guard self.config.activeProvider()?.kind != .openAIOAuth,
              let provider = self.oauthProvider() else {
            return
        }
        self.config.active.providerId = provider.id
        self.config.active.accountId = provider.activeAccountId ?? provider.accounts.first?.id
    }

    private func reconcileOpenAIAccountGatewayLifecycle(
        effectiveMode: CodexBarOpenAIAccountUsageMode
    ) {
        if self.config.openAI.modelRoutingEnabled || self.openAIAccountGatewayRouteTarget(effectiveMode: effectiveMode).requiresListener {
            self.openAIAccountGatewayService.startIfNeeded()
        } else {
            self.openAIAccountGatewayService.stop()
        }
    }

    private func reconcileOpenRouterGatewayLifecycle() {
        if self.shouldRunOpenRouterGatewayListener {
            self.openRouterGatewayService.startIfNeeded()
        } else {
            self.openRouterGatewayService.stop()
        }
    }

    private var shouldRunOpenRouterGatewayListener: Bool {
        let hasActiveLease = self.openRouterGatewayLeaseSnapshot?.leasedProcessIDs.isEmpty == false
        let activeProviderIsOpenRouter = self.config.activeProvider()?.kind == .openRouter
        return self.openRouterServiceableProvider() != nil &&
            ((activeProviderIsOpenRouter && self.hasOAuthLoginAccount == false) || hasActiveLease)
    }

    private func openRouterServiceableProvider() -> CodexBarProvider? {
        guard let provider = self.config.openRouterProvider(),
              provider.openRouterServiceableSelection != nil else {
            return nil
        }
        return provider
    }

    private func refreshOpenRouterGatewayLeaseState() -> Bool {
        let activeProviderIsOpenRouter = self.config.activeProvider()?.kind == .openRouter
        guard let provider = self.openRouterServiceableProvider() else {
            return self.clearOpenRouterGatewayLease()
        }

        if activeProviderIsOpenRouter {
            return self.clearOpenRouterGatewayLease()
        }

        let runningProcessIDs = self.codexRunningProcessIDs()
        let existingProcessIDs = self.openRouterGatewayLeaseSnapshot?.processIDs ?? []
        let shouldAcquireLease = self.lastPublishedOpenRouterSelected && runningProcessIDs.isEmpty == false

        if existingProcessIDs.isEmpty {
            guard shouldAcquireLease else {
                self.configureOpenRouterGatewayLeaseTimer()
                return false
            }
            self.openRouterGatewayLeaseSnapshot = OpenRouterGatewayLeaseSnapshot(
                processIDs: runningProcessIDs,
                sourceProviderId: provider.id
            )
            self.persistOpenRouterGatewayLeaseState()
            self.configureOpenRouterGatewayLeaseTimer()
            return true
        }

        let updatedProcessIDs = runningProcessIDs
        if updatedProcessIDs.isEmpty {
            return self.clearOpenRouterGatewayLease()
        }

        if updatedProcessIDs != existingProcessIDs {
            self.openRouterGatewayLeaseSnapshot = OpenRouterGatewayLeaseSnapshot(
                processIDs: updatedProcessIDs,
                sourceProviderId: provider.id
            )
            self.persistOpenRouterGatewayLeaseState()
            self.configureOpenRouterGatewayLeaseTimer()
            return true
        }

        self.configureOpenRouterGatewayLeaseTimer()
        return false
    }

    private func clearOpenRouterGatewayLease() -> Bool {
        let changed = self.openRouterGatewayLeaseSnapshot != nil
        self.openRouterGatewayLeaseSnapshot = nil
        self.persistOpenRouterGatewayLeaseState()
        self.configureOpenRouterGatewayLeaseTimer()
        return changed
    }

    private func persistOpenRouterGatewayLeaseState() {
        guard let lease = self.openRouterGatewayLeaseSnapshot,
              lease.leasedProcessIDs.isEmpty == false else {
            self.openRouterGatewayLeaseStore.clear()
            return
        }
        self.openRouterGatewayLeaseStore.saveLease(lease)
    }

    private func configureOpenRouterGatewayLeaseTimer() {
        let shouldPoll = self.config.activeProvider()?.kind != .openRouter &&
            self.openRouterGatewayLeaseSnapshot?.leasedProcessIDs.isEmpty == false

        if shouldPoll {
            if self.openRouterGatewayLeaseTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.refreshOpenRouterGatewayLeaseState() {
                        self.pushPublishedState()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.openRouterGatewayLeaseTimer = timer
            }
            return
        }

        self.openRouterGatewayLeaseTimer?.invalidate()
        self.openRouterGatewayLeaseTimer = nil
    }

    private func appendSwitchJournal() throws {
        try self.appendSwitchJournal(previousAccountID: nil)
    }

    private func appendSwitchJournal(
        previousAccountID: String?,
        reason: AutoRoutingSwitchReason = .manual,
        automatic: Bool = false,
        forced: Bool = false,
        protectedByManualGrace: Bool = false
    ) throws {
        try self.switchJournalStore.appendActivation(
            providerID: self.config.active.providerId,
            accountID: self.config.active.accountId,
            previousAccountID: previousAccountID,
            reason: reason,
            automatic: automatic,
            forced: forced,
            protectedByManualGrace: protectedByManualGrace
        )
    }

    private func seedSwitchJournalIfNeeded() {
        guard FileManager.default.fileExists(atPath: CodexPaths.switchJournalURL.path) == false,
              self.config.active.providerId != nil else { return }
        try? self.appendSwitchJournal()
    }

    deinit {
        self.openRouterGatewayLeaseTimer?.invalidate()
    }

    private func slug(from label: String) -> String {
        let lowered = label.lowercased()
        let slug = lowered.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let resolved = slug.isEmpty ? "provider-\(UUID().uuidString.lowercased())" : slug
        if resolved == "openrouter" {
            return "openrouter-custom"
        }
        return resolved
    }

}

enum TokenStoreError: LocalizedError {
    case accountNotFound
    case providerNotFound
    case invalidInput
    case missingRequestModel
    case invalidCodexAppPath

    var errorDescription: String? {
        switch self {
        case .accountNotFound: return "未找到账号"
        case .providerNotFound: return "未找到 provider"
        case .invalidInput: return "输入无效"
        case .missingRequestModel: return L.zh ? "请为此 Key 指定请求模型后保存。" : "Choose a request model for this key before saving."
        case .invalidCodexAppPath: return L.codexAppPathInvalidSelection
        }
    }
}
