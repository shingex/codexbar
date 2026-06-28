import Foundation

enum LocalCompressionLayerRoute {
    case responses
    case compact
}

protocol LocalCompressionLayerControlling {
    func shouldEnable(for mode: CodexBarOpenAIAccountUsageMode) -> Bool
    func compress(_ body: Data, route: LocalCompressionLayerRoute) -> Data
}

struct LocalCompressionLayerService: LocalCompressionLayerControlling {
    func shouldEnable(for mode: CodexBarOpenAIAccountUsageMode) -> Bool {
        switch mode {
        case .switchAccount:
            return false
        case .aggregateGateway, .hybridProvider:
            return true
        }
    }

    func compress(_ body: Data, route: LocalCompressionLayerRoute) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        guard let input = json["input"] else {
            return body
        }

        json["input"] = self.compactInput(input, route: route)

        if route == .responses {
            json["stream"] = true
            if json["store"] == nil {
                json["store"] = false
            }
        }

        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return data
    }

    private func compactInput(_ value: Any, route: LocalCompressionLayerRoute) -> Any {
        if let string = value as? String {
            return self.compactText(string, route: route)
        }
        if let array = value as? [Any] {
            return array.map { self.compactInput($0, route: route) }
        }
        if let dictionary = value as? [String: Any] {
            var copy = dictionary
            for key in ["text", "content", "output"] {
                if let text = copy[key] as? String {
                    copy[key] = self.compactText(text, route: route)
                }
            }
            return copy
        }
        return value
    }

    private func compactText(_ text: String, route: LocalCompressionLayerRoute) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 40 || text.count > 2048 else {
            return text
        }

        let keptLines = lines.enumerated().filter { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return index < 4 || index >= max(lines.count - 4, 0) }
            if trimmed.hasPrefix("```") { return true }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
            return index < 6 || index >= max(lines.count - 6, 0)
        }.map { String($0.element) }

        let suffix = route == .compact ? "\n[compressed locally]" : "\n[compressed locally for streaming]"
        return keptLines.joined(separator: "\n") + suffix
    }
}
