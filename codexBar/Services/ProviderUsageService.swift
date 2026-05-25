import Foundation

enum ProviderUsageError: LocalizedError, Equatable {
    case invalidURL
    case authorizationFailed
    case timeout
    case invalidJSON
    case unableToDetectFields
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid usage URL"
        case .authorizationFailed:
            return "Authorization failed"
        case .timeout:
            return "Request timeout"
        case .invalidJSON:
            return "Invalid JSON response"
        case .unableToDetectFields:
            return "Unable to detect usage fields"
        case .requestFailed(let message):
            return message
        }
    }
}

struct ProviderUsageFetchResult: Equatable {
    var data: CodexBarProviderUsageData?
    var rawResponse: String
    var errorMessage: String?
}

struct ProviderUsageNormalizer {
    private let calendar: Calendar
    private let now: () -> Date

    init(
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.calendar = calendar
        self.now = now
    }

    func normalize(jsonObject: Any) throws -> CodexBarProviderUsageData {
        let isValid = self.bool(
            jsonObject,
            paths: ["isValid", "is_valid", "valid", "active", "is_active"]
        )
        let unit = self.string(jsonObject, paths: ["unit", "currency"]) ?? "USD"
        let remaining = self.number(
            jsonObject,
            paths: ["remaining", "daily_remaining", "subscription.daily_remaining_usd"]
        )

        let todayUsed = self.number(
            jsonObject,
            paths: [
                "subscription.daily_usage_usd",
                "usage.today.actual_cost",
                "usage.today.cost",
                "daily_usage_usd",
                "daily.used",
            ]
        ) ?? self.todayUsageFromDailyUsageArray(jsonObject)
        let todayLimit = self.number(
            jsonObject,
            paths: ["subscription.daily_limit_usd", "daily_limit_usd", "daily.limit"]
        )
        let weeklyUsed = self.number(
            jsonObject,
            paths: ["subscription.weekly_usage_usd", "weekly_usage_usd", "weekly.used"]
        )
        let weeklyLimit = self.number(
            jsonObject,
            paths: ["subscription.weekly_limit_usd", "weekly_limit_usd", "weekly.limit"]
        )
        let monthlyUsed = self.number(
            jsonObject,
            paths: ["subscription.monthly_usage_usd", "monthly_usage_usd", "monthly.used"]
        )
        let monthlyLimit = self.number(
            jsonObject,
            paths: ["subscription.monthly_limit_usd", "monthly_limit_usd", "monthly.limit"]
        )
        let totalUsed = self.number(
            jsonObject,
            paths: ["usage.total.actual_cost", "usage.total.cost", "total_usage", "total.used"]
        )
        let planName = self.string(
            jsonObject,
            paths: ["planName", "plan_name", "subscription.planName"]
        )
        let expiresAt = self.string(
            jsonObject,
            paths: ["subscription.expires_at", "expires_at"]
        )

        let usage = CodexBarProviderUsageData(
            isValid: isValid,
            unit: unit,
            remaining: remaining,
            today: CodexBarProviderUsagePeriod(
                used: todayUsed,
                limit: todayLimit,
                remaining: remaining
            ),
            weekly: CodexBarProviderUsagePeriod(used: weeklyUsed, limit: weeklyLimit),
            monthly: CodexBarProviderUsagePeriod(used: monthlyUsed, limit: monthlyLimit),
            totalUsed: totalUsed,
            planName: planName,
            expiresAt: expiresAt
        )

        guard usage.hasDetectedUsageFields else {
            throw ProviderUsageError.unableToDetectFields
        }
        return usage
    }

    private func todayUsageFromDailyUsageArray(_ object: Any) -> Double? {
        guard let dailyUsage = self.value(object, path: "daily_usage") as? [Any] else { return nil }
        let today = self.dayKey(self.now())
        for item in dailyUsage {
            guard self.itemMatchesToday(item, todayKey: today) else { continue }
            return self.number(item, paths: ["actual_cost", "cost", "used"])
        }
        return nil
    }

    private func itemMatchesToday(_ item: Any, todayKey: String) -> Bool {
        let dateCandidates = ["date", "day", "created_at", "timestamp"]
        for key in dateCandidates {
            guard let raw = self.value(item, path: key) else { continue }
            if let string = raw as? String {
                if string.hasPrefix(todayKey) {
                    return true
                }
                if let parsed = Self.iso8601Formatter.date(from: string), self.dayKey(parsed) == todayKey {
                    return true
                }
            } else if let number = self.double(from: raw) {
                let timestamp = number > 10_000_000_000 ? number / 1000 : number
                if self.dayKey(Date(timeIntervalSince1970: timestamp)) == todayKey {
                    return true
                }
            }
        }
        return false
    }

