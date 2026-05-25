import Combine
import Foundation

protocol SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws
    func applySettingsRouteTarget(_ target: SettingsRouteTarget) throws -> Bool
}

extension TokenStore: SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        try self.saveSettings(requests)
    }
}

protocol LaunchAtLoginControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ isEnabled: Bool) throws
}

private struct StaticLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false

    nonisolated init() {}

    func setEnabled(_: Bool) throws {}
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case gettingStarted
    case accounts
    case usage
    case records
    case backup
    case updates

    var id: String { self.rawValue }
}

struct SettingsRouteDraft: Equatable {
    var mode: CodexBarOpenAIAccountUsageMode
    var target: SettingsRouteTarget?

    init(config: CodexBarConfig) {
        self.mode = config.openAI.accountUsageMode
        self.target = Self.target(from: config)
    }

    static func target(from config: CodexBarConfig) -> SettingsRouteTarget? {
        switch config.openAI.accountUsageMode {
        case .switchAccount:
            guard let provider = config.activeProvider(),
                  let accountID = config.active.accountId else {
                return nil
            }
            switch provider.kind {
            case .openAIOAuth:
                let openAIAccountID = provider.accounts
                    .first(where: { $0.id == accountID })?
                    .openAIAccountId ?? accountID
                return .openAIAccount(accountID: openAIAccountID)
            case .openAICompatible:
                return .compatibleProvider(providerID: provider.id, accountID: accountID, mode: .switchAccount)
            case .openRouter:
                return .openRouter(
                    accountID: accountID,
                    modelID: provider.openRouterEffectiveModelID(forAccountID: accountID),
                    mode: .switchAccount
                )
            }
        case .aggregateGateway:
            return .aggregateGateway
        case .hybridProvider:
            guard let provider = config.activeProvider(),
                  let accountID = config.active.accountId else {
                return nil
            }
            switch provider.kind {
            case .openAIOAuth:
                let openAIAccountID = provider.accounts
                    .first(where: { $0.id == accountID })?
                    .openAIAccountId ?? accountID
                return .openAIAccount(accountID: openAIAccountID)
            case .openAICompatible:
                return .compatibleProvider(providerID: provider.id, accountID: accountID, mode: .hybridProvider)
            case .openRouter:
                return .openRouter(
                    accountID: accountID,
                    modelID: provider.openRouterEffectiveModelID(forAccountID: accountID),
                    mode: .hybridProvider
                )
            }
        }
    }
}

struct SettingsSaveResult: Equatable {
    var requests: SettingsSaveRequests
    var routeTargetApplied: Bool
}

struct SettingsGettingStartedProgress: Equatable {
    var mode: CodexBarOpenAIAccountUsageMode
    var openAIAccountCount: Int
    var thirdPartyAccountCount: Int

    var completedStepCount: Int {
        switch self.mode {
        case .switchAccount:
            return min(self.openAIAccountCount + self.thirdPartyAccountCount, 2)
        case .hybridProvider:
            return min(self.openAIAccountCount, 1) + min(self.thirdPartyAccountCount, 1)
        case .aggregateGateway:
            return min(self.openAIAccountCount, 2)
        }
    }

    var requiredStepCount: Int {
        2
    }

    var isComplete: Bool {
        self.completedStepCount >= self.requiredStepCount
    }

    static func shouldShowRequirementProgress(
        current: SettingsGettingStartedProgress,
        previous: SettingsGettingStartedProgress?,
        showingCompletedProgress: Bool
    ) -> Bool {
        current.isComplete == false ||
            showingCompletedProgress ||
            (current.isComplete && previous?.isComplete == false)
    }
}

struct SettingsWindowDraft: Equatable {
    var accountOrder: [String]
    var route: SettingsRouteDraft
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
    var usageDisplayMode: CodexBarUsageDisplayMode
    var disableLocalUsageStats: Bool
    var plusRelativeWeight: Double
    var proRelativeToPlusMultiplier: Double
    var teamRelativeToPlusMultiplier: Double
    var modelPricing: [String: CodexBarModelPricing]
    var preferredCodexAppPath: String?
    var launchAtLoginEnabled: Bool

