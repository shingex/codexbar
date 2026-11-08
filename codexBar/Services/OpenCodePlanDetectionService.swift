import Foundation

enum OpenCodePlanDetectionError: LocalizedError, Equatable {
    case invalidCredential
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return L.openCodeInvalidCredential
        case .unavailable:
            return L.openCodePlanDetectionFailed
        }
    }
}

protocol OpenCodePlanDetecting {
    func detectPlan(apiKey: String) async throws -> CodexBarOpenCodePlan
}

struct OpenCodePlanDetectionService: OpenCodePlanDetecting {
    private let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
    }

    func detectPlan(apiKey: String) async throws -> CodexBarOpenCodePlan {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else {
            throw OpenCodePlanDetectionError.invalidCredential
        }

        if let status = try? await self.status(
            url: URL(string: "https://opencode.ai/inference/go/v1/usage")!,
            apiKey: key
        ), (200...299).contains(status) {
            return .go
        }

        if let status = try? await self.status(
            url: CodexBarOpenCodePlan.zen.modelCatalogURL,
            apiKey: key
        ) {
            if (200...299).contains(status) {
                return .zen
            }
            if status == 401 || status == 403 {
                throw OpenCodePlanDetectionError.invalidCredential
            }
        }

        throw OpenCodePlanDetectionError.unavailable
    }

    private func status(url: URL, apiKey: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodePlanDetectionError.unavailable
        }
        return httpResponse.statusCode
    }
}
