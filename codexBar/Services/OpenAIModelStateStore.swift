import Foundation

struct OpenAIModelStateSnapshot: Codable, Equatable {
    var model: String
    var reviewModel: String?
    var savedAt: Date
}

struct OpenAIModelStateStore {
    private struct StateFile: Codable {
        var model: String
        var reviewModel: String?
        var savedAt: Date
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
        guard let data = self.readData(self.fileURL),
              let state = try? self.decoder.decode(StateFile.self, from: data),
              let model = Self.normalizedOpenAIModel(state.model) else {
            return nil
        }
        return OpenAIModelStateSnapshot(
            model: model,
            reviewModel: Self.normalizedOpenAIModel(state.reviewModel),
            savedAt: state.savedAt
        )
    }

    func saveSnapshot(model: String?, reviewModel: String?) throws {
        guard let model = Self.normalizedOpenAIModel(model) else { return }
        let state = StateFile(
            model: model,
            reviewModel: Self.normalizedOpenAIModel(reviewModel),
            savedAt: self.now()
        )
        let data = try self.encoder.encode(state)
        try self.writeSecureFile(data, self.fileURL)
    }

    static func normalizedOpenAIModel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false,
              trimmed.contains("/") == false else {
            return nil
        }
        return trimmed
    }
}