    init(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        historicalModels: [String],
        launchAtLoginEnabled: Bool = false
    ) {
        let normalizedHistoricalModels = Self.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        self.accountOrder = Self.normalizedAccountOrder(
            config.openAI.accountOrder,
            availableAccountIDs: accounts.map(\.accountId)
        )
        self.route = SettingsRouteDraft(config: config)
        self.accountOrderingMode = config.openAI.accountOrderingMode
        self.usageDisplayMode = config.openAI.usageDisplayMode
        self.disableLocalUsageStats = config.openAI.disableLocalUsageStats
        self.plusRelativeWeight = config.openAI.quotaSort.plusRelativeWeight
        self.proRelativeToPlusMultiplier = config.openAI.quotaSort.proRelativeToPlusMultiplier
        self.teamRelativeToPlusMultiplier = config.openAI.quotaSort.teamRelativeToPlusMultiplier
        self.modelPricing = Self.effectiveModelPricing(
            config: config,
            historicalModels: normalizedHistoricalModels
        )
        self.preferredCodexAppPath = config.desktop.preferredCodexAppPath
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }

    static func mergedAccountOrder(
        preferredAccountOrder: [String],
        fallbackAccountOrder: [String],
        availableAccountIDs: [String]
    ) -> [String] {
        self.normalizedAccountOrder(
            preferredAccountOrder + fallbackAccountOrder,
            availableAccountIDs: availableAccountIDs
        )
    }

    private static func normalizedAccountOrder(_ accountOrder: [String], availableAccountIDs: [String]) -> [String] {
        let availableSet = Set(availableAccountIDs)
        var normalized: [String] = []
        var seen: Set<String> = []

        for accountID in accountOrder where availableSet.contains(accountID) {
            guard seen.insert(accountID).inserted else { continue }
            normalized.append(accountID)
        }

        for accountID in availableAccountIDs where seen.insert(accountID).inserted {
            normalized.append(accountID)
        }

        return normalized
    }

    static func normalizedHistoricalModels(_ historicalModels: [String]) -> [String] {
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

    static func mergedHistoricalModels(
        preferredHistoricalModels: [String],
        fallbackHistoricalModels: [String]
    ) -> [String] {
        self.normalizedHistoricalModels(
            preferredHistoricalModels + fallbackHistoricalModels
        )
    }

    static func effectiveModelPricing(
        config: CodexBarConfig,
        historicalModels: [String]
    ) -> [String: CodexBarModelPricing] {
        Dictionary(uniqueKeysWithValues: historicalModels.map { model in
            (
                model,
                LocalCostPricing.effectivePricing(
                    for: model,
                    customPricingByModel: config.modelPricing
                )
            )
        })
    }

    static func settingsHistoricalModels(
        config: CodexBarConfig,
        historicalModels: [String]
    ) -> [String] {
        self.mergedHistoricalModels(
            preferredHistoricalModels: historicalModels,
            fallbackHistoricalModels: Array(config.modelPricing.keys)
        )
    }
}

struct SettingsOpenAIAccountOrderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

enum SettingsDirtyField: Hashable {
    case accountOrder
    case route
    case accountOrderingMode
    case usageDisplayMode
    case disableLocalUsageStats
    case plusRelativeWeight
    case proRelativeToPlusMultiplier
    case teamRelativeToPlusMultiplier
    case modelPricing
    case preferredCodexAppPath
    case launchAtLogin
}

@MainActor
final class SettingsWindowCoordinator: ObservableObject {
    @Published var selectedPage: SettingsPage
    @Published var draft: SettingsWindowDraft
    @Published var validationMessage: String?
    @Published private(set) var historicalModels: [String]

    private var accounts: [TokenAccount]
    private var baseline: SettingsWindowDraft
    private var dirtyFields: Set<SettingsDirtyField> = []
    private let launchAtLoginController: LaunchAtLoginControlling

    init(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        historicalModels: [String],
        selectedPage: SettingsPage = .gettingStarted,
        launchAtLoginController: LaunchAtLoginControlling = StaticLaunchAtLoginController()
    ) {
        let normalizedHistoricalModels = SettingsWindowDraft.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        let draft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            historicalModels: normalizedHistoricalModels,
            launchAtLoginEnabled: launchAtLoginController.isEnabled
        )
        self.selectedPage = selectedPage
        self.draft = draft
        self.historicalModels = normalizedHistoricalModels
        self.accounts = accounts
        self.baseline = draft
        self.validationMessage = nil
        self.launchAtLoginController = launchAtLoginController
    }

