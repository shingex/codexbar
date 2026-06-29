import AppKit
import Combine
import Foundation

struct OpenAIAccountSettingsUpdate: Equatable {
    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
}

struct OpenAIUsageSettingsUpdate: Equatable {
    var usageDisplayMode: CodexBarUsageDisplayMode
    var disableLocalUsageStats: Bool
    var experimentalLocalCompressionEnabled: Bool = false
    var plusRelativeWeight: Double
    var proRelativeToPlusMultiplier: Double
    var teamRelativeToPlusMultiplier: Double
}

struct ModelPricingSettingsUpdate: Equatable {
    var upserts: [String: CodexBarModelPricing]
    var removals: [String]
}

struct DesktopSettingsUpdate: Equatable {
    var preferredCodexAppPath: String?
}

struct LaunchAtLoginSettingsUpdate: Equatable {
    var isEnabled: Bool
}

struct CustomProviderUpdate: Equatable {
    var label: String
    var baseURL: String
    var accountID: String?
    var accountLabel: String
    var apiKey: String
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
    var modelPricing: ModelPricingSettingsUpdate?
    var desktop: DesktopSettingsUpdate?
    var launchAtLogin: LaunchAtLoginSettingsUpdate?

    init(
        openAIAccount: OpenAIAccountSettingsUpdate? = nil,
        openAIUsage: OpenAIUsageSettingsUpdate? = nil,
        modelPricing: ModelPricingSettingsUpdate? = nil,
        desktop: DesktopSettingsUpdate? = nil,
        launchAtLogin: LaunchAtLoginSettingsUpdate? = nil
    ) {
        self.openAIAccount = openAIAccount
        self.openAIUsage = openAIUsage
        self.modelPricing = modelPricing
        self.desktop = desktop
        self.launchAtLogin = launchAtLogin
    }

    var isEmpty: Bool {
        self.openAIAccount == nil &&
        self.openAIUsage == nil &&
        self.modelPricing == nil &&
        self.desktop == nil &&
        self.launchAtLogin == nil
    }

    var persistentRequests: SettingsSaveRequests {
        SettingsSaveRequests(
            openAIAccount: self.openAIAccount,
            openAIUsage: self.openAIUsage,
            modelPricing: self.modelPricing,
            desktop: self.desktop
        )
    }
}

enum SettingsRouteTarget: Equatable {
    case openAIAccount(accountID: String)
    case aggregateGateway
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

    private struct LocalCostSummaryRefreshRequest {
        var force: Bool
        var minimumInterval: TimeInterval
        var refreshSessionCache: Bool

        mutating func merge(_ other: LocalCostSummaryRefreshRequest) {
            self.force = self.force || other.force
            self.minimumInterval = min(self.minimumInterval, other.minimumInterval)
            self.refreshSessionCache = self.refreshSessionCache || other.refreshSessionCache
        }
    }

    @Published var accounts: [TokenAccount] = []
    @Published private(set) var config: CodexBarConfig
    @Published private(set) var localCostSummary: LocalCostSummary = .empty
    @Published private(set) var isRefreshingLocalCostSummaryInBackground = false
    @Published private(set) var historicalModels: [String]
    @Published private(set) var aggregateRoutedAccountID: String?
    @Published private(set) var openAIAccountGatewayLocalCompressionActivity: OpenAIAccountGatewayLocalCompressionActivity?
    @Published private(set) var openAIAccountGatewayReasoningRetryGuardSnapshot: OpenAIAccountGatewayReasoningRetryGuardSnapshot = .empty
    @Published private(set) var localCompressionHistory: [LocalCompressionHistoryEntry] = []
    @Published private(set) var resetCreditCache: CodexResetCreditCache = .empty
    @Published private(set) var refreshingResetCreditAccountIDs: Set<String> = []

    private let configStore: CodexBarConfigStore
    private let syncService: any CodexSynchronizing
    private let switchJournalStore = SwitchJournalStore()
    private let costSummaryService: any LocalCostSummaryLoading
    private let openAIAccountGatewayService: OpenAIAccountGatewayControlling
    private let openRouterGatewayService: OpenRouterGatewayControlling
    private let openRouterModelCatalogService: any OpenRouterModelCatalogFetching
    private let providerUsageService: ProviderUsageService
    private let resetCreditService: CodexResetCreditService
    private let openRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring
    private let aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring
    private let aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring
    private let localCompressionHistoryStore = LocalCompressionHistoryStore()
    private let codexRunningProcessIDs: () -> Set<pid_t>
    private let refreshStateQueue = DispatchQueue(label: "lzl.codexbar.refresh-state")
    private let localCostSummaryQueue = DispatchQueue(label: "lzl.codexbar.local-cost-summary-refresh", qos: .utility)
    private let usageRefreshStateQueue = DispatchQueue(label: "lzl.codexbar.usage-refresh-state")
    private let localCostGatewayRecentActivityWindow: TimeInterval = 90
    private let localCostGatewayBusyDeferralInterval: TimeInterval = 120
    private var isRefreshingLocalCostSummary = false
    private var pendingLocalCostSummaryRefresh: LocalCostSummaryRefreshRequest?
    private var lastLocalCostSummaryRefreshFinishedAt: Date?
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
    private var aggregateGatewayLeaseProcessIDs: Set<pid_t>
    private var aggregateGatewayLeaseTimer: Timer?
    private var lastPublishedOpenRouterSelected = false

