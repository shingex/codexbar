import Foundation

struct LocalCompressionHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let recordedAt: Date
    let route: String
    let accountUsageMode: String
    let modelID: String
    let inputTokenCount: Int
    let outputTokenCount: Int
    let compressionRatio: Double
    let inputByteCount: Int
    let outputByteCount: Int
}

struct LocalCompressionHistorySnapshot: Codable, Equatable {
    var entries: [LocalCompressionHistoryEntry]
}

final class LocalCompressionHistoryStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maxEntries = 60

    init(
        fileURL: URL = CodexPaths.codexBarRoot.appendingPathComponent("local-compression-history.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func load() -> [LocalCompressionHistoryEntry] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let snapshot = try? self.decoder.decode(LocalCompressionHistorySnapshot.self, from: data) else {
            return []
        }
        return snapshot.entries.sorted { $0.recordedAt > $1.recordedAt }
    }

    func append(_ entry: LocalCompressionHistoryEntry) {
        var entries = self.load()
        entries.insert(entry, at: 0)
        if entries.count > self.maxEntries {
            entries = Array(entries.prefix(self.maxEntries))
        }
        let snapshot = LocalCompressionHistorySnapshot(entries: entries)
        guard let data = try? self.encoder.encode(snapshot) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.fileURL)
    }

    func clear() {
        try? self.fileManager.removeItem(at: self.fileURL)
    }
}
