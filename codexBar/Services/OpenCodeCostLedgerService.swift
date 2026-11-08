import Foundation

struct OpenCodeCostEvent: Codable, Equatable {
    let responseID: String?
    let sessionID: String
    let timestamp: Date
    let modelID: String
    let costUSD: Double
    let listCostUSD: Double?
    let allowanceUSD: Double?
    let billingSource: String?
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int

    var totalTokens: Int {
        max(0, self.inputTokens) + max(0, self.outputTokens)
    }
}

struct OpenCodeCostLedgerSnapshot: Equatable {
    var events: [OpenCodeCostEvent]
    var sessionIDs: Set<String>
}

protocol OpenCodeCostLedgerLoading {
    func load() -> OpenCodeCostLedgerSnapshot
}

protocol OpenCodeCostLedgerRecording {
    func record(_ event: OpenCodeCostEvent)
}

final class OpenCodeCostLedgerService: OpenCodeCostLedgerLoading, OpenCodeCostLedgerRecording {
    static var shared: OpenCodeCostLedgerService {
        OpenCodeCostLedgerService()
    }
    static let maxEvents = 5_000
    static let maxFileBytes = 2 * 1024 * 1024

    private static let queue = DispatchQueue(label: "lzl.codexbar.opencode-cost-ledger")

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = CodexPaths.openCodeCostLedgerURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func record(_ event: OpenCodeCostEvent) {
        Self.queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(event) else { return }
            var line = data
            line.append(0x0A)
            try? CodexPaths.appendSecureFile(line, to: self.fileURL)
            self.compactIfNeededLocked()
        }
    }

    func load() -> OpenCodeCostLedgerSnapshot {
        Self.queue.sync {
            self.loadLocked()
        }
    }

    private func loadLocked() -> OpenCodeCostLedgerSnapshot {
        guard let data = try? Data(contentsOf: self.fileURL),
              data.isEmpty == false else {
            return OpenCodeCostLedgerSnapshot(events: [], sessionIDs: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var seenResponseIDs: Set<String> = []
        var events: [OpenCodeCostEvent] = []
        for line in data.split(separator: 0x0A) where line.isEmpty == false {
            guard let event = try? decoder.decode(OpenCodeCostEvent.self, from: Data(line)) else {
                continue
            }
            if let responseID = event.responseID, responseID.isEmpty == false {
                guard seenResponseIDs.insert(responseID).inserted else { continue }
            }
            events.append(event)
        }
        events.sort { $0.timestamp < $1.timestamp }
        if events.count > Self.maxEvents {
            events = Array(events.suffix(Self.maxEvents))
        }
        return OpenCodeCostLedgerSnapshot(
            events: events,
            sessionIDs: Set(events.map(\.sessionID).filter { $0.isEmpty == false })
        )
    }

    private func compactIfNeededLocked() {
        guard let data = try? Data(contentsOf: self.fileURL),
              data.count > Self.maxFileBytes else {
            return
        }
        let snapshot = self.loadLocked()
        let events = Array(snapshot.events.suffix(Self.maxEvents))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = events.compactMap { try? encoder.encode($0) }
        var compacted = Data()
        for line in lines {
            compacted.append(line)
            compacted.append(0x0A)
        }
        try? CodexPaths.writeSecureFile(compacted, to: self.fileURL)
    }
}
