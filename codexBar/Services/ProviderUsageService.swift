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
    private struct MimoTokenPlanUsage {
        var isValid: Bool
        var used: Double
        var limit: Double
        var remaining: Double
        var unit: String
        var planName: String
    }

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
        let mimoTokenPlan = self.mimoTokenPlanUsage(jsonObject)
        let balanceDetails = self.deepSeekBalanceDetails(jsonObject)
        let isValid = self.bool(
            jsonObject,
            paths: ["isValid", "is_valid", "valid", "active", "is_active", "is_available"]
        ) ?? mimoTokenPlan?.isValid
        let unit = self.string(jsonObject, paths: ["unit", "currency", "balance_infos[0].currency"]) ?? mimoTokenPlan?.unit ?? "USD"
        let remaining = self.number(
            jsonObject,
            paths: ["remaining", "daily_remaining", "subscription.daily_remaining_usd", "balance_infos[0].total_balance", "total_balance"]
        ) ?? mimoTokenPlan?.remaining

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
        ) ?? mimoTokenPlan?.used
        let monthlyLimit = self.number(
            jsonObject,
            paths: ["subscription.monthly_limit_usd", "monthly_limit_usd", "monthly.limit"]
        ) ?? mimoTokenPlan?.limit
        let totalUsed = self.number(
            jsonObject,
            paths: ["usage.total.actual_cost", "usage.total.cost", "total_usage", "total.used"]
        ) ?? mimoTokenPlan?.used
        let planName = self.string(
            jsonObject,
            paths: ["planName", "plan_name", "subscription.planName"]
        ) ?? mimoTokenPlan?.planName
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
                remaining: todayUsed != nil || todayLimit != nil ? remaining : nil
            ),
            weekly: CodexBarProviderUsagePeriod(used: weeklyUsed, limit: weeklyLimit),
            monthly: CodexBarProviderUsagePeriod(used: monthlyUsed, limit: monthlyLimit),
            totalUsed: totalUsed,
            planName: planName,
            expiresAt: expiresAt,
            balanceDetails: balanceDetails
        )

        guard usage.hasDetectedUsageFields else {
            throw ProviderUsageError.unableToDetectFields
        }
        return usage
    }

    private func deepSeekBalanceDetails(_ object: Any) -> [CodexBarProviderUsageBalanceDetail] {
        let fields = [
            "total_balance",
            "granted_balance",
            "topped_up_balance",
        ]
        return fields.compactMap { field in
            guard let amount = self.number(object, paths: ["balance_infos[0].\(field)", field]) else {
                return nil
            }
            return CodexBarProviderUsageBalanceDetail(key: field, label: field, amount: amount)
        }
    }

    private func mimoTokenPlanUsage(_ object: Any) -> MimoTokenPlanUsage? {
        if let code = self.number(object, paths: ["code"]), code != 0 {
            return nil
        }
        guard let items = self.value(object, path: "data.usage.items") as? [Any] else {
            return nil
        }

        var usedRaw = 0.0
        var limitRaw = 0.0
        for item in items {
            guard let name = self.string(item, paths: ["name"]),
                  name == "plan_total_token" || name == "compensation_total_token" else {
                continue
            }
            usedRaw += self.number(item, paths: ["used"]) ?? 0
            limitRaw += self.number(item, paths: ["limit"]) ?? 0
        }
        guard usedRaw > 0 || limitRaw > 0 else { return nil }

        let remainingRaw = max(limitRaw - usedRaw, 0)
        let scale = self.mimoTokenPlanScale(for: max(abs(usedRaw), abs(limitRaw), abs(remainingRaw)))
        return MimoTokenPlanUsage(
            isValid: remainingRaw > 0,
            used: usedRaw / scale.divisor,
            limit: limitRaw / scale.divisor,
            remaining: remainingRaw / scale.divisor,
            unit: scale.unit,
            planName: "MiMo Token Plan"
        )
    }

    private func mimoTokenPlanScale(for rawValue: Double) -> (divisor: Double, unit: String) {
        if rawValue >= 1_000_000_000 {
            return (1_000_000_000, "B Credits")
        }
        if rawValue >= 1_000_000 {
            return (1_000_000, "M Credits")
        }
        if rawValue >= 1_000 {
            return (1_000, "K Credits")
        }
        return (1, "Credits")
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
            if let bracketIndex = component.firstIndex(of: "["),
               component.hasSuffix("]"),
               let closeBracket = component.lastIndex(of: "]"),
               closeBracket > bracketIndex {
                let key = String(component[..<bracketIndex])
                let indexStr = String(component[component.index(after: bracketIndex)..<closeBracket])
                if let dictionary = current as? [String: Any] {
                    current = dictionary[key]
                } else if let dictionary = current as? [String: Any?] {
                    current = dictionary[key] ?? nil
                } else {
                    return nil
                }
                if let array = current as? [Any],
                   let index = Int(indexStr),
                   index >= 0, index < array.count {
                    current = array[index]
                } else {
                    return nil
                }
            } else {
                if let dictionary = current as? [String: Any] {
                    current = dictionary[component]
                } else if let dictionary = current as? [String: Any?] {
                    current = dictionary[component] ?? nil
                } else {
                    return nil
                }
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
            if Self.isMimoTokenPlanUsageRequest(provider: provider, url: url) {
                if let normalizedCookie = Self.normalizedMimoCookie(apiKey) {
                    request.setValue(normalizedCookie, forHTTPHeaderField: "Cookie")
                }
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
                request.setValue("https://platform.xiaomimimo.com/console/plan-manage", forHTTPHeaderField: "Referer")
                request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-timezone")
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        for header in configuration.requestHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.key)
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
            rawURL = Self.defaultUsageURLString(provider: provider, baseURL: baseURL)
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

    private static func defaultUsageURLString(provider: CodexBarProvider, baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let thirdParty = provider.thirdPartyModelProvider {
            switch thirdParty {
            case .deepSeek:
                return trimmed + "/user/balance"
            case .mimo:
                return "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
            case .custom:
                break
            }
        }
        guard let url = URL(string: trimmed),
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last == "v1" else {
            return trimmed + "/v1/usage"
        }
        return trimmed + "/usage"
    }

    private static func isMimoTokenPlanUsageRequest(provider: CodexBarProvider, url: URL) -> Bool {
        guard provider.thirdPartyModelProvider == .mimo else { return false }
        return url.host?.localizedCaseInsensitiveCompare("platform.xiaomimimo.com") == .orderedSame &&
            url.path == "/api/v1/tokenPlan/usage"
    }

    private static func normalizedMimoCookie(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let normalizedSeparators = trimmed
            .replacingOccurrences(of: "\n", with: ";")
            .replacingOccurrences(of: "\r", with: ";")
            .replacingOccurrences(of: ",", with: ";")

        let candidates = normalizedSeparators
            .split(separator: ";")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        var pairs: [String] = []
        for candidate in candidates {
            guard let separator = candidate.firstIndex(of: "=") else { continue }
            let name = candidate[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let cookieValue = candidate[candidate.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false, cookieValue.isEmpty == false else { continue }
            pairs.append("\(name)=\(cookieValue)")
        }
        guard pairs.isEmpty == false else { return nil }
        return pairs.joined(separator: "; ")
    }


}
