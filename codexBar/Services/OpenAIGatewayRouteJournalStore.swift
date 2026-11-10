import Foundation

struct OpenAIGatewayRouteRecord: Codable, Equatable {
    let timestamp: Date
    let threadID: String
    let accountID: String
}

protocol OpenAIGatewayRouteJournalStoring {
    func recordRoute(threadID: String, accountID: String, timestamp: Date)
    func routeHistory() -> [OpenAIGatewayRouteRecord]
}

private struct OpenAIGatewayRouteJournalSnapshot: Codable, Equatable {
    var routes: [OpenAIGatewayRouteRecord]
    var updatedAt: Date
}

final class OpenAIGatewayRouteJournalStore: OpenAIGatewayRouteJournalStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "lzl.codexbar.openai-gateway.route-journal")

    init(
        fileURL: URL = CodexPaths.openAIGatewayRouteJournalURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func recordRoute(threadID: String, accountID: String, timestamp: Date = Date()) {
        guard threadID.isEmpty == false, accountID.isEmpty == false else { return }

        self.queue.sync {
            var snapshot = self.loadSnapshot()
            if let last = snapshot.routes.last(where: { $0.threadID == threadID }),
               last.accountID == accountID {
                return
            }

            snapshot.routes.append(
                OpenAIGatewayRouteRecord(
                    timestamp: timestamp,
                    threadID: threadID,
                    accountID: accountID
                )
            )
            snapshot.updatedAt = timestamp
            self.pruneRoutes(in: &snapshot, referenceDate: timestamp)
            self.saveSnapshot(snapshot)
        }
    }

    func routeHistory() -> [OpenAIGatewayRouteRecord] {
        self.queue.sync {
            self.loadSnapshot().routes.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                if lhs.threadID != rhs.threadID {
                    return lhs.threadID < rhs.threadID
                }
                return lhs.accountID < rhs.accountID
            }
        }
    }

    private func loadSnapshot() -> OpenAIGatewayRouteJournalSnapshot {
        guard let data = try? Data(contentsOf: self.fileURL) else {
            return OpenAIGatewayRouteJournalSnapshot(routes: [], updatedAt: .distantPast)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OpenAIGatewayRouteJournalSnapshot.self, from: data))
            ?? OpenAIGatewayRouteJournalSnapshot(routes: [], updatedAt: .distantPast)
    }

    private func saveSnapshot(_ snapshot: OpenAIGatewayRouteJournalSnapshot) {
        if snapshot.routes.isEmpty {
            if self.fileManager.fileExists(atPath: self.fileURL.path) {
                try? self.fileManager.removeItem(at: self.fileURL)
            }
            return
        }

        try? CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.fileURL)
    }

    private func pruneRoutes(
        in snapshot: inout OpenAIGatewayRouteJournalSnapshot,
        referenceDate: Date
    ) {
        let cutoff = referenceDate.addingTimeInterval(-(60 * 60 * 24))
        snapshot.routes = snapshot.routes.filter { $0.timestamp >= cutoff }

        let maxEntries = 512
        guard snapshot.routes.count > maxEntries else { return }
        snapshot.routes = Array(snapshot.routes.suffix(maxEntries))
    }
}

protocol OpenRouterGatewayLeaseStoring {
    func loadLease() -> OpenRouterGatewayLeaseSnapshot?
    func saveLease(_ lease: OpenRouterGatewayLeaseSnapshot)
    func clear()
    func hasActiveLease() -> Bool
}

extension OpenRouterGatewayLeaseStoring {
    func hasActiveLease() -> Bool {
        guard let lease = self.loadLease() else { return false }
        return lease.leasedProcessIDs.isEmpty == false
    }
}

struct OpenRouterGatewayLeaseSnapshot: Codable, Equatable {
    var leasedProcessIDs: [Int32]
    var leasedAt: Date
    var sourceProviderId: String

    var processIDs: Set<pid_t> {
        Set(self.leasedProcessIDs.map { pid_t($0) })
    }

    init(
        processIDs: Set<pid_t>,
        leasedAt: Date = Date(),
        sourceProviderId: String = "openrouter"
    ) {
        self.leasedProcessIDs = processIDs.map { Int32($0) }.sorted()
        self.leasedAt = leasedAt
        self.sourceProviderId = sourceProviderId
    }
}

final class OpenRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = CodexPaths.openRouterGatewayStateURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func loadLease() -> OpenRouterGatewayLeaseSnapshot? {
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OpenRouterGatewayLeaseSnapshot.self, from: data)
    }

    func saveLease(_ lease: OpenRouterGatewayLeaseSnapshot) {
        guard lease.leasedProcessIDs.isEmpty == false else {
            self.clear()
            return
        }

        try? CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(lease) else { return }
        try? CodexPaths.writeSecureFile(data, to: self.fileURL)
    }

    func clear() {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
        try? self.fileManager.removeItem(at: self.fileURL)
    }
}
