import Foundation
import OSLog

enum RecordsDiagnostics {
    nonisolated static let logger = Logger(subsystem: "lzhl.codexbar", category: "records")
    nonisolated private static let fileQueue = DispatchQueue(label: "lzl.codexbar.records-diagnostics")
    private static let maxLogFileSize = 512 * 1024

    nonisolated static func elapsedMilliseconds(since start: DispatchTime) -> Double {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsedNanoseconds) / 1_000_000
    }

    nonisolated static func record(
        _ event: String,
        level: String = "info",
        fields: [String: String] = [:]
    ) {
        var payload = fields
        payload["event"] = event
        payload["level"] = level
        payload["timestamp"] = Self.timestampString()

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }

        let rendered = fields.isEmpty
            ? event
            : event + " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        switch level {
        case "error":
            Self.logger.error("\(rendered, privacy: .public)")
        case "debug":
            Self.logger.debug("\(rendered, privacy: .public)")
        default:
            Self.logger.info("\(rendered, privacy: .public)")
        }

        guard level != "debug" else { return }
        Self.appendLineToDiagnosticsFile(line)
    }

    nonisolated static var diagnosticsLogURL: URL {
        Self.codexBarRootURL().appendingPathComponent("records-diagnostics.jsonl")
    }

    private nonisolated static func timestampString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private nonisolated static func appendLineToDiagnosticsFile(_ line: String) {
        let logURL = Self.diagnosticsLogURL
        let data = Data((line + "\n").utf8)
        Self.fileQueue.async {
            do {
                try Self.appendDiagnosticsData(data, to: logURL)
            } catch {
                do {
                    try Self.appendDiagnosticsData(data, to: logURL)
                } catch {
                    Self.logger.debug("records.diagnostics.fileWriteFailed error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private nonisolated static func codexBarRootURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEXBAR_HOME"],
           override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent(".codexbar", isDirectory: true)
        }
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir), isDirectory: true)
                .appendingPathComponent(".codexbar", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar", isDirectory: true)
    }

    private static func appendDiagnosticsData(_ data: Data, to logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.rotateDiagnosticsFileIfNeeded(logURL)
        if FileManager.default.fileExists(atPath: logURL.path) == false {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: logURL.path
            )
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func rotateDiagnosticsFileIfNeeded(_ logURL: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > Self.maxLogFileSize else {
            return
        }

        let rotatedURL = logURL.deletingLastPathComponent()
            .appendingPathComponent(logURL.deletingPathExtension().lastPathComponent + ".1")
            .appendingPathExtension(logURL.pathExtension)
        try? FileManager.default.removeItem(at: rotatedURL)
        try FileManager.default.moveItem(at: logURL, to: rotatedURL)
    }
}

enum RecordsRefreshMode: Equatable, Sendable {
    case incremental
    case rebuildAll
}

enum RecordsSnapshotWarningKind: String, Codable, Equatable, Sendable {
    case unreadableSessionFile
    case incompleteSessionRecord
}

struct RecordsSnapshotWarning: Codable, Equatable, Identifiable, Sendable {
    let sessionFilePath: String
    let kind: RecordsSnapshotWarningKind
    let message: String

    var id: String {
        "\(self.kind.rawValue)|\(self.sessionFilePath)|\(self.message)"
    }
}

struct HistoricalModelRecord: Codable, Equatable, Identifiable, Sendable {
    let modelID: String
    let sessionCount: Int
    let lastSeenAt: Date

    var id: String { self.modelID }
}

struct SessionMessageRecord: Codable, Equatable, Identifiable, Sendable {
    let role: String
    let content: String
    let timestamp: Date?

    var id: String {
        [
            self.role,
            self.timestamp.map { Self.timestampFormatter.string(from: $0) } ?? "",
            String(self.content.hashValue),
        ].joined(separator: "|")
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct HistoricalSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let modelID: String
    let title: String?
    let summary: String?
    let projectDirectory: String?
    let sourcePath: String?
    let resumeCommand: String?
    let startedAt: Date
    let lastActivityAt: Date
    let isArchived: Bool
    let totalTokens: Int

    var id: String { self.sessionID }
    var projectFolderName: String? {
        self.projectDirectory.flatMap(Self.pathBasename(_:))
    }

    init(
        sessionID: String,
        modelID: String,
        title: String? = nil,
        summary: String? = nil,
        projectDirectory: String? = nil,
        sourcePath: String? = nil,
        resumeCommand: String? = nil,
        startedAt: Date,
        lastActivityAt: Date,
        isArchived: Bool,
        totalTokens: Int
    ) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.title = title
        self.summary = summary
        self.projectDirectory = projectDirectory
        self.sourcePath = sourcePath
        self.resumeCommand = resumeCommand
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived
        self.totalTokens = totalTokens
    }

    var displayTitle: String {
        if let title = self.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           title.isEmpty == false {
            return title
        }
        if let projectDirectory = self.projectDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           projectDirectory.isEmpty == false,
           let basename = Self.pathBasename(projectDirectory) {
            return basename
        }
        return String(self.sessionID.prefix(8))
    }

    nonisolated private static func pathBasename(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let parts = stripped.split { $0 == "/" || $0 == "\\" }
        return parts.last.map(String.init)
    }
}

struct RecordsSourceSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

struct RecordsSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let models: [HistoricalModelRecord]
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

enum RecordsListEvent: Equatable, Sendable {
    case cached(RecordsSnapshot)
    case partial(RecordsSnapshot)
    case finished(RecordsSnapshot)
}

enum RecordsSourceListEvent: Equatable, Sendable {
    case partial(RecordsSourceSnapshot)
    case finished(RecordsSourceSnapshot)
}

protocol RecordsSourceSnapshotLoading: Sendable {
    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot
}

protocol ProgressiveRecordsSourceSnapshotLoading: RecordsSourceSnapshotLoading {
    func loadPersistedRecordsSourceSnapshot() async throws -> RecordsSourceSnapshot
    func streamIncrementalRecordsSourceSnapshots() -> AsyncThrowingStream<RecordsSourceListEvent, Error>
}

protocol RecordsSnapshotServing: Sendable {
    func streamCurrentList() -> AsyncThrowingStream<RecordsListEvent, Error>
    func loadCurrent() async throws -> RecordsSnapshot
    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot
    func loadMessages(for session: HistoricalSessionRecord) async throws -> [SessionMessageRecord]
    func loadTokenCount(for session: HistoricalSessionRecord) async throws -> Int?
    func deleteSessions(_ sessions: [HistoricalSessionRecord]) async -> [SessionDeleteResult]
    func launchResumeTerminal(for session: HistoricalSessionRecord) async throws
}

struct SessionDeleteResult: Equatable, Sendable {
    let sessionID: String
    let sourcePath: String?
    let didDelete: Bool
    let errorMessage: String?
}

protocol SessionMessageLoading: Sendable {
    func loadMessages(for session: HistoricalSessionRecord) async throws -> [SessionMessageRecord]
}

protocol SessionTokenLoading: Sendable {
    func loadTokenCount(for session: HistoricalSessionRecord) async throws -> Int?
}

protocol SessionDeleting: Sendable {
    func deleteSessions(_ sessions: [HistoricalSessionRecord]) async -> [SessionDeleteResult]
}

protocol SessionResumeLaunching: Sendable {
    func launchResumeTerminal(for session: HistoricalSessionRecord) async throws
}

enum RecordsSnapshotServiceError: LocalizedError, Equatable {
    case requestSuperseded
    case timedOut(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestSuperseded:
            return "Records request was superseded by a newer request."
        case .timedOut(let timeout):
            let seconds = String(format: "%.1f", timeout)
            return "Records refresh timed out after \(seconds) seconds."
        }
    }
}

