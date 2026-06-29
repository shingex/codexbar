import Foundation

enum LocalCompressionLayerRoute {
    case responses
    case compact
}

private struct LocalCompressionLayerResult {
    let value: Any
    let changed: Bool
}

protocol LocalCompressionLayerControlling {
    func compress(
        _ body: Data,
        route: LocalCompressionLayerRoute,
        settings: CodexBarOpenAISettings.LocalCompressionSettings
    ) -> Data
}

struct LocalCompressionLayerService: LocalCompressionLayerControlling {
    func compress(
        _ body: Data,
        route: LocalCompressionLayerRoute,
        settings: CodexBarOpenAISettings.LocalCompressionSettings
    ) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        guard let input = json["input"] else {
            return body
        }

        let compactedInput = self.compactInput(input, route: route, settings: settings, depth: 0, inheritedRole: nil)
        guard compactedInput.changed else {
            return body
        }
        json["input"] = compactedInput.value

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

    private func compactInput(
        _ value: Any,
        route: LocalCompressionLayerRoute,
        settings: CodexBarOpenAISettings.LocalCompressionSettings,
        depth: Int,
        inheritedRole: String?
    ) -> LocalCompressionLayerResult {
        if let string = value as? String {
            guard settings.allowsCompression(forRole: inheritedRole) else {
                return LocalCompressionLayerResult(value: string, changed: false)
            }
            let compacted = self.compactText(string, route: route, settings: settings)
            return LocalCompressionLayerResult(value: compacted, changed: compacted != string)
        }
        if let array = value as? [Any] {
            let protectedStart = max(array.count - settings.protectRecentItems, 0)
            var changed = false
            let compactedArray = array.enumerated().map { index, item in
                if depth == 0 && index >= protectedStart {
                    return item
                }
                let result = self.compactInput(
                    item,
                    route: route,
                    settings: settings,
                    depth: depth + 1,
                    inheritedRole: inheritedRole
                )
                changed = changed || result.changed
                return result.value
            }
            return LocalCompressionLayerResult(value: compactedArray, changed: changed)
        }
        if let dictionary = value as? [String: Any] {
            var copy = dictionary
            let role = (dictionary["role"] as? String) ?? inheritedRole
            guard settings.allowsCompression(forRole: role) else {
                return LocalCompressionLayerResult(value: dictionary, changed: false)
            }
            var changed = false
            for (key, value) in dictionary {
                if ["text", "content", "output"].contains(key),
                   let text = value as? String {
                    let compacted = self.compactText(text, route: route, settings: settings)
                    copy[key] = compacted
                    changed = changed || compacted != text
                } else {
                    let result = self.compactInput(
                        value,
                        route: route,
                        settings: settings,
                        depth: depth,
                        inheritedRole: role
                    )
                    copy[key] = result.value
                    changed = changed || result.changed
                }
            }
            return LocalCompressionLayerResult(value: copy, changed: changed)
        }
        return LocalCompressionLayerResult(value: value, changed: false)
    }

    private func compactText(
        _ text: String,
        route: LocalCompressionLayerRoute,
        settings: CodexBarOpenAISettings.LocalCompressionSettings
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > settings.minLinesToCompress || text.count > settings.minCharactersToCompress else {
            return text
        }

        let lineBudget = max(2, Int((Double(lines.count) * settings.targetRatio).rounded(.up)))
        let headBudget = max(1, lineBudget / 2)
        let tailBudget = max(1, lineBudget - headBudget)
        let keptLines = lines.enumerated().filter { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return index < min(4, headBudget) || index >= max(lines.count - min(4, tailBudget), 0) }
            if trimmed.hasPrefix("```") { return true }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
            return index < headBudget || index >= max(lines.count - tailBudget, 0)
        }.map { String($0.element) }

        guard keptLines.joined(separator: "\n").count < text.count else {
            return text
        }
        guard settings.appendCompressionMarker else {
            return keptLines.joined(separator: "\n")
        }
        let suffix = route == .compact ? "\n[compressed locally]" : "\n[compressed locally for streaming]"
        return keptLines.joined(separator: "\n") + suffix
    }
}
