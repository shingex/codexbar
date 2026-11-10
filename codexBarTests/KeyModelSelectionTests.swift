import Foundation
import XCTest

final class KeyModelSelectionTests: CodexBarTestCase {
    func testConcurrentSecureReplacementNeverRemovesTheReadableFile() throws {
        let url = CodexPaths.codexBarRoot.appendingPathComponent("concurrent.json")
        let payload = Data(String(repeating: "complete", count: 256).utf8)
        try CodexPaths.writeSecureFile(payload, to: url)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                try CodexPaths.writeSecureFile(payload, to: url)
                let read = try Data(contentsOf: url)
                XCTAssertEqual(read, payload)
            } catch {
                XCTFail("Concurrent replacement failed: \(error)")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func provider(models: CodexBarKeyModelSelection? = nil) -> CodexBarProvider {
        .init(id: "relay", kind: .openAICompatible, label: "", baseURL: "https://relay.example/v1", defaultModel: "legacy-only",
            activeAccountId: "old", accounts: [.init(id: "old", kind: .apiKey, label: "Old", apiKey: "fixture-old-key", modelSelection: models)])
    }

    private func store(provider: CodexBarProvider, sync: KeyModelSyncSpy = KeyModelSyncSpy()) throws -> TokenStore {
        let config = CodexBarConfig(active: .init(providerId: provider.id, accountId: provider.activeAccountId),
            openAI: .init(disableLocalUsageStats: true), providers: [provider])
        try self.writeConfig(config)
        return TokenStore(syncService: sync, openAIAccountGatewayService: KeyModelGatewaySpy(), openRouterGatewayService: KeyModelOpenRouterSpy())
    }

    func testLegacyKeySelectionsDecodeIntoOneCanonicalField() throws {
        for legacyField in ["openRouterSelection", "thirdPartyModelSelection"] {
            let json = """
            {"id":"key","kind":"api_key","label":"Key","apiKey":"fixture-key", "\(legacyField)":{"selectedModelID":"model-a","pinnedModelIDs":["model-a","model-b"],"cachedModelCatalog":[]}}
            """
            let key = try JSONDecoder().decode(CodexBarProviderAccount.self, from: Data(json.utf8))
            XCTAssertEqual(key.modelSelection?.selectedModelID, "model-a")
            XCTAssertEqual(key.modelSelection?.pinnedModelIDs, ["model-a", "model-b"])
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as? [String: Any])
            XCTAssertNotNil(encoded["modelSelection"])
            XCTAssertNil(encoded["openRouterSelection"])
            XCTAssertNil(encoded["thirdPartyModelSelection"])
        }
    }

    func testLoadDoesNotMaterializeProviderDefaultsIntoInvalidLegacyKey() throws {
        let original = self.provider()
        try self.writeConfig(.init(active: .init(providerId: original.id, accountId: "old"), providers: [original]))
        let loaded = try CodexBarConfigStore().loadOrMigrate()
        let relay = try XCTUnwrap(loaded.provider(id: original.id))
        XCTAssertNil(relay.accounts.first?.modelSelection)
        XCTAssertEqual(relay.thirdPartyEffectiveModelID(forAccountID: "old"), "legacy-only")
        XCTAssertEqual(relay.accounts.first?.id, "old")
        XCTAssertEqual(relay.displayName, "relay.example")
    }

    func testInvalidLegacyKeyCanRemainButEditingRequiresARequestModel() throws {
        let store = try self.store(provider: self.provider())
        XCTAssertThrowsError(try store.updateCustomProviderAccount(providerID: "relay", accountID: "old", label: "Changed", apiKey: "fixture-new-key"))
        XCTAssertEqual(store.config.provider(id: "relay")?.accounts.first?.label, "Old")
        XCTAssertNil(store.config.provider(id: "relay")?.accounts.first?.modelSelection)
        try store.updateCustomProviderMetadata(providerID: "relay", label: "", baseURL: "https://changed.example/v1")
        XCTAssertEqual(store.config.provider(id: "relay")?.displayName, "changed.example")
        XCTAssertNil(store.config.provider(id: "relay")?.accounts.first?.modelSelection)
        try store.updateCustomProviderAccount(providerID: "relay", accountID: "old", label: "Changed", apiKey: "fixture-new-key",
            selectedModelID: "model-a", pinnedModelIDs: ["model-a", "model-b"])
        XCTAssertEqual(store.config.provider(id: "relay")?.accounts.first?.modelSelection?.selectedModelID, "model-a")
    }

