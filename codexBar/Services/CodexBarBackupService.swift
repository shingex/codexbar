import Foundation

enum CodexBarBackupKind: String, Codable, CaseIterable, Equatable {
    case codexbarSettings
    case codexConfig

    var displaySlug: String {
        switch self {
        case .codexbarSettings:
            return "codexbar-settings"
        case .codexConfig:
            return "codex-config"
        }
    }

    var allowedRelativePaths: [String] {
        switch self {
        case .codexbarSettings:
            return [
                ".codexbar/config.json",
                ".codexbar/openai-model-state.json",
            ]
        case .codexConfig:
            return [
                ".codex/auth.json",
                ".codex/config.toml",
            ]
        }
    }
}

struct CodexBarBackupFile: Codable, Equatable {
    var relativePath: String
    var dataBase64: String
    var byteCount: Int
}

struct CodexBarBackupEnvelope: Codable, Equatable {
    static let currentFormat = "codexbar.backup.v1"

    var format: String
    var kind: CodexBarBackupKind
    var createdAt: Date
    var appVersion: String
    var files: [CodexBarBackupFile]
}

struct CodexBarBackupSummary: Equatable {
    var url: URL
    var kind: CodexBarBackupKind
    var createdAt: Date
    var appVersion: String
    var fileCount: Int
}

enum CodexBarBackupError: LocalizedError, Equatable {
    case emptyBackup(CodexBarBackupKind)
    case invalidFormat
    case unexpectedKind(expected: CodexBarBackupKind, actual: CodexBarBackupKind)
    case unknownPath(String)
    case unsafePath(String)
    case invalidFileData(String)

    var errorDescription: String? {
        switch self {
        case let .emptyBackup(kind):
            return L.backupErrorEmpty(kind.title)
        case .invalidFormat:
            return L.backupErrorInvalidFormat
        case let .unexpectedKind(expected, actual):
            return L.backupErrorUnexpectedKind(expected.title, actual.title)
        case let .unknownPath(path):
            return L.backupErrorUnknownPath(path)
        case let .unsafePath(path):
            return L.backupErrorUnsafePath(path)
        case let .invalidFileData(path):
            return L.backupErrorInvalidFileData(path)
        }
    }
}

struct CodexBarBackupService {
    var backupsDirectoryURL: URL
    var now: () -> Date
    var appVersion: () -> String
    var fileManager: FileManager

    init(
        backupsDirectoryURL: URL = CodexPaths.backupsRootURL,
        now: @escaping () -> Date = Date.init,
        appVersion: @escaping () -> String = { AppVersionDisplay.versionAndBuild },
        fileManager: FileManager = .default
    ) {
        self.backupsDirectoryURL = backupsDirectoryURL
        self.now = now
        self.appVersion = appVersion
        self.fileManager = fileManager
    }

    func createBackup(kind: CodexBarBackupKind) throws -> CodexBarBackupSummary {
        try self.createBackup(kind: kind, filenamePrefix: kind.displaySlug)
    }

    @discardableResult
    func restoreBackup(from backupURL: URL, expectedKind: CodexBarBackupKind) throws -> CodexBarBackupSummary {
        let envelope = try self.loadEnvelope(from: backupURL)
        try self.validate(envelope: envelope, expectedKind: expectedKind)

        _ = try? self.createBackup(kind: expectedKind, filenamePrefix: "\(expectedKind.displaySlug)-pre-restore")

        for file in envelope.files {
            guard let data = Data(base64Encoded: file.dataBase64) else {
                throw CodexBarBackupError.invalidFileData(file.relativePath)
            }
            let destinationURL = try self.destinationURL(for: file.relativePath, kind: expectedKind)
            try CodexPaths.writeSecureFile(data, to: destinationURL)
        }

        return CodexBarBackupSummary(
            url: backupURL,
            kind: envelope.kind,
            createdAt: envelope.createdAt,
            appVersion: envelope.appVersion,
            fileCount: envelope.files.count
        )
    }

