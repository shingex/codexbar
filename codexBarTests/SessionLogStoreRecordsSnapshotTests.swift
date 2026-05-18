import Foundation
import XCTest

final class SessionLogStoreRecordsSnapshotTests: CodexBarTestCase {
    func testInitializationDoesNotSeedUsageLedgerOrPersistSessionCache() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let cacheURL = home.appendingPathComponent(".codexbar/test-records-session-cache.json")
        let ledgerURL = home.appendingPathComponent(".codexbar/test-records-ledger.json")

        try self.writeLargeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "large.jsonl",
            id: "large",
            cwd: "/tmp/large-project"
        )

        _ = self.makeStore(
            home: home,
            persistedCacheURL: cacheURL,
            persistedUsageLedgerURL: ledgerURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testReduceBillableEventsSeedsUsageLedgerOnDemand() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let ledgerURL = home.appendingPathComponent(".codexbar/test-records-ledger.json")
        let store = self.makeStore(home: home) { _, usage, _ in
            Double(usage.totalTokens)
        }

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
        XCTAssertEqual(self.billableSessionIDs(from: store, refreshSessionCache: true), ["alpha"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testHistoricalModelsRefreshSessionCacheIncludesNewSessionModel() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: true), ["gpt-5.4"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 50,
            cachedInputTokens: 0,
            outputTokens: 10
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: false), ["gpt-5.4"])
        XCTAssertEqual(
            store.historicalModels(refreshSessionCache: true),
            ["google/gemini-2.5-pro", "gpt-5.4"]
        )
    }

    func testReduceBillableEventsRefreshSessionCacheRebuildsLedgerForNewSessionFiles() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home) { _, usage, _ in
            Double(usage.totalTokens)
        }

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha"]
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: false),
            ["alpha"]
        )
        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha", "beta"]
        )
    }

    func testLoadRecordsSourceSnapshotCapturesWarnings() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "valid.jsonl",
            id: "valid",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let incompleteURL = codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("incomplete.jsonl")
        let incompleteContent = [
            #"{"payload":{"type":"session_meta","id":"broken","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":90,"cached_input_tokens":10,"output_tokens":10}}}"#,
        ].joined(separator: "\n") + "\n"
        try incompleteContent.write(to: incompleteURL, atomically: true, encoding: .utf8)

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)

        XCTAssertEqual(snapshot.refreshMode, .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["valid"])
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].sessionFilePath.hasSuffix("/incomplete.jsonl"))
        XCTAssertEqual(snapshot.warnings[0].kind, .incompleteSessionRecord)
    }

    func testRebuildAllReturnsFreshRecordsSourceSnapshot() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let firstSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(firstSnapshot.sessions.map(\.sessionID), ["alpha"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        let rebuiltSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)

        XCTAssertEqual(rebuiltSnapshot.refreshMode, .rebuildAll)
        XCTAssertEqual(rebuiltSnapshot.sessions.map(\.sessionID), ["beta", "alpha"])
        XCTAssertEqual(
            rebuiltSnapshot.sessions.map(\.modelID),
            ["google/gemini-2.5-pro", "gpt-5.4"]
        )
    }

    func testSnapshotIncludesCodexSessionMetadataForSessionManager() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions/2026/05/17", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            cwd: "/tmp/demo-project"
        )

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)
        let session = try XCTUnwrap(snapshot.sessions.first)

        XCTAssertEqual(session.sessionID, "alpha")
        XCTAssertEqual(session.title, "demo-project")
        XCTAssertEqual(session.projectDirectory, "/tmp/demo-project")
        XCTAssertEqual(session.sourcePath?.hasSuffix("/alpha.jsonl"), true)
        XCTAssertEqual(session.resumeCommand, "codex resume alpha")
    }

    func testSnapshotPrefersThreadTitleFromStateDatabase() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            cwd: "/tmp/demo-project"
        )
        try RuntimeSQLiteFixtureSupport.writeStateDatabase(
            at: codexRoot.appendingPathComponent("state_6.sqlite"),
            threads: [
                RuntimeSQLiteFixtureSupport.ThreadRow(
                    id: "alpha",
                    source: "codex",
                    cwd: "/tmp/demo-project",
                    title: "Codex 会话标题",
                    createdAt: 1_768_648_800,
                    updatedAt: 1_768_648_900
                ),
            ]
        )

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        let session = try XCTUnwrap(snapshot.sessions.first)

        XCTAssertEqual(session.sessionID, "alpha")
        XCTAssertEqual(session.title, "Codex 会话标题")
    }

    func testLoadMessagesReturnsCodexConversationItems() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            cwd: "/tmp/demo-project"
        )

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)
        let session = try XCTUnwrap(snapshot.sessions.first)
        let messages = try await store.loadMessages(for: session)

        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "assistant", "tool"])
        XCTAssertEqual(messages.first?.content, "Fix login")
        XCTAssertEqual(messages[2].content, "[Tool: shell]")
    }

    func testDeleteSessionsRemovesCodexSessionFile() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)
        let sessionURL = codexRoot.appendingPathComponent("sessions/alpha.jsonl")

        try self.writeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            cwd: "/tmp/demo-project"
        )

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)
        let session = try XCTUnwrap(snapshot.sessions.first)
        let results = await store.deleteSessions([session])

        XCTAssertEqual(results.map(\.didDelete), [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    func testIncrementalSnapshotUsesLightweightIndexForLargeCodexSession() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeLargeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "large.jsonl",
            id: "large",
            cwd: "/tmp/large-project"
        )

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        let session = try XCTUnwrap(snapshot.sessions.first)

        XCTAssertEqual(session.sessionID, "large")
        XCTAssertEqual(session.title, "large-project")
        XCTAssertNil(session.summary)
        XCTAssertEqual(session.projectDirectory, "/tmp/large-project")
        XCTAssertEqual(session.totalTokens, 0)
    }

    func testIncrementalSnapshotDoesNotUseFirstMessageAsListTitleWithoutCodexThreadTitle() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeConversationSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            cwd: "/tmp/demo-project"
        )

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        let session = try XCTUnwrap(snapshot.sessions.first)

        XCTAssertEqual(session.title, "demo-project")
        XCTAssertNotEqual(session.title, "Fix login")
    }

    private func billableSessionIDs(from store: SessionLogStore, refreshSessionCache: Bool) -> [String] {
        store.reduceBillableEvents(into: Set<String>(), refreshSessionCache: refreshSessionCache) { partialResult, event in
            partialResult.insert(event.sessionID)
        }
        .sorted()
    }

    private func makeCodexHome() throws -> URL {
        let home = try XCTUnwrap(self.temporaryHomeURL())
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func temporaryHomeURL() -> URL? {
        let home = ProcessInfo.processInfo.environment["CODEXBAR_HOME"]
        guard let home, home.isEmpty == false else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func makeStore(
        home: URL,
        persistedCacheURL: URL? = nil,
        persistedUsageLedgerURL: URL? = nil,
        billableCostCalculator: @escaping (String, SessionLogStore.Usage, SessionLogStore.Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) -> SessionLogStore {
        SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: persistedCacheURL ?? home.appendingPathComponent(".codexbar/test-records-session-cache.json"),
            persistedUsageLedgerURL: persistedUsageLedgerURL ?? home.appendingPathComponent(".codexbar/test-records-ledger.json"),
            billableCostCalculator: billableCostCalculator
        )
    }

    private func writeFastSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(cachedInputTokens),"output_tokens":\#(outputTokens)}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writeConversationSession(
        directory: URL,
        fileName: String,
        id: String,
        cwd: String
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"timestamp":"2026-05-17T10:00:00Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-05-17T10:00:00Z","cwd":"\#(cwd)"}}"#,
            #"{"timestamp":"2026-05-17T10:00:01Z","type":"turn_context","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"timestamp":"2026-05-17T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":"Fix login"}}"#,
            #"{"timestamp":"2026-05-17T10:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"I will inspect it."}}"#,
            #"{"timestamp":"2026-05-17T10:00:04Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#,
            #"{"timestamp":"2026-05-17T10:00:05Z","type":"response_item","payload":{"type":"function_call_output","output":"done"}}"#,
            #"{"timestamp":"2026-05-17T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writeLargeConversationSession(
        directory: URL,
        fileName: String,
        id: String,
        cwd: String
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let prefix = [
            #"{"timestamp":"2026-05-17T10:00:00Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-05-17T10:00:00Z","cwd":"\#(cwd)"}}"#,
            #"{"timestamp":"2026-05-17T10:00:01Z","type":"turn_context","payload":{"model":"openai/gpt-5.4"}}"#,
            #"{"timestamp":"2026-05-17T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":"Investigate large session"}}"#,
        ].joined(separator: "\n") + "\n"
        try handle.write(contentsOf: Data(prefix.utf8))

        let filler = #"{"timestamp":"2026-05-17T10:01:00Z","type":"response_item","payload":{"type":"function_call_output","output":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"# + "\n"
        let fillerData = Data(filler.utf8)
        for _ in 0..<4000 {
            try handle.write(contentsOf: fillerData)
        }

        let suffix = #"{"timestamp":"2026-05-17T10:59:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"Final compact summary"}}"# + "\n"
        try handle.write(contentsOf: Data(suffix.utf8))
    }
}
