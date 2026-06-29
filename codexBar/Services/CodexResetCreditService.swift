import Foundation

enum CodexResetCreditError: LocalizedError, Equatable {
    case authorizationFailed
    case invalidResponse
    case invalidJSON
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationFailed:
            return L.resetCreditAuthorizationFailed
        case .invalidResponse:
            return L.resetCreditInvalidResponse
        case .invalidJSON:
            return L.resetCreditInvalidJSON
        case .requestFailed(let message):
            return message
        }
    }
}

struct CodexResetCreditDateTime: Codable, Equatable {
    var dateLocal: String
    var timeLocal: String
    var timeUTC: String
}

struct CodexResetCredit: Codable, Equatable, Identifiable {
    var id: String
    var status: String
    var resetType: String
    var expiresAt: CodexResetCreditDateTime?
}

struct CodexResetCreditSnapshot: Codable, Equatable {
    var queriedAt: Date
    var availableCount: Int
    var credits: [CodexResetCredit]
}

struct CodexResetCreditCache: Codable, Equatable {
    var snapshotsByAccountID: [String: CodexResetCreditSnapshot]

    static let empty = CodexResetCreditCache(snapshotsByAccountID: [:])
}

struct CodexResetCreditFetchResult: Equatable {
    var snapshot: CodexResetCreditSnapshot
}

struct CodexResetCreditService {
    private let endpoint: URL
    private let urlSession: URLSession
    private let cacheURL: URL
    private let now: () -> Date

    init(
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
        urlSession: URLSession = URLSession(configuration: .ephemeral),
        cacheURL: URL = CodexPaths.resetCreditCacheURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.cacheURL = cacheURL
        self.now = now
    }

    func loadCache() -> CodexResetCreditCache {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let cache = try? JSONDecoder.codexResetCredits.decode(CodexResetCreditCache.self, from: data) else {
            return .empty
        }
        return cache
    }

    func saveCache(_ cache: CodexResetCreditCache) throws {
        let data = try JSONEncoder.codexResetCredits.encode(cache)
        try CodexPaths.writeSecureFile(data, to: self.cacheURL)
    }

    func fetch(account: TokenAccount) async throws -> CodexResetCreditFetchResult {
        var request = URLRequest(url: self.endpoint, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/1.0", forHTTPHeaderField: "User-Agent")
        let remoteAccountID = account.remoteAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteAccountID.isEmpty == false {
            request.setValue(remoteAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await self.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexResetCreditError.invalidResponse
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CodexResetCreditError.authorizationFailed
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw CodexResetCreditError.requestFailed("HTTP \(httpResponse.statusCode)")
            }
            guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexResetCreditError.invalidJSON
            }

            let snapshot = Self.sanitizedSnapshot(from: jsonObject, queriedAt: self.now())
            return CodexResetCreditFetchResult(snapshot: snapshot)
        } catch let error as CodexResetCreditError {
            throw error
        } catch {
            throw CodexResetCreditError.requestFailed(error.localizedDescription)
        }
    }

    static func sanitizedSnapshot(from json: [String: Any], queriedAt: Date, calendar: Calendar = .current) -> CodexResetCreditSnapshot {
        let creditsObject = json["credits"] as? [Any] ?? []
        let credits = creditsObject.compactMap { object -> CodexResetCredit? in
            guard let credit = object as? [String: Any] else { return nil }
            let rawID = Self.string(credit["id"]) ?? UUID().uuidString
            let status = Self.string(credit["status"]) ?? "unknown"
            let resetType = Self.string(credit["reset_type"]) ?? Self.string(credit["resetType"]) ?? "unknown"
            let expiresAtValue = credit["expires_at"] ?? credit["expiresAt"]

            return CodexResetCredit(
                id: String(rawID.suffix(8)),
                status: status,
                resetType: resetType,
                expiresAt: Self.formattedDateTime(expiresAtValue, calendar: calendar)
            )
        }
        .sorted {
            let lhs = $0.expiresAt?.timeUTC ?? "9999"
            let rhs = $1.expiresAt?.timeUTC ?? "9999"
            if lhs == rhs { return $0.id < $1.id }
            return lhs < rhs
        }

        let availableCredits = credits.filter { $0.status.lowercased() == "available" }
        let availableCount = Self.int(json["available_count"])
            ?? Self.int(json["availableCount"])
            ?? availableCredits.count

        return CodexResetCreditSnapshot(
            queriedAt: queriedAt,
            availableCount: availableCount,
            credits: availableCredits
        )
    }

    private static func formattedDateTime(_ value: Any?, calendar: Calendar) -> CodexResetCreditDateTime? {
        guard let date = Self.date(from: value) else { return nil }
        let localFormatter = DateFormatter()
        localFormatter.calendar = calendar
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = calendar.timeZone
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let utcFormatter = DateFormatter()
        utcFormatter.calendar = calendar
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        utcFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"

        return CodexResetCreditDateTime(
            dateLocal: dateFormatter.string(from: date),
            timeLocal: localFormatter.string(from: date),
            timeUTC: utcFormatter.string(from: date)
        )
    }

    private static func date(from value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        if let number = value as? Int {
            let double = Double(number)
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }
        guard let text = Self.string(value) else { return nil }
        if let double = Double(text) {
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }

        if let date = Self.iso8601Formatter.date(from: text) {
            return date
        }
        return Self.iso8601FormatterWithoutFractionalSeconds.date(from: text)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = Self.string(value) { return Int(string) }
        return nil
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601FormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension JSONDecoder {
    static var codexResetCredits: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var codexResetCredits: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
