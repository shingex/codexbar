import Foundation

struct OpenCodeUsageWindow: Codable, Equatable {
    var status: String?
    var percent: Double?
    var resetsAt: Date?
}

struct OpenCodeUsageSnapshot: Codable, Equatable {
    var rolling: OpenCodeUsageWindow
    var weekly: OpenCodeUsageWindow
    var monthly: OpenCodeUsageWindow
    var fetchedAt: Date

    var providerUsageData: CodexBarProviderUsageData {
        let windows = [self.rolling, self.weekly, self.monthly]
        let isValid = windows.allSatisfy { ($0.status ?? "ok").lowercased() == "ok" }
        return CodexBarProviderUsageData(
            isValid: isValid,
            unit: "%",
            today: Self.period(from: self.rolling),
            weekly: Self.period(from: self.weekly),
            monthly: Self.period(from: self.monthly),
            planName: "OpenCode Go"
        )
    }

    private static func period(from window: OpenCodeUsageWindow) -> CodexBarProviderUsagePeriod {
        guard let percent = window.percent else {
            return CodexBarProviderUsagePeriod(resetAt: window.resetsAt)
        }
        return CodexBarProviderUsagePeriod(
            used: percent,
            limit: 100,
            remaining: max(100 - percent, 0),
            resetAt: window.resetsAt
        )
    }
}

protocol OpenCodeUsageFetching {
    func fetchGoUsage(apiKey: String) async throws -> OpenCodeUsageSnapshot
}

struct OpenCodeUsageService: OpenCodeUsageFetching {
    private let urlSession: URLSession
    private let now: () -> Date

    init(
        urlSession: URLSession? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
        self.now = now
    }

    func fetchGoUsage(apiKey: String) async throws -> OpenCodeUsageSnapshot {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }
        guard let url = CodexBarOpenCodePlan.go.usageURL else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }

        return OpenCodeUsageSnapshot(
            rolling: Self.window(from: usage["rolling"]),
            weekly: Self.window(from: usage["weekly"]),
            monthly: Self.window(from: usage["monthly"]),
            fetchedAt: self.now()
        )
    }

    private static func window(from value: Any?) -> OpenCodeUsageWindow {
        guard let dictionary = value as? [String: Any] else {
            return OpenCodeUsageWindow(status: nil, percent: nil, resetsAt: nil)
        }
        return OpenCodeUsageWindow(
            status: dictionary["status"] as? String,
            percent: self.doubleValue(dictionary["percent"]),
            resetsAt: (dictionary["resetsAt"] as? String).flatMap(Self.parseDate)
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
