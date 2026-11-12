import Combine
import Foundation

protocol SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws
    func applySettingsRoute(_ route: SettingsRouteDraft) throws -> Bool
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
    case skills
    case backup
    case updates

    var id: String { self.rawValue }
}

struct SettingsRouteDraft: Equatable {
    var style: CodexRoutingStyle = .follow
    var modelRoutingEnabled: Bool = false
    var modeBeforeModelRouting: CodexBarOpenAIAccountUsageMode = .switchAccount
    var mode: CodexBarOpenAIAccountUsageMode
    var target: SettingsRouteTarget?

    init(config: CodexBarConfig) {
        self.style = config.openAI.modelRoutingStyle
        self.modelRoutingEnabled = config.openAI.modelRoutingEnabled
        self.modeBeforeModelRouting = config.openAI.modelRoutingPreviousMode ?? config.openAI.accountUsageMode
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
                return .openAIAccount(accountID: accountID, mode: .switchAccount)
            case .openAICompatible:
                return .compatibleProvider(
                    providerID: provider.id,
                    accountID: accountID,
                    modelID: provider.thirdPartyEffectiveModelID(forAccountID: accountID),
                    mode: .switchAccount
                )
            case .openRouter:
                return .openRouter(
                    accountID: accountID,
                    modelID: provider.openRouterEffectiveModelID(forAccountID: accountID),
                    mode: .switchAccount
                )
            }
        case .hybridProvider:
            guard let provider = config.activeProvider(),
                  let accountID = config.active.accountId else {
                return nil
            }
            switch provider.kind {
            case .openAIOAuth:
                return .openAIAccount(accountID: accountID, mode: .hybridProvider)
            case .openAICompatible:
                return .compatibleProvider(
                    providerID: provider.id,
                    accountID: accountID,
                    modelID: provider.thirdPartyEffectiveModelID(forAccountID: accountID),
                    mode: .hybridProvider
                )
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
        let previousForCurrentMode = previous?.mode == current.mode ? previous : nil
        return current.isComplete == false ||
            showingCompletedProgress ||
            (current.isComplete && previousForCurrentMode?.isComplete == false)
    }
}

struct SettingsWindowDraft: Equatable {
    var accountOrder: [String]
    var route: SettingsRouteDraft
    var usagePollingIntervalSeconds: Int
    var usageDisplayMode: CodexBarUsageDisplayMode
    var preferredCodexAppPath: String?
    var launchAtLoginEnabled: Bool

    init(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        launchAtLoginEnabled: Bool = false
    ) {
        self.accountOrder = Self.normalizedAccountOrder(
            config.openAI.accountOrder,
            availableAccountIDs: accounts.map(\.accountId)
        )
        self.route = SettingsRouteDraft(config: config)
        self.usagePollingIntervalSeconds = config.openAI.usagePollingIntervalSeconds
        self.usageDisplayMode = config.openAI.usageDisplayMode
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

}

struct SettingsOpenAIAccountOrderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

enum SettingsDirtyField: Hashable {
    case accountOrder
    case route
    case usageDisplayMode
}

@MainActor
final class SettingsWindowCoordinator: ObservableObject {
    @Published var selectedPage: SettingsPage
    @Published var draft: SettingsWindowDraft
    @Published var validationMessage: String?

    private var accounts: [TokenAccount]
    private var baseline: SettingsWindowDraft
    private var dirtyFields: Set<SettingsDirtyField> = []
    private let launchAtLoginController: LaunchAtLoginControlling

    init(
        config: CodexBarConfig,
        accounts: [TokenAccount],
        selectedPage: SettingsPage = .gettingStarted,
        launchAtLoginController: LaunchAtLoginControlling = StaticLaunchAtLoginController()
    ) {
        let draft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            launchAtLoginEnabled: launchAtLoginController.isEnabled
        )
        self.selectedPage = selectedPage
        self.draft = draft
        self.accounts = accounts
        self.baseline = draft
        self.validationMessage = nil
        self.launchAtLoginController = launchAtLoginController
    }

