import AppKit
import Foundation
import SQLite3

private let sessionLogStoreSQLiteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SessionLogStore: @unchecked Sendable, ProgressiveRecordsSourceSnapshotLoading, SessionMessageLoading, SessionDeleting, SessionResumeLaunching {
    static let shared = SessionLogStore()

    enum TaskLifecycleState: String, Codable, Equatable {
        case running
        case completed
    }

    struct SessionRecord: Codable, Equatable {
        let id: String
        let startedAt: Date
        let lastActivityAt: Date
        let isArchived: Bool
        let model: String
        let taskLifecycleState: TaskLifecycleState?
        let title: String?
        let summary: String?
        let projectDirectory: String?
        let sourcePath: String?

        enum CodingKeys: String, CodingKey {
            case id
            case startedAt
            case lastActivityAt
            case isArchived
            case model
            case taskLifecycleState
            case title
            case summary
            case projectDirectory
            case sourcePath
        }

        init(
            id: String,
            startedAt: Date,
            lastActivityAt: Date,
            isArchived: Bool,
            model: String,
            taskLifecycleState: TaskLifecycleState?,
            title: String? = nil,
            summary: String? = nil,
            projectDirectory: String? = nil,
            sourcePath: String? = nil
        ) {
            self.id = id
            self.startedAt = startedAt
            self.lastActivityAt = lastActivityAt
            self.isArchived = isArchived
            self.model = model
            self.taskLifecycleState = taskLifecycleState
            self.title = title
            self.summary = summary
            self.projectDirectory = projectDirectory
            self.sourcePath = sourcePath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.startedAt = try container.decode(Date.self, forKey: .startedAt)
            self.lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
            self.isArchived = try container.decode(Bool.self, forKey: .isArchived)
            self.model = try container.decode(String.self, forKey: .model)
            self.taskLifecycleState = try container.decodeIfPresent(TaskLifecycleState.self, forKey: .taskLifecycleState)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
            self.projectDirectory = try container.decodeIfPresent(String.self, forKey: .projectDirectory)
            self.sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        }
    }

    struct SessionLifecycleRecord: Codable, Equatable {
        let id: String
        let startedAt: Date
        let lastActivityAt: Date
        let isArchived: Bool
        let taskLifecycleState: TaskLifecycleState?
    }

    private struct FileFingerprint: Codable, Equatable {
        let fileSize: Int
        let modificationDate: Date
    }

    private struct CachedSessionRecord: Codable {
        let fingerprint: FileFingerprint
        let record: SessionRecord?

    }

    private struct CachedSessionLifecycleRecord: Codable {
        let fingerprint: FileFingerprint
        let record: SessionLifecycleRecord?
    }

    private struct RefreshedCachedSessions {
        let records: [CachedSessionRecord]
        let warnings: [RecordsSnapshotWarning]
    }

    private struct IncrementalRecordsSourceSnapshotProgress {
        let snapshot: RecordsSourceSnapshot
        let isFinished: Bool
    }

    private struct SessionFileScanResult {
        let files: [URL]
        let warnings: [RecordsSnapshotWarning]
    }

    private struct ParsedSessionResult {
        let cachedRecord: CachedSessionRecord
        let warning: RecordsSnapshotWarning?
    }

    private struct PersistedCache: Codable {
        let version: Int
        let files: [String: CachedSessionRecord]
    }

    private let fileManager: FileManager
    private let codexRootURL: URL
    private let persistedCacheURL: URL
    private let queue = DispatchQueue(label: "lzl.codexbar.session-log-store", qos: .utility)
    private let persistedCacheVersion = 5

    private var sessionCache: [URL: CachedSessionRecord] = [:]
    private var sessionLifecycleCache: [URL: CachedSessionLifecycleRecord] = [:]
    private static let queueWaitDiagnosticsThresholdMilliseconds = 250.0

    init(
        fileManager: FileManager = .default,
        codexRootURL: URL = CodexPaths.codexRoot,
        persistedCacheURL: URL = CodexPaths.recordsSessionCacheURL
    ) {
        self.fileManager = fileManager
        self.codexRootURL = codexRootURL
        self.persistedCacheURL = persistedCacheURL

        let loadedSessionCache = self.loadPersistedCache()
        self.sessionCache = loadedSessionCache
    }

    func reduceSessions<Result>(
        into initialResult: Result,
        _ update: (inout Result, SessionRecord) -> Void
    ) -> Result {
        self.queue.sync {
            var result = initialResult
            self.reduceSessionsLocked(into: &result, update)
            return result
        }
    }

    func sessionRecords() -> [SessionRecord] {
        self.reduceSessions(into: [SessionRecord]()) { result, record in
            result.append(record)
        }
    }

    func currentSessionRecords() -> [SessionRecord] {
        self.sessionRecords().filter { $0.isArchived == false }
    }

    func currentSessionLifecycleRecords(
        matchingSessionIDs: Set<String>? = nil
    ) -> [SessionLifecycleRecord] {
        guard matchingSessionIDs?.isEmpty != true else { return [] }

        return self.reduceSessionLifecycle(
            into: [SessionLifecycleRecord](),
            matchingSessionIDs: matchingSessionIDs
        ) { result, record in
            result.append(record)
        }
        .filter { $0.isArchived == false }
    }

    func loadRecordsSourceSnapshot(
        refreshMode: RecordsRefreshMode
    ) async throws -> RecordsSourceSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.asyncOnQueue(operation: "loadRecordsSourceSnapshot") {
                do {
                    let snapshot = try self.loadRecordsSourceSnapshotLocked(refreshMode: refreshMode)
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadPersistedRecordsSourceSnapshot() async throws -> RecordsSourceSnapshot {
        await withCheckedContinuation { continuation in
            self.asyncOnQueue(operation: "loadPersistedRecordsSourceSnapshot") {
                let start = DispatchTime.now()
                let snapshot = self.loadPersistedRecordsSourceSnapshotLocked()
                RecordsDiagnostics.record("records.store.persisted.complete", fields: [
                    "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: start)),
                    "sessions": "\(snapshot.sessions.count)",
                    "warnings": "\(snapshot.warnings.count)",
                ])
                continuation.resume(returning: snapshot)
            }
        }
    }

    func streamIncrementalRecordsSourceSnapshots() -> AsyncThrowingStream<RecordsSourceListEvent, Error> {
        AsyncThrowingStream { continuation in
            self.asyncOnQueue(operation: "streamIncrementalRecordsSourceSnapshots") {
                let start = DispatchTime.now()
                RecordsDiagnostics.record("records.store.incremental.start")
                do {
                    let eventCount = try self.streamIncrementalRecordsSourceSnapshotProgressLocked { progress in
                        if progress.isFinished {
                            continuation.yield(.finished(progress.snapshot))
                        } else {
                            continuation.yield(.partial(progress.snapshot))
                        }
                    }
                    RecordsDiagnostics.record("records.store.incremental.complete", fields: [
                        "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: start)),
                        "event_count": "\(eventCount)",
                    ])
                    continuation.finish()
                } catch {
                    RecordsDiagnostics.record("records.store.incremental.failed", level: "error", fields: [
                        "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: start)),
                        "error": error.localizedDescription,
                    ])
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func loadMessages(for session: HistoricalSessionRecord) async throws -> [SessionMessageRecord] {
        try await withCheckedThrowingContinuation { continuation in
            self.asyncOnQueue(operation: "loadMessages") {
                do {
                    let messages = try self.loadMessagesLocked(for: session)
                    continuation.resume(returning: messages)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteSessions(_ sessions: [HistoricalSessionRecord]) async -> [SessionDeleteResult] {
        await withCheckedContinuation { continuation in
            self.asyncOnQueue(operation: "deleteSessions") {
                let results = sessions.map { self.deleteSessionLocked($0) }
                continuation.resume(returning: results)
            }
        }
    }

    func launchResumeTerminal(for session: HistoricalSessionRecord) async throws {
        guard let resumeCommand = session.resumeCommand, resumeCommand.isEmpty == false else { return }
        try await MainActor.run {
            try Self.launchTerminal(command: resumeCommand, cwd: session.projectDirectory)
        }
    }

    private func asyncOnQueue(operation: String, execute work: @escaping () -> Void) {
        let enqueuedAt = DispatchTime.now()
        self.queue.async {
            let waitedMilliseconds = RecordsDiagnostics.elapsedMilliseconds(since: enqueuedAt)
            if waitedMilliseconds >= Self.queueWaitDiagnosticsThresholdMilliseconds {
                RecordsDiagnostics.record("records.store.queue.waited", fields: [
                    "operation": operation,
                    "waited_ms": Self.formatMilliseconds(waitedMilliseconds),
                ])
            }
            work()
        }
    }

    private func reduceSessionsLocked<Result>(
        into result: inout Result,
        _ update: (inout Result, SessionRecord) -> Void
    ) {
        self.reduceCachedSessionsLocked(into: &result) { partialResult, cached in
            if let record = cached.record {
                update(&partialResult, record)
            }
        }
    }

    private func reduceCachedSessionsLocked<Result>(
        into result: inout Result,
        _ update: (inout Result, CachedSessionRecord) -> Void
    ) {
        for cached in self.refreshCachedSessionsLocked() {
            update(&result, cached)
        }
    }

    private func refreshCachedSessionsLocked() -> [CachedSessionRecord] {
        (try? self.refreshCachedSessionsLocked(
            rebuildAll: false,
            collectWarnings: false
        ).records) ?? Array(self.sessionCache.values)
    }

    private func refreshCachedSessionsLocked(
        rebuildAll: Bool,
        collectWarnings: Bool
    ) throws -> RefreshedCachedSessions {
        let scanResult = try self.sessionFilesThrowing(collectWarnings: collectWarnings)
        let files = scanResult.files
        let previousSessionCache = rebuildAll ? [:] : self.sessionCache

        var nextSessionCache: [URL: CachedSessionRecord] = [:]
        nextSessionCache.reserveCapacity(files.count)

        var cachedSessions: [CachedSessionRecord] = []
        cachedSessions.reserveCapacity(files.count)

        var warnings = scanResult.warnings
        warnings.reserveCapacity(files.count)

        for fileURL in files {
            autoreleasepool {
                guard let fingerprint = self.fingerprint(for: fileURL) else {
                    if collectWarnings {
                        warnings.append(
                            RecordsSnapshotWarning(
                                sessionFilePath: fileURL.path,
                                kind: .unreadableSessionFile,
                                message: "Unable to read session file metadata."
                            )
                        )
                    }
                    return
                }

                if let cached = previousSessionCache[fileURL],
                   cached.fingerprint == fingerprint,
                   collectWarnings == false || cached.record != nil {
                    nextSessionCache[fileURL] = cached
                    cachedSessions.append(cached)
                    return
                }

                let parsed = self.parseSession(
                    fileURL,
                    fingerprint: fingerprint,
                    collectWarning: collectWarnings
                )
                nextSessionCache[fileURL] = parsed.cachedRecord
                cachedSessions.append(parsed.cachedRecord)
                if let warning = parsed.warning {
                    warnings.append(warning)
                }
            }
        }

        self.sessionCache = nextSessionCache
        self.persistSessionCache(nextSessionCache)

        return RefreshedCachedSessions(
            records: cachedSessions,
            warnings: warnings.sorted { lhs, rhs in
                if lhs.sessionFilePath != rhs.sessionFilePath {
                    return lhs.sessionFilePath < rhs.sessionFilePath
                }
                if lhs.kind != rhs.kind {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.message < rhs.message
            }
        )
    }

    private func loadRecordsSourceSnapshotLocked(
        refreshMode: RecordsRefreshMode
    ) throws -> RecordsSourceSnapshot {
        if refreshMode == .incremental {
            return try self.loadFastRecordsSourceSnapshotLocked(refreshMode: refreshMode)
        }

        let refreshed = try self.refreshCachedSessionsLocked(
            rebuildAll: refreshMode == .rebuildAll,
            collectWarnings: true
        )

        return RecordsSourceSnapshot(
            generatedAt: Date(),
            refreshMode: refreshMode,
            sessions: self.historicalSessionRecords(from: refreshed.records),
            warnings: refreshed.warnings
        )
    }

    private func loadFastRecordsSourceSnapshotLocked(
        refreshMode: RecordsRefreshMode
    ) throws -> RecordsSourceSnapshot {
        let scanResult = try self.sessionFilesThrowing(collectWarnings: true)
        var cachedSessions: [CachedSessionRecord] = []
        cachedSessions.reserveCapacity(scanResult.files.count)

        var warnings = scanResult.warnings
        warnings.reserveCapacity(scanResult.files.count)

        for fileURL in scanResult.files {
            autoreleasepool {
                guard let fingerprint = self.fingerprint(for: fileURL) else {
                    warnings.append(
                        RecordsSnapshotWarning(
                            sessionFilePath: fileURL.path,
                            kind: .unreadableSessionFile,
                            message: "Unable to read session file metadata."
                        )
                    )
                    return
                }

                if let cached = self.sessionCache[fileURL],
                   cached.fingerprint == fingerprint,
                   let record = cached.record {
                    cachedSessions.append(
                        CachedSessionRecord(
                            fingerprint: cached.fingerprint,
                            record: self.record(record, fillingSourcePathFrom: fileURL)
                        )
                    )
                    return
                }

                let parsed = self.parseSessionIndex(fileURL, fingerprint: fingerprint)
                cachedSessions.append(parsed.cachedRecord)
                if let warning = parsed.warning {
                    warnings.append(warning)
                }
            }
        }

        return RecordsSourceSnapshot(
            generatedAt: Date(),
            refreshMode: refreshMode,
            sessions: self.historicalSessionRecords(from: cachedSessions),
            warnings: warnings.sorted { lhs, rhs in
                if lhs.sessionFilePath != rhs.sessionFilePath {
                    return lhs.sessionFilePath < rhs.sessionFilePath
                }
                if lhs.kind != rhs.kind {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.message < rhs.message
            }
        )
    }

    private func loadPersistedRecordsSourceSnapshotLocked() -> RecordsSourceSnapshot {
        let start = DispatchTime.now()
        let cachedSessions = Array(self.sessionCache.values)
        let sessions = self.historicalSessionRecords(
            from: cachedSessions,
            loadThreadTitles: false
        )
        RecordsDiagnostics.record("records.store.persisted.snapshot", fields: [
            "cache_entries": "\(cachedSessions.count)",
            "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: start)),
            "sessions": "\(sessions.count)",
        ])
        return RecordsSourceSnapshot(
            generatedAt: Date(),
            refreshMode: .incremental,
            sessions: sessions,
            warnings: []
        )
    }

    private func streamIncrementalRecordsSourceSnapshotProgressLocked(
        yieldProgress: (IncrementalRecordsSourceSnapshotProgress) -> Void
    ) throws -> Int {
        let totalStart = DispatchTime.now()
        let scanStart = DispatchTime.now()
        let scanResult = try self.sessionFilesThrowing(collectWarnings: true)
        RecordsDiagnostics.record("records.store.incremental.scan", fields: [
            "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: scanStart)),
            "files": "\(scanResult.files.count)",
            "warnings": "\(scanResult.warnings.count)",
        ])
        var nextSessionCache: [URL: CachedSessionRecord] = [:]
        nextSessionCache.reserveCapacity(scanResult.files.count)

        var cachedSessions: [CachedSessionRecord] = []
        cachedSessions.reserveCapacity(scanResult.files.count)

        var warnings = scanResult.warnings
        warnings.reserveCapacity(scanResult.files.count)

        let previousSessionCache = self.sessionCache
        var eventCount = 0
        let batchSize = 20
        let batchInterval: TimeInterval = 0.150
        var filesSinceLastPublish = 0
        var lastPublishDate = Date()
        var processedFileCount = 0
        var cacheHitCount = 0
        var parsedIndexCount = 0
        var unreadableMetadataCount = 0

        func makeProgressSnapshot(isFinished: Bool) -> IncrementalRecordsSourceSnapshotProgress {
            let snapshotStart = DispatchTime.now()
            let sessions = self.historicalSessionRecords(
                from: cachedSessions,
                loadThreadTitles: isFinished
            )
            RecordsDiagnostics.record("records.store.incremental.makeSnapshot", fields: [
                "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: snapshotStart)),
                "finished": "\(isFinished)",
                "load_thread_titles": "\(isFinished)",
                "processed_files": "\(processedFileCount)",
                "sessions": "\(sessions.count)",
                "total_elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: totalStart)),
                "warnings": "\(warnings.count)",
            ])
            return IncrementalRecordsSourceSnapshotProgress(
                snapshot: RecordsSourceSnapshot(
                    generatedAt: Date(),
                    refreshMode: .incremental,
                    sessions: sessions,
                    warnings: warnings.sorted { lhs, rhs in
                        if lhs.sessionFilePath != rhs.sessionFilePath {
                            return lhs.sessionFilePath < rhs.sessionFilePath
                        }
                        if lhs.kind != rhs.kind {
                            return lhs.kind.rawValue < rhs.kind.rawValue
                        }
                        return lhs.message < rhs.message
                    }
                ),
                isFinished: isFinished
            )
        }

        for fileURL in scanResult.files {
            autoreleasepool {
                processedFileCount += 1
                guard let fingerprint = self.fingerprint(for: fileURL) else {
                    unreadableMetadataCount += 1
                    warnings.append(
                        RecordsSnapshotWarning(
                            sessionFilePath: fileURL.path,
                            kind: .unreadableSessionFile,
                            message: "Unable to read session file metadata."
                        )
                    )
                    filesSinceLastPublish += 1
                    return
                }

                if let cached = previousSessionCache[fileURL],
                   cached.fingerprint == fingerprint,
                   let record = cached.record {
                    cacheHitCount += 1
                    let filledCached = CachedSessionRecord(
                        fingerprint: cached.fingerprint,
                        record: self.record(record, fillingSourcePathFrom: fileURL)
                    )
                    nextSessionCache[fileURL] = filledCached
                    cachedSessions.append(filledCached)
                } else {
                    let parseStart = DispatchTime.now()
                    let parsed = self.parseSessionIndex(fileURL, fingerprint: fingerprint)
                    parsedIndexCount += 1
                    RecordsDiagnostics.record("records.store.incremental.parseIndex", level: "debug", fields: [
                        "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: parseStart)),
                        "path": fileURL.path,
                    ])
                    nextSessionCache[fileURL] = parsed.cachedRecord
                    cachedSessions.append(parsed.cachedRecord)
                    if let warning = parsed.warning {
                        warnings.append(warning)
                    }
                }
                filesSinceLastPublish += 1
            }

            let now = Date()
            if filesSinceLastPublish >= batchSize || now.timeIntervalSince(lastPublishDate) >= batchInterval {
                RecordsDiagnostics.record("records.store.incremental.publishPartial", fields: [
                    "cache_hits": "\(cacheHitCount)",
                    "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: totalStart)),
                    "parsed_indexes": "\(parsedIndexCount)",
                    "processed_files": "\(processedFileCount)",
                    "unreadable_metadata": "\(unreadableMetadataCount)",
                ])
                eventCount += 1
                yieldProgress(makeProgressSnapshot(isFinished: false))
                filesSinceLastPublish = 0
                lastPublishDate = now
            }
        }

        self.sessionCache = nextSessionCache
        let persistStart = DispatchTime.now()
        self.persistSessionCache(nextSessionCache)
        RecordsDiagnostics.record("records.store.incremental.persist", fields: [
            "cache_entries": "\(nextSessionCache.count)",
            "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: persistStart)),
        ])

        RecordsDiagnostics.record("records.store.incremental.finish", fields: [
            "cache_hits": "\(cacheHitCount)",
            "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: totalStart)),
            "parsed_indexes": "\(parsedIndexCount)",
            "processed_files": "\(processedFileCount)",
            "unreadable_metadata": "\(unreadableMetadataCount)",
        ])
        eventCount += 1
        yieldProgress(makeProgressSnapshot(isFinished: true))
        return eventCount
    }

    private func shouldPreferRecord(_ lhs: CachedSessionRecord, over rhs: CachedSessionRecord) -> Bool {
        guard let left = lhs.record, let right = rhs.record else { return lhs.record != nil }
        if left.isArchived != right.isArchived { return !left.isArchived }
        if left.lastActivityAt != right.lastActivityAt { return left.lastActivityAt > right.lastActivityAt }
        return left.startedAt < right.startedAt
    }

    private func historicalSessionRecords(
        from cachedSessions: [CachedSessionRecord],
        loadThreadTitles: Bool = true
    ) -> [HistoricalSessionRecord] {
        var preferredRecordBySessionID: [String: CachedSessionRecord] = [:]
        preferredRecordBySessionID.reserveCapacity(cachedSessions.count)
        let threadTitlesBySessionID = loadThreadTitles ? self.loadThreadTitlesBySessionIDLocked() : [:]

        for cached in cachedSessions {
            guard let record = cached.record else { continue }

            if let existing = preferredRecordBySessionID[record.id],
               self.shouldPreferRecord(existing, over: cached) {
                continue
            }
            preferredRecordBySessionID[record.id] = cached
        }

        return preferredRecordBySessionID.values.compactMap { cached in
            guard let record = cached.record else { return nil }
            return HistoricalSessionRecord(
                sessionID: record.id,
                modelID: record.model,
                title: self.listTitle(for: record, threadTitlesBySessionID: threadTitlesBySessionID),
                summary: nil,
                projectDirectory: record.projectDirectory,
                sourcePath: record.sourcePath,
                resumeCommand: "codex resume \(record.id)",
                startedAt: record.startedAt,
                lastActivityAt: record.lastActivityAt,
                isArchived: record.isArchived
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.sessionID < rhs.sessionID
        }
    }

    private func listTitle(
        for record: SessionRecord,
        threadTitlesBySessionID: [String: String]
    ) -> String? {
        if let title = threadTitlesBySessionID[record.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           title.isEmpty == false {
            return title
        }
        return record.projectDirectory.flatMap(Self.pathBasename(_:))
    }

    private func loadThreadTitlesBySessionIDLocked() -> [String: String] {
        let start = DispatchTime.now()
        let stateDatabaseURLs = self.stateDatabaseURLs()
        guard stateDatabaseURLs.isEmpty == false else {
            RecordsDiagnostics.record("records.store.threadTitles.none", fields: [
                "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: start)),
            ])
            return [:]
        }

        var titlesBySessionID: [String: String] = [:]
        var loadedDatabaseCount = 0
        var failedDatabaseCount = 0
        for databaseURL in stateDatabaseURLs {
            let databaseStart = DispatchTime.now()
            guard let databaseTitles = try? self.loadThreadTitles(from: databaseURL) else {
                failedDatabaseCount += 1
                RecordsDiagnostics.record("records.store.threadTitles.databaseFailed", fields: [
                    "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: databaseStart)),
                    "path": databaseURL.path,
                ])
                continue
            }
            loadedDatabaseCount += 1
            RecordsDiagnostics.record("records.store.threadTitles.databaseLoaded", fields: [
                "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: databaseStart)),
                "path": databaseURL.path,
                "titles": "\(databaseTitles.count)",
            ])
            for (sessionID, title) in databaseTitles {
                titlesBySessionID[sessionID] = title
            }
        }
        RecordsDiagnostics.record("records.store.threadTitles.complete", fields: [
            "databases": "\(stateDatabaseURLs.count)",
            "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: start)),
            "failed": "\(failedDatabaseCount)",
            "loaded": "\(loadedDatabaseCount)",
            "titles": "\(titlesBySessionID.count)",
        ])
        return titlesBySessionID
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func stateDatabaseURLs() -> [URL] {
        guard let urls = try? self.fileManager.contentsOfDirectory(
            at: self.codexRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.filter { url in
            guard url.pathExtension == "sqlite" else { return false }
            guard url.deletingPathExtension().lastPathComponent.hasPrefix("state_") else { return false }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
            return values.isRegularFile == true
        }
        .sorted { lhs, rhs in
            self.stateDatabaseVersion(lhs) < self.stateDatabaseVersion(rhs)
        }
    }

    private func stateDatabaseVersion(_ url: URL) -> Int {
        let filename = url.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix("state_") else { return 0 }
        return Int(filename.dropFirst("state_".count)) ?? 0
    }

    private func loadThreadTitles(from databaseURL: URL) throws -> [String: String] {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            sqlite3_close(database)
            return [:]
        }
        defer { sqlite3_close(database) }

        guard try self.sqliteTableExists("threads", in: database),
              try self.sqliteTableColumns(in: database, table: "threads").isSuperset(of: ["id", "title"]) else {
            return [:]
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT id, title FROM threads WHERE title IS NOT NULL AND TRIM(title) != ''",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        var titlesBySessionID: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let titlePointer = sqlite3_column_text(statement, 1) else { continue }
            let sessionID = String(cString: idPointer)
            let title = String(cString: titlePointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sessionID.isEmpty == false, title.isEmpty == false else { continue }
            titlesBySessionID[sessionID] = title
        }
        return titlesBySessionID
    }

    private func sqliteTableExists(_ table: String, in database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, table, -1, sessionLogStoreSQLiteTransientDestructor) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func sqliteTableColumns(in database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 1) else { continue }
            columns.insert(String(cString: namePointer))
        }
        return columns
    }

    private func reduceSessionLifecycle<Result>(
        into initialResult: Result,
        matchingSessionIDs: Set<String>?,
        _ update: (inout Result, SessionLifecycleRecord) -> Void
    ) -> Result {
        self.queue.sync {
            var result = initialResult
            self.reduceCachedSessionLifecycleLocked(
                into: &result,
                matchingSessionIDs: matchingSessionIDs
            ) { partialResult, cached in
                if let record = cached.record {
                    update(&partialResult, record)
                }
            }
            return result
        }
    }

    private func reduceCachedSessionLifecycleLocked<Result>(
        into result: inout Result,
        matchingSessionIDs: Set<String>?,
        _ update: (inout Result, CachedSessionLifecycleRecord) -> Void
    ) {
        let files = self.sessionFiles()
        var nextLifecycleCache: [URL: CachedSessionLifecycleRecord] = [:]
        nextLifecycleCache.reserveCapacity(files.count)

        for fileURL in files {
            autoreleasepool {
                if let matchingSessionIDs,
                   self.matchesSessionLifecycleFilter(
                        fileURL: fileURL,
                        sessionIDs: matchingSessionIDs
                   ) == false {
                    return
                }

                guard let fingerprint = self.fingerprint(for: fileURL) else { return }

                if let cached = self.sessionLifecycleCache[fileURL], cached.fingerprint == fingerprint {
                    nextLifecycleCache[fileURL] = cached
                    update(&result, cached)
                    return
                }

                if let cachedSession = self.sessionCache[fileURL],
                   cachedSession.fingerprint == fingerprint,
                   let record = cachedSession.record {
                    let lifecycleRecord = CachedSessionLifecycleRecord(
                        fingerprint: fingerprint,
                        record: SessionLifecycleRecord(
                            id: record.id,
                            startedAt: record.startedAt,
                            lastActivityAt: record.lastActivityAt,
                            isArchived: record.isArchived,
                            taskLifecycleState: record.taskLifecycleState
                        )
                    )
                    nextLifecycleCache[fileURL] = lifecycleRecord
                    update(&result, lifecycleRecord)
                    return
                }

                let cached = self.parseSessionLifecycle(fileURL, fingerprint: fingerprint)
                nextLifecycleCache[fileURL] = cached
                update(&result, cached)
            }
        }

        self.sessionLifecycleCache = nextLifecycleCache
    }

    private func matchesSessionLifecycleFilter(
        fileURL: URL,
        sessionIDs: Set<String>
    ) -> Bool {
        let filename = fileURL.lastPathComponent
        return sessionIDs.contains { filename.contains($0) }
    }

    private func sessionFiles() -> [URL] {
        (try? self.sessionFilesThrowing(collectWarnings: false).files) ?? []
    }

    private func sessionFilesThrowing(
        collectWarnings: Bool
    ) throws -> SessionFileScanResult {
        let directories = [
            self.codexRootURL.appendingPathComponent("sessions", isDirectory: true),
            self.codexRootURL.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        var files: [URL] = []
        var warnings: [RecordsSnapshotWarning] = []
        for directory in directories {
            guard self.fileManager.fileExists(atPath: directory.path) else { continue }

            var enumeratorDidFail = false
            guard let enumerator = self.fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                errorHandler: { fileURL, error in
                    guard collectWarnings else {
                        enumeratorDidFail = true
                        return false
                    }

                    warnings.append(
                        RecordsSnapshotWarning(
                            sessionFilePath: fileURL.path,
                            kind: .unreadableSessionFile,
                            message: error.localizedDescription
                        )
                    )
                    return true
                }
            ) else {
                throw RecordsSourceSnapshotError.directoryEnumerationFailed(path: directory.path)
            }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                files.append(url)
            }

            if enumeratorDidFail {
                throw RecordsSourceSnapshotError.directoryEnumerationFailed(path: directory.path)
            }
        }
        return SessionFileScanResult(
            files: files.sorted { $0.path < $1.path },
            warnings: warnings
        )
    }

    private func fingerprint(for fileURL: URL) -> FileFingerprint? {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }

        return FileFingerprint(
            fileSize: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate ?? .distantPast
        )
    }

    private func parseSession(
        _ fileURL: URL,
        fingerprint: FileFingerprint,
        collectWarning: Bool
    ) -> ParsedSessionResult {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var taskLifecycleState: TaskLifecycleState?
        var projectDirectory: String?
        var firstUserMessage: String?
        var latestMessage: String?
        var isSubagentSession = false

        let didRead = self.enumerateLines(in: fileURL) { line in
            self.consumeSessionMetadata(
                in: line,
                sessionID: &sessionID,
                sessionDate: &sessionDate,
                projectDirectory: &projectDirectory,
                isSubagentSession: &isSubagentSession
            )
            self.consumeTurnContext(in: line, model: &model)
            self.consumeTaskLifecycle(in: line, taskLifecycleState: &taskLifecycleState)
            self.consumeMessageSummary(
                in: line,
                firstUserMessage: &firstUserMessage,
                latestMessage: &latestMessage
            )
        }

        let record: SessionRecord?
        let warning: RecordsSnapshotWarning?
        let resolvedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)

        if didRead,
           let startedAt = sessionDate,
           let resolvedModel,
           resolvedModel.isEmpty == false,
           isSubagentSession == false {
            record = SessionRecord(
                id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: startedAt,
                lastActivityAt: fingerprint.modificationDate,
                isArchived: self.isArchivedSessionFile(fileURL),
                model: resolvedModel,
                taskLifecycleState: taskLifecycleState,
                title: firstUserMessage.map { Self.truncated($0, limit: 80) }
                    ?? projectDirectory.flatMap(Self.pathBasename(_:)),
                summary: latestMessage.map { Self.truncated($0, limit: 160) },
                projectDirectory: projectDirectory,
                sourcePath: fileURL.path
            )
            warning = nil
        } else {
            record = nil
            if collectWarning {
                warning = RecordsSnapshotWarning(
                    sessionFilePath: fileURL.path,
                    kind: didRead ? .incompleteSessionRecord : .unreadableSessionFile,
                    message: didRead
                        ? "Missing required session metadata or model."
                        : "Unable to read session file."
                )
            } else {
                warning = nil
            }
        }

        return ParsedSessionResult(
            cachedRecord: CachedSessionRecord(
                fingerprint: fingerprint,
                record: record
            ),
            warning: warning
        )
    }

    private func parseSessionIndex(
        _ fileURL: URL,
        fingerprint: FileFingerprint
    ) -> ParsedSessionResult {
        var sessionID: String?
        var sessionDate: Date?
        var model: String?
        var projectDirectory: String?
        var isSubagentSession = false
        var didReadAnyLine = false

        let metadataRead = self.enumerateHeadLines(in: fileURL, maxLines: 80) { line, stop in
            didReadAnyLine = true
            self.consumeSessionMetadata(
                in: line,
                sessionID: &sessionID,
                sessionDate: &sessionDate,
                projectDirectory: &projectDirectory,
                isSubagentSession: &isSubagentSession
            )
            self.consumeTurnContext(in: line, model: &model)

            if sessionDate != nil,
               model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                stop = true
            }
        }

        _ = metadataRead

        let record: SessionRecord?
        let warning: RecordsSnapshotWarning?
        let resolvedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)

        if didReadAnyLine,
           let startedAt = sessionDate,
           let resolvedModel,
           resolvedModel.isEmpty == false,
           isSubagentSession == false {
            record = SessionRecord(
                id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: startedAt,
                lastActivityAt: fingerprint.modificationDate,
                isArchived: self.isArchivedSessionFile(fileURL),
                model: resolvedModel,
                taskLifecycleState: self.sessionCache[fileURL]?.record?.taskLifecycleState,
                title: projectDirectory.flatMap(Self.pathBasename(_:)),
                summary: nil,
                projectDirectory: projectDirectory,
                sourcePath: fileURL.path
            )
            warning = nil
        } else {
            record = nil
            warning = RecordsSnapshotWarning(
                sessionFilePath: fileURL.path,
                kind: didReadAnyLine ? .incompleteSessionRecord : .unreadableSessionFile,
                message: didReadAnyLine
                    ? "Missing required session metadata or model."
                    : "Unable to read session file."
            )
        }

        return ParsedSessionResult(
            cachedRecord: CachedSessionRecord(
                fingerprint: fingerprint,
                record: record
            ),
            warning: warning
        )
    }

    private func parseSessionLifecycle(
        _ fileURL: URL,
        fingerprint: FileFingerprint
    ) -> CachedSessionLifecycleRecord {
        var sessionID: String?
        var sessionDate: Date?
        var taskLifecycleState: TaskLifecycleState?

        let didRead = self.enumerateLines(in: fileURL) { line in
            self.consumeSessionMetadata(in: line, sessionID: &sessionID, sessionDate: &sessionDate)
            self.consumeTaskLifecycle(in: line, taskLifecycleState: &taskLifecycleState)
        }

        let record: SessionLifecycleRecord?
        if didRead,
           let startedAt = sessionDate {
            record = SessionLifecycleRecord(
                id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                startedAt: startedAt,
                lastActivityAt: fingerprint.modificationDate,
                isArchived: self.isArchivedSessionFile(fileURL),
                taskLifecycleState: taskLifecycleState
            )
        } else {
            record = nil
        }

        return CachedSessionLifecycleRecord(
            fingerprint: fingerprint,
            record: record
        )
    }

    private func isArchivedSessionFile(_ fileURL: URL) -> Bool {
        let archivedRoot = self.codexRootURL
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .standardizedFileURL
            .path
        return fileURL.standardizedFileURL.path.hasPrefix(archivedRoot)
    }

    private func consumeSessionMetadata(
        in line: String,
        sessionID: inout String?,
        sessionDate: inout Date?,
        projectDirectory: inout String?,
        isSubagentSession: inout Bool
    ) {
        guard sessionDate == nil,
              line.contains("\"type\":\"session_meta\"") else { return }

        if let payload = self.payloadSlice(in: line) {
            if sessionID == nil {
                sessionID = self.extractString("id", in: payload)
            }
            if projectDirectory == nil {
                projectDirectory = self.extractString("cwd", in: payload)
            }
            if let timestamp = self.extractString("timestamp", in: payload) {
                sessionDate = ISO8601Parsing.parse(timestamp)
            }
        }

        if sessionDate == nil,
           let payload = self.parsePayload(from: line) {
            if sessionID == nil {
                sessionID = payload["id"] as? String
            }
            if projectDirectory == nil {
                projectDirectory = payload["cwd"] as? String
            }
            if let source = payload["source"] as? [String: Any],
               source["subagent"] != nil {
                isSubagentSession = true
            }
            if let timestamp = payload["timestamp"] as? String {
                sessionDate = ISO8601Parsing.parse(timestamp)
            }
        }
    }

    private func consumeSessionMetadata(in line: String, sessionID: inout String?, sessionDate: inout Date?) {
        var projectDirectory: String?
        var isSubagentSession = false
        self.consumeSessionMetadata(
            in: line,
            sessionID: &sessionID,
            sessionDate: &sessionDate,
            projectDirectory: &projectDirectory,
            isSubagentSession: &isSubagentSession
        )
    }

    private func consumeTurnContext(in line: String, model: inout String?) {
        guard model == nil,
              line.contains("\"type\":\"turn_context\"") else { return }

        if let payload = self.payloadSlice(in: line),
           let currentModel = self.extractString("model", in: payload) {
            model = self.normalizeModel(currentModel)
            return
        }

        if let payload = self.parsePayload(from: line),
           let currentModel = payload["model"] as? String {
            model = self.normalizeModel(currentModel)
        }
    }

    private func consumeTaskLifecycle(
        in line: String,
        taskLifecycleState: inout TaskLifecycleState?
    ) {
        guard line.contains("\"type\":\"event_msg\""),
              line.contains("\"task_"),
              let payload = self.parsePayload(from: line),
              let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "task_started":
            taskLifecycleState = .running
        case "task_complete", "task_cancelled", "task_failed":
            taskLifecycleState = .completed
        default:
            break
        }
    }

    private func consumeMessageSummary(
        in line: String,
        firstUserMessage: inout String?,
        latestMessage: inout String?
    ) {
        guard line.contains("\"type\":\"response_item\""),
              let message = self.parseSessionMessage(from: line) else { return }

        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if message.role == "user",
           firstUserMessage == nil,
           Self.isRealUserPrompt(trimmed) {
            firstUserMessage = trimmed
        }
        latestMessage = trimmed
    }

    private func parseSessionMessage(from line: String) -> SessionMessageRecord? {
        guard let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else { return nil }

        let role: String
        let content: String
        switch payloadType {
        case "message":
            role = payload["role"] as? String ?? "unknown"
            content = self.extractMessageContent(payload["content"])
        case "function_call":
            let name = payload["name"] as? String ?? "unknown"
            role = "assistant"
            content = "[Tool: \(name)]"
        case "function_call_output":
            role = "tool"
            content = payload["output"] as? String ?? ""
        default:
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let timestamp = (object["timestamp"] as? String).flatMap(ISO8601Parsing.parse(_:))
        return SessionMessageRecord(role: role, content: trimmed, timestamp: timestamp)
    }

    private func extractMessageContent(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            return array.compactMap { item -> String? in
                if let string = item as? String {
                    return string
                }
                guard let object = item as? [String: Any] else { return nil }
                if let text = object["text"] as? String {
                    return text
                }
                if let output = object["output"] as? String {
                    return output
                }
                if let type = object["type"] as? String {
                    return "[\(type)]"
                }
                return nil
            }
            .joined(separator: "\n")
        }
        return ""
    }

    private func parsePayload(from line: String) -> [String: Any]? {
        guard let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        return object["payload"] as? [String: Any]
    }

    private func payloadSlice(in line: String) -> Substring? {
        guard let range = line.range(of: "\"payload\":{") else { return nil }
        return line[range.upperBound...]
    }

    private func extractString(_ key: String, in text: Substring) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
        let valueStart = range.upperBound
        guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(text[valueStart..<valueEnd])
    }

    private func loadMessagesLocked(for session: HistoricalSessionRecord) throws -> [SessionMessageRecord] {
        let fileURL = try self.validatedSessionFileURL(for: session)
        var messages: [SessionMessageRecord] = []
        let didRead = self.enumerateLines(in: fileURL) { line in
            if let message = self.parseSessionMessage(from: line) {
                messages.append(message)
            }
        }
        guard didRead else {
            throw SessionLogStoreSessionError.unreadableSession(path: fileURL.path)
        }
        return messages
    }

    private func deleteSessionLocked(_ session: HistoricalSessionRecord) -> SessionDeleteResult {
        do {
            let fileURL = try self.validatedSessionFileURL(for: session)
            if let cachedRecord = self.sessionCache[fileURL].flatMap(\.record),
               cachedRecord.id != session.sessionID {
                throw SessionLogStoreSessionError.sessionIDMismatch(
                    expected: session.sessionID,
                    actual: cachedRecord.id
                )
            }
            try self.fileManager.removeItem(at: fileURL)
            self.sessionCache.removeValue(forKey: fileURL)
            self.sessionLifecycleCache.removeValue(forKey: fileURL)
            self.persistSessionCache(self.sessionCache)
            return SessionDeleteResult(
                sessionID: session.sessionID,
                sourcePath: session.sourcePath,
                didDelete: true,
                errorMessage: nil
            )
        } catch {
            return SessionDeleteResult(
                sessionID: session.sessionID,
                sourcePath: session.sourcePath,
                didDelete: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func validatedSessionFileURL(for session: HistoricalSessionRecord) throws -> URL {
        guard let sourcePath = session.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              sourcePath.isEmpty == false else {
            throw SessionLogStoreSessionError.missingSourcePath(sessionID: session.sessionID)
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard self.fileManager.fileExists(atPath: sourceURL.path) else {
            throw SessionLogStoreSessionError.missingSession(path: sourceURL.path)
        }

        let standardizedSource = sourceURL.standardizedFileURL.path
        let roots = [
            self.codexRootURL.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path,
            self.codexRootURL.appendingPathComponent("archived_sessions", isDirectory: true).standardizedFileURL.path,
        ]
        guard roots.contains(where: { root in
            standardizedSource == root || standardizedSource.hasPrefix(root + "/")
        }) else {
            throw SessionLogStoreSessionError.sessionOutsideRoot(path: sourceURL.path)
        }

        return sourceURL
    }

    @MainActor
    private static func launchTerminal(command: String, cwd: String?) throws {
        let escapedCommand = "/bin/zsh -lc \(Self.shellEscaped(command))"
        let scriptCommand: String
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           cwd.isEmpty == false {
            scriptCommand = "cd \(Self.shellEscaped(cwd)) && \(escapedCommand)"
        } else {
            scriptCommand = escapedCommand
        }

        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.appleScriptEscaped(scriptCommand))"
        end tell
        """
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw SessionLogStoreSessionError.terminalLaunchFailed("Unable to create AppleScript.")
        }
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw SessionLogStoreSessionError.terminalLaunchFailed(errorInfo.description)
        }
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func enumerateLines(in fileURL: URL, handleLine: (String) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 64 * 1024
        let newline = UInt8(ascii: "\n")

        do {
            while let chunk = try handle.read(upToCount: chunkSize), chunk.isEmpty == false {
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: newline) {
                    autoreleasepool {
                        self.emitLine(from: buffer[..<newlineIndex], handleLine: handleLine)
                    }
                    let nextIndex = buffer.index(after: newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<nextIndex)
                }
            }

            if buffer.isEmpty == false {
                autoreleasepool {
                    self.emitLine(from: buffer[buffer.startIndex..<buffer.endIndex], handleLine: handleLine)
                }
            }

            return true
        } catch {
            return false
        }
    }

    private func emitLine(from bytes: Data.SubSequence, handleLine: (String) -> Void) {
        guard let line = self.normalizedLine(from: bytes) else { return }
        handleLine(line)
    }

    private func enumerateHeadLines(
        in fileURL: URL,
        maxLines: Int,
        handleLine: (String, inout Bool) -> Void
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        var emittedLines = 0
        var shouldStop = false
        let chunkSize = 64 * 1024

        do {
            while shouldStop == false,
                  emittedLines < maxLines,
                  let chunk = try handle.read(upToCount: chunkSize),
                  chunk.isEmpty == false {
                buffer.append(chunk)
                while emittedLines < maxLines,
                      let newlineIndex = buffer.firstIndex(of: newline) {
                    if let line = self.normalizedLine(from: buffer[..<newlineIndex]) {
                        handleLine(line, &shouldStop)
                        emittedLines += 1
                    }
                    let nextIndex = buffer.index(after: newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<nextIndex)
                    if shouldStop {
                        break
                    }
                }
            }

            if shouldStop == false,
               emittedLines < maxLines,
               buffer.isEmpty == false,
               let line = self.normalizedLine(from: buffer[buffer.startIndex..<buffer.endIndex]) {
                handleLine(line, &shouldStop)
            }

            return true
        } catch {
            return false
        }
    }

    private func enumerateTailLines(
        in fileURL: URL,
        maxBytes: UInt64,
        maxLines: Int,
        handleLine: (String) -> Void
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let startOffset = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            guard data.isEmpty == false else { return true }

            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if startOffset > 0, lines.isEmpty == false {
                lines.removeFirst()
            }
            for bytes in lines.suffix(maxLines) {
                if let line = self.normalizedLine(from: bytes) {
                    handleLine(line)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func normalizedLine(from bytes: Data.SubSequence) -> String? {
        var slice = bytes
        if slice.last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }
        guard slice.isEmpty == false,
              let line = String(data: Data(slice), encoding: .utf8) else { return nil }
        return line
    }

    private func loadPersistedCache() -> [URL: CachedSessionRecord] {
        guard let data = try? Data(contentsOf: self.persistedCacheURL) else { return [:] }

        let decoder = self.makePersistedJSONDecoder()

        guard let persisted = try? decoder.decode(PersistedCache.self, from: data),
              persisted.version <= self.persistedCacheVersion else {
            return [:]
        }

        var cache: [URL: CachedSessionRecord] = [:]
        cache.reserveCapacity(persisted.files.count)
        for (path, record) in persisted.files {
            let fileURL = URL(fileURLWithPath: path)
            cache[fileURL] = self.cachedRecord(record, fillingSourcePathFrom: fileURL)
        }
        return cache
    }

    private func cachedRecord(
        _ cached: CachedSessionRecord,
        fillingSourcePathFrom fileURL: URL
    ) -> CachedSessionRecord {
        CachedSessionRecord(
            fingerprint: cached.fingerprint,
            record: cached.record.map { self.record($0, fillingSourcePathFrom: fileURL) }
        )
    }

    private func record(
        _ record: SessionRecord,
        fillingSourcePathFrom fileURL: URL
    ) -> SessionRecord {
        if record.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return record
        }

        return SessionRecord(
            id: record.id,
            startedAt: record.startedAt,
            lastActivityAt: record.lastActivityAt,
            isArchived: record.isArchived,
            model: record.model,
            taskLifecycleState: record.taskLifecycleState,
            title: record.title,
            summary: record.summary,
            projectDirectory: record.projectDirectory,
            sourcePath: fileURL.path
        )
    }

    private func persistSessionCache(_ cache: [URL: CachedSessionRecord]) {
        let payload = PersistedCache(
            version: self.persistedCacheVersion,
            files: Dictionary(uniqueKeysWithValues: cache.map { ($0.key.path, $0.value) })
        )

        let encoder = self.makePersistedJSONEncoder()

        guard let data = try? encoder.encode(payload) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.persistedCacheURL)
    }

    @discardableResult

    private func makePersistedJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601Parsing.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }

    private func makePersistedJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.persistedDateFormatter.string(from: date))
        }
        return encoder
    }

    nonisolated(unsafe) private static let persistedDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func normalizeModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            return String(trimmed.dropFirst("openai/".count))
        }
        return trimmed
    }

    nonisolated private static func isRealUserPrompt(_ value: String) -> Bool {
        value.hasPrefix("# AGENTS.md") == false &&
            value.hasPrefix("<environment_context>") == false &&
            value.hasPrefix("<permissions") == false
    }

    nonisolated private static func truncated(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    nonisolated private static func pathBasename(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let parts = stripped.split { $0 == "/" || $0 == "\\" }
        return parts.last.map(String.init)
    }
}

private enum RecordsSourceSnapshotError: LocalizedError {
    case directoryEnumerationFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .directoryEnumerationFailed(let path):
            return "Failed to enumerate session directory at \(path)."
        }
    }
}

private enum SessionLogStoreSessionError: LocalizedError {
    case missingSourcePath(sessionID: String)
    case missingSession(path: String)
    case sessionOutsideRoot(path: String)
    case unreadableSession(path: String)
    case sessionIDMismatch(expected: String, actual: String)
    case terminalLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSourcePath(let sessionID):
            return "Session \(sessionID) does not include a source file path."
        case .missingSession(let path):
            return "Session source file was not found at \(path)."
        case .sessionOutsideRoot(let path):
            return "Session source path is outside the Codex session root: \(path)."
        case .unreadableSession(let path):
            return "Unable to read session source file at \(path)."
        case .sessionIDMismatch(let expected, let actual):
            return "Session ID mismatch: expected \(expected), found \(actual)."
        case .terminalLaunchFailed(let message):
            return "Failed to launch Terminal: \(message)"
        }
    }
}
