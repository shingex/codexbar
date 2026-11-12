import Combine
import Foundation

enum OpenAIUsagePollingPolicy {
    static func accountsToRefresh(
        accounts: [TokenAccount],
        now: Date,
        maxAge: TimeInterval,
        forcedAccountID: String? = nil
    ) -> [TokenAccount] {
        accounts.filter { account in
            !account.isSuspended && !account.tokenExpired &&
                (account.accountId == forcedAccountID || account.isUsageSnapshotStale(maxAge: maxAge, now: now))
        }
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
            await self.refreshIfNeeded()

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: sleepDuration)
                } catch {
                    break
                }
                await self.refreshIfNeeded()
            }
        }
    }

    func stop() {
        self.configSubscription?.cancel()
        self.configSubscription = nil
        self.loopTask?.cancel()
        self.loopTask = nil
    }

    func refreshNow(accountID: String? = nil) {
        guard let accountID = accountID ?? self.store.activeAccount()?.accountId else { return }
        Task {
            await self.refreshIfNeeded(forcedAccountID: accountID)
        }
    }

    private func refreshIfNeeded(forcedAccountID: String? = nil) async {
        _ = try? self.store.reconcileAuthJSONIfNeeded()
        let candidates = forcedAccountID.map { id in self.store.accounts.filter { $0.accountId == id } }
            ?? self.store.accounts
        let accounts = OpenAIUsagePollingPolicy.accountsToRefresh(
            accounts: candidates,
            now: self.now(),
            maxAge: self.refreshInterval,
            forcedAccountID: forcedAccountID
        )
        for account in accounts {
            guard !Task.isCancelled else { break }
            await self.refreshAction(account, self.store)
        }
    }
}
