import Foundation
import XCTest

@MainActor
final class SettingsRecordsViewModelTests: XCTestCase {
    func testPageDidAppearLoadsCurrentSnapshotWithoutForcingFullRefresh() async throws {
        let service = RecordsSnapshotServiceStub()
        await service.enqueueLoadCurrent(self.makeSnapshot(sessionID: "load-current", modelID: "gpt-5.4"))
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.pageDidAppear()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        let loadCurrentCallCount = await service.loadCurrentCount()
        let refreshAllCallCount = await service.refreshAllCount()
        XCTAssertEqual(loadCurrentCallCount, 1)
        XCTAssertEqual(refreshAllCallCount, 0)
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["load-current"])
        XCTAssertFalse(viewModel.isRefreshingAll)
    }

    func testLatestRequestTokenWinsWhenRefreshOverridesInFlightLoad() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) {
            let count = await service.loadCurrentCount()
            return count == 1
        }

        viewModel.refreshAll(timeout: 1)
        try await self.waitUntil(timeout: 1) {
            let count = await service.refreshAllCount()
            return count == 1
        }

        await service.resumeRefreshAll(
            with: .success(self.makeSnapshot(sessionID: "refresh", modelID: "gpt-5.4"))
        )
        try await self.waitUntil(timeout: 1) { viewModel.snapshot?.sessions.first?.sessionID == "refresh" }

        await service.finishStream(
            with: .success([.finished(self.makeSnapshot(sessionID: "stale-load", modelID: "gpt-5.4-mini"))])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["refresh"])
        XCTAssertFalse(viewModel.isRefreshingAll)
        XCTAssertFalse(viewModel.isLoadingSnapshot)
    }

    func testPageDidAppearShowsCachedSessionsBeforeIncrementalRefreshFinishes() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)
        let cachedSnapshot = self.makeSnapshot(sessionID: "cached", modelID: "gpt-5.4")
        let finishedSnapshot = self.makeSnapshot(sessionID: "finished", modelID: "gpt-5.5")

        viewModel.pageDidAppear()
        try await self.waitUntil(timeout: 1) {
            let count = await service.loadCurrentCount()
            return count == 1
        }

        await service.yieldStreamEvent(.cached(cachedSnapshot))
        try await self.waitUntil(timeout: 1) { viewModel.sessions.map(\.sessionID) == ["cached"] }

        XCTAssertEqual(viewModel.listLoadState, .refreshing)
        XCTAssertFalse(viewModel.shouldShowSkeleton)
        let messageRequests = await service.messageSessionIDs()
        let tokenRequests = await service.tokenCountSessionIDs()
        XCTAssertEqual(messageRequests, [])
        XCTAssertEqual(tokenRequests, [])

        await service.finishStream(with: .success([.finished(finishedSnapshot)]))
        try await self.waitUntil(timeout: 1) { viewModel.sessions.map(\.sessionID) == ["finished"] }
        XCTAssertEqual(viewModel.listLoadState, .finished)
    }

    func testIncrementalFailureKeepsCachedListVisible() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)
        let cachedSnapshot = self.makeSnapshot(sessionID: "cached", modelID: "gpt-5.4")

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) {
            let count = await service.loadCurrentCount()
            return count == 1
        }

        await service.yieldStreamEvent(.cached(cachedSnapshot))
        try await self.waitUntil(timeout: 1) { viewModel.sessions.map(\.sessionID) == ["cached"] }

        await service.finishStream(with: .failure(RecordsViewModelTestError.streamFailed))
        try await self.waitUntil(timeout: 1) {
            if case .failed = viewModel.listLoadState {
                return true
            }
            return false
        }

        XCTAssertEqual(viewModel.sessions.map(\.sessionID), ["cached"])
        XCTAssertNil(viewModel.selectedSession)
    }

    func testNoCacheShowsCompactLoadingStateWithoutSkeleton() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) {
            let count = await service.loadCurrentCount()
            return count == 1
        }

        XCTAssertEqual(viewModel.listLoadState, .loadingCached)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.shouldShowSkeleton)

        await service.yieldStreamEvent(
            .cached(
                RecordsSnapshot(
                    generatedAt: self.date("2026-04-21T10:00:00Z"),
                    refreshMode: .incremental,
                    models: [],
                    sessions: [],
                    warnings: []
                )
            )
        )

        try await self.waitUntil(timeout: 1) { viewModel.listLoadState == .refreshing }
        XCTAssertFalse(viewModel.shouldShowSkeleton)
        await service.finishStream()
    }

    func testSearchFiltersSessionsBySessionIDOrModel() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)

        await service.enqueueLoadCurrent(
            RecordsSnapshot(
                generatedAt: self.date("2026-04-21T10:00:00Z"),
                refreshMode: .incremental,
                models: [
                    HistoricalModelRecord(modelID: "gpt-5.4", sessionCount: 1, lastSeenAt: self.date("2026-04-21T10:00:00Z")),
                    HistoricalModelRecord(modelID: "google/gemini-2.5-pro", sessionCount: 1, lastSeenAt: self.date("2026-04-21T09:00:00Z")),
                ],
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "session-alpha",
                        modelID: "gpt-5.4",
                        startedAt: self.date("2026-04-21T08:00:00Z"),
                        lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                        isArchived: false,
                        totalTokens: 220
                    ),
                    HistoricalSessionRecord(
                        sessionID: "session-beta",
                        modelID: "google/gemini-2.5-pro",
                        startedAt: self.date("2026-04-21T07:00:00Z"),
                        lastActivityAt: self.date("2026-04-21T09:00:00Z"),
                        isArchived: true,
                        totalTokens: 120
                    ),
                ],
                warnings: []
            )
        )

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        viewModel.searchText = "beta"
        XCTAssertEqual(viewModel.filteredSessions.map(\.sessionID), ["session-beta"])
        XCTAssertEqual(viewModel.filteredModels.map(\.modelID), ["google/gemini-2.5-pro"])

        viewModel.searchText = "gpt-5.4"
        XCTAssertEqual(viewModel.filteredSessions.map(\.sessionID), ["session-alpha"])
        XCTAssertEqual(viewModel.filteredModels.map(\.modelID), ["gpt-5.4"])
    }

    func testStatusFilterFiltersSessionsAndPersistsSelection() async throws {
        let service = RecordsSnapshotServiceStub()
        let userDefaults = try self.makeUserDefaults()
        let viewModel = SettingsRecordsViewModel(service: service, userDefaults: userDefaults)
        let snapshot = RecordsSnapshot(
            generatedAt: self.date("2026-04-21T10:00:00Z"),
            refreshMode: .incremental,
            models: [],
            sessions: [
                HistoricalSessionRecord(
                    sessionID: "active",
                    modelID: "gpt-5.4",
                    startedAt: self.date("2026-04-21T09:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                    isArchived: false,
                    totalTokens: 100
                ),
                HistoricalSessionRecord(
                    sessionID: "archived",
                    modelID: "gpt-5.5",
                    startedAt: self.date("2026-04-21T08:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T09:00:00Z"),
                    isArchived: true,
                    totalTokens: 80
                ),
            ],
            warnings: []
        )
        await service.enqueueLoadCurrent(snapshot)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        viewModel.setStatusFilter(.active)
        XCTAssertEqual(viewModel.filteredSessions.map(\.sessionID), ["active"])
        XCTAssertEqual(userDefaults.string(forKey: "settings.records.sessionStatusFilter"), "active")

        viewModel.setStatusFilter(.archived)
        XCTAssertEqual(viewModel.filteredSessions.map(\.sessionID), ["archived"])
        XCTAssertEqual(userDefaults.string(forKey: "settings.records.sessionStatusFilter"), "archived")

        let restoredViewModel = SettingsRecordsViewModel(service: service, userDefaults: userDefaults)
        XCTAssertEqual(restoredViewModel.statusFilter, .archived)
    }

    func testRefreshButtonStaysDisabledWhileRefreshIsInFlight() async throws {
        let service = RecordsSnapshotServiceStub()
        await service.enqueueLoadCurrent(self.makeSnapshot(sessionID: "initial", modelID: "gpt-5.4"))
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }

        viewModel.refreshAll(timeout: 1)
        try await self.waitUntil(timeout: 1) {
            let count = await service.refreshAllCount()
            return count == 1
        }

        XCTAssertTrue(viewModel.isRefreshingAll)
        viewModel.refreshAll(timeout: 1)
        let refreshCallCount = await service.refreshAllCount()
        XCTAssertEqual(refreshCallCount, 1)

        await service.resumeRefreshAll(
            with: .success(self.makeSnapshot(sessionID: "refreshed", modelID: "gpt-5.4"))
        )
        try await self.waitUntil(timeout: 1) { viewModel.isRefreshingAll == false }
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["refreshed"])
    }

    func testTimedOutRefreshKeepsOldSnapshotAndDropsLateResult() async throws {
        let sourceLoader = SlowRecordsSourceSnapshotLoader(
            rebuildDelayNanoseconds: 100_000_000
        )
        let service = RecordsSnapshotService(sourceLoader: sourceLoader)
        let viewModel = SettingsRecordsViewModel(service: service)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot?.sessions.first?.sessionID == "initial" }

        viewModel.refreshAll(timeout: 0.01)
        try await self.waitUntil(timeout: 1) { viewModel.isRefreshingAll == false }

        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["initial"])
        XCTAssertEqual(viewModel.errorMessage, L.settingsRecordsRefreshTimeout)

        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["initial"])
        XCTAssertEqual(viewModel.errorMessage, L.settingsRecordsRefreshTimeout)
    }

    func testInitialLoadDoesNotSelectSessionOrLoadDetailData() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)
        let snapshot = RecordsSnapshot(
            generatedAt: self.date("2026-04-21T10:00:00Z"),
            refreshMode: .incremental,
            models: [],
            sessions: [
                HistoricalSessionRecord(
                    sessionID: "alpha",
                    modelID: "gpt-5.4",
                    startedAt: self.date("2026-04-21T09:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                    isArchived: false,
                    totalTokens: 80
                ),
                HistoricalSessionRecord(
                    sessionID: "beta",
                    modelID: "gpt-5.5",
                    startedAt: self.date("2026-04-21T09:30:00Z"),
                    lastActivityAt: self.date("2026-04-21T10:30:00Z"),
                    isArchived: false,
                    totalTokens: 120
                ),
            ],
            warnings: []
        )
        await service.enqueueLoadCurrent(snapshot)

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(viewModel.selectedSession)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.selectedSessionTokenCount)
        let initialMessageRequests = await service.messageSessionIDs()
        let initialTokenCountRequests = await service.tokenCountSessionIDs()
        XCTAssertEqual(initialMessageRequests, [])
        XCTAssertEqual(initialTokenCountRequests, [])

        guard let beta = snapshot.sessions.first(where: { $0.sessionID == "beta" }) else {
            return XCTFail("Missing beta")
        }
        viewModel.selectSession(beta)
        try await self.waitUntil(timeout: 1) {
            let ids = await service.messageSessionIDs()
            return ids == ["beta"]
        }
        try await self.waitUntil(timeout: 1) { viewModel.selectedSessionTokenCount == 120 }
        let tokenCountRequests = await service.tokenCountSessionIDs()
        XCTAssertEqual(tokenCountRequests, [])
    }

    func testSelectSessionFallsBackToLoadingTokenCountWhenSnapshotHasNoTokens() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)
        await service.enqueueLoadCurrent(
            RecordsSnapshot(
                generatedAt: self.date("2026-04-21T10:00:00Z"),
                refreshMode: .incremental,
                models: [],
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "initial",
                        modelID: "gpt-5.4",
                        startedAt: self.date("2026-04-21T09:00:00Z"),
                        lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                        isArchived: false,
                        totalTokens: 0
                    ),
                ],
                warnings: []
            )
        )
        await service.setTokenCounts(["initial": 200])

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }
        guard let initial = viewModel.snapshot?.sessions.first else {
            return XCTFail("Missing initial")
        }
        viewModel.selectSession(initial)
        try await self.waitUntil(timeout: 1) {
            let tokenRequestIDs = await service.tokenCountSessionIDs()
            return tokenRequestIDs == ["initial"]
        }
        XCTAssertEqual(viewModel.selectedSessionTokenCount, 200)
    }

    func testRefreshAllOnlyLoadsSelectedDetailAfterListSnapshot() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)
        await service.enqueueLoadCurrent(self.makeSnapshot(sessionID: "initial", modelID: "gpt-5.4"))

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }
        let initialTokenCountRequests = await service.tokenCountSessionIDs()
        XCTAssertEqual(initialTokenCountRequests, [])

        guard let initial = viewModel.snapshot?.sessions.first else {
            return XCTFail("Missing initial")
        }
        viewModel.selectSession(initial)
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenRequestIDsBeforeRefresh = await service.tokenCountSessionIDs()
        XCTAssertEqual(tokenRequestIDsBeforeRefresh, [])

        viewModel.refreshAll(timeout: 1)
        try await self.waitUntil(timeout: 1) {
            let count = await service.refreshAllCount()
            return count == 1
        }
        await service.resumeRefreshAll(with: .success(self.makeSnapshot(sessionID: "initial", modelID: "gpt-5.4")))
        try await self.waitUntil(timeout: 1) { viewModel.isRefreshingAll == false }

        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenRequestIDs = await service.tokenCountSessionIDs()
        XCTAssertEqual(tokenRequestIDs, [])
        XCTAssertEqual(viewModel.selectedSessionTokenCount, 200)
    }

    func testDirectoryItemsUseConsecutiveDisplayIndexesFromFirstVisibleMessage() async throws {
        let service = RecordsSnapshotServiceStub()
        let viewModel = SettingsRecordsViewModel(service: service)
        await service.enqueueLoadCurrent(self.makeSnapshot(sessionID: "initial", modelID: "gpt-5.4"))
        await service.setMessages(
            [
                "initial": [
                    SessionMessageRecord(role: "assistant", content: "System summary", timestamp: self.date("2026-04-21T09:00:00Z")),
                    SessionMessageRecord(role: "tool", content: "tool output", timestamp: self.date("2026-04-21T09:00:01Z")),
                    SessionMessageRecord(role: "user", content: "First real user prompt", timestamp: self.date("2026-04-21T09:00:02Z")),
                    SessionMessageRecord(role: "assistant", content: "answer", timestamp: self.date("2026-04-21T09:00:03Z")),
                    SessionMessageRecord(role: "user", content: "Second user prompt", timestamp: self.date("2026-04-21T09:00:04Z")),
                ],
            ]
        )

        viewModel.loadCurrent()
        try await self.waitUntil(timeout: 1) { viewModel.snapshot != nil }
        guard let initial = viewModel.snapshot?.sessions.first else {
            return XCTFail("Missing initial")
        }
        viewModel.selectSession(initial)
        try await self.waitUntil(timeout: 1) { viewModel.directoryItems.count == 3 }

        XCTAssertEqual(viewModel.directoryItems.map(\.displayIndex), [1, 2, 3])
        XCTAssertEqual(viewModel.directoryItems.map(\.title), ["System summary", "First real user prompt", "Second user prompt"])
    }

    private func makeSnapshot(sessionID: String, modelID: String) -> RecordsSnapshot {
        RecordsSnapshot(
            generatedAt: self.date("2026-04-21T10:00:00Z"),
            refreshMode: .incremental,
            models: [
                HistoricalModelRecord(
                    modelID: modelID,
                    sessionCount: 1,
                    lastSeenAt: self.date("2026-04-21T10:00:00Z")
                ),
            ],
            sessions: [
                HistoricalSessionRecord(
                    sessionID: sessionID,
                    modelID: modelID,
                    startedAt: self.date("2026-04-21T09:00:00Z"),
                    lastActivityAt: self.date("2026-04-21T10:00:00Z"),
                    isArchived: false,
                    totalTokens: 200
                ),
            ],
            warnings: []
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601Parsing.parse(value) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "SettingsRecordsViewModelTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await condition() == false {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor RecordsSnapshotServiceStub: RecordsSnapshotServing {
    private(set) var loadCurrentCallCount = 0
    private(set) var refreshAllCallCount = 0
    private(set) var messageRequests: [String] = []
    private(set) var tokenCountRequests: [String] = []

    private var pendingLoadCurrentContinuations: [CheckedContinuation<RecordsSnapshot, Error>] = []
    private var pendingRefreshAllContinuations: [CheckedContinuation<RecordsSnapshot, Error>] = []
    private var pendingStreamContinuations: [AsyncThrowingStream<RecordsListEvent, Error>.Continuation] = []
    private var queuedLoadCurrentResults: [Result<RecordsSnapshot, Error>] = []
    private var queuedStreamResults: [Result<[RecordsListEvent], Error>] = []
    private var messages: [String: [SessionMessageRecord]] = [:]
    private var tokenCounts: [String: Int?] = [:]

    func enqueueLoadCurrent(_ snapshot: RecordsSnapshot) {
        self.queuedLoadCurrentResults.append(.success(snapshot))
    }

    func enqueueStreamEvents(_ events: [RecordsListEvent]) {
        self.queuedStreamResults.append(.success(events))
    }

    func loadCurrentCount() -> Int {
        self.loadCurrentCallCount
    }

    func refreshAllCount() -> Int {
        self.refreshAllCallCount
    }

    func messageSessionIDs() -> [String] {
        self.messageRequests
    }

    func tokenCountSessionIDs() -> [String] {
        self.tokenCountRequests
    }

    func setMessages(_ messages: [String: [SessionMessageRecord]]) {
        self.messages = messages
    }

    func setTokenCounts(_ tokenCounts: [String: Int?]) {
        self.tokenCounts = tokenCounts
    }

    nonisolated func streamCurrentList() -> AsyncThrowingStream<RecordsListEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.registerStreamContinuation(continuation)
            }
        }
    }

    func loadCurrent() async throws -> RecordsSnapshot {
        self.loadCurrentCallCount += 1
        if self.queuedLoadCurrentResults.isEmpty == false {
            return try self.queuedLoadCurrentResults.removeFirst().get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingLoadCurrentContinuations.append(continuation)
        }
    }

    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot {
        _ = timeout
        self.refreshAllCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRefreshAllContinuations.append(continuation)
        }
    }

    func loadMessages(for session: HistoricalSessionRecord) async throws -> [SessionMessageRecord] {
        self.messageRequests.append(session.sessionID)
        return self.messages[session.sessionID] ?? []
    }

    func loadTokenCount(for session: HistoricalSessionRecord) async throws -> Int? {
        self.tokenCountRequests.append(session.sessionID)
        return self.tokenCounts[session.sessionID] ?? nil
    }

    func deleteSessions(_ sessions: [HistoricalSessionRecord]) async -> [SessionDeleteResult] {
        sessions.map {
            SessionDeleteResult(sessionID: $0.sessionID, sourcePath: $0.sourcePath, didDelete: true, errorMessage: nil)
        }
    }

    func launchResumeTerminal(for session: HistoricalSessionRecord) async throws {
        _ = session
    }

    func resumeStream(with result: Result<[RecordsListEvent], Error>) {
        guard self.pendingStreamContinuations.isEmpty == false else {
            self.queuedStreamResults.append(result)
            return
        }
        let continuation = self.pendingStreamContinuations.removeFirst()
        self.finishStreamContinuation(continuation, with: result)
    }

    func yieldStreamEvent(_ event: RecordsListEvent) {
        guard let continuation = self.pendingStreamContinuations.first else {
            self.queuedStreamResults.append(.success([event]))
            return
        }
        continuation.yield(event)
    }

    func finishStream(with result: Result<[RecordsListEvent], Error> = .success([])) {
        guard self.pendingStreamContinuations.isEmpty == false else {
            self.queuedStreamResults.append(result)
            return
        }
        let continuation = self.pendingStreamContinuations.removeFirst()
        self.finishStreamContinuation(continuation, with: result)
    }

    func resumeLoadCurrent(with result: Result<RecordsSnapshot, Error>) {
        guard self.pendingLoadCurrentContinuations.isEmpty == false else { return }
        let continuation = self.pendingLoadCurrentContinuations.removeFirst()
        continuation.resume(with: result)
    }

    func resumeRefreshAll(with result: Result<RecordsSnapshot, Error>) {
        guard self.pendingRefreshAllContinuations.isEmpty == false else { return }
        let continuation = self.pendingRefreshAllContinuations.removeFirst()
        continuation.resume(with: result)
    }

    private func registerStreamContinuation(
        _ continuation: AsyncThrowingStream<RecordsListEvent, Error>.Continuation
    ) {
        self.loadCurrentCallCount += 1
        if self.queuedStreamResults.isEmpty == false {
            self.finishStreamContinuation(continuation, with: self.queuedStreamResults.removeFirst())
            return
        }
        if self.queuedLoadCurrentResults.isEmpty == false {
            let result: Result<[RecordsListEvent], Error> = self.queuedLoadCurrentResults.removeFirst().map { snapshot in
                [RecordsListEvent.finished(snapshot)]
            }
            self.finishStreamContinuation(continuation, with: result)
            return
        }
        self.pendingStreamContinuations.append(continuation)
    }

    private func finishStreamContinuation(
        _ continuation: AsyncThrowingStream<RecordsListEvent, Error>.Continuation,
        with result: Result<[RecordsListEvent], Error>
    ) {
        switch result {
        case .success(let events):
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }
}