    func testNewKeyRequiresModelAndDoesNotInheritSiblingSelection() throws {
        let store = try self.store(provider: self.provider(models: .init(selectedModelID: "model-a", pinnedModelIDs: ["model-a", "model-c"])))
        XCTAssertThrowsError(try store.addCustomProviderAccount(providerID: "relay", label: "New", apiKey: "fixture-key"))
        XCTAssertEqual(store.config.provider(id: "relay")?.accounts.count, 1)
        try store.addCustomProviderAccount(providerID: "relay", label: "New", apiKey: "fixture-new", selectedModelID: "model-b", pinnedModelIDs: ["model-b"])
        let provider = try XCTUnwrap(store.config.provider(id: "relay"))
        let newKey = try XCTUnwrap(provider.accounts.last)
        XCTAssertEqual(newKey.modelSelection?.pinnedModelIDs, ["model-b"])
        try store.updateThirdPartySelectedModel("model-b2", providerID: "relay", accountID: newKey.id)
        XCTAssertEqual(store.config.provider(id: "relay")?.accounts.first?.modelSelection?.selectedModelID, "model-a")
        XCTAssertEqual(store.config.provider(id: "relay")?.accounts.first?.modelSelection?.pinnedModelIDs, ["model-a", "model-c"])
        XCTAssertEqual(store.config.provider(id: "relay")?.defaultModel, "legacy-only")
    }

    func testProviderNameIsOptionalButNewKeyModelIsNot() throws {
        let store = try self.store(provider: self.provider())
        XCTAssertThrowsError(try store.addCustomProvider(label: "", baseURL: "https://new.example/v1", accountLabel: "", apiKey: "fixture-key"))
        try store.addCustomProvider(label: "", baseURL: "https://new.example/v1", accountLabel: "", apiKey: "fixture-key", selectedModelID: "custom-model")
        let provider = try XCTUnwrap(store.config.providers.first { $0.baseURL == "https://new.example/v1" })
        XCTAssertEqual(provider.displayName, "new.example")
        XCTAssertEqual(provider.accounts.first?.modelSelection?.selectedModelID, "custom-model")
    }

    func testPresetKeyAcceptsAnExplicitCustomModelWithoutInheritingDefaults() throws {
        let store = try self.store(provider: self.provider())
        try store.addThirdPartyModelProvider(provider: .deepSeek, label: "Custom name", baseURL: "https://api.deepseek.com/v1",
            selectedModelID: "custom-upstream-model", pinnedModelIDs: [], accountLabel: "New", apiKey: "fixture")
        let provider = try XCTUnwrap(store.config.providers.first { $0.thirdPartyModelProvider == .deepSeek })
        XCTAssertEqual(provider.displayName, "Custom name")
        XCTAssertEqual(provider.activeAccount?.modelSelection?.selectedModelID, "custom-upstream-model")
        XCTAssertEqual(provider.activeAccount?.modelSelection?.pinnedModelIDs, ["custom-upstream-model"])
    }

    func testKeyWritesRequireAProviderRequestAddress() throws {
        var provider = self.provider(models: .init(selectedModelID: "model-a"))
        provider.baseURL = nil
        let store = try self.store(provider: provider)
        XCTAssertThrowsError(try store.addCustomProviderAccount(providerID: "relay", label: "New", apiKey: "fixture", selectedModelID: "model-b"))
        XCTAssertThrowsError(try store.updateCustomProviderAccount(providerID: "relay", accountID: "old", label: "Old", apiKey: "fixture", selectedModelID: "model-a"))
        XCTAssertEqual(store.config.provider(id: "relay")?.accounts.count, 1)
    }

    func testKeyWithModelsButNoCurrentModelCannotBeSaved() throws {
        XCTAssertThrowsError(try TokenStore.validatedKeyModels(nil, pinned: ["model-a", "model-b"]))
        XCTAssertThrowsError(try TokenStore.validatedKeyModels("  ", pinned: ["model-a"]))
        XCTAssertEqual(try TokenStore.validatedKeyModels("custom-model", pinned: []).selectedModelID, "custom-model")
    }
}

private final class KeyModelSyncSpy: CodexSynchronizing {
    var calls = 0
    func synchronize(config: CodexBarConfig) throws { self.calls += 1 }
}

private final class KeyModelGatewaySpy: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(accounts: [TokenAccount], quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode, routeTarget: OpenAIAccountGatewayRouteTarget) {}
    func currentRoutedAccountID() -> String? { nil }
    func isHandlingHighFrequencyRequests(recentActivityWindow: TimeInterval) -> Bool { false }
}

private final class KeyModelOpenRouterSpy: OpenRouterGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
    func isHandlingHighFrequencyRequests(recentActivityWindow: TimeInterval) -> Bool { false }
}
