import Foundation

/// Capacity rejection is the only replayable upstream error. Success text is never inspected as an error.
enum GatewayCapacityRetryPolicy {
    @TaskLocal static var requestBudget: GatewayCapacityRequestBudget?
    static let maximumAttempts = 5
    static let prefixLimit = 64 * 1024
    static let message = "selected model is at capacity. please try a different model."
    enum SSEDisposition { case lifecycle, business, capacity }

    static func matches(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains(message)
    }

    static func isCapacityError(_ object: Any, httpError: Bool = false) -> Bool {
        guard let value = object as? [String: Any] else { return false }
        let type = value["type"] as? String ?? ""
        let response = value["response"] as? [String: Any]
        let envelope = value["error"] ?? response?["error"]
        if let error = envelope as? [String: Any], let message = error["message"] as? String { return matches(message) }
        if let error = envelope as? String { return matches(error) }
        if httpError || type == "error" || type == "response.failed" {
            return (value["message"] as? String).map(matches) ?? false
        }
        return false
    }

    static func isCapacityBody(_ data: Data, statusCode: Int) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return isCapacityError(object, httpError: statusCode >= 400)
        }
        return statusCode >= 400 && String(data: data, encoding: .utf8).map(matches) == true
    }

    static func disposition(_ event: Data) -> SSEDisposition {
        guard let text = String(data: event, encoding: .utf8) else { return .business }
        let lines = text.components(separatedBy: .newlines)
        let payload = lines.filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        if payload.isEmpty || payload == "[DONE]" { return .lifecycle }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return .business }
        if isCapacityError(object) { return .capacity }
        let type = object["type"] as? String ?? ""
        if ["response.created", "response.in_progress", "ping"].contains(type) {
            let response = object["response"] as? [String: Any]
            return (response?["output"] as? [Any])?.isEmpty == false ? .business : .lifecycle
        }
        return .business
    }

    static func hasBusinessPrefix(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return ["response.output_", "response.reasoning_", "response.function_call_", "response.custom_tool_"].contains { text.contains($0) }
    }

    static func delay(attempt: Int, retryAfter: String?, now: Date = Date(), jitter: Double) -> TimeInterval? {
        let base = [5.0, 10.0, 20.0, 30.0][min(max(attempt - 1, 0), 3)]
        var delay = base * min(max(jitter, 1), 1.2)
        if let retryAfter {
            let serverDelay: TimeInterval?
            if let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 {
                serverDelay = seconds
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                serverDelay = formatter.date(from: retryAfter).map { max(0, $0.timeIntervalSince(now)) }
            }
            if let serverDelay {
                guard serverDelay <= 120 else { return nil }
                delay = max(delay, serverDelay)
            }
        }
        return delay
    }
}

struct GatewayCapacityRejection: Error {
    var response: HTTPURLResponse
    var body: Data
}

final class GatewayCapacityRequestBudget: @unchecked Sendable {
    struct Exhausted: Error {}
    private let lock = NSLock()
    private var remaining = GatewayCapacityRetryPolicy.maximumAttempts
    var hasRemaining: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.remaining > 0 }
    func consume() throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.remaining > 0 else { throw Exhausted() }
        self.remaining -= 1
    }
}