    init(
        configStore: CodexBarConfigStore = CodexBarConfigStore(),
        syncService: any CodexSynchronizing = CodexSyncService(),
        costSummaryService: any LocalCostSummaryLoading = LocalCostSummaryService(),
        openAIAccountGatewayService: OpenAIAccountGatewayControlling = OpenAIAccountGatewayService.shared,
        openRouterGatewayService: OpenRouterGatewayControlling = OpenRouterGatewayService(),
        openRouterModelCatalogService: any OpenRouterModelCatalogFetching = OpenRouterModelCatalogService(),
        providerUsageService: ProviderUsageService = ProviderUsageService(),
        resetCreditService: CodexResetCreditService = CodexResetCreditService(),
        openRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring = OpenRouterGatewayLeaseStore(),
        aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring = OpenAIAggregateGatewayLeaseStore(),
        aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(),
        codexRunningProcessIDs: @escaping () -> Set<pid_t> = {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier))
        }
    ) {
        self.configStore = configStore
        self.syncService = syncService
        self.costSummaryService = costSummaryService
        self.openAIAccountGatewayService = openAIAccountGatewayService
        self.openRouterGatewayService = openRouterGatewayService
        self.openRouterModelCatalogService = openRouterModelCatalogService
        self.providerUsageService = providerUsageService
        self.resetCreditService = resetCreditService
        self.openRouterGatewayLeaseStore = openRouterGatewayLeaseStore
        self.aggregateGatewayLeaseStore = aggregateGatewayLeaseStore
        self.aggregateRouteJournalStore = aggregateRouteJournalStore
        self.codexRunningProcessIDs = codexRunningProcessIDs
        self.openRouterGatewayLeaseSnapshot = openRouterGatewayLeaseStore.loadLease()
        self.aggregateGatewayLeaseProcessIDs = aggregateGatewayLeaseStore.loadProcessIDs()

        let initialConfig: CodexBarConfig
        if let loaded = try? self.configStore.loadOrMigrate() {
            initialConfig = loaded
        } else {
            initialConfig = CodexBarConfig()
        }
        self.config = initialConfig
        self.historicalModels = Self.normalizedHistoricalModels(Array(initialConfig.modelPricing.keys))
        self.resetCreditCache = resetCreditService.loadCache()
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter

        NotificationCenter.default.publisher(for: .openAIAccountGatewayDidRouteAccount)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .openAIAccountGatewayDidApplyLocalCompression)
            .compactMap { $0.object as? OpenAIAccountGatewayLocalCompressionActivity }
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in
                self?.openAIAccountGatewayLocalCompressionActivity = activity
                self?.appendLocalCompressionHistory(activity)
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .openAIAccountGatewayReasoningRetryGuardDidUpdate)
            .compactMap { $0.object as? OpenAIAccountGatewayReasoningRetryGuardSnapshot }
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.openAIAccountGatewayReasoningRetryGuardSnapshot = snapshot
            }
            .store(in: &self.cancellables)

        self.publishState()
        self.refreshOpenAIAccountGatewayReasoningRetryGuardSnapshot()
        self.localCostSummary = self.config.openAI.disableLocalUsageStats ? .empty : self.loadCachedLocalCostSummary()
        if self.config.openAI.disableLocalUsageStats == false {
            self.refreshLocalCostSummaryIfNeeded()
        }
        self.refreshHistoricalModels()
        self.seedSwitchJournalIfNeeded()
        self.refreshConfiguredProviderUsageOnStartupIfNeeded()
        self.reconcileProviderUsagePolling(refreshImmediately: true)
        try? self.syncService.synchronize(config: self.config)
        self.localCompressionHistory = self.localCompressionHistoryStore.load()
    }

    var customProviders: [CodexBarProvider] {
        self.config.providers.filter { $0.isCustomRelayProvider }
    }

    var thirdPartyModelProviders: [CodexBarProvider] {
        self.config.providers.filter { $0.isThirdPartyModelProvider }
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

    var aggregateRoutedAccount: TokenAccount? {
        guard let aggregateRoutedAccountID else { return nil }
        return self.accounts.first(where: { $0.accountId == aggregateRoutedAccountID })
    }

    func load() {
        if let loaded = try? self.configStore.loadOrMigrate() {
            self.config = loaded
            self.publishState()
            if self.config.openAI.disableLocalUsageStats {
                self.cancelLocalCostSummaryRefresh(clearSummary: true)
            } else {
                let cachedLocalCostSummary = self.loadCachedLocalCostSummary()
                let shouldRefreshEmptyCache = self.isEffectivelyEmptyLocalCostSummary(cachedLocalCostSummary) &&
                    self.isEffectivelyEmptyLocalCostSummary(self.localCostSummary) == false
                self.localCostSummary = self.resolvedCachedLocalCostSummary(cachedLocalCostSummary)
                if shouldRefreshEmptyCache {
                    self.refreshLocalCostSummary(
                        force: true,
                        minimumInterval: 0,
                        refreshSessionCache: true
                    )
                } else {
                    self.refreshLocalCostSummaryIfNeeded()
                }
            }
            self.historicalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: Array(self.config.modelPricing.keys)
            )
            self.refreshHistoricalModels()
            self.reconcileProviderUsagePolling()
        }
    }

    func addOrUpdate(_ account: TokenAccount) {
        let result = self.config.upsertOAuthAccount(account, activate: false)
        self.persistIgnoringErrors(syncCodex: result.syncCodex)
    }

    func remove(_ account: TokenAccount) {
        guard var provider = self.oauthProvider() else { return }
        provider.accounts.removeAll { $0.id == account.accountId }
        self.config.removeOpenAIAccountOrder(accountID: account.accountId)

        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
            if self.config.active.providerId == provider.id {
                let fallback = self.config.providers.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
            }
        } else {
            if provider.activeAccountId == account.accountId {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if self.config.active.providerId == provider.id && self.config.active.accountId == account.accountId {
                self.config.active.accountId = provider.activeAccountId
            }
            self.upsertProvider(provider)
        }

        self.config.normalizeOpenAIAccountOrder()
        self.persistIgnoringErrors(syncCodex: self.config.active.providerId == provider.id)
        self.reconcileProviderUsagePolling()
    }

    func activate(
        _ account: TokenAccount,
        reason: AutoRoutingSwitchReason = .manual,
        automatic: Bool = false,
        forced: Bool = false,
        protectedByManualGrace: Bool = false
    ) throws {
        _ = try self.reconcileAuthJSONIfNeeded(accountID: account.accountId)
        let previousAccountID = self.activeAccount()?.accountId
        _ = try self.config.activateOAuthAccount(accountID: account.accountId)
        self.config.openAI.accountUsageMode = .switchAccount
        self.config.captureSwitchModeSelection()
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
        let previousSelection = self.config.active
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        guard provider.accounts.contains(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        if provider.isThirdPartyModelProvider,
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
        case .openAIAccount, .aggregateGateway:
            break
        }

        self.config.openAI.switchModeSelection = nil
    }

    func addCustomProvider(label: String, baseURL: String, accountLabel: String, apiKey: String) throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false,
              trimmedBaseURL.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let providerID = self.slug(from: trimmedLabel)
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel,
            apiKey: trimmedAPIKey,
            addedAt: Date()
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
        apiKey: String
    ) throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPinnedModelIDs = Self.normalizedThirdPartyModelIDs(
            pinnedModelIDs,
            provider: thirdPartyProvider
        )
        let normalizedSelectedModelID = Self.normalizedThirdPartySelectedModelID(
            selectedModelID,
            pinnedModelIDs: normalizedPinnedModelIDs
        )
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
                pinnedModelIDs: normalizedPinnedModelIDs
            )
        )
        let providerLabel = thirdPartyProvider == .custom && trimmedLabel.isEmpty == false
            ? trimmedLabel
            : thirdPartyProvider.title
        let provider = CodexBarProvider(
            id: self.slug(from: providerLabel),
            kind: .openAICompatible,
            label: providerLabel,
            enabled: true,
            baseURL: trimmedBaseURL,
            defaultModel: normalizedSelectedModelID ?? normalizedPinnedModelIDs.first,
            thirdPartyModelProvider: thirdPartyProvider,
            activeAccountId: account.id,
            accounts: [account]
        )

        self.config.providers.removeAll { $0.id == provider.id }
        self.config.providers.append(provider)

        try self.persist(syncCodex: false)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: provider.id)
    }

    func addOpenRouterProvider(
        accountLabel: String = "",
        apiKey: String,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        fetchedAt: Date? = nil
    ) throws {
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
        if configuration.intervalMinutes <= 0 {
            self.refreshProviderUsage(providerID: providerID)
        } else {
            self.reconcileProviderUsagePolling(refreshImmediately: true)
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

    func addCustomProviderAccount(providerID: String, label: String, apiKey: String) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { throw TokenStoreError.invalidInput }

        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Account \(provider.accounts.count + 1)" : label.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            addedAt: Date(),
            thirdPartyModelSelection: provider.isThirdPartyModelProvider ? provider.thirdPartySelection(forAccountID: provider.activeAccountId) : nil
        )
        provider.accounts.append(account)
        if provider.activeAccountId == nil {
            provider.activeAccountId = account.id
        }
        self.upsertProvider(provider)
        try self.persist(syncCodex: false)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func updateCustomProvider(providerID: String, request: CustomProviderUpdate) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.isCustomRelayProvider }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedLabel = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = request.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false,
              trimmedBaseURL.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let accountID = request.accountID ?? provider.activeAccountId ?? provider.activeAccount?.id
        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        provider.label = trimmedLabel
        provider.baseURL = trimmedBaseURL
        provider.thirdPartyModelProvider = nil
        provider.accounts[accountIndex].label = trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel
        provider.accounts[accountIndex].apiKey = trimmedAPIKey
        provider.activeAccountId = provider.accounts[accountIndex].id
        self.upsertProvider(provider)

        let shouldSyncCodex = self.config.active.providerId == providerID
        if shouldSyncCodex {
            self.config.active.accountId = provider.accounts[accountIndex].id
        }
        try self.persist(syncCodex: shouldSyncCodex)
        self.refreshProviderUsageAfterProviderCredentialsChanged(providerID: providerID)
    }

    func updateThirdPartyModelProvider(
        providerID: String,
        request: ThirdPartyModelProviderUpdate
    ) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.isThirdPartyModelProvider }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedBaseURL = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = request.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPinnedModelIDs = Self.normalizedThirdPartyModelIDs(
            request.pinnedModelIDs,
            provider: request.provider
        )
        let normalizedSelectedModelID = Self.normalizedThirdPartySelectedModelID(
            request.selectedModelID,
            pinnedModelIDs: normalizedPinnedModelIDs
        )
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
        provider.label = request.provider == .custom && trimmedLabel.isEmpty == false
            ? trimmedLabel
            : request.provider.title
        provider.baseURL = trimmedBaseURL
        provider.defaultModel = normalizedSelectedModelID ?? normalizedPinnedModelIDs.first
        provider.thirdPartyModelProvider = request.provider
        provider.accounts[accountIndex].label = trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel
        provider.accounts[accountIndex].apiKey = trimmedAPIKey
        provider.accounts[accountIndex].thirdPartyModelSelection = CodexBarOpenRouterSelection(
            selectedModelID: normalizedSelectedModelID,
            pinnedModelIDs: normalizedPinnedModelIDs
        )
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
        storedProvider.label = thirdPartyProvider == .custom && trimmedLabel.isEmpty == false
            ? trimmedLabel
            : thirdPartyProvider.title
        storedProvider.baseURL = trimmedBaseURL
        storedProvider.thirdPartyModelProvider = thirdPartyProvider
        self.upsertProvider(storedProvider)

        let shouldSyncCodex = self.config.active.providerId == providerID
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func updateThirdPartySelectedModel(
        _ modelID: String,
        providerID: String,
        accountID: String
    ) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.isThirdPartyModelProvider }) else {
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

    func updateCustomProviderAccount(providerID: String, accountID: String, label: String, apiKey: String) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }

        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { throw TokenStoreError.invalidInput }

        guard let accountIndex = provider.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

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

        let previousSelection = self.config.active
        self.captureAggregateGatewayLeasesIfNeeded(
            previousMode: self.config.openAI.accountUsageMode,
            newMode: mode
        )
        self.config.setOpenAIAccountUsageMode(mode)
        if mode == .aggregateGateway,
           let provider = self.oauthProvider() {
            self.config.active.providerId = provider.id
            self.config.active.accountId = provider.activeAccountId
            self.config.openAI.switchModeSelection = previousSelection
        } else if mode == .switchAccount {
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
            syncCodex: mode == .aggregateGateway ||
                mode == .hybridProvider ||
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

    func saveExperimentalLocalCompressionEnabled(_ enabled: Bool) throws {
        guard self.config.openAI.experimentalLocalCompressionEnabled != enabled else {
            self.publishState()
            return
        }

        self.config.openAI.experimentalLocalCompressionEnabled = enabled
        self.openAIAccountGatewayLocalCompressionActivity = nil
        try self.persist(syncCodex: false)
    }

    func saveLocalCompressionSettings(_ settings: CodexBarOpenAISettings.LocalCompressionSettings) throws {
        let normalizedSettings = CodexBarOpenAISettings.LocalCompressionSettings(
            minCharactersToCompress: settings.minCharactersToCompress,
            minLinesToCompress: settings.minLinesToCompress,
            targetRatio: settings.targetRatio,
            protectRecentItems: settings.protectRecentItems,
            compressUserMessages: settings.compressUserMessages,
            compressSystemMessages: settings.compressSystemMessages,
            compressAssistantMessages: settings.compressAssistantMessages,
            compressToolOutputs: settings.compressToolOutputs,
            appendCompressionMarker: settings.appendCompressionMarker
        )
        guard self.config.openAI.localCompressionSettings != normalizedSettings else {
            self.publishState()
            return
        }

        self.config.openAI.localCompressionSettings = normalizedSettings
        self.openAIAccountGatewayLocalCompressionActivity = nil
        try self.persist(syncCodex: false)
    }

    func saveReasoningRetryGuardSettings(_ settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings) throws {
        let normalizedSettings = CodexBarOpenAISettings.ReasoningRetryGuardSettings(
            isEnabled: settings.isEnabled,
            matchMode: settings.matchMode,
            reasoningEquals: settings.reasoningEquals,
            interceptStreaming: settings.interceptStreaming,
            interceptNonStreaming: settings.interceptNonStreaming,
            routeTargetRetryAttempts: settings.routeTargetRetryAttempts,
            nonStreamStatusCode: settings.nonStreamStatusCode,
            streamAction: settings.streamAction,
            logMatch: settings.logMatch,
            endpoints: settings.endpoints
        )
        guard self.config.openAI.reasoningRetryGuard != normalizedSettings else {
            self.publishState()
            self.refreshOpenAIAccountGatewayReasoningRetryGuardSnapshot()
            return
        }

        self.config.openAI.reasoningRetryGuard = normalizedSettings
        try self.persist(syncCodex: false)
        self.refreshOpenAIAccountGatewayReasoningRetryGuardSnapshot()
    }

    func refreshOpenAIAccountGatewayReasoningRetryGuardSnapshot() {
        self.openAIAccountGatewayReasoningRetryGuardSnapshot = self.openAIAccountGatewayService.reasoningRetryGuardSnapshot()
    }

    func reloadLocalCompressionHistory() {
        self.localCompressionHistory = self.localCompressionHistoryStore.load()
    }

    func saveDesktopSettings(_ request: DesktopSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(desktop: request)
        )
    }

    func saveModelPricingSettings(_ request: ModelPricingSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(modelPricing: request)
        )
    }

    func saveSettings(_ requests: SettingsSaveRequests) throws {
        guard requests.isEmpty == false else { return }

        let persistentRequests = requests.persistentRequests
        guard persistentRequests.isEmpty == false else { return }

        var updatedConfig = self.config
        try SettingsSaveRequestApplier.apply(persistentRequests, to: &updatedConfig)

        self.config = updatedConfig
        try self.persist(syncCodex: false)
        self.historicalModels = Self.mergedHistoricalModels(
            preferredHistoricalModels: self.historicalModels,
            fallbackHistoricalModels: Array(self.config.modelPricing.keys)
        )
        if persistentRequests.openAIUsage != nil {
            if self.config.openAI.disableLocalUsageStats {
                self.cancelLocalCostSummaryRefresh(clearSummary: true)
            } else if self.isEffectivelyEmptyLocalCostSummary(self.localCostSummary) {
                self.localCostSummary = self.loadCachedLocalCostSummary()
                self.refreshLocalCostSummary(force: true, minimumInterval: 0)
            }
        }
        if persistentRequests.modelPricing != nil,
           self.config.openAI.disableLocalUsageStats == false {
            self.refreshLocalCostSummary(force: true, minimumInterval: 0)
        }
    }

    func applySettingsRouteTarget(_ target: SettingsRouteTarget) throws -> Bool {
        switch target {
        case .openAIAccount(let accountID):
            guard let account = self.accounts.first(where: { $0.accountId == accountID }) else {
                throw TokenStoreError.accountNotFound
            }
            guard self.config.openAI.accountUsageMode != .switchAccount ||
                    self.config.activeProvider()?.kind != .openAIOAuth ||
                    self.activeAccount()?.accountId != accountID else {
                return false
            }
            self.cleanupThirdPartySelectionIfLeavingThirdParty(to: target)
            try self.activate(
                account,
                reason: .manual,
                automatic: false,
                forced: false,
                protectedByManualGrace: false
            )
            return true

        case .aggregateGateway:
            guard self.config.openAI.accountUsageMode != .aggregateGateway else { return false }
            self.cleanupThirdPartySelectionIfLeavingThirdParty(to: target)
            try self.updateOpenAIAccountUsageMode(.aggregateGateway)
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

    func resetCreditSnapshot(accountID: String) -> CodexResetCreditSnapshot? {
        self.resetCreditCache.snapshotsByAccountID[accountID]
    }

    func isRefreshingResetCredits(accountID: String) -> Bool {
        self.refreshingResetCreditAccountIDs.contains(accountID)
    }

    func refreshResetCredits(account: TokenAccount) async -> Result<CodexResetCreditSnapshot, CodexResetCreditError> {
        await MainActor.run {
            self.refreshingResetCreditAccountIDs.insert(account.accountId)
        }
        defer {
            Task { @MainActor in
                self.refreshingResetCreditAccountIDs.remove(account.accountId)
            }
        }

        do {
            let result = try await self.resetCreditService.fetch(account: account)
            await MainActor.run {
                var cache = self.resetCreditCache
                cache.snapshotsByAccountID[account.accountId] = result.snapshot
                self.resetCreditCache = cache
                try? self.resetCreditService.saveCache(cache)
            }
            return .success(result.snapshot)
        } catch let error as CodexResetCreditError {
            return .failure(error)
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    func openAIRuntimeRouteSnapshot(
        runningThreadAttribution: OpenAIRunningThreadAttribution,
        now: Date = Date()
    ) -> OpenAIRuntimeRouteSnapshot {
        let stickyBindings = self.openAIAccountGatewayService.stickyBindingsSnapshot()
        let latestStickyBinding = stickyBindings.first
        let latestRouteRecord = self.aggregateRouteJournalStore.routeHistory().last
        let latestRouteAt = latestStickyBinding?.updatedAt ?? latestRouteRecord?.timestamp
        let latestRoutedAccountID = self.aggregateRoutedAccountID
            ?? latestStickyBinding?.accountID
            ?? latestRouteRecord?.accountID
        let runningThreadIDs = runningThreadAttribution.activeThreadIDs
        let leaseActive = self.aggregateGatewayLeaseProcessIDs.isEmpty == false ||
            self.aggregateGatewayLeaseStore.hasActiveLease()
        let recentActivityWindow = runningThreadAttribution.recentActivityWindow

        let staleStickyEligible: Bool
        if let latestStickyBinding,
           runningThreadAttribution.summary.isUnavailable == false,
           runningThreadIDs.contains(latestStickyBinding.threadID) == false,
           leaseActive == false,
           now.timeIntervalSince(latestStickyBinding.updatedAt) > recentActivityWindow {
            staleStickyEligible = true
        } else {
            staleStickyEligible = false
        }

        return OpenAIRuntimeRouteSnapshot(
            configuredMode: self.config.openAI.accountUsageMode,
            effectiveMode: self.effectiveGatewayMode,
            aggregateRuntimeActive: self.effectiveGatewayMode == .aggregateGateway,
            latestRoutedAccountID: latestRoutedAccountID,
            latestRoutedAccountIsSummary: latestRoutedAccountID != nil,
            stickyAffectsFutureRouting: latestStickyBinding != nil && self.config.openAI.accountUsageMode == .aggregateGateway,
            leaseActive: leaseActive,
            staleStickyEligible: staleStickyEligible,
            staleStickyThreadID: staleStickyEligible ? latestStickyBinding?.threadID : nil,
            latestRouteAt: latestRouteAt
        )
    }

    @discardableResult
    func clearStaleAggregateSticky(using snapshot: OpenAIRuntimeRouteSnapshot) -> Bool {
        guard snapshot.staleStickyEligible,
              let threadID = snapshot.staleStickyThreadID else {
            return false
        }
        return self.openAIAccountGatewayService.clearStickyBinding(threadID: threadID)
    }

    func endAllUsageRefresh() {
        self.usageRefreshStateQueue.sync {
            self.isRefreshingAllUsage = false
        }
    }

    private func reconcileProviderUsagePolling(refreshImmediately: Bool = false) {
        let configuredProviders = self.config.providers.filter {
            $0.usageConfiguration?.intervalMinutes ?? 0 > 0
        }
        let configuredIDs = Set(configuredProviders.map(\.id))

        for providerID in self.providerUsagePollingTasks.keys where configuredIDs.contains(providerID) == false {
            self.providerUsagePollingTasks[providerID]?.cancel()
            self.providerUsagePollingTasks[providerID] = nil
            self.providerUsagePollingKeys[providerID] = nil
        }

        for provider in configuredProviders {
            guard let configuration = provider.usageConfiguration else { continue }
            let intervalMinutes = max(configuration.intervalMinutes, 0)
            let headersKey = configuration.requestHeaders
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "&")
            let accountsKey = provider.accounts.map(\.id).joined(separator: "|")
            let taskKey = "\(provider.id):\(configuration.requestURL ?? ""):\(headersKey):\(configuration.timeoutSeconds):\(intervalMinutes):\(accountsKey)"
            if self.providerUsagePollingKeys[provider.id] == taskKey {
                if refreshImmediately {
                    self.refreshProviderUsageIfDue(providerID: provider.id, minimumInterval: TimeInterval(intervalMinutes * 60))
                }
                continue
            }

            self.providerUsagePollingTasks[provider.id]?.cancel()
            self.providerUsagePollingKeys[provider.id] = taskKey
            self.providerUsagePollingTasks[provider.id] = Task { [weak self] in
                let sleepNanoseconds = UInt64(max(intervalMinutes, 1) * 60) * 1_000_000_000
                var didRunImmediateRefresh = false
                while Task.isCancelled == false {
                    if didRunImmediateRefresh {
                        do {
                            try await Task.sleep(nanoseconds: sleepNanoseconds)
                        } catch {
                            break
                        }
                    }
                    await self?.refreshProviderUsageNow(providerID: provider.id, force: false)
                    didRunImmediateRefresh = true
                }
            }
        }
    }

    private func refreshConfiguredProviderUsageOnStartupIfNeeded() {
        guard self.didRefreshConfiguredProviderUsageOnStartup == false else { return }
        self.didRefreshConfiguredProviderUsageOnStartup = true
        for provider in self.config.providers where provider.usageConfiguration != nil &&
            (provider.usageConfiguration?.intervalMinutes ?? 0) <= 0 {
            self.scheduleProviderUsageRefresh(
                providerID: provider.id,
                force: true,
                minimumInterval: 0,
                enqueueIfInFlight: false
            )
        }
    }

    private func refreshProviderUsageAfterProviderCredentialsChanged(providerID: String) {
        guard let configuration = self.config.provider(id: providerID)?.usageConfiguration else {
            return
        }
        if configuration.intervalMinutes <= 0 {
            self.scheduleProviderUsageRefresh(
                providerID: providerID,
                force: true,
                minimumInterval: 0,
                enqueueIfInFlight: true
            )
        }
        self.reconcileProviderUsagePolling(refreshImmediately: true)
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

        guard let provider = self.config.provider(id: providerID),
              let configuration = provider.usageConfiguration else {
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

    private static func normalizedThirdPartyModelIDs(
        _ modelIDs: [String],
        provider: CodexBarThirdPartyModelProvider
    ) -> [String] {
        var source = CodexBarProvider.normalizedOpenRouterModelIDs(modelIDs)
        if source.isEmpty,
           let fallback = CodexBarProvider.normalizedOpenRouterModelID(provider.defaultModel) {
            source = [fallback]
        }
        return source
    }

    private static func normalizedThirdPartySelectedModelID(
        _ selectedModelID: String?,
        pinnedModelIDs: [String]
    ) -> String? {
        guard let normalizedSelectedModelID = CodexBarProvider.normalizedOpenRouterModelID(selectedModelID),
              pinnedModelIDs.contains(normalizedSelectedModelID) else {
            return pinnedModelIDs.first
        }
        return normalizedSelectedModelID
    }

    private static func applyThirdPartyModelSelection(
        modelID: String,
        accountID: String,
        provider: inout CodexBarProvider
    ) throws {
        guard provider.isThirdPartyModelProvider else {
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
        provider.defaultModel = normalizedModelID
        provider.activeAccountId = provider.accounts[accountIndex].id
    }

    private func persist(syncCodex: Bool) throws {
        if syncCodex,
           self.config.activeProvider()?.kind == .openAIOAuth {
            _ = self.absorbNewerAuthJSONIfNeeded(accountID: self.config.active.accountId)
        }
        try self.configStore.save(self.config)
        if syncCodex {
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
        _ = self.refreshAggregateGatewayLeaseState()
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
        self.accounts = self.config.oauthTokenAccounts()
        let effectiveGatewayMode = self.effectiveGatewayMode
        self.openAIAccountGatewayService.updateState(
            accounts: self.accounts,
            quotaSortSettings: self.config.openAI.quotaSort,
            accountUsageMode: effectiveGatewayMode,
            routeTarget: self.openAIAccountGatewayRouteTarget(effectiveMode: effectiveGatewayMode)
        )
        self.openAIAccountGatewayService.setExperimentalLocalCompressionConfiguration(
            isEnabled: self.config.openAI.experimentalLocalCompressionEnabled,
            settings: self.config.openAI.localCompressionSettings
        )
        self.openAIAccountGatewayService.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: self.config.openAI.reasoningRetryGuard
            )
        )
        self.openRouterGatewayService.updateState(
            provider: self.config.openRouterProvider(),
            isActiveProvider: self.config.activeProvider()?.kind == .openRouter
        )
        self.reconcileOpenAIAccountGatewayLifecycle(effectiveMode: effectiveGatewayMode)
        self.reconcileOpenRouterGatewayLifecycle()
        self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter
    }

    private func appendLocalCompressionHistory(_ activity: OpenAIAccountGatewayLocalCompressionActivity) {
        let entry = LocalCompressionHistoryEntry(
            id: UUID().uuidString,
            recordedAt: activity.recordedAt,
            route: activity.route == .responses ? "responses" : "compact",
            accountUsageMode: activity.accountUsageMode.rawValue,
            modelID: activity.modelID,
            inputTokenCount: activity.inputTokenCount,
            outputTokenCount: activity.outputTokenCount,
            compressionRatio: activity.compressionRatio,
            inputByteCount: activity.inputByteCount,
            outputByteCount: activity.outputByteCount
        )
        self.localCompressionHistoryStore.append(entry)
        self.localCompressionHistory = self.localCompressionHistoryStore.load()
    }

    private func openAIAccountGatewayRouteTarget(
        effectiveMode: CodexBarOpenAIAccountUsageMode
    ) -> OpenAIAccountGatewayRouteTarget {
        if effectiveMode == .aggregateGateway {
            return .openAIAggregate
        }

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
            return .none
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
              apiKey.isEmpty == false else {
            return .none
        }
        return .compatibleProvider(
            .init(
                providerID: provider.id,
                providerLabel: provider.label,
                baseURL: baseURL,
                accountID: account.id,
                apiKey: apiKey,
                modelID: provider.isThirdPartyModelProvider
                    ? (provider.thirdPartyEffectiveModelID(forAccountID: account.id) ?? provider.defaultModel ?? self.config.global.sanitizedDefaultModel)
                    : (provider.defaultModel ?? self.config.global.sanitizedDefaultModel),
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
        if self.config.openAI.accountUsageMode == .aggregateGateway ||
            self.aggregateGatewayLeaseProcessIDs.isEmpty == false {
            return .aggregateGateway
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
        if self.openAIAccountGatewayRouteTarget(effectiveMode: effectiveMode).requiresListener {
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

    private func captureAggregateGatewayLeasesIfNeeded(
        previousMode: CodexBarOpenAIAccountUsageMode,
        newMode: CodexBarOpenAIAccountUsageMode
    ) {
        if previousMode == .aggregateGateway, newMode != .aggregateGateway {
            self.aggregateGatewayLeaseProcessIDs = self.codexRunningProcessIDs()
            self.persistAggregateGatewayLeaseState()
            self.configureAggregateGatewayLeaseTimer()
            return
        }

        if newMode == .aggregateGateway, self.aggregateGatewayLeaseProcessIDs.isEmpty == false {
            self.aggregateGatewayLeaseProcessIDs.removeAll()
            self.persistAggregateGatewayLeaseState()
            self.configureAggregateGatewayLeaseTimer()
        }
    }

    private func refreshAggregateGatewayLeaseState() -> Bool {
        if self.config.openAI.accountUsageMode == .aggregateGateway {
            let changed = self.aggregateGatewayLeaseProcessIDs.isEmpty == false
            if changed {
                self.aggregateGatewayLeaseProcessIDs.removeAll()
                self.persistAggregateGatewayLeaseState()
            }
            self.configureAggregateGatewayLeaseTimer()
            return changed
        }

        let runningProcessIDs = self.codexRunningProcessIDs()
        let prunedProcessIDs = self.aggregateGatewayLeaseProcessIDs.intersection(runningProcessIDs)
        let changed = prunedProcessIDs != self.aggregateGatewayLeaseProcessIDs
        if changed {
            self.aggregateGatewayLeaseProcessIDs = prunedProcessIDs
            self.persistAggregateGatewayLeaseState()
        }
        self.configureAggregateGatewayLeaseTimer()
        return changed
    }

    private func persistAggregateGatewayLeaseState() {
        if self.aggregateGatewayLeaseProcessIDs.isEmpty {
            self.aggregateGatewayLeaseStore.clear()
        } else {
            self.aggregateGatewayLeaseStore.saveProcessIDs(self.aggregateGatewayLeaseProcessIDs)
        }
    }

    private func configureAggregateGatewayLeaseTimer() {
        let shouldPoll = self.config.openAI.accountUsageMode != .aggregateGateway &&
            self.aggregateGatewayLeaseProcessIDs.isEmpty == false

        if shouldPoll {
            if self.aggregateGatewayLeaseTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.refreshAggregateGatewayLeaseState() {
                        self.pushPublishedState()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.aggregateGatewayLeaseTimer = timer
            }
            return
        }

        self.aggregateGatewayLeaseTimer?.invalidate()
        self.aggregateGatewayLeaseTimer = nil
    }

    func refreshLocalCostSummary(
        force: Bool = false,
        minimumInterval: TimeInterval = 5 * 60,
        refreshSessionCache: Bool = false
    ) {
        guard self.config.openAI.disableLocalUsageStats == false else {
            self.cancelLocalCostSummaryRefresh(clearSummary: true)
            return
        }
        let request = LocalCostSummaryRefreshRequest(
            force: force,
            minimumInterval: minimumInterval,
            refreshSessionCache: refreshSessionCache
        )
        self.enqueueLocalCostSummaryRefresh(request)
    }

    func refreshLocalCostSummaryIfDue(minimumInterval: TimeInterval = 5 * 60) {
        guard self.config.openAI.disableLocalUsageStats == false else {
            self.cancelLocalCostSummaryRefresh(clearSummary: true)
            return
        }
        if let updatedAt = self.localCostSummary.updatedAt,
           Date().timeIntervalSince(updatedAt) < minimumInterval {
            return
        }
        self.refreshLocalCostSummary(
            force: false,
            minimumInterval: minimumInterval,
            refreshSessionCache: true
        )
    }

    private func refreshLocalCostSummaryIfNeeded() {
        guard self.config.openAI.disableLocalUsageStats == false else {
            self.cancelLocalCostSummaryRefresh(clearSummary: true)
            return
        }
        guard self.localCostSummary.updatedAt == nil ||
              self.localCostSummary.isStaleForLocalDay() else { return }
        self.refreshLocalCostSummary(
            force: true,
            minimumInterval: 0,
            refreshSessionCache: false
        )
    }

    private func enqueueLocalCostSummaryRefresh(_ request: LocalCostSummaryRefreshRequest) {
        guard self.config.openAI.disableLocalUsageStats == false else {
            self.cancelLocalCostSummaryRefresh(clearSummary: true)
            return
        }
        if request.force == false,
           let lastLocalCostSummaryRefreshFinishedAt,
           Date().timeIntervalSince(lastLocalCostSummaryRefreshFinishedAt) < request.minimumInterval {
            return
        }

        if self.shouldDeferLocalCostSummaryRefreshForGateway(request) {
            self.scheduleDeferredLocalCostSummaryRefresh(request)
            return
        }

        let shouldStart = self.refreshStateQueue.sync { () -> Bool in
            guard self.isRefreshingLocalCostSummary == false else {
                if self.pendingLocalCostSummaryRefresh == nil {
                    self.pendingLocalCostSummaryRefresh = request
                } else {
                    self.pendingLocalCostSummaryRefresh?.merge(request)
                }
                return false
            }
            self.isRefreshingLocalCostSummary = true
            DispatchQueue.main.async {
                self.isRefreshingLocalCostSummaryInBackground = true
            }
            return true
        }
        guard shouldStart else { return }

        self.runLocalCostSummaryRefresh(
            request,
            currentSummary: self.localCostSummary
        )
    }

    private func shouldDeferLocalCostSummaryRefreshForGateway(_ request: LocalCostSummaryRefreshRequest) -> Bool {
        guard request.force == false else { return false }
        return self.openAIAccountGatewayService.isHandlingHighFrequencyRequests(
            recentActivityWindow: self.localCostGatewayRecentActivityWindow
        ) || self.openRouterGatewayService.isHandlingHighFrequencyRequests(
            recentActivityWindow: self.localCostGatewayRecentActivityWindow
        )
    }

    private func scheduleDeferredLocalCostSummaryRefresh(_ request: LocalCostSummaryRefreshRequest) {
        self.localCostSummaryQueue.asyncAfter(
            deadline: .now() + self.localCostGatewayBusyDeferralInterval
        ) {
            self.enqueueLocalCostSummaryRefresh(request)
        }
    }

    private func runLocalCostSummaryRefresh(
        _ request: LocalCostSummaryRefreshRequest,
        currentSummary: LocalCostSummary
    ) {
        guard self.config.openAI.disableLocalUsageStats == false else {
            self.cancelLocalCostSummaryRefresh(clearSummary: true)
            return
        }
        let service = self.costSummaryService
        let modelPricing = self.config.modelPricing
        self.localCostSummaryQueue.async {
            if request.force == false,
               let lastFinishedAt = self.lastLocalCostSummaryRefreshFinishedAt,
               Date().timeIntervalSince(lastFinishedAt) < request.minimumInterval {
                DispatchQueue.main.async {
                    self.completeLocalCostSummaryRefresh(recordFinishedAt: false)
                }
                return
            }

            if self.shouldDeferLocalCostSummaryRefreshForGateway(request) {
                self.scheduleDeferredLocalCostSummaryRefresh(request)
                DispatchQueue.main.async {
                    self.completeLocalCostSummaryRefresh(recordFinishedAt: false)
                }
                return
            }

            var summary = service.load(
                now: Date(),
                modelPricingOverrides: modelPricing,
                refreshSessionCache: request.refreshSessionCache
            )
            if request.refreshSessionCache == false,
               self.isEffectivelyEmptyLocalCostSummary(summary) {
                summary = service.load(
                    now: Date(),
                    modelPricingOverrides: modelPricing,
                    refreshSessionCache: true
                )
            }
            DispatchQueue.main.async {
                guard self.config.openAI.disableLocalUsageStats == false else {
                    self.localCostSummary = .empty
                    self.completeLocalCostSummaryRefresh(recordFinishedAt: false)
                    return
                }
                let resolvedSummary = self.resolvedLocalCostSummaryRefreshResult(
                    summary,
                    currentSummary: currentSummary
                )
                self.localCostSummary = resolvedSummary
                self.saveCachedLocalCostSummary(resolvedSummary)
                self.completeLocalCostSummaryRefresh(recordFinishedAt: true)
            }
        }
    }

    private func resolvedLocalCostSummaryRefreshResult(
        _ refreshedSummary: LocalCostSummary,
        currentSummary: LocalCostSummary
    ) -> LocalCostSummary {
        guard self.isEffectivelyEmptyLocalCostSummary(refreshedSummary) else {
            return refreshedSummary
        }

        if self.isEffectivelyEmptyLocalCostSummary(currentSummary) == false {
            return currentSummary
        }

        let cachedSummary = self.loadCachedLocalCostSummary()
        if self.isEffectivelyEmptyLocalCostSummary(cachedSummary) == false {
            return cachedSummary
        }

        return refreshedSummary
    }

    private func completeLocalCostSummaryRefresh(recordFinishedAt: Bool) {
        if recordFinishedAt {
            self.lastLocalCostSummaryRefreshFinishedAt = Date()
        }
        let pendingRequest = self.refreshStateQueue.sync { () -> LocalCostSummaryRefreshRequest? in
            if let pendingLocalCostSummaryRefresh {
                self.pendingLocalCostSummaryRefresh = nil
                self.isRefreshingLocalCostSummary = false
                DispatchQueue.main.async {
                    self.isRefreshingLocalCostSummaryInBackground = false
                }
                return pendingLocalCostSummaryRefresh
            }
            self.isRefreshingLocalCostSummary = false
            DispatchQueue.main.async {
                self.isRefreshingLocalCostSummaryInBackground = false
            }
            return nil
        }
        if let pendingRequest {
            self.enqueueLocalCostSummaryRefresh(pendingRequest)
        }
    }

    private func cancelLocalCostSummaryRefresh(clearSummary: Bool) {
        self.refreshStateQueue.sync {
            self.pendingLocalCostSummaryRefresh = nil
            self.isRefreshingLocalCostSummary = false
        }
        if self.isRefreshingLocalCostSummaryInBackground {
            self.isRefreshingLocalCostSummaryInBackground = false
        }
        if clearSummary && self.isEffectivelyEmptyLocalCostSummary(self.localCostSummary) == false {
            self.localCostSummary = .empty
        }
    }

    private func refreshHistoricalModels() {
        let service = self.costSummaryService
        let fallbackHistoricalModels = Array(self.config.modelPricing.keys)
        guard self.config.openAI.disableLocalUsageStats == false else {
            self.historicalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: fallbackHistoricalModels
            )
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let fetchedHistoricalModels = service.historicalModels(refreshSessionCache: true)
            let mergedHistoricalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: fetchedHistoricalModels,
                fallbackHistoricalModels: fallbackHistoricalModels
            )

            DispatchQueue.main.async {
                self.historicalModels = mergedHistoricalModels
            }
        }
    }

    private static func normalizedHistoricalModels(_ historicalModels: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for model in historicalModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }

        return normalized.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func mergedHistoricalModels(
        preferredHistoricalModels: [String],
        fallbackHistoricalModels: [String]
    ) -> [String] {
        self.normalizedHistoricalModels(
            preferredHistoricalModels + fallbackHistoricalModels
        )
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

    private func loadCachedLocalCostSummary() -> LocalCostSummary {
        guard let data = try? Data(contentsOf: CodexPaths.costCacheURL) else {
            return .empty
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = (try? decoder.decode(LocalCostSummary.self, from: data)) ?? .empty

        if self.shouldInvalidateCachedLocalCostSummary(summary) {
            return .empty
        }

        return summary
    }

    private func resolvedCachedLocalCostSummary(_ cachedSummary: LocalCostSummary) -> LocalCostSummary {
        guard self.isEffectivelyEmptyLocalCostSummary(cachedSummary),
              self.isEffectivelyEmptyLocalCostSummary(self.localCostSummary) == false else {
            return cachedSummary
        }
        return self.localCostSummary
    }

    private func saveCachedLocalCostSummary(_ summary: LocalCostSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(summary) else { return }
        try? CodexPaths.writeSecureFile(data, to: CodexPaths.costCacheURL)
    }

    private func shouldInvalidateCachedLocalCostSummary(_ summary: LocalCostSummary) -> Bool {
        guard self.isEffectivelyEmptyLocalCostSummary(summary) else {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: CodexPaths.costEventLedgerURL.path
        ),
        let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        return fileSize.int64Value > 0
    }

    private func isEffectivelyEmptyLocalCostSummary(_ summary: LocalCostSummary) -> Bool {
        summary.todayTokens == 0 &&
        summary.last30DaysTokens == 0 &&
        summary.lifetimeTokens == 0 &&
        summary.dailyEntries.isEmpty
    }

    deinit {
        self.openRouterGatewayLeaseTimer?.invalidate()
        self.aggregateGatewayLeaseTimer?.invalidate()
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
    case invalidCodexAppPath

    var errorDescription: String? {
        switch self {
        case .accountNotFound: return "未找到账号"
        case .providerNotFound: return "未找到 provider"
        case .invalidInput: return "输入无效"
        case .invalidCodexAppPath: return L.codexAppPathInvalidSelection
        }
    }
}
