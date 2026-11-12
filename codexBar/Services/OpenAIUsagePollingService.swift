import Combine
import Foundation

enum OpenAIUsagePollingPolicy {
    static func accountToRefresh(
        activeProvider: CodexBarProvider?,
        activeAccount: TokenAccount?,
        now: Date,
        maxAge: TimeInterval,
        force: Bool
    ) -> TokenAccount? {
        guard activeProvider?.kind == .openAIOAuth,
              let activeAccount,
              activeAccount.isSuspended == false,
              activeAccount.tokenExpired == false else {
            return nil
        }

        guard force || activeAccount.isUsageSnapshotStale(maxAge: maxAge, now: now) else {
            return nil
        }
        return activeAccount
    }
}

@MainActor
final class OpenAIUsagePollingService {
    static let shared = OpenAIUsagePollingService()
    nonisolated static let defaultRefreshInterval: TimeInterval = TimeInterval(UsagePollingInterval.defaultOpenAI)

    private let store: TokenStore
    private let intervalOverride: TimeInterval?
    private var configSubscription: AnyCancellable?
    private var refreshInterval: TimeInterval {
        self.intervalOverride ?? TimeInterval(self.store.config.openAI.usagePollingIntervalSeconds)
    }
    private let now: () -> Date
    private let refreshAction: (TokenAccount, TokenStore) async -> Void

    private var loopTask: Task<Void, Never>?

    init(
        store: TokenStore? = nil,
        refreshInterval: TimeInterval? = nil,
        now: @escaping () -> Date = Date.init,
        refreshAction: @escaping (TokenAccount, TokenStore) async -> Void = { account, store in
            await WhamService.shared.refreshOne(account: account, store: store)
        }
    ) {
        self.store = store ?? .shared
        self.intervalOverride = refreshInterval
        self.now = now
        self.refreshAction = refreshAction
    }

    func start() {
        guard self.configSubscription == nil else { return }
        self.configSubscription = self.store.$config
            .map { $0.openAI.usagePollingIntervalSeconds }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self else { return }
                self.schedule(interval: self.intervalOverride ?? TimeInterval(seconds))
            }
    }

    private func schedule(interval: TimeInterval) {
        self.loopTask?.cancel()
        self.loopTask = nil
        guard interval > 0 else { return }
        let sleepDuration = UsagePollingInterval.nanoseconds(Int(interval))
        self.loopTask = Task {
            await self.refreshIfNeeded(force: false)

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: sleepDuration)
                } catch {
                    break
                }
                await self.refreshIfNeeded(force: false)
            }
        }
    }

    func stop() {
        self.configSubscription?.cancel()
        self.configSubscription = nil
        self.loopTask?.cancel()
        self.loopTask = nil
    }

    func refreshNow() {
        Task {
            await self.refreshIfNeeded(force: true)
        }
    }

    private func refreshIfNeeded(force: Bool) async {
        _ = try? self.store.reconcileAuthJSONIfNeeded()
        guard let account = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: self.store.activeProvider,
            activeAccount: self.store.activeAccount(),
            now: self.now(),
            maxAge: self.refreshInterval,
            force: force
        ) else {
            return
        }

        await self.refreshAction(account, self.store)
    }
}