private enum RecordsViewModelTestError: LocalizedError {
    case streamFailed

    var errorDescription: String? {
        "stream failed"
    }
}

private actor SlowRecordsSourceSnapshotLoader: RecordsSourceSnapshotLoading {
    private let rebuildDelayNanoseconds: UInt64

    init(rebuildDelayNanoseconds: UInt64) {
        self.rebuildDelayNanoseconds = rebuildDelayNanoseconds
    }

    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot {
        switch refreshMode {
        case .incremental:
            return RecordsSourceSnapshot(
                generatedAt: ISO8601Parsing.parse("2026-04-21T10:00:00Z") ?? Date(timeIntervalSince1970: 0),
                refreshMode: .incremental,
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "initial",
                        modelID: "gpt-5.4",
                        startedAt: ISO8601Parsing.parse("2026-04-21T09:00:00Z") ?? Date(timeIntervalSince1970: 0),
                        lastActivityAt: ISO8601Parsing.parse("2026-04-21T10:00:00Z") ?? Date(timeIntervalSince1970: 0),
                        isArchived: false,
                        totalTokens: 100
                    ),
                ],
                warnings: []
            )
        case .rebuildAll:
            try? await Task.sleep(nanoseconds: self.rebuildDelayNanoseconds)
            return RecordsSourceSnapshot(
                generatedAt: ISO8601Parsing.parse("2026-04-21T10:30:00Z") ?? Date(timeIntervalSince1970: 0),
                refreshMode: .rebuildAll,
                sessions: [
                    HistoricalSessionRecord(
                        sessionID: "late-refresh",
                        modelID: "gpt-5.4-mini",
                        startedAt: ISO8601Parsing.parse("2026-04-21T10:10:00Z") ?? Date(timeIntervalSince1970: 0),
                        lastActivityAt: ISO8601Parsing.parse("2026-04-21T10:30:00Z") ?? Date(timeIntervalSince1970: 0),
                        isArchived: false,
                        totalTokens: 140
                    ),
                ],
                warnings: []
            )
        }
    }
}