    private func dayKey(_ date: Date) -> String {
        let components = self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func bool(_ object: Any, paths: [String]) -> Bool? {
        for path in paths {
            guard let value = self.value(object, path: path) else { continue }
            if let bool = value as? Bool {
                return bool
            }
            if let string = value as? String {
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1", "active":
                    return true
                case "false", "no", "0", "inactive":
                    return false
                default:
                    continue
                }
            }
            if let number = self.double(from: value) {
                return number != 0
            }
        }
        return nil
    }

    private func string(_ object: Any, paths: [String]) -> String? {
        for path in paths {
            guard let value = self.value(object, path: path) else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func number(_ object: Any, paths: [String]) -> Double? {
        for path in paths {
            guard let value = self.value(object, path: path),
                  let number = self.double(from: value) else {
                continue
            }
            return number
        }
        return nil
    }

    private func value(_ object: Any, path: String) -> Any? {
        var current: Any? = object
        for component in path.split(separator: ".").map(String.init) {
            if let dictionary = current as? [String: Any] {
                current = dictionary[component]
            } else if let dictionary = current as? [String: Any?] {
                current = dictionary[component] ?? nil
            } else {
                return nil
            }
        }
        if current is NSNull {
            return nil
        }
        return current
    }

    private func double(from value: Any) -> Double? {
        if let number = value as? Double, number.isFinite {
            return number
        }
        if let number = value as? Int {
            return Double(number)
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String {
            let cleaned = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
            guard let double = Double(cleaned), double.isFinite else { return nil }
            return double
        }
        return nil
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct ProviderUsageService {
    private let urlSession: URLSession
    private let normalizer: ProviderUsageNormalizer

    init(
        urlSession: URLSession = URLSession(configuration: .ephemeral),
        normalizer: ProviderUsageNormalizer = ProviderUsageNormalizer()
    ) {
        self.urlSession = urlSession
        self.normalizer = normalizer
    }

    func fetch(
        provider: CodexBarProvider,
        account: CodexBarProviderAccount,
        configuration: CodexBarProviderUsageConfiguration
    ) async throws -> ProviderUsageFetchResult {
        let url = try self.resolvedUsageURL(provider: provider, configuration: configuration)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("CodexBar/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           apiKey.isEmpty == false {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await self.urlSession.data(for: request)
            let rawResponse = String(data: data, encoding: .utf8) ?? ""
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderUsageError.requestFailed("Invalid HTTP response")
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ProviderUsageError.authorizationFailed
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ProviderUsageError.requestFailed("HTTP \(httpResponse.statusCode)")
            }

            let jsonObject: Any
            do {
                jsonObject = try JSONSerialization.jsonObject(with: data)
            } catch {
                return ProviderUsageFetchResult(
                    data: nil,
                    rawResponse: rawResponse,
                    errorMessage: ProviderUsageError.invalidJSON.localizedDescription
                )
            }

            do {
                let usage = try self.normalizer.normalize(jsonObject: jsonObject)
                return ProviderUsageFetchResult(data: usage, rawResponse: rawResponse, errorMessage: nil)
            } catch ProviderUsageError.unableToDetectFields {
                return ProviderUsageFetchResult(
                    data: nil,
                    rawResponse: rawResponse,
                    errorMessage: ProviderUsageError.unableToDetectFields.localizedDescription
                )
            }
        } catch let error as ProviderUsageError {
            throw error
        } catch {
            if (error as? URLError)?.code == .timedOut {
                throw ProviderUsageError.timeout
            }
            throw ProviderUsageError.requestFailed(error.localizedDescription)
        }
    }

    func resolvedUsageURL(
        provider: CodexBarProvider,
        configuration: CodexBarProviderUsageConfiguration
    ) throws -> URL {
        let rawURL: String
        if let configuredURL = configuration.requestURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           configuredURL.isEmpty == false {
            rawURL = configuredURL
        } else if let baseURL = provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  baseURL.isEmpty == false {
            rawURL = Self.defaultUsageURLString(baseURL: baseURL)
        } else {
            throw ProviderUsageError.invalidURL
        }

        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            throw ProviderUsageError.invalidURL
        }
        return url
    }

    private static func defaultUsageURLString(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last == "v1" else {
            return trimmed + "/v1/usage"
        }
        return trimmed + "/usage"
    }
}
