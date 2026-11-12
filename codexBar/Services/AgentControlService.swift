import Darwin
import Foundation

/// Local control endpoint. Requests are dispatched to the same main-thread store as the UI.
final class AgentControlService {
    static let shared = AgentControlService()
    static var socketPath: String { CodexPaths.codexBarRoot.appendingPathComponent("agent.sock").path }
    private let queue = DispatchQueue(label: "codexbar.agent-control", qos: .utility)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    func start() {
        guard listener == -1 else { return }
        let directory = (Self.socketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.enumerated() { bytes[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Do not remove an endpoint owned by a running instance.
        if FileManager.default.fileExists(atPath: Self.socketPath) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            close(probe)
            if connected == 0 { close(fd); return }
            unlink(Self.socketPath)
        }
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return }
        guard chmod(Self.socketPath, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); unlink(Self.socketPath); return
        }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        guard listener != -1 else { return }
        source?.cancel()
        source = nil
        listener = -1
        unlink(Self.socketPath)
    }

    private func acceptClient(_ fd: Int32) {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(10) { break }
        }
        let line = Data(data.prefix { $0 != 10 })
        let response: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: line), let request = object as? [String: Any] {
            response = DispatchQueue.main.sync { AgentControlHandler.handle(request, store: .shared) }
        } else {
            response = ["ok": false, "error": ["code": "invalid_request", "message": "Invalid JSON request"]]
        }
        guard var output = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return }
        output.append(10)
        output.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = write(client, base.advanced(by: sent), bytes.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}

struct AgentControlError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

enum AgentControlHandler {
    static func handle(_ request: [String: Any], store: TokenStore) -> [String: Any] {
        do { return ["ok": true, "result": try perform(request, store: store)] }
        catch let error as AgentControlError { return ["ok": false, "error": ["code": error.code, "message": error.message]] }
        catch { return ["ok": false, "error": ["code": "operation_failed", "message": "Operation failed; check CodexBar configuration."]] }
    }

    private static func required(_ request: [String: Any], _ key: String) throws -> String {
        guard let value = request[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentControlError("invalid_request", "Missing or empty field: \(key)")
        }
        return value
    }

