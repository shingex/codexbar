import Foundation

struct OpenCodeModel: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var family: String?
    var canonicalID: String?
    var contextLimit: Int?
    var outputLimit: Int?
    var supportsTools: Bool
    var reasoningEfforts: [String]
    var inputModalities: [String]
    var nativeAPIs: [String]
    var responsesBaseURL: String?
    var inputUSDPerMillion: Double?
    var outputUSDPerMillion: Double?
    var cacheReadUSDPerMillion: Double?
    var cacheWriteUSDPerMillion: Double?

    var selectionModel: CodexBarOpenRouterModel {
        CodexBarOpenRouterModel(id: self.id, name: self.name)
    }
}

struct OpenCodeModelCatalogSnapshot: Codable, Equatable {
    var models: [OpenCodeModel]
    var fetchedAt: Date
}

protocol OpenCodeModelCatalogFetching {
    func fetchCatalog(plan: CodexBarOpenCodePlan, apiKey: String) async throws -> OpenCodeModelCatalogSnapshot
    func loadCachedCatalog(plan: CodexBarOpenCodePlan) -> OpenCodeModelCatalogSnapshot?
}

struct OpenCodeModelCatalogService: OpenCodeModelCatalogFetching {
    static let cacheTTL: TimeInterval = 6 * 60 * 60
    static let maxCacheBytes = 1 * 1024 * 1024

    private let urlSession: URLSession
    private let now: () -> Date

    init(
        urlSession: URLSession? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
        self.now = now
    }

    func fetchCatalog(plan: CodexBarOpenCodePlan, apiKey: String) async throws -> OpenCodeModelCatalogSnapshot {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        var request = URLRequest(url: plan.modelCatalogURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let snapshot = OpenCodeModelCatalogSnapshot(
            models: Self.decodeModels(from: data),
            fetchedAt: self.now()
        )
        guard snapshot.models.isEmpty == false else {
            throw URLError(.cannotParseResponse)
        }
        self.writeCache(snapshot, plan: plan)
        return snapshot
    }

    func loadCachedCatalog(plan: CodexBarOpenCodePlan) -> OpenCodeModelCatalogSnapshot? {
        let url = CodexPaths.openCodeModelCatalogURL(plan: plan)
        guard let data = try? Data(contentsOf: url),
              data.isEmpty == false,
              data.count <= Self.maxCacheBytes,
              let snapshot = try? JSONDecoder().decode(OpenCodeModelCatalogSnapshot.self, from: data),
              snapshot.models.isEmpty == false else {
            return nil
        }
        return snapshot
    }

    static func decodeModels(from data: Data) -> [OpenCodeModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            return []
        }
        var seen: Set<String> = []
        return rows.compactMap { row -> OpenCodeModel? in
            guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  id.isEmpty == false,
                  seen.insert(id).inserted else {
                return nil
            }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = row["cost"] as? [String: Any]
            let textCost = cost?["text"] as? [String: Any]
            let inputCost = textCost?["input"] as? [String: Any]
            let outputCost = textCost?["output"] as? [String: Any]
            let cacheCost = inputCost?["cache"] as? [String: Any]
            let model = OpenCodeModel(
                id: id,
                name: name?.isEmpty == false ? name! : id,
                family: row["family"] as? String,
                canonicalID: row["canonical_id"] as? String,
                contextLimit: Self.intValue((row["limit"] as? [String: Any])?["context"]),
                outputLimit: Self.intValue((row["limit"] as? [String: Any])?["output"]),
                supportsTools: Self.supportsTools(row),
                reasoningEfforts: Self.reasoningEfforts(row),
                inputModalities: ((row["modalities"] as? [String: Any])?["input"] as? [String]) ?? [],
                nativeAPIs: (row["api"] as? [String: Any]).map { Array($0.keys).sorted() } ?? [],
                responsesBaseURL: ((row["api"] as? [String: Any])?["responses"] as? [String: Any])?["base_url"] as? String,
                inputUSDPerMillion: Self.doubleValue(inputCost?["price"]),
                outputUSDPerMillion: Self.doubleValue(outputCost?["price"]),
                cacheReadUSDPerMillion: Self.doubleValue(cacheCost?["read"]),
                cacheWriteUSDPerMillion: Self.doubleValue(cacheCost?["write"])
            )
            return Self.isExternalHarnessEligible(model) ? model : nil
        }.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func isExternalHarnessEligible(_ model: OpenCodeModel) -> Bool {
        let lowercasedID = model.id.lowercased()
        if lowercasedID.hasSuffix("-free") ||
            lowercasedID == "big-pickle" ||
            lowercasedID.contains("contributor-free") {
            return false
        }
        if model.inputUSDPerMillion == 0, model.outputUSDPerMillion == 0 {
            return false
        }
        return true
    }

    private func writeCache(_ snapshot: OpenCodeModelCatalogSnapshot, plan: CodexBarOpenCodePlan) {
        guard let data = try? JSONEncoder().encode(snapshot),
              data.count <= Self.maxCacheBytes else {
            return
        }
        try? CodexPaths.writeSecureFile(data, to: CodexPaths.openCodeModelCatalogURL(plan: plan))
    }

    private static func supportsTools(_ row: [String: Any]) -> Bool {
        guard let capabilities = row["capabilities"] as? [String: Any],
              let tools = capabilities["tools"] as? [String: Any] else {
            return false
        }
        return (tools["supported"] as? Bool) ?? false
    }

    private static func reasoningEfforts(_ row: [String: Any]) -> [String] {
        guard let capabilities = row["capabilities"] as? [String: Any],
              let reasoning = capabilities["reasoning"] as? [String: Any],
              let efforts = reasoning["effort"] as? [String] else {
            return []
        }
        return efforts
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