    var hasChanges: Bool {
        self.makeSaveRequests().isEmpty == false || self.hasStagedRouteChange
    }

    var hasGettingStartedChanges: Bool {
        self.hasStagedRouteChange
    }

    var hasAccountSettingsChanges: Bool {
        self.makeAccountSettingsSaveRequests().isEmpty == false
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

    func acceptSavedRoute(_ route: SettingsRouteDraft) {
        self.draft.route = route
        self.baseline.route = route
        self.dirtyFields.remove(.route)
    }

    func selectRoutingStyle(_ style: CodexRoutingStyle) {
        self.draft.route.style = style
        self.dirtyFields.insert(.route)
    }

    func setModelRoutingEnabled(_ enabled: Bool) {
        if enabled && !self.draft.route.modelRoutingEnabled { self.draft.route.modeBeforeModelRouting = self.draft.route.mode }
        self.draft.route.modelRoutingEnabled = enabled
        self.selectRouteMode(enabled ? .hybridProvider : .switchAccount)
    }

    func selectRouteMode(_ mode: CodexBarOpenAIAccountUsageMode) {
        self.draft.route.mode = mode
        if let target = self.draft.route.target {
            self.draft.route.target = self.retarget(target, mode: mode)
        }
        self.dirtyFields.insert(.route)
    }

    func selectRouteTarget(_ target: SettingsRouteTarget) {
        switch target {
        case .compatibleProvider, .openRouter: self.draft.route.modelRoutingEnabled = true
        case .openAIAccount: break
        }
        self.draft.route.mode = self.draft.route.modelRoutingEnabled ? .hybridProvider : Self.mode(for: target)
        self.draft.route.target = self.retarget(target, mode: self.draft.route.mode)
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

    func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try self.launchAtLoginController.setEnabled(enabled)
            let applied = self.launchAtLoginController.isEnabled
            self.draft.launchAtLoginEnabled = applied
            self.baseline.launchAtLoginEnabled = applied
            self.validationMessage = nil
        } catch {
            self.validationMessage = error.localizedDescription
        }
    }

    func applyPreferredCodexAppPath(_ path: String?, using sink: SettingsSaveRequestApplying) {
        do {
            try sink.applySettingsSaveRequests(SettingsSaveRequests(desktop: .init(preferredCodexAppPath: path)))
            self.draft.preferredCodexAppPath = path
            self.baseline.preferredCodexAppPath = path
            self.validationMessage = nil
        } catch {
            self.validationMessage = error.localizedDescription
        }
    }

