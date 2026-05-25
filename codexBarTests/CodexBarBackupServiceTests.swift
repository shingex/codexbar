import Foundation
import XCTest

final class CodexBarBackupServiceTests: CodexBarTestCase {
    func testCodexBarSettingsBackupContainsOnlyAllowedFilesAndPreservesSecrets() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(
            Data(#"{"providers":[{"apiKey":"sk-secret"}]}"#.utf8),
            to: CodexPaths.barConfigURL
        )
        try CodexPaths.writeSecureFile(
            Data(#"{"model":"gpt-5.4"}"#.utf8),
            to: CodexPaths.openAIModelStateURL
        )
        try CodexPaths.writeSecureFile(
            Data(#"{"ignored":true}"#.utf8),
            to: CodexPaths.costCacheURL
        )

        let service = self.makeService()
        let summary = try service.createBackup(kind: .codexbarSettings)
        let envelope = try service.loadEnvelope(from: summary.url)

        XCTAssertEqual(envelope.format, CodexBarBackupEnvelope.currentFormat)
        XCTAssertEqual(envelope.kind, .codexbarSettings)
        XCTAssertEqual(envelope.files.map(\.relativePath).sorted(), [
            ".codexbar/config.json",
            ".codexbar/openai-model-state.json",
        ])

        let configFile = try XCTUnwrap(envelope.files.first { $0.relativePath == ".codexbar/config.json" })
        XCTAssertEqual(Data(base64Encoded: configFile.dataBase64), Data(#"{"providers":[{"apiKey":"sk-secret"}]}"#.utf8))
        XCTAssertFalse(envelope.files.contains { $0.relativePath == ".codexbar/cost-cache.json" })
    }

    func testCodexConfigBackupContainsOnlyAuthAndToml() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(Data(#"{"tokens":"secret"}"#.utf8), to: CodexPaths.authURL)
        try CodexPaths.writeSecureFile(Data("model = \"gpt-5.4\"".utf8), to: CodexPaths.configTomlURL)
        try CodexPaths.writeSecureFile(Data("OPENAI_API_KEY=secret".utf8), to: CodexPaths.providerSecretsURL)

        let service = self.makeService()
        let summary = try service.createBackup(kind: .codexConfig)
        let envelope = try service.loadEnvelope(from: summary.url)

        XCTAssertEqual(envelope.kind, .codexConfig)
        XCTAssertEqual(envelope.files.map(\.relativePath).sorted(), [
            ".codex/auth.json",
            ".codex/config.toml",
        ])
    }

    func testRestoreRejectsWrongKindUnknownPathAndPathTraversal() throws {
        let service = self.makeService()
        let wrongKindURL = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexConfig,
                createdAt: Date(timeIntervalSince1970: 10),
                appVersion: "test",
                files: [
                    CodexBarBackupFile(
                        relativePath: ".codex/auth.json",
                        dataBase64: Data("{}".utf8).base64EncodedString(),
                        byteCount: 2
                    ),
                ]
            ),
            filename: "wrong-kind.json"
        )

        XCTAssertThrowsError(try service.restoreBackup(from: wrongKindURL, expectedKind: .codexbarSettings)) { error in
            XCTAssertEqual(
                error as? CodexBarBackupError,
                .unexpectedKind(expected: .codexbarSettings, actual: .codexConfig)
            )
        }

        let unknownPathURL = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexbarSettings,
                createdAt: Date(timeIntervalSince1970: 11),
                appVersion: "test",
                files: [
                    CodexBarBackupFile(
                        relativePath: ".codexbar/cost-cache.json",
                        dataBase64: Data("{}".utf8).base64EncodedString(),
                        byteCount: 2
                    ),
                ]
            ),
            filename: "unknown-path.json"
        )

        XCTAssertThrowsError(try service.restoreBackup(from: unknownPathURL, expectedKind: .codexbarSettings)) { error in
            XCTAssertEqual(error as? CodexBarBackupError, .unknownPath(".codexbar/cost-cache.json"))
        }

        let traversalURL = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexbarSettings,
                createdAt: Date(timeIntervalSince1970: 12),
                appVersion: "test",
                files: [
                    CodexBarBackupFile(
                        relativePath: "../config.json",
                        dataBase64: Data("{}".utf8).base64EncodedString(),
                        byteCount: 2
                    ),
                ]
            ),
            filename: "traversal.json"
        )

        XCTAssertThrowsError(try service.restoreBackup(from: traversalURL, expectedKind: .codexbarSettings)) { error in
            XCTAssertEqual(error as? CodexBarBackupError, .unsafePath("../config.json"))
        }
    }

    func testRestoreCreatesPreRestoreBackupBeforeOverwritingFiles() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(Data("before".utf8), to: CodexPaths.barConfigURL)
        let service = self.makeService()
        let backupURL = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexbarSettings,
                createdAt: Date(timeIntervalSince1970: 20),
                appVersion: "test",
                files: [
                    CodexBarBackupFile(
                        relativePath: ".codexbar/config.json",
                        dataBase64: Data("after".utf8).base64EncodedString(),
                        byteCount: 5
                    ),
                ]
            ),
            filename: "restore.json"
        )

        try service.restoreBackup(from: backupURL, expectedKind: .codexbarSettings)

        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), Data("after".utf8))
        let latest = try XCTUnwrap(service.latestBackupSummary(kind: .codexbarSettings))
        XCTAssertTrue(latest.url.lastPathComponent.hasPrefix("codexbar-settings-pre-restore-"))
        let envelope = try service.loadEnvelope(from: latest.url)
        let backedUpFile = try XCTUnwrap(envelope.files.first)
        XCTAssertEqual(Data(base64Encoded: backedUpFile.dataBase64), Data("before".utf8))
    }

    func testLatestBackupSummaryFiltersByKindAndSortsByCreatedAt() throws {
        let service = self.makeService()
        _ = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexbarSettings,
                createdAt: Date(timeIntervalSince1970: 100),
                appVersion: "old",
                files: []
            ),
            filename: "old.json"
        )
        let newestURL = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexbarSettings,
                createdAt: Date(timeIntervalSince1970: 200),
                appVersion: "new",
                files: []
            ),
            filename: "new.json"
        )
        _ = try self.writeEnvelope(
            CodexBarBackupEnvelope(
                format: CodexBarBackupEnvelope.currentFormat,
                kind: .codexConfig,
                createdAt: Date(timeIntervalSince1970: 300),
                appVersion: "other",
                files: []
            ),
            filename: "other-kind.json"
        )

        let latest = try XCTUnwrap(service.latestBackupSummary(kind: .codexbarSettings))

        XCTAssertEqual(latest.url.standardizedFileURL.path, newestURL.standardizedFileURL.path)
        XCTAssertEqual(latest.createdAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(latest.appVersion, "new")
    }

    private func makeService() -> CodexBarBackupService {
        CodexBarBackupService(
            backupsDirectoryURL: CodexPaths.backupsRootURL,
            now: { Date(timeIntervalSince1970: 1_000) },
            appVersion: { "test-version" }
        )
    }

    private func writeEnvelope(_ envelope: CodexBarBackupEnvelope, filename: String) throws -> URL {
        try CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        let url = CodexPaths.backupsRootURL.appendingPathComponent(filename)
        try CodexPaths.writeSecureFile(data, to: url)
        return url
    }
}