struct RecordsSnapshotService: RecordsSnapshotServing {
    private let sourceLoader: any RecordsSourceSnapshotLoading
    private let requestCoordinator: RecordsSnapshotRequestCoordinator

    init(
        sourceLoader: any RecordsSourceSnapshotLoading = SessionLogStore.shared,
        requestCoordinator: RecordsSnapshotRequestCoordinator = RecordsSnapshotRequestCoordinator()
    ) {
        self.sourceLoader = sourceLoader
        self.requestCoordinator = requestCoordinator
    }

    func streamCurrentList() -> AsyncThrowingStream<RecordsListEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let streamStart = DispatchTime.now()
                RecordsDiagnostics.record("records.streamCurrentList.start")
                do {
                    if let progressiveLoader = self.sourceLoader as? any ProgressiveRecordsSourceSnapshotLoading {
                        let cachedStart = DispatchTime.now()
                        let cached = try await progressiveLoader.loadPersistedRecordsSourceSnapshot()
                        let cachedSnapshot = Self.makeSnapshot(from: cached)
                        RecordsDiagnostics.record("records.streamCurrentList.cached", fields: [
                            "elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: cachedStart)),
                            "models": "\(cachedSnapshot.models.count)",
                            "sessions": "\(cachedSnapshot.sessions.count)",
                            "warnings": "\(cachedSnapshot.warnings.count)",
                        ])
                        continuation.yield(.cached(cachedSnapshot))

                        for try await event in progressiveLoader.streamIncrementalRecordsSourceSnapshots() {
                            switch event {
                            case .partial(let sourceSnapshot):
                                let snapshot = Self.makeSnapshot(from: sourceSnapshot)
                                RecordsDiagnostics.record("records.streamCurrentList.partial", fields: [
                                    "models": "\(snapshot.models.count)",
                                    "sessions": "\(snapshot.sessions.count)",
                                    "total_elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: streamStart)),
                                    "warnings": "\(snapshot.warnings.count)",
                                ])
                                continuation.yield(.partial(snapshot))
                            case .finished(let sourceSnapshot):
                                let snapshot = Self.makeSnapshot(from: sourceSnapshot)
                                RecordsDiagnostics.record("records.streamCurrentList.finished", fields: [
                                    "models": "\(snapshot.models.count)",
                                    "sessions": "\(snapshot.sessions.count)",
                                    "total_elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: streamStart)),
                                    "warnings": "\(snapshot.warnings.count)",
                                ])
                                continuation.yield(.finished(snapshot))
                            }
                        }
                    } else {
                        let snapshot = try await self.loadCurrent()
                        RecordsDiagnostics.record("records.streamCurrentList.finished_legacy", fields: [
                            "models": "\(snapshot.models.count)",
                            "sessions": "\(snapshot.sessions.count)",
                            "total_elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: streamStart)),
                            "warnings": "\(snapshot.warnings.count)",
                        ])
                        continuation.yield(.finished(snapshot))
                    }
                    RecordsDiagnostics.record("records.streamCurrentList.complete", fields: [
                        "total_elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: streamStart)),
                    ])
                    continuation.finish()
                } catch {
                    RecordsDiagnostics.record("records.streamCurrentList.failed", level: "error", fields: [
                        "error": error.localizedDescription,
                        "total_elapsed_ms": Self.formatMilliseconds(RecordsDiagnostics.elapsedMilliseconds(since: streamStart)),
                    ])
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func loadCurrent() async throws -> RecordsSnapshot {
        try await self.requestCoordinator.runRequest(
            refreshMode: .incremental,
            timeout: nil,
            sourceLoader: self.sourceLoader,
            makeSnapshot: Self.makeSnapshot(from:)
        )
    }

    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot {
        try await self.requestCoordinator.runRequest(
            refreshMode: .rebuildAll,
            timeout: max(0, timeout),
            sourceLoader: self.sourceLoader,
            makeSnapshot: Self.makeSnapshot(from:)
        )
    }

    func loadMessages(for session: HistoricalSessionRecord) async throws -> [SessionMessageRecord] {
        if let sourceLoader = self.sourceLoader as? any SessionMessageLoading {
            return try await sourceLoader.loadMessages(for: session)
        }
        return []
    }

    func loadTokenCount(for session: HistoricalSessionRecord) async throws -> Int? {
        if let sourceLoader = self.sourceLoader as? any SessionTokenLoading {
            return try await sourceLoader.loadTokenCount(for: session)
        }
        return nil
    }

    func deleteSessions(_ sessions: [HistoricalSessionRecord]) async -> [SessionDeleteResult] {
        if let sourceLoader = self.sourceLoader as? any SessionDeleting {
            return await sourceLoader.deleteSessions(sessions)
        }
        return sessions.map {
            SessionDeleteResult(
                sessionID: $0.sessionID,
                sourcePath: $0.sourcePath,
                didDelete: false,
                errorMessage: "Session deletion is not supported by this source."
            )
        }
    }

    func launchResumeTerminal(for session: HistoricalSessionRecord) async throws {
        if let launcher = self.sourceLoader as? any SessionResumeLaunching {
            try await launcher.launchResumeTerminal(for: session)
        }
    }

    nonisolated private static func makeSnapshot(from sourceSnapshot: RecordsSourceSnapshot) -> RecordsSnapshot {
        RecordsSnapshot(
            generatedAt: sourceSnapshot.generatedAt,
            refreshMode: sourceSnapshot.refreshMode,
            models: Self.models(from: sourceSnapshot.sessions),
            sessions: sourceSnapshot.sessions.sorted(by: Self.shouldSortSessionsBefore),
            warnings: sourceSnapshot.warnings.sorted(by: Self.shouldSortWarningsBefore)
        )
    }

    nonisolated private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    nonisolated private static func models(from sessions: [HistoricalSessionRecord]) -> [HistoricalModelRecord] {
        let groupedSessions = Dictionary(grouping: sessions, by: \.modelID)
        return groupedSessions.map { modelID, groupedRecords in
            HistoricalModelRecord(
                modelID: modelID,
                sessionCount: groupedRecords.count,
                lastSeenAt: groupedRecords.map(\.lastActivityAt).max() ?? .distantPast
            )
        }
        .sorted(by: Self.shouldSortModelsBefore)
    }

    nonisolated private static func shouldSortSessionsBefore(
        _ lhs: HistoricalSessionRecord,
        _ rhs: HistoricalSessionRecord
    ) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.sessionID < rhs.sessionID
    }