    func applyUsagePollingInterval(_ seconds: Int, using sink: SettingsSaveRequestApplying) {
        let interval = UsagePollingInterval.normalized(seconds)
        guard interval != self.baseline.usagePollingIntervalSeconds else {
            self.validationMessage = nil
            return
        }
        do {
            try sink.applySettingsSaveRequests(SettingsSaveRequests(openAIUsage: .init(
                pollingIntervalSeconds: interval
            )))
            self.draft.usagePollingIntervalSeconds = interval
            self.baseline.usagePollingIntervalSeconds = interval
            self.validationMessage = nil
        } catch {
            self.validationMessage = error.localizedDescription
        }
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
        if self.hasStagedRouteChange, routeTarget == nil && self.draft.route.modelRoutingEnabled {
            throw TokenStoreError.invalidInput
        }
        let requests = self.makeSaveRequests()
        try self.applySaveRequests(requests, using: sink)
        var routeTargetApplied = false
        if self.hasStagedRouteChange {
            routeTargetApplied = try sink.applySettingsRoute(self.draft.route)
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

    func saveGettingStartedSettings(using sink: SettingsSaveRequestApplying) throws -> SettingsSaveResult {
        guard self.hasStagedRouteChange else {
            self.validationMessage = nil
            return SettingsSaveResult(requests: SettingsSaveRequests(), routeTargetApplied: false)
        }
        guard self.draft.route.target != nil || !self.draft.route.modelRoutingEnabled else {
            throw TokenStoreError.invalidInput
        }

        let routeTargetApplied = try sink.applySettingsRoute(self.draft.route)
        self.baseline.route = self.draft.route
        self.dirtyFields.remove(.route)
        self.validationMessage = nil
        return SettingsSaveResult(
            requests: SettingsSaveRequests(),
            routeTargetApplied: routeTargetApplied
        )
    }

    func saveAccountSettings(using sink: SettingsSaveRequestApplying) throws -> SettingsSaveResult {
        let requests = self.makeAccountSettingsSaveRequests()
        try self.applySaveRequests(requests, using: sink)
        self.baseline.accountOrder = self.draft.accountOrder
        self.dirtyFields.remove(.accountOrder)
        self.validationMessage = nil
        return SettingsSaveResult(requests: requests, routeTargetApplied: false)
    }

    func cancelGettingStartedChanges() {
        self.draft.route = self.baseline.route
        self.dirtyFields.remove(.route)
        self.validationMessage = nil
    }

    func cancelAccountSettingsChanges() {
        self.draft.accountOrder = self.baseline.accountOrder
        self.dirtyFields.remove(.accountOrder)
        self.validationMessage = nil
    }

    func reconcileExternalState(
        config: CodexBarConfig,
        accounts: [TokenAccount]
    ) {
        let externalDraft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
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
        self.draft.usagePollingIntervalSeconds = externalDraft.usagePollingIntervalSeconds
        self.baseline.usagePollingIntervalSeconds = externalDraft.usagePollingIntervalSeconds
        self.reconcile(\.usageDisplayMode, externalValue: externalDraft.usageDisplayMode, field: .usageDisplayMode)
        self.draft.preferredCodexAppPath = externalDraft.preferredCodexAppPath
        self.baseline.preferredCodexAppPath = externalDraft.preferredCodexAppPath
        self.draft.launchAtLoginEnabled = externalDraft.launchAtLoginEnabled
        self.baseline.launchAtLoginEnabled = externalDraft.launchAtLoginEnabled
    }

    func makeSaveRequests() -> SettingsSaveRequests {
        let accountRequests = self.makeAccountSettingsSaveRequests()
        let usageRequests = self.makeUsageSettingsSaveRequests()
        return SettingsSaveRequests(
            openAIAccount: accountRequests.openAIAccount,
            openAIUsage: usageRequests.openAIUsage
        )
    }

    private func makeAccountSettingsSaveRequests() -> SettingsSaveRequests {
        var requests = SettingsSaveRequests()

        if self.draft.accountOrder != self.baseline.accountOrder {
            requests.openAIAccount = OpenAIAccountSettingsUpdate(
                accountOrder: self.draft.accountOrder,
                accountUsageMode: self.baseline.route.mode
            )
        }

        return requests
    }

    private func makeUsageSettingsSaveRequests() -> SettingsSaveRequests {
        var requests = SettingsSaveRequests()

        if self.draft.usageDisplayMode != self.baseline.usageDisplayMode {
            requests.openAIUsage = OpenAIUsageSettingsUpdate(
                usageDisplayMode: self.draft.usageDisplayMode
            )
        }

        return requests
    }

    private func applySaveRequests(_ requests: SettingsSaveRequests, using sink: SettingsSaveRequestApplying) throws {
        guard requests.isEmpty == false else { return }

        try sink.applySettingsSaveRequests(requests)
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
        case .openAIAccount(_, let mode):
            return mode
        case .compatibleProvider(_, _, _, let mode), .openRouter(_, _, let mode):
            return mode
        }
    }

    private func retarget(_ target: SettingsRouteTarget, mode: CodexBarOpenAIAccountUsageMode) -> SettingsRouteTarget {
        switch target {
        case .openAIAccount(let accountID, _):
            return .openAIAccount(accountID: accountID, mode: mode == .hybridProvider ? .hybridProvider : .switchAccount)
        case .compatibleProvider(let providerID, let accountID, let modelID, _):
            return .compatibleProvider(providerID: providerID, accountID: accountID, modelID: modelID, mode: mode)
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

}