    func latestBackupSummary(kind: CodexBarBackupKind) -> CodexBarBackupSummary? {
        guard let urls = try? self.fileManager.contentsOfDirectory(
            at: self.backupsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> CodexBarBackupSummary? in
                guard let envelope = try? self.loadEnvelope(from: url),
                      envelope.kind == kind else {
                    return nil
                }
                return CodexBarBackupSummary(
                    url: url,
                    kind: envelope.kind,
                    createdAt: envelope.createdAt,
                    appVersion: envelope.appVersion,
                    fileCount: envelope.files.count
                )
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.url.lastPathComponent > $1.url.lastPathComponent
                }
                return $0.createdAt > $1.createdAt
            }
            .first
    }

    func loadEnvelope(from url: URL) throws -> CodexBarBackupEnvelope {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexBarBackupEnvelope.self, from: data)
    }

    private func createBackup(kind: CodexBarBackupKind, filenamePrefix: String) throws -> CodexBarBackupSummary {
        try self.fileManager.createDirectory(at: self.backupsDirectoryURL, withIntermediateDirectories: true)
        let createdAt = self.now()
        let files = try kind.allowedRelativePaths.compactMap { relativePath -> CodexBarBackupFile? in
            let sourceURL = try self.destinationURL(for: relativePath, kind: kind)
            guard self.fileManager.fileExists(atPath: sourceURL.path) else { return nil }
            let data = try Data(contentsOf: sourceURL)
            return CodexBarBackupFile(
                relativePath: relativePath,
                dataBase64: data.base64EncodedString(),
                byteCount: data.count
            )
        }

        guard files.isEmpty == false else {
            throw CodexBarBackupError.emptyBackup(kind)
        }

        let envelope = CodexBarBackupEnvelope(
            format: CodexBarBackupEnvelope.currentFormat,
            kind: kind,
            createdAt: createdAt,
            appVersion: self.appVersion(),
            files: files
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        let backupURL = self.backupsDirectoryURL.appendingPathComponent(
            "\(filenamePrefix)-\(self.timestamp(for: createdAt)).json"
        )
        try CodexPaths.writeSecureFile(data, to: backupURL)

        return CodexBarBackupSummary(
            url: backupURL,
            kind: kind,
            createdAt: createdAt,
            appVersion: envelope.appVersion,
            fileCount: files.count
        )
    }

    private func validate(envelope: CodexBarBackupEnvelope, expectedKind: CodexBarBackupKind) throws {
        guard envelope.format == CodexBarBackupEnvelope.currentFormat else {
            throw CodexBarBackupError.invalidFormat
        }
        guard envelope.kind == expectedKind else {
            throw CodexBarBackupError.unexpectedKind(expected: expectedKind, actual: envelope.kind)
        }

        for file in envelope.files {
            _ = try self.destinationURL(for: file.relativePath, kind: expectedKind)
            guard Data(base64Encoded: file.dataBase64)?.count == file.byteCount else {
                throw CodexBarBackupError.invalidFileData(file.relativePath)
            }
        }
    }

    private func destinationURL(for relativePath: String, kind: CodexBarBackupKind) throws -> URL {
        guard self.isSafeRelativePath(relativePath) else {
            throw CodexBarBackupError.unsafePath(relativePath)
        }
        guard kind.allowedRelativePaths.contains(relativePath) else {
            throw CodexBarBackupError.unknownPath(relativePath)
        }
        return CodexPaths.realHome.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func isSafeRelativePath(_ relativePath: String) -> Bool {
        guard relativePath.hasPrefix("/") == false else { return false }
        return relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains("..") == false
    }

    private func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private extension CodexBarBackupKind {
    var title: String {
        switch self {
        case .codexbarSettings:
            return L.backupCodexBarCardTitle
        case .codexConfig:
            return L.backupCodexCardTitle
        }
    }
}
