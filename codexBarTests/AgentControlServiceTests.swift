import Foundation
import XCTest

@MainActor
final class AgentControlServiceTests: CodexBarTestCase {
    func testProviderAddEditConflictAndSecretRedaction() throws {
        let store = TokenStore(syncService: AgentSyncStub())
        let add: [String: Any] = ["action": "provider_add", "label": "Example", "base_url": "https://example.com/v1", "api_key": "secret-test-key", "model_id": "gpt-test", "model_ids": ["gpt-test"]]
        XCTAssertEqual(AgentControlHandler.handle(add, store: store)["ok"] as? Bool, true)
        let provider = try XCTUnwrap(store.customProviders.first)
        let duplicate = AgentControlHandler.handle(add.merging(["label": "Different name", "base_url": "https://example.com/v2"]) { _, new in new }, store: store)
        XCTAssertEqual((duplicate["error"] as? [String: String])?["code"], "conflict")
        XCTAssertEqual(store.customProviders.count, 1)
        XCTAssertEqual(store.customProviders.first?.accounts.count, 1)
        try store.addCustomProviderAccount(providerID: provider.id, label: "Other", apiKey: "other-secret", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let other = try XCTUnwrap(store.customProviders.first?.accounts.first(where: { $0.label == "Other" }))
        let activeID = store.customProviders.first?.activeAccountId
        let edit = AgentControlHandler.handle(["action": "provider_edit", "provider_id": provider.id, "account_id": other.id, "label": "Changed"], store: store)
        XCTAssertEqual(store.customProviders.first?.activeAccountId, activeID)
        XCTAssertEqual(edit["ok"] as? Bool, true)
        XCTAssertEqual(store.customProviders.first?.activeAccount?.apiKey, "secret-test-key")
        XCTAssertEqual(store.customProviders.first?.label, "Changed")
        let output = try JSONSerialization.data(withJSONObject: edit)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("secret-test-key"))
    }

    func testInvalidRequestsAndMissingTargets() {
        let store = TokenStore(syncService: AgentSyncStub())
        for request: [String: Any] in [["action": "unknown"], ["action": "mode", "mode": "wrong"], ["action": "activate", "provider_id": "missing", "account_id": "missing"]] {
            XCTAssertEqual(AgentControlHandler.handle(request, store: store)["ok"] as? Bool, false)
        }
    }

    func testSocketHasUserOnlyPermissions() throws {
        let shortHome = URL(fileURLWithPath: "/tmp/cb-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: shortHome, withIntermediateDirectories: true)
        CodexPaths.homeOverrideForTesting = shortHome
        let service = AgentControlService()
        service.start()
        defer {
            service.stop()
            try? FileManager.default.removeItem(at: shortHome)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: AgentControlService.socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testModeAliasesUseTheUnifiedSwitch() throws {
        let account = try self.makeOAuthAccount(accountID: "oauth", email: "test@example.test")
        let key = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
        let provider = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: key.id, accounts: [key])
        try self.writeConfig(.init(active: .init(providerId: provider.id, accountId: key.id), providers: [provider]))
        let store = TokenStore(syncService: AgentSyncStub())
        XCTAssertEqual(AgentControlHandler.handle(["action": "mode", "mode": "hybrid_provider"], store: store)["ok"] as? Bool, true)
        XCTAssertTrue(store.config.openAI.modelRoutingEnabled)
        XCTAssertEqual(AgentControlHandler.handle(["action": "routing", "enabled": false], store: store)["ok"] as? Bool, true)
        XCTAssertFalse(store.config.openAI.modelRoutingEnabled)
        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
    }
}

private struct AgentSyncStub: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws {}
}