    nonisolated private static func shouldSortModelsBefore(
        _ lhs: HistoricalModelRecord,
        _ rhs: HistoricalModelRecord
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        if lhs.sessionCount != rhs.sessionCount {
            return lhs.sessionCount > rhs.sessionCount
        }
        return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
    }

    nonisolated private static func shouldSortWarningsBefore(
        _ lhs: RecordsSnapshotWarning,
        _ rhs: RecordsSnapshotWarning
    ) -> Bool {
        if lhs.sessionFilePath != rhs.sessionFilePath {
            return lhs.sessionFilePath < rhs.sessionFilePath
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.message < rhs.message
    }
}

actor RecordsSnapshotRequestCoordinator: Sendable {
    private var latestRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
    private var activeTask: Task<RecordsSnapshot, Error>?

    func runRequest(
        refreshMode: RecordsRefreshMode,
        timeout: TimeInterval?,
        sourceLoader: any RecordsSourceSnapshotLoading,
        makeSnapshot: @escaping @Sendable (RecordsSourceSnapshot) -> RecordsSnapshot
    ) async throws -> RecordsSnapshot {
        self.latestRequestID &+= 1
        let requestID = self.latestRequestID

        self.activeTask?.cancel()

        let task = Task<RecordsSnapshot, Error> {
            let sourceSnapshot = try await sourceLoader.loadRecordsSourceSnapshot(refreshMode: refreshMode)
            return makeSnapshot(sourceSnapshot)
        }

        self.activeRequestID = requestID
        self.activeTask = task

        do {
            let snapshot = try await self.resolve(task, timeout: timeout)
            guard self.activeRequestID == requestID else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }
            self.clearActiveRequest(ifMatching: requestID)
            return snapshot
        } catch {
            if error is CancellationError {
                if self.activeRequestID == requestID {
                    self.clearActiveRequest(ifMatching: requestID)
                }
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            if self.activeRequestID == requestID {
                self.clearActiveRequest(ifMatching: requestID)
            }
            throw error
        }
    }

    private func clearActiveRequest(ifMatching requestID: UInt64) {
        guard self.activeRequestID == requestID else { return }
        self.activeRequestID = nil
        self.activeTask = nil
    }

    private func resolve(
        _ task: Task<RecordsSnapshot, Error>,
        timeout: TimeInterval?
    ) async throws -> RecordsSnapshot {
        guard let timeout else {
            return try await task.value
        }

        let clampedTimeout = max(0, timeout)
        return try await withThrowingTaskGroup(of: Result<RecordsSnapshot, Error>.self) { group in
            group.addTask {
                do {
                    return .success(try await task.value)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                if clampedTimeout > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                }
                return .failure(RecordsSnapshotServiceError.timedOut(timeout: clampedTimeout))
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            switch first {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                if case RecordsSnapshotServiceError.timedOut = error {
                    task.cancel()
                }
                throw error
            }
        }
    }
}
