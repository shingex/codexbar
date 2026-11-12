import AppKit
import SwiftUI
import Foundation
import XCTest

final class CodexModelRoutingTests: CodexBarTestCase {
    private func config() -> CodexBarConfig {
        let account = CodexBarProviderAccount(id: "official", kind: .oauthTokens, label: "Official",
            openAIAccountId: "remote-official", accessToken: "test-access", refreshToken: "test-refresh", idToken: "test-id")
        let other = CodexBarProviderAccount(id: "other", kind: .oauthTokens, label: "Other",
            openAIAccountId: "remote-other", accessToken: "test-other-access", refreshToken: "test-other-refresh", idToken: "test-other-id")
        let provider = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: account.id, accounts: [account, other])
        return CodexBarConfig(active: .init(providerId: provider.id, accountId: account.id), providers: [provider])
    }

    private func prepareCatalog() throws {
        try CodexPaths.ensureDirectories()
        let catalog = Data(#"{"models":[{"slug":"gpt-native","display_name":"Native","tool_mode":"code","prefer_websockets":true,"context_window":200000,"use_responses_lite":true,"multi_agent_version":"v1","unknown_future_field":{"keep":true}}]}"#.utf8)
        try CodexPaths.writeSecureFile(catalog, to: CodexPaths.codexRoot.appendingPathComponent("models_cache.json"))
    }

    func testLegacyAggregateModeMigratesToSwitchAndNewIntegrationDefaultsOff() throws {
        let settings = try JSONDecoder().decode(CodexBarOpenAISettings.self,
            from: Data(#"{"accountUsageMode":"aggregate_gateway"}"#.utf8))
        XCTAssertEqual(settings.accountUsageMode, .switchAccount)
        XCTAssertFalse(settings.modelRoutingEnabled)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("aggregate_gateway"))
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.allCases, [.switchAccount, .hybridProvider])
    }

    func testCatalogAddsStableConservativeAliasWithoutChangingNativeCapabilities() throws {
        try self.prepareCatalog()
        let input = try Data(contentsOf: CodexPaths.codexRoot.appendingPathComponent("models_cache.json"))
        let data = try CodexModelRouting.catalogData(from: input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["tool_mode"] as? String, "code")
        XCTAssertEqual(models[0]["context_window"] as? Int, 200_000)
        XCTAssertNotNil(models[0]["unknown_future_field"])
        XCTAssertEqual(models[0]["prefer_websockets"] as? Bool, false)
        let alias = models[1]
        XCTAssertEqual(alias["slug"] as? String, "codexbar")
        XCTAssertEqual(alias["tool_mode"] as? String, "direct")
        XCTAssertEqual(alias["use_responses_lite"] as? Bool, false)
        XCTAssertEqual(alias["context_window"] as? Int, 200_000)
        XCTAssertTrue(alias["auto_compact_token_limit"] is NSNull)
        XCTAssertNil(alias["multi_agent_version"])
        let again = try CodexModelRouting.catalogData(from: data)
        XCTAssertEqual(data, again)
    }

    func testManagedAliasUsesCachedDeepSeekContextAndRefreshDoesNotTouchCodexSettings() throws {
        try self.prepareCatalog()
        let cache = Data(#"{"models":[{"id":"deepseek-v4.1-flash","name":"Flash","contextLimit":1000000,"supportsTools":true,"reasoningEfforts":[],"inputModalities":[],"nativeAPIs":[]}],"fetchedAt":0}"#.utf8)
        try CodexPaths.writeSecureFile(cache, to: CodexPaths.openCodeModelCatalogURL(plan: .go))
        var config = self.config()
        let account = CodexBarProviderAccount(id: "key", kind: .apiKey, label: "Key", apiKey: "fixture", modelSelection: .init(selectedModelID: "deepseek-v4.1-flash"))
        let provider = CodexBarProvider(id: "opencode", kind: .openAICompatible, label: "OpenCode", baseURL: CodexBarOpenCodePlan.go.defaultBaseURL,
            thirdPartyModelProvider: .openCode, openCodePlan: .go, activeAccountId: account.id, accounts: [account])
        config.providers.append(provider)
        config.active = .init(providerId: provider.id, accountId: account.id)
        config.openAI.modelRoutingEnabled = true
        XCTAssertEqual(CodexModelRouting.targetContextWindow(config: config), 1_000_000)
        let source = try Data(contentsOf: CodexPaths.codexRoot.appendingPathComponent("models_cache.json"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexModelRouting.catalogData(from: source)) as? [String: Any])
        var models = try XCTUnwrap(old["models"] as? [[String: Any]])
        models[models.count - 1]["context_window"] = 32_768
        models[models.count - 1]["auto_compact_token_limit"] = 29_491
        old["models"] = models
        try CodexPaths.writeSecureFile(JSONSerialization.data(withJSONObject: old), to: CodexModelRouting.catalogURL)
        let settings = Data("model_context_window = 123456\n# unrelated\n".utf8)
        try CodexPaths.writeSecureFile(settings, to: CodexPaths.configTomlURL)
        try CodexModelRouting.refreshCatalogContext(config: config)
        let refreshed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: CodexModelRouting.catalogURL)) as? [String: Any])
        let entries = try XCTUnwrap(refreshed["models"] as? [[String: Any]])
        let alias = try XCTUnwrap(entries.first { $0["slug"] as? String == "codexbar" })
        XCTAssertEqual(alias["context_window"] as? Int, 1_000_000)
        XCTAssertEqual(alias["max_context_window"] as? Int, 1_000_000)
        XCTAssertTrue(alias["auto_compact_token_limit"] is NSNull)
        XCTAssertEqual(entries[0]["context_window"] as? Int, 200_000)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.configTomlURL), settings)
        let stable = try Data(contentsOf: CodexModelRouting.catalogURL)
        try CodexModelRouting.refreshCatalogContext(config: config)
        XCTAssertEqual(try Data(contentsOf: CodexModelRouting.catalogURL), stable)
    }

    func testCatalogShowsSelectedOAuthInListAndExplicitSwitchUpdatesOnlyLogin() throws {
        try self.prepareCatalog()
        var config = self.config()
        config.openAI.modelRoutingEnabled = true
        config.openAI.modelRoutingStyle = .catalog
        XCTAssertEqual(MenuPanelPresentation.selectedOAuthAccountID(config: config), "official")
        XCTAssertNil(MenuPanelPresentation.oauthAccountIDShownInSummary(config: config))
        config.openAI.modelRoutingStyle = .follow
        XCTAssertEqual(MenuPanelPresentation.oauthAccountIDShownInSummary(config: config), "official")
        config.openAI.modelRoutingStyle = .catalog

        let original = Data("model_provider = \"openai\"\nservice_tier = \"fast\"\n".utf8)
        let auth = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"old","account_id":"remote-official"},"client_id":"old-client","custom":"keep"}"#.utf8)
        try CodexPaths.writeSecureFile(original, to: CodexPaths.configTomlURL)
        try CodexPaths.writeSecureFile(auth, to: CodexPaths.authURL)

        _ = try config.activateOAuthAccount(accountID: "other")
        let sync = CodexSyncService()
        try sync.switchOAuthLogin(config: config) {}
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: CodexPaths.authURL)) as? [String: Any])
        let tokens = try XCTUnwrap(updated["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["account_id"] as? String, "remote-other")
        XCTAssertEqual(updated["custom"] as? String, "keep")
        XCTAssertNil(updated["client_id"])
        XCTAssertEqual(try Data(contentsOf: CodexPaths.configTomlURL), original)
    }

    func testEnableAndDisablePreserveOAuthAndUnrelatedOldConfiguration() throws {
        try self.prepareCatalog()
        let auth = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"running-client-token","account_id":"current-client-account"},"extra":"preserve"}"#.utf8)
        let original = """
        model = "gpt-native"
        model_provider = "openai"
        openai_base_url = "https://original.example/v1"
        service_tier = "fast"
        custom_setting = "preserve"

        [features]
        enable_request_compression = true
        another_feature = true

        [mcp_servers.example]
        command = "example"
        """ + "\n"
        try CodexPaths.writeSecureFile(auth, to: CodexPaths.authURL)
        try CodexPaths.writeSecureFile(Data(original.utf8), to: CodexPaths.configTomlURL)
        var config = self.config()
        config.openAI.modelRoutingEnabled = true
        let service = CodexSyncService()
        try service.synchronize(config: config)
        let enabled = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        XCTAssertTrue(enabled.contains("model_provider = \"openai\""))
        XCTAssertTrue(enabled.contains("openai_base_url = \"http://127.0.0.1:1456/v1\""))
        XCTAssertTrue(enabled.contains("model_catalog_json ="))
        XCTAssertTrue(enabled.contains("service_tier = \"fast\""))
        XCTAssertTrue(enabled.contains("another_feature = true"))
        XCTAssertTrue(enabled.contains("[mcp_servers.example]\ncommand = \"example\""))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), auth)
        // A second sync must not overwrite the original restoration state.
        try service.synchronize(config: config)
        config.openAI.modelRoutingEnabled = false
        try service.synchronize(config: config)
        let disabled = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        XCTAssertFalse(disabled.contains("openai_base_url"))
        XCTAssertFalse(disabled.contains("model_catalog_json"))
        XCTAssertTrue(disabled.contains("enable_request_compression = true"))
        XCTAssertTrue(disabled.contains("custom_setting = \"preserve\""))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), auth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexModelRouting.syncStateURL.path))
    }

    func testFailedEnableRestoresAllFilesAndDoesNotLeaveRestorationState() throws {
        try self.prepareCatalog()
        let original = Data("model = \"gpt-native\"\n".utf8)
        try CodexPaths.writeSecureFile(original, to: CodexPaths.configTomlURL)
        var config = self.config()
        config.openAI.modelRoutingEnabled = true
        var failOnce = true
        let service = CodexSyncService(writeSecureFile: { data, url in
            if url == CodexPaths.configTomlURL && failOnce {
                failOnce = false
                throw URLError(.cannotWriteToFile)
            }
            try CodexPaths.writeSecureFile(data, to: url)
        })
        XCTAssertThrowsError(try service.synchronize(config: config))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.configTomlURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexModelRouting.syncStateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexModelRouting.catalogURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    @MainActor
    func testSettingsStageIntegrationAndTargetUntilSave() throws {
        let config = self.config()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: config.oauthTokenAccounts())
        coordinator.setModelRoutingEnabled(true)
        coordinator.selectRouteTarget(.openAIAccount(accountID: "other", mode: .switchAccount))
        XCTAssertTrue(coordinator.hasStagedRouteChange)
        XCTAssertFalse(config.openAI.modelRoutingEnabled)
        coordinator.cancel()
        XCTAssertFalse(coordinator.draft.route.modelRoutingEnabled)
        XCTAssertFalse(coordinator.hasStagedRouteChange)
    }

    func testLegacySyncPreservesUnmanagedModelCatalog() throws {
        try self.prepareCatalog()
        let catalogPath = CodexPaths.codexRoot.appendingPathComponent("custom-models.json").path
        let original = """
        model = "gpt-native"
        model_catalog_json = "\(catalogPath)"
        """ + "\n"
        try CodexPaths.writeSecureFile(Data(original.utf8), to: CodexPaths.configTomlURL)
        try CodexSyncService().synchronize(config: self.config())
        XCTAssertTrue(try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8).contains("model_catalog_json"))
    }

    func testExitKeepsOAuthInsteadOfRestoringThePreviousAPIKey() throws {
        try self.prepareCatalog()
        let auth = Data(#"{"OPENAI_API_KEY":"fixture-original-key"}"#.utf8)
        try CodexPaths.writeSecureFile(auth, to: CodexPaths.authURL)
        try CodexPaths.writeSecureFile(Data("model = \"gpt-native\"\n".utf8), to: CodexPaths.configTomlURL)
        var config = self.config()
        config.openAI.modelRoutingEnabled = true
        let service = CodexSyncService()
        try service.synchronize(config: config)
        let enabled = try JSONSerialization.jsonObject(with: Data(contentsOf: CodexPaths.authURL)) as? [String: Any]
        XCTAssertNotNil(enabled?["tokens"])
        config.openAI.modelRoutingEnabled = false
        try service.synchronize(config: config)
        let exited = try JSONSerialization.jsonObject(with: Data(contentsOf: CodexPaths.authURL)) as? [String: Any]
        XCTAssertNotNil(exited?["tokens"])
        XCTAssertTrue(exited?["OPENAI_API_KEY"] == nil || exited?["OPENAI_API_KEY"] is NSNull)
    }

    func testIntegrationMergesOriginalCatalogAndRestoresItsPathAfterRepeatedSync() throws {
        try self.prepareCatalog()
        let customURL = CodexPaths.codexRoot.appendingPathComponent("custom-models.json")
        let customData = Data(#"{"models":[{"slug":"user-model","display_name":"My model","custom":true}]}"#.utf8)
        try CodexPaths.writeSecureFile(customData, to: customURL)
        let text = "model = \"gpt-native\"\nmodel_catalog_json = \"\(customURL.path)\"\n"
        try CodexPaths.writeSecureFile(Data(text.utf8), to: CodexPaths.configTomlURL)
        var config = self.config()
        config.openAI.modelRoutingEnabled = true
        let service = CodexSyncService()
        try service.synchronize(config: config)
        try service.synchronize(config: config)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: CodexModelRouting.catalogURL)) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(Set(models.compactMap { $0["slug"] as? String }), ["gpt-native", "user-model", "codexbar"])
        XCTAssertEqual(try Data(contentsOf: customURL), customData)
        config.openAI.modelRoutingEnabled = false
        try service.synchronize(config: config)
        XCTAssertTrue(try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8).contains("model_catalog_json = \"\(customURL.path)\""))
    }

    @MainActor
    func testIntegrationDraftSwitchesToHybridAndSurvivesExternalRefresh() {
        let config = self.config()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: config.oauthTokenAccounts())
        coordinator.setModelRoutingEnabled(true)
        XCTAssertEqual(coordinator.draft.route.mode, .hybridProvider)
        XCTAssertEqual(coordinator.draft.route.target, .openAIAccount(accountID: "official", mode: .hybridProvider))
        coordinator.reconcileExternalState(config: config, accounts: config.oauthTokenAccounts())
        XCTAssertTrue(coordinator.draft.route.modelRoutingEnabled)
        XCTAssertTrue(coordinator.hasStagedRouteChange)
        coordinator.setModelRoutingEnabled(false)
        XCTAssertEqual(coordinator.draft.route.mode, .switchAccount)
    }

    @MainActor
    func testMainPanelToggleRendersBothLanguagesAndThemes() throws {
        let originalLanguage = L.languageOverride
        defer { L.languageOverride = originalLanguage }
        let directory = URL(fileURLWithPath: "/tmp/codexbar-model-routing-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for chinese in [true, false] {
            L.languageOverride = chinese
            for dark in [false, true] {
                for enabled in [false, true] {
                    let view = CodexIntegrationToggle(enabled: .constant(enabled))
                        .padding(16).frame(width: 400, alignment: .topLeading)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertLessThanOrEqual(host.fittingSize.height, 230)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(enabled ? "on" : "off").png"
                    try data.write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }

    func testOfficialTransportDoesNotUseShortResourceLimitOrGatewayRetries() {
        let policy = OpenAIAccountGatewayUpstreamTransportConfiguration.official
        XCTAssertEqual(policy.requestTimeout, 300)
        XCTAssertEqual(policy.resourceTimeout, 604_800)
        XCTAssertEqual(policy.streamStartMaxAttempts, 1)
    }
}
