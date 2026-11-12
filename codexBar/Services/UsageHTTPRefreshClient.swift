import Foundation

/// Coalesces usage reads across panel opens and background polling. Credentials stay in memory only.
actor UsageHTTPRefreshClient {
    static let shared = UsageHTTPRefreshClient()
    static let minimumInterval: TimeInterval = 5
    private static let transportFailureCooldown: TimeInterval = 300
    private struct Entry {
        var nextAllowed: Date
        var failures: Int
        var task: Task<(Data, URLResponse), Error>
    }
    private var entries: [String: Entry] = [:]

    static func cooldown(status: Int?, retryAfter: String?, failures: Int, now: Date) -> TimeInterval {
        var delay = minimumInterval
        if status == 429 { delay = min(3600, 900 * pow(2, Double(min(max(failures - 1, 0), 2)))) }
        if status == 403 { delay = 1800 }
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 {
                delay = max(delay, seconds)
            } else {
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0)
                format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = format.date(from: retryAfter) { delay = max(delay, date.timeIntervalSince(now)) }
            }
        }
        return delay
    }

    func data(for request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let key = [CodexPaths.realHome.path, request.url?.absoluteString ?? "", request.httpMethod ?? "GET",
            (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "\n")].joined(separator: "\n")
        let now = Date()
        if let entry = self.entries[key], now < entry.nextAllowed { return try await entry.task.value }
        let previousFailures = self.entries[key]?.failures ?? 0
        let task = Task { try await session.data(for: request) }
        self.entries[key] = Entry(nextAllowed: .distantFuture, failures: previousFailures, task: task)
        do {
            let result = try await task.value
            let response = result.1 as? HTTPURLResponse
            let failures = response?.statusCode == 429 || response?.statusCode == 403 ? previousFailures + 1 : 0
            self.entries[key] = Entry(nextAllowed: Date().addingTimeInterval(Self.cooldown(status: response?.statusCode,
                retryAfter: response?.value(forHTTPHeaderField: "Retry-After"), failures: failures, now: Date())), failures: failures, task: task)
            return result
        } catch {
            self.entries[key] = Entry(nextAllowed: Date().addingTimeInterval(Self.transportFailureCooldown), failures: previousFailures, task: task)
            throw error
        }
    }
}