    var hasChanges: Bool {
        self.makeSaveRequests().isEmpty == false || self.hasStagedRouteChange
    }

    var orderedAccounts: [SettingsOpenAIAccountOrderItem] {
        let accountByID = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.accountId, $0) })
        return self.draft.accountOrder.compactMap { accountID in
            guard let account = accountByID[accountID] else { return nil }
            return SettingsOpenAIAccountOrderItem(
                id: accountID,
                title: Self.accountTitle(for: account),
                detail: Self.accountDetail(for: account)
            )
        }
    }

    var showsManualAccountOrderSection: Bool {
        self.draft.accountOrderingMode == .manual
    }

    var selectedRouteTarget: SettingsRouteTarget? {
        self.draft.route.target
    }

    var hasStagedRouteChange: Bool {
        self.draft.route != self.baseline.route
    }

    func gettingStartedProgress(
        mode: CodexBarOpenAIAccountUsageMode,
        openAIAccountCount: Int,
        thirdPartyAccountCount: Int
    ) -> SettingsGettingStartedProgress {
        SettingsGettingStartedProgress(
            mode: mode,
            openAIAccountCount: openAIAccountCount,
            thirdPartyAccountCount: thirdPartyAccountCount
        )
    }

    func selectRouteMode(_ mode: CodexBarOpenAIAccountUsageMode) {
        self.draft.route.mode = mode
        if mode == .aggregateGateway {
            self.draft.route.target = .aggregateGateway
        } else if mode == .hybridProvider,
                  case .openAIAccount = self.draft.route.target {
            self.draft.route.target = nil
        } else if let target = self.draft.route.target {
            self.draft.route.target = self.retarget(target, mode: mode)
        }
        self.dirtyFields.insert(.route)
    }

    func selectRouteTarget(_ target: SettingsRouteTarget) {
        self.draft.route.mode = Self.mode(for: target)
        self.draft.route.target = target
        self.dirtyFields.insert(.route)
    }

    func isRouteTargetSelected(_ target: SettingsRouteTarget) -> Bool {
        self.draft.route.target == target
    }

    func moveAccount(accountID: String, offset: Int) {
        guard let currentIndex = self.draft.accountOrder.firstIndex(of: accountID) else { return }
        let targetIndex = currentIndex + offset
        guard self.draft.accountOrder.indices.contains(targetIndex) else { return }
        self.draft.accountOrder.swapAt(currentIndex, targetIndex)
        self.dirtyFields.insert(.accountOrder)
    }

    func setAccountOrder(_ accountOrder: [String]) {
        self.draft.accountOrder = accountOrder
        self.dirtyFields.insert(.accountOrder)
    }

    func update<Value>(
        _ keyPath: WritableKeyPath<SettingsWindowDraft, Value>,
        to value: Value,
        field: SettingsDirtyField
    ) {
        self.draft[keyPath: keyPath] = value
        self.dirtyFields.insert(field)
    }

    func commitUsageDisplayMode(_ mode: CodexBarUsageDisplayMode) {
        self.draft.usageDisplayMode = mode
        self.baseline.usageDisplayMode = mode
        self.dirtyFields.remove(.usageDisplayMode)
    }

    func updateModelPricing(for model: String, pricing: CodexBarModelPricing) {
        self.draft.modelPricing[model] = pricing
        self.dirtyFields.insert(.modelPricing)
    }

    func saveAndClose(
        using sink: SettingsSaveRequestApplying,
        onClose: () -> Void
    ) {
        do {
            _ = try self.save(using: sink)
            onClose()
        } catch {
            self.validationMessage = error.localizedDescription
        }
    }

    func save(using sink: SettingsSaveRequestApplying) throws -> SettingsSaveResult {
        let routeTarget = self.hasStagedRouteChange ? self.draft.route.target : nil
        if self.hasStagedRouteChange, routeTarget == nil {
            throw TokenStoreError.invalidInput
        }
        let requests = self.makeSaveRequests()
        if requests.isEmpty == false {
            if let launchAtLogin = requests.launchAtLogin {
                try self.launchAtLoginController.setEnabled(launchAtLogin.isEnabled)
            }
            let persistentRequests = requests.persistentRequests
            if persistentRequests.isEmpty == false {
                try sink.applySettingsSaveRequests(persistentRequests)
            }
        }
        var routeTargetApplied = false
        if let target = routeTarget {
            routeTargetApplied = try sink.applySettingsRouteTarget(target)
        }
        self.baseline = self.draft
        self.dirtyFields.removeAll()
        self.validationMessage = nil
        return SettingsSaveResult(
            requests: requests,
            routeTargetApplied: routeTargetApplied
        )
    }

    func cancelAndClose(onClose: () -> Void) {
        self.cancel()
        onClose()
    }

    func cancel() {
        self.draft = self.baseline
        self.dirtyFields.removeAll()
        self.validationMessage = nil
    }

    func reconcileExternalState(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        historicalModels: [String]
    ) {
        let normalizedHistoricalModels = SettingsWindowDraft.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        let externalDraft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            historicalModels: normalizedHistoricalModels,
            launchAtLoginEnabled: self.launchAtLoginController.isEnabled
        )
        self.accounts = accounts

        if self.dirtyFields.contains(.accountOrder) == false {
            self.draft.accountOrder = externalDraft.accountOrder
        } else {
            self.draft.accountOrder = SettingsWindowDraft.mergedAccountOrder(
                preferredAccountOrder: self.draft.accountOrder,
                fallbackAccountOrder: externalDraft.accountOrder,
                availableAccountIDs: accounts.map(\.accountId)
            )
        }
        self.baseline.accountOrder = externalDraft.accountOrder

        self.reconcile(\.route, externalValue: externalDraft.route, field: .route)
        self.reconcile(\.accountOrderingMode, externalValue: externalDraft.accountOrderingMode, field: .accountOrderingMode)
        self.reconcile(\.usageDisplayMode, externalValue: externalDraft.usageDisplayMode, field: .usageDisplayMode)
        self.reconcile(\.disableLocalUsageStats, externalValue: externalDraft.disableLocalUsageStats, field: .disableLocalUsageStats)
        self.reconcile(\.plusRelativeWeight, externalValue: externalDraft.plusRelativeWeight, field: .plusRelativeWeight)
        self.reconcile(\.proRelativeToPlusMultiplier, externalValue: externalDraft.proRelativeToPlusMultiplier, field: .proRelativeToPlusMultiplier)
        self.reconcile(\.teamRelativeToPlusMultiplier, externalValue: externalDraft.teamRelativeToPlusMultiplier, field: .teamRelativeToPlusMultiplier)
        self.reconcileModelPricing(
            externalValue: externalDraft.modelPricing,
            externalHistoricalModels: normalizedHistoricalModels
        )
        self.reconcile(\.preferredCodexAppPath, externalValue: externalDraft.preferredCodexAppPath, field: .preferredCodexAppPath)
        self.reconcile(\.launchAtLoginEnabled, externalValue: externalDraft.launchAtLoginEnabled, field: .launchAtLogin)
    }

    func makeSaveRequests() -> SettingsSaveRequests {
        var requests = SettingsSaveRequests()

        if self.draft.accountOrder != self.baseline.accountOrder ||
            self.draft.accountOrderingMode != self.baseline.accountOrderingMode {
            requests.openAIAccount = OpenAIAccountSettingsUpdate(
                accountOrder: self.draft.accountOrder,
                accountUsageMode: self.baseline.route.mode,
                accountOrderingMode: self.draft.accountOrderingMode
            )
        }

        if self.draft.usageDisplayMode != self.baseline.usageDisplayMode ||
            self.draft.disableLocalUsageStats != self.baseline.disableLocalUsageStats ||
            self.draft.plusRelativeWeight != self.baseline.plusRelativeWeight ||
            self.draft.proRelativeToPlusMultiplier != self.baseline.proRelativeToPlusMultiplier ||
            self.draft.teamRelativeToPlusMultiplier != self.baseline.teamRelativeToPlusMultiplier {
            requests.openAIUsage = OpenAIUsageSettingsUpdate(
                usageDisplayMode: self.draft.usageDisplayMode,
                disableLocalUsageStats: self.draft.disableLocalUsageStats,
                plusRelativeWeight: self.draft.plusRelativeWeight,
                proRelativeToPlusMultiplier: self.draft.proRelativeToPlusMultiplier,
                teamRelativeToPlusMultiplier: self.draft.teamRelativeToPlusMultiplier
            )
        }

        let modelPricingUpdate = self.makeModelPricingUpdate()
        if modelPricingUpdate.upserts.isEmpty == false || modelPricingUpdate.removals.isEmpty == false {
            requests.modelPricing = modelPricingUpdate
        }

        if self.draft.preferredCodexAppPath != self.baseline.preferredCodexAppPath {
            requests.desktop = DesktopSettingsUpdate(
                preferredCodexAppPath: self.draft.preferredCodexAppPath
            )
        }

        if self.draft.launchAtLoginEnabled != self.baseline.launchAtLoginEnabled {
            requests.launchAtLogin = LaunchAtLoginSettingsUpdate(
                isEnabled: self.draft.launchAtLoginEnabled
            )
        }

        return requests
    }

    private static func accountTitle(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        if account.email.isEmpty == false {
            return account.email
        }
        return account.accountId
    }

    private static func accountDetail(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false,
           account.email.isEmpty == false {
            return account.email
        }
        return account.accountId
    }

    private static func mode(for target: SettingsRouteTarget) -> CodexBarOpenAIAccountUsageMode {
        switch target {
        case .openAIAccount:
            return .switchAccount
        case .aggregateGateway:
            return .aggregateGateway
        case .compatibleProvider(_, _, let mode), .openRouter(_, _, let mode):
            return mode
        }
    }

    private func retarget(_ target: SettingsRouteTarget, mode: CodexBarOpenAIAccountUsageMode) -> SettingsRouteTarget {
        switch target {
        case .openAIAccount(let accountID):
            return .openAIAccount(accountID: accountID)
        case .aggregateGateway:
            return mode == .aggregateGateway ? .aggregateGateway : target
        case .compatibleProvider(let providerID, let accountID, _):
            return .compatibleProvider(providerID: providerID, accountID: accountID, mode: mode)
        case .openRouter(let accountID, let modelID, _):
            return .openRouter(accountID: accountID, modelID: modelID, mode: mode)
        }
    }

    private func reconcile<Value: Equatable>(
        _ keyPath: WritableKeyPath<SettingsWindowDraft, Value>,
        externalValue: Value,
        field: SettingsDirtyField
    ) {
        if self.dirtyFields.contains(field) == false {
            self.draft[keyPath: keyPath] = externalValue
        }
        self.baseline[keyPath: keyPath] = externalValue
    }

    private func reconcileModelPricing(
        externalValue: [String: CodexBarModelPricing],
        externalHistoricalModels: [String]
    ) {
        if self.dirtyFields.contains(.modelPricing) == false {
            self.historicalModels = externalHistoricalModels
            self.draft.modelPricing = externalValue
        } else {
            let mergedHistoricalModels = SettingsWindowDraft.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: externalHistoricalModels
            )
            var mergedPricing = Dictionary(
                uniqueKeysWithValues: mergedHistoricalModels.map { model in
                    (model, externalValue[model] ?? self.draft.modelPricing[model] ?? .zero)
                }
            )

            for model in mergedHistoricalModels where self.historicalModels.contains(model) {
                if let editedPricing = self.draft.modelPricing[model] {
                    mergedPricing[model] = editedPricing
                }
            }

            self.historicalModels = mergedHistoricalModels
            self.draft.modelPricing = mergedPricing
        }

        self.baseline.modelPricing = Dictionary(
            uniqueKeysWithValues: self.historicalModels.map { model in
                (model, externalValue[model] ?? .zero)
            }
        )
    }

    private func makeModelPricingUpdate() -> ModelPricingSettingsUpdate {
        var upserts: [String: CodexBarModelPricing] = [:]
        var removals: [String] = []

        for model in self.historicalModels {
            let draftPricing = self.draft.modelPricing[model] ?? .zero
            let baselinePricing = self.baseline.modelPricing[model] ?? .zero
            guard draftPricing != baselinePricing else { continue }

            let defaultPricing = LocalCostPricing.defaultPricing(for: model) ?? .zero
            if draftPricing == defaultPricing {
                removals.append(model)
            } else {
                upserts[model] = draftPricing
            }
        }

        return ModelPricingSettingsUpdate(
            upserts: upserts,
            removals: removals
        )
    }
}
