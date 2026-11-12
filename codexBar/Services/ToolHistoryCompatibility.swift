import Foundation

/// Repairs only tool records. Associations are resolved once for the entire request.
enum ToolHistoryCompatibility {
    struct InvalidAssociation: LocalizedError {
        var errorDescription: String? { "工具历史缺少可唯一关联的 call_id，无法安全继续此会话。" }
    }
    static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    static func normalize(_ data: Data) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        if root["type"] as? String == "response.create", let response = root["response"] as? [String: Any] {
            let original = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            let repaired = try normalize(original)
            guard repaired != original else { return data }
            root["response"] = try JSONSerialization.jsonObject(with: repaired)
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
        guard let items = root["input"] as? [Any] else { return data }
        var changed = false
        var aliases: [String: String] = [:]
        var pending: [(String, String, String?)] = []
        var deferredContext: [Any] = []
        var normalized: [Any] = []
        for index in items.indices {
            guard var item = items[index] as? [String: Any] else { normalized.append(items[index]); continue }
            let type = item["type"] as? String ?? ""
            if type == "function_call" || type == "custom_tool_call" {
                let oldID = nonempty(item["id"])
                let oldCall = nonempty(item["call_id"])
                let call = oldCall ?? oldID ?? "call_codexbar_history_\(index)"
                if oldCall == nil { item["call_id"] = call; changed = true }
                for alias in [oldCall, oldID].compactMap({ $0 }) {
                    if let existing = aliases[alias], existing != call { throw InvalidAssociation() }
                    aliases[alias] = call
                }
                let prefix = type == "custom_tool_call" ? "ctc" : "fc"
                if let id = oldID, !id.hasPrefix(prefix + "_") {
                    item["id"] = prefix + "_codexbar_history_\(index)"
                    changed = true
                }
                pending.append((call, type, nonempty(item["name"])))
            } else if type == "function_call_output" || type == "custom_tool_call_output" {
                let call = nonempty(item["call_id"])
                let resultAlias = nonempty(item["id"])
                let expected = type == "custom_tool_call_output" ? "custom_tool_call" : "function_call"
                let resolved: String
                if let call { resolved = aliases[call] ?? call }
                else if let resultAlias, let paired = aliases[resultAlias] { resolved = paired }
                else if let name = nonempty(item["name"]) ?? nonempty(item["namespace"]) {
                    let matches = pending.filter { $0.1 == expected && $0.2 == name }
                    if matches.count == 1 { resolved = matches[0].0 }
                    else if !matches.isEmpty { throw InvalidAssociation() }
                    else {
                        let output = item["output"] ?? item["content"] ?? ""
                        let text: String
                        if let value = output as? String { text = value }
                        else { text = String(data: try JSONSerialization.data(withJSONObject: output, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8) ?? "" }
                        let context: [String: Any] = ["type": "message", "role": "user", "content": [["type": "input_text", "text": name + ": " + text]]]
                        // Context updates have no invocation. Preserve their contents without sending
                        // invalid tool outputs or promoting external data into system instructions.
                        if pending.isEmpty { normalized.append(context) } else { deferredContext.append(context) }
                        changed = true
                        continue
                    }
                } else {
                    let candidates = pending.filter { $0.1 == expected }
                    guard candidates.count == 1 else { throw InvalidAssociation() }
                    resolved = candidates[0].0
                }
                if call != resolved { item["call_id"] = resolved; changed = true }
                pending.removeAll { $0.0 == resolved }
            }
            normalized.append(item)
            if pending.isEmpty && !deferredContext.isEmpty {
                normalized.append(contentsOf: deferredContext)
                deferredContext.removeAll()
            }
        }
        guard changed else { return data }
        normalized.append(contentsOf: deferredContext)
        root["input"] = normalized
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
