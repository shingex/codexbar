import Foundation

struct OpenAIModelStateSnapshot: Codable, Equatable {
    var model: String
    var reviewModel: String?
    var savedAt: Date
}

struct OpenAIModelStateStore {
    private struct SnapshotFile: Codable {
        var model: String
        var reviewModel: String?
        var savedAt: Date
    }

    private struct StateFile: Codable {
        var schemaVersion: Int?
        var model: String?
        var reviewModel: String?
        var savedAt: Date?
        var targets: [String: SnapshotFile]?
        var lastActiveTargetKey: String?
    }

    private let fileURL: URL
    private let writeSecureFile: (Data, URL) throws -> Void
    private let readData: (URL) -> Data?
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL = CodexPaths.openAIModelStateURL,
        writeSecureFile: @escaping (Data, URL) throws -> Void = { data, url in
            try CodexPaths.writeSecureFile(data, to: url)
        },
        readData: @escaping (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.writeSecureFile = writeSecureFile
        self.readData = readData
        self.now = now

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSnapshot() -> OpenAIModelStateSnapshot? {
        let state = self.loadState()
        guard let model = Self.normalizedOpenAIModel(state.model) else {
            return nil
        }
        return OpenAIModelStateSnapshot(
            model: model,
            reviewModel: Self.normalizedOpenAIModel(state.reviewModel),
            savedAt: state.savedAt ?? Date.distantPast
        )
    }

    func saveSnapshot(model: String?, reviewModel: String?) throws {
        guard let model = Self.normalizedOpenAIModel(model) else { return }
        var state = self.loadState()
        state.schemaVersion = 2
        state.model = model
        state.reviewModel = Self.normalizedOpenAIModel(reviewModel)
        state.savedAt = self.now()
        try self.saveState(state)
    }

    func loadSnapshot(for targetKey: String?) -> OpenAIModelStateSnapshot? {
        guard let targetKey = Self.normalizedTargetKey(targetKey),
              let snapshot = self.loadState().targets?[targetKey] else {
            return nil
        }
        let model = Self.isOpenAITargetKey(targetKey)
            ? Self.normalizedOpenAIModel(snapshot.model)
            : Self.normalizedProviderModel(snapshot.model)
        guard let model else { return nil }
        return OpenAIModelStateSnapshot(
            model: model,
            reviewModel: Self.isOpenAITargetKey(targetKey)
                ? Self.normalizedOpenAIModel(snapshot.reviewModel)
                : Self.normalizedProviderModel(snapshot.reviewModel),
            savedAt: snapshot.savedAt
        )
    }

    func saveSnapshot(model: String?, reviewModel: String?, for targetKey: String?) throws {
        guard let targetKey = Self.normalizedTargetKey(targetKey) else { return }
        let model = Self.isOpenAITargetKey(targetKey)
            ? Self.normalizedOpenAIModel(model)
            : Self.normalizedProviderModel(model)
        guard let model else { return }

        var state = self.loadState()
        state.schemaVersion = 2
        var targets = state.targets ?? [:]
        targets[targetKey] = SnapshotFile(
            model: model,
            reviewModel: Self.isOpenAITargetKey(targetKey)
                ? Self.normalizedOpenAIModel(reviewModel)
                : Self.normalizedProviderModel(reviewModel),
            savedAt: self.now()
        )
        state.targets = targets
        try self.saveState(state)
    }

    func loadLastActiveTargetKey() -> String? {
        Self.normalizedTargetKey(self.loadState().lastActiveTargetKey)
    }

    func recordActiveTargetKey(_ targetKey: String?) throws {
        guard let targetKey = Self.normalizedTargetKey(targetKey) else { return }
        var state = self.loadState()
        state.schemaVersion = 2
        state.lastActiveTargetKey = targetKey
        try self.saveState(state)
    }

    static func normalizedOpenAIModel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false,
              trimmed.contains("/") == false,
              CodexBarThirdPartyModelProvider.knownSnapshotModelIDs.contains(trimmed) == false,
              Self.isKnownOpenAIModelIdentifier(trimmed) else {
            return nil
        }
        return trimmed
    }

    static func normalizedProviderModel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isOpenAITargetKey(_ targetKey: String) -> Bool {
        targetKey.hasPrefix("openai:")
    }

    private static func normalizedTargetKey(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isKnownOpenAIModelIdentifier(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("gpt-") ||
            lowercased.hasPrefix("chatgpt-") ||
            lowercased.hasPrefix("codex-") ||
            lowercased.hasPrefix("o1") ||
            lowercased.hasPrefix("o3") ||
            lowercased.hasPrefix("o4")
    }

    private func loadState() -> StateFile {
        guard let data = self.readData(self.fileURL),
              let state = try? self.decoder.decode(StateFile.self, from: data) else {
            return StateFile(
                schemaVersion: 2,
                model: nil,
                reviewModel: nil,
                savedAt: nil,
                targets: nil,
                lastActiveTargetKey: nil
            )
        }
        return state
    }

    private func saveState(_ state: StateFile) throws {
        let data = try self.encoder.encode(state)
        try self.writeSecureFile(data, self.fileURL)
    }
}