    private static func perform(_ request: [String: Any], store: TokenStore) throws -> [String: Any] {
        switch try required(request, "action") {
        case "status": return status(store)
        case "provider_add":
            let label = request["label"] as? String ?? ""
            do {
                try store.addCustomProvider(label: label, baseURL: try required(request, "base_url"), accountLabel: request["account_label"] as? String ?? "", apiKey: try required(request, "api_key"), selectedModelID: request["model_id"] as? String, pinnedModelIDs: request["model_ids"] as? [String] ?? [], mergeExistingProvider: false)
            } catch TokenStoreError.providerAlreadyExists {
                throw AgentControlError("conflict", "Provider already exists")
            }
        case "provider_edit":
            let id = try required(request, "provider_id")
            guard let provider = store.config.providers.first(where: { $0.id == id && $0.isCustomRelayProvider }) else { throw AgentControlError("not_found", "Custom provider not found") }
            if !["account_id", "account_label", "api_key", "model_id", "model_ids"].contains(where: { request[$0] != nil }) {
                try store.updateCustomProviderMetadata(providerID: id, label: request["label"] as? String ?? provider.label,
                    baseURL: request["base_url"] as? String ?? provider.baseURL ?? "")
                break
            }
            let accountID = request["account_id"] as? String ?? provider.activeAccountId
            guard let account = provider.accounts.first(where: { $0.id == accountID }) else { throw AgentControlError("not_found", "Account not found") }
            try store.updateCustomProvider(providerID: id, request: CustomProviderUpdate(label: request["label"] as? String ?? provider.label, baseURL: request["base_url"] as? String ?? provider.baseURL ?? "", accountID: account.id, accountLabel: request["account_label"] as? String ?? account.label, apiKey: request["api_key"] as? String ?? account.apiKey ?? "", selectedModelID: request["model_id"] as? String, pinnedModelIDs: request["model_ids"] as? [String] ?? []), preserveActiveAccount: true)
        case "routing":
            guard let enabled = request["enabled"] as? Bool else { throw AgentControlError("invalid_request", "enabled must be a boolean") }
            try store.setCodexIntegrationEnabled(enabled)
        case "mode":
            guard let mode = CodexBarOpenAIAccountUsageMode(rawValue: try required(request, "mode")) else { throw AgentControlError("invalid_request", "Invalid mode") }
            try store.setCodexIntegrationEnabled(mode == .hybridProvider)
        case "activate":
            if store.config.openAI.modelRoutingStyle == .catalog,
               store.config.provider(id: request["provider_id"] as? String)?.usesAPIKeyAuth == true { throw CodexModelRoutingError.selectInCodex }
            let providerID = try required(request, "provider_id")
            let accountID = try required(request, "account_id")
            guard let provider = store.config.providers.first(where: { $0.id == providerID }), provider.accounts.contains(where: { $0.id == accountID }) else { throw AgentControlError("not_found", "Provider or account not found") }
            switch provider.kind {
            case .openAIOAuth:
                guard let account = store.oauthAccount(accountID: accountID) else { throw AgentControlError("not_found", "OpenAI account not found") }
                try store.activate(account)
            case .openAICompatible:
                if let model = request["model_id"] as? String {
                    guard provider.kind == .openAICompatible, provider.thirdPartySelection(forAccountID: accountID).pinnedModelIDs.contains(model) else { throw AgentControlError("invalid_request", "Model is not selected for this account") }
                }
                try store.setCodexIntegrationEnabled(true, selection: .init(providerId: providerID, accountId: accountID))
                if let model = request["model_id"] as? String { try store.updateThirdPartySelectedModel(model, providerID: providerID, accountID: accountID) }
            case .openRouter:
                if let model = request["model_id"] as? String {
                    guard provider.openRouterSelection(forAccountID: accountID).pinnedModelIDs.contains(model) else { throw AgentControlError("invalid_request", "Model is not selected for this account") }
                    try store.updateOpenRouterSelectedModel(model, accountID: accountID)
                }
                try store.setCodexIntegrationEnabled(true, selection: .init(providerId: providerID, accountId: accountID))
            }
        case "model":
            if store.config.openAI.modelRoutingStyle == .catalog { throw CodexModelRoutingError.selectInCodex }
            let providerID = try required(request, "provider_id"), accountID = try required(request, "account_id"), model = try required(request, "model_id")
            guard let provider = store.config.providers.first(where: { $0.id == providerID }), provider.accounts.contains(where: { $0.id == accountID }) else { throw AgentControlError("not_found", "Provider or account not found") }
            if provider.kind == .openRouter {
                guard provider.openRouterSelection(forAccountID: accountID).pinnedModelIDs.contains(model) else { throw AgentControlError("invalid_request", "Model is not selected for this account") }
                try store.updateOpenRouterSelectedModel(model, accountID: accountID)
            } else if provider.kind == .openAICompatible {
                guard provider.thirdPartySelection(forAccountID: accountID).pinnedModelIDs.contains(model) else { throw AgentControlError("invalid_request", "Model is not selected for this account") }
                try store.updateThirdPartySelectedModel(model, providerID: providerID, accountID: accountID)
            } else { throw AgentControlError("invalid_request", "Provider does not support model selection") }
        default: throw AgentControlError("invalid_request", "Unknown action")
        }
        return status(store)
    }

    private static func status(_ store: TokenStore) -> [String: Any] {
        let providers: [[String: Any]] = store.config.providers.map { provider in
            let accounts: [[String: Any]] = provider.accounts.map { account in
                let selection = provider.kind == .openRouter ? provider.openRouterSelection(forAccountID: account.id) : provider.thirdPartySelection(forAccountID: account.id)
                return ["id": account.id, "label": account.label, "models": selection.pinnedModelIDs, "selected_model": selection.selectedModelID as Any? ?? NSNull()]
            }
            var safeURL: String? = nil
            if let url = provider.baseURL, var components = URLComponents(string: url) {
                components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
                safeURL = components.string
            }
            return ["id": provider.id, "label": provider.label, "kind": provider.kind.rawValue, "base_url": safeURL as Any? ?? NSNull(), "active_account_id": provider.activeAccountId as Any? ?? NSNull(), "accounts": accounts]
        }
        return ["model_routing_enabled": store.config.openAI.modelRoutingEnabled, "mode": store.config.openAI.accountUsageMode.rawValue, "active_provider_id": store.config.active.providerId as Any? ?? NSNull(), "active_account_id": store.config.active.accountId as Any? ?? NSNull(), "active_model": store.activeModel, "providers": providers]
    }
}
