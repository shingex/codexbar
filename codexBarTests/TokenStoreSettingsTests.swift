import Foundation
import XCTest

@MainActor
final class TokenStoreSettingsTests: CodexBarTestCase {
    func testLegacyLocalStatisticsFieldsAreIgnoredWithoutLosingAPIUsage() throws {
        var config = CodexBarConfig()
        config.openAI.usageDisplayMode = .remaining
        config.providers = [CodexBarProvider(
            id: "provider", kind: .openAICompatible, label: "Provider",
            usageState: .init(data: .init(unit: "USD", today: .init(used: 20, limit: 100)))
        )]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        legacy["modelPricing"] = ["gpt-5.4": ["inputUSDPerToken": 0.00001]]
        var openAI = try XCTUnwrap(legacy["openAI"] as? [String: Any])
        openAI["disableLocalUsageStats"] = true
        openAI["showsMenuBarUsageSummary"] = false
        legacy["openAI"] = openAI

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(decoded), try encoder.encode(config))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let savedOpenAI = try XCTUnwrap(saved["openAI"] as? [String: Any])
        XCTAssertNil(saved["modelPricing"])
        XCTAssertNil(savedOpenAI["disableLocalUsageStats"])
        XCTAssertNil(savedOpenAI["showsMenuBarUsageSummary"])
        XCTAssertEqual(ProviderUsageFormat.quotaStatusTitle(for: decoded.providers[0], mode: .remaining), "80%")
    }

    func testSaveOpenAIAccountSettingsWritesAccountOrderAndMode() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_beta", email: "beta@example.com"))

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount
            )
        )

        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_beta", "acct_alpha"])
    }

    func testSaveOpenAIUsageSettingsOnlyTouchesUsageFields() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha"],
                accountUsageMode: .switchAccount
            )
        )

        try store.saveOpenAIUsageSettings(
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining
            )
        )

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .remaining)
        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_alpha"])
    }

    func testSaveUsageDisplayModePersistsOnlyDisplayMode() throws {
        var config = CodexBarConfig()
        config.openAI.usageDisplayMode = .remaining
        config.openAI.accountOrder = ["acct_beta", "acct_alpha"]
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveUsageDisplayMode(.used)

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .used)

        let persisted = try CodexBarConfigStore().load()
        XCTAssertEqual(persisted.openAI.usageDisplayMode, .used)
        XCTAssertEqual(persisted.openAI.accountOrder, ["acct_beta", "acct_alpha"])
    }

    func testSaveDesktopSettingsOnlyTouchesPreferredPath() throws {
        let store = TokenStore.shared
        store.load()
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: [],
                accountUsageMode: .switchAccount
            )
        )

        let validAppURL = try self.makeValidCodexApp(named: "Test/Codex.app")
        try store.saveDesktopSettings(
            DesktopSettingsUpdate(preferredCodexAppPath: validAppURL.path)
        )

        XCTAssertEqual(store.config.desktop.preferredCodexAppPath, validAppURL.path)
    }

    func testRestoreActiveSelectionPersistsPreviousCompatibleProvider() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://a.example.com/v1",
            accountLabel: "Alpha",
            apiKey: "sk-provider-a"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let providerA = try XCTUnwrap(store.config.providers.first(where: { $0.label == "Provider A" }))
        let accountA = try XCTUnwrap(providerA.activeAccount)
        try store.activateCustomProvider(providerID: providerA.id, accountID: accountA.id)

        try store.addCustomProvider(
            label: "Provider B",
            baseURL: "https://b.example.com/v1",
            accountLabel: "Beta",
            apiKey: "sk-provider-b"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        XCTAssertEqual(store.activeProvider?.label, "Provider A")

        try store.restoreActiveSelection(
            activeProviderID: providerA.id,
            activeAccountID: accountA.id
        )

        XCTAssertEqual(store.activeProvider?.id, providerA.id)
        XCTAssertEqual(store.activeProviderAccount?.id, accountA.id)
    }

    func testAddCustomProviderDoesNotActivateInCurrentMode() throws {
        let oauthAccount = TokenAccount(
            email: "active@example.com",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            expiresAt: nil,
            isActive: true
        )
        var config = CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: "openai-oauth",
                accountId: oauthAccount.accountId
            ),
            openAI: CodexBarOpenAISettings(accountUsageMode: .hybridProvider)
        )
        _ = config.upsertOAuthAccount(oauthAccount, activate: true)
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://a.example.com/v1",
            accountLabel: "Alpha",
            apiKey: "sk-provider-a"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])

        XCTAssertEqual(store.config.openAI.accountUsageMode, .hybridProvider)
        XCTAssertEqual(store.activeProvider?.kind, .openAIOAuth)
        XCTAssertEqual(store.activeProviderAccount?.id, oauthAccount.accountId)
        XCTAssertNotNil(store.config.providers.first(where: { $0.label == "Provider A" }))
    }

    func testAddCustomProviderNamedOpenRouterAvoidsReservedProviderID() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "OpenRouter",
            baseURL: "https://relay.example.com/v1",
            accountLabel: "Relay",
            apiKey: "sk-relay"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])

        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "OpenRouter" }))
        XCTAssertEqual(provider.kind, .openAICompatible)
        XCTAssertEqual(provider.id, "openrouter-custom")
    }

    func testUpdateCustomProviderEditsCurrentValuesWithoutChangingProviderID() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://old.example.com/v1",
            accountLabel: "Old Account",
            apiKey: "sk-old"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let addedProvider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "Provider A" }))
        let providerID = addedProvider.id
        let accountID = try XCTUnwrap(addedProvider.activeAccount?.id)
        try store.activateCustomProvider(providerID: providerID, accountID: accountID)

        try store.updateCustomProvider(
            providerID: providerID,
            request: CustomProviderUpdate(
                label: "Provider B",
                baseURL: "https://new.example.com/v1",
                accountID: accountID,
                accountLabel: "New Account",
                apiKey: "sk-new"
            )
        )

        let provider = try XCTUnwrap(store.config.provider(id: providerID))
        XCTAssertEqual(provider.id, providerID)
        XCTAssertEqual(provider.label, "Provider B")
        XCTAssertEqual(provider.baseURL, "https://new.example.com/v1")
        XCTAssertEqual(provider.activeAccountId, accountID)
        XCTAssertEqual(provider.activeAccount?.label, "New Account")
        XCTAssertEqual(provider.activeAccount?.apiKey, "sk-new")
        XCTAssertEqual(store.activeProvider?.id, providerID)
        XCTAssertEqual(store.activeProviderAccount?.id, accountID)
    }

    func testUpdateCustomProviderAccountDoesNotActivateEditedInactiveAccount() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://provider.example.com/v1",
            accountLabel: "Primary",
            apiKey: "sk-primary"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let addedProvider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "Provider A" }))
        let providerID = addedProvider.id
        let primaryAccountID = try XCTUnwrap(addedProvider.activeAccount?.id)
        try store.activateCustomProvider(providerID: providerID, accountID: primaryAccountID)
        try store.addCustomProviderAccount(providerID: providerID, label: "Backup", apiKey: "sk-backup", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])

        let providerBeforeEdit = try XCTUnwrap(store.config.provider(id: providerID))
        let backupAccountID = try XCTUnwrap(providerBeforeEdit.accounts.first(where: { $0.label == "Backup" })?.id)

        try store.updateCustomProviderAccount(
            providerID: providerID,
            accountID: backupAccountID,
            label: "Backup Edited",
            apiKey: "sk-backup-edited"
        )

        let provider = try XCTUnwrap(store.config.provider(id: providerID))
        let backupAccount = try XCTUnwrap(provider.accounts.first(where: { $0.id == backupAccountID }))
        XCTAssertEqual(backupAccount.label, "Backup Edited")
        XCTAssertEqual(backupAccount.apiKey, "sk-backup-edited")
        XCTAssertEqual(provider.activeAccountId, primaryAccountID)
        XCTAssertEqual(store.config.active.accountId, primaryAccountID)
        XCTAssertEqual(store.activeProviderAccount?.id, primaryAccountID)
    }

    func testProviderUsageRefreshPersistsStandardizedDataAndRawResponse() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        try store.addCustomProvider(
            label: "AI Input",
            baseURL: "https://ai.input.im/v1",
            accountLabel: "Default",
            apiKey: "sk-provider"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "AI Input" }))

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":8.5,"subscription":{"daily_usage_usd":1.5,"daily_limit_usd":10,"weekly_limit_usd":0,"monthly_limit_usd":0}}"#.utf8
            )
            return (response, data)
        }

        try store.saveProviderUsageConfiguration(
            providerID: provider.id,
            configuration: CodexBarProviderUsageConfiguration()
        )
        store.refreshProviderUsage(providerID: provider.id)

        let timeout = Date().addingTimeInterval(3)
        while store.config.provider(id: provider.id)?.usageState?.lastUpdatedAt == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let state = try XCTUnwrap(store.config.provider(id: provider.id)?.usageState)
        XCTAssertNotNil(state.lastUpdatedAt)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.rawResponse, #"{"remaining":8.5,"subscription":{"daily_usage_usd":1.5,"daily_limit_usd":10,"weekly_limit_usd":0,"monthly_limit_usd":0}}"#)
        XCTAssertEqual(state.data?.remaining, 8.5)
        XCTAssertEqual(try XCTUnwrap(state.data?.today.usageRatio), 0.15, accuracy: 0.0001)
        XCTAssertNil(state.data?.weekly.usageRatio)
        XCTAssertNil(state.data?.monthly.usageRatio)
    }

    func testSavingProviderUsageConfigurationRefreshesImmediately() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        try store.addCustomProvider(
            label: "AI Input",
            baseURL: "https://ai.input.im/v1",
            accountLabel: "Default",
            apiKey: "sk-provider"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "AI Input" }))

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":12,"subscription":{"daily_usage_usd":3,"daily_limit_usd":15}}"#.utf8
            )
            return (response, data)
        }

        try store.saveProviderUsageConfiguration(
            providerID: provider.id,
            configuration: CodexBarProviderUsageConfiguration()
        )

        let state = try self.waitForProviderUsageState(store, providerID: provider.id)
        XCTAssertEqual(state.data?.remaining, 12)
        XCTAssertEqual(state.accountSnapshots.count, 1)
    }

    func testProviderUsagePollingStartsWithImmediateRefresh() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        try store.addCustomProvider(
            label: "AI Input",
            baseURL: "https://ai.input.im/v1",
            accountLabel: "Default",
            apiKey: "sk-provider"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "AI Input" }))

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":18,"subscription":{"daily_usage_usd":2,"daily_limit_usd":20}}"#.utf8
            )
            return (response, data)
        }

        try store.saveProviderUsageConfiguration(
            providerID: provider.id,
            configuration: CodexBarProviderUsageConfiguration(intervalSeconds: 3600)
        )

        let state = try self.waitForProviderUsageState(store, providerID: provider.id)
        XCTAssertEqual(state.data?.remaining, 18)
        XCTAssertEqual(state.accountSnapshots.count, 1)
    }

    func testProviderUsageLoadDoesNotRefreshPollingProviderAgain() throws {
        var config = CodexBarConfig()
        let account = CodexBarProviderAccount(
            id: "acct-provider",
            kind: .apiKey,
            label: "Default",
            apiKey: "sk-provider"
        )
        config.providers = [
            CodexBarProvider(
                id: "ai-input",
                kind: .openAICompatible,
                label: "AI Input",
                baseURL: "https://ai.input.im/v1",
                activeAccountId: account.id,
                usageConfiguration: CodexBarProviderUsageConfiguration(intervalSeconds: 3600),
                accounts: [account]
            ),
        ]
        try self.writeConfig(config)

        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":18,"subscription":{"daily_usage_usd":2,"daily_limit_usd":20}}"#.utf8
            )
            return (response, data)
        }

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )
        _ = try self.waitForProviderUsageState(store, providerID: "ai-input")
        XCTAssertEqual(requestCount, 1)

        store.load()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        XCTAssertEqual(requestCount, 1)
    }

    func testProviderUsageRefreshCoalescesConcurrentRequests() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        try store.addCustomProvider(
            label: "AI Input",
            baseURL: "https://ai.input.im/v1",
            accountLabel: "Default",
            apiKey: "sk-provider"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "AI Input" }))

        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":18,"subscription":{"daily_usage_usd":2,"daily_limit_usd":20}}"#.utf8
            )
            return (response, data)
        }

        try store.saveProviderUsageConfiguration(
            providerID: provider.id,
            configuration: CodexBarProviderUsageConfiguration()
        )

        store.refreshProviderUsage(providerID: provider.id)
        store.refreshProviderUsage(providerID: provider.id)

        let state = try self.waitForProviderUsageState(store, providerID: provider.id)
        XCTAssertEqual(state.data?.remaining, 18)
        XCTAssertEqual(requestCount, 1)
    }

    func testAddingProviderAccountRefreshesUsageForAllKeysImmediately() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        try store.addCustomProvider(
            label: "AI Input",
            baseURL: "https://ai.input.im/v1",
            accountLabel: "Star",
            apiKey: "sk-star"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let provider = try XCTUnwrap(store.config.providers.first(where: { $0.label == "AI Input" }))

        var requestedKeys: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requestedKeys.append(authorization)
            let used = authorization == "Bearer sk-kami" ? 15.06 : 135.14
            let limit = authorization == "Bearer sk-kami" ? 500.0 : 300.0
            let remaining = limit - used
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":\#(remaining),"subscription":{"daily_usage_usd":\#(used),"daily_limit_usd":\#(limit)}}"#.utf8
            )
            return (response, data)
        }

        try store.saveProviderUsageConfiguration(
            providerID: provider.id,
            configuration: CodexBarProviderUsageConfiguration()
        )
        _ = try self.waitForProviderUsageState(store, providerID: provider.id)

        try store.addCustomProviderAccount(providerID: provider.id, label: "Kami", apiKey: "sk-kami", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])

        let refreshedState = try self.waitForProviderUsageState(
            store,
            providerID: provider.id,
            expectedSnapshotCount: 2
        )
        XCTAssertEqual(Set(requestedKeys), Set(["Bearer sk-star", "Bearer sk-kami"]))
        XCTAssertEqual(refreshedState.accountSnapshots.count, 2)
        XCTAssertEqual(
            refreshedState.accountSnapshots.first { $0.accountLabel == "Kami" }?.data?.today.limit,
            500
        )
    }

    func testStartupRefreshesConfiguredProviderUsage() throws {
        var config = CodexBarConfig()
        let account = CodexBarProviderAccount(
            id: "acct-provider",
            kind: .apiKey,
            label: "Default",
            apiKey: "sk-provider"
        )
        config.providers = [
            CodexBarProvider(
                id: "ai-input",
                kind: .openAICompatible,
                label: "AI Input",
                baseURL: "https://ai.input.im/v1",
                activeAccountId: account.id,
                usageConfiguration: CodexBarProviderUsageConfiguration(),
                accounts: [account]
            ),
        ]
        try self.writeConfig(config)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-provider")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"remaining":9,"subscription":{"daily_usage_usd":1,"daily_limit_usd":10}}"#.utf8
            )
            return (response, data)
        }

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            providerUsageService: ProviderUsageService(urlSession: self.makeMockSession())
        )

        let state = try self.waitForProviderUsageState(store, providerID: "ai-input")
        XCTAssertEqual(state.data?.remaining, 9)
        XCTAssertEqual(state.accountSnapshots.count, 1)
    }

    func testAddingSameThirdPartyProviderTypeAppendsAccount() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addThirdPartyModelProvider(
            provider: .deepSeek,
            label: "",
            baseURL: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL,
            selectedModelID: "deepseek-v4-pro",
            pinnedModelIDs: ["deepseek-v4-pro"],
            accountLabel: "Primary",
            apiKey: "sk-deepseek-primary"
        )
        let primaryProvider = try XCTUnwrap(store.thirdPartyModelProviders.first(where: { $0.thirdPartyModelProvider == .deepSeek }))
        let primaryAccountID = try XCTUnwrap(primaryProvider.activeAccountId)

        try store.addThirdPartyModelProvider(
            provider: .deepSeek,
            label: "",
            baseURL: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL,
            selectedModelID: "deepseek-v4-flash",
            pinnedModelIDs: ["deepseek-v4-flash"],
            accountLabel: "Backup",
            apiKey: "sk-deepseek-backup"
        )

        let providers = store.thirdPartyModelProviders.filter { $0.thirdPartyModelProvider == .deepSeek }
        XCTAssertEqual(providers.count, 1)
        let provider = try XCTUnwrap(providers.first)
        XCTAssertEqual(provider.accounts.map(\.label), ["Primary", "Backup"])
        XCTAssertEqual(provider.accounts.map(\.apiKey), ["sk-deepseek-primary", "sk-deepseek-backup"])
        XCTAssertEqual(provider.activeAccountId, provider.accounts.last?.id)
        XCTAssertEqual(provider.thirdPartyEffectiveModelID(forAccountID: primaryAccountID), "deepseek-v4-pro")
        XCTAssertEqual(provider.thirdPartyEffectiveModelID(forAccountID: provider.accounts.last?.id), "deepseek-v4-flash")
    }

    func testAddingOpenCodeProviderStoresPlanAndKeepsPerKeyModelSelection() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addThirdPartyModelProvider(
            provider: .openCode,
            label: "OpenCode Go",
            baseURL: CodexBarOpenCodePlan.go.defaultBaseURL,
            selectedModelID: "deepseek-v4.1-flash",
            pinnedModelIDs: ["deepseek-v4.1-flash", "deepseek-v4-pro"],
            accountLabel: "Go Primary",
            apiKey: "sk-opencode-go-primary",
            openCodePlan: .go
        )
        let primaryProvider = try XCTUnwrap(store.openCodeProviders.first)
        let primaryAccountID = try XCTUnwrap(primaryProvider.activeAccountId)
        XCTAssertEqual(primaryProvider.effectiveOpenCodePlan, .go)

        try store.addThirdPartyModelProvider(
            provider: .openCode,
            label: "OpenCode Go",
            baseURL: CodexBarOpenCodePlan.go.defaultBaseURL,
            selectedModelID: "deepseek-v4-pro",
            pinnedModelIDs: ["deepseek-v4-pro"],
            accountLabel: "Go Backup",
            apiKey: "sk-opencode-go-backup",
            openCodePlan: .go
        )

        try store.addThirdPartyModelProvider(
            provider: .openCode,
            label: "OpenCode Zen",
            baseURL: CodexBarOpenCodePlan.zen.defaultBaseURL,
            selectedModelID: "gpt-6.1-sol",
            pinnedModelIDs: ["gpt-6.1-sol"],
            accountLabel: "Zen",
            apiKey: "sk-opencode-zen",
            openCodePlan: .zen
        )

        XCTAssertEqual(store.openCodeProviders.count, 2)
        let goProvider = try XCTUnwrap(store.openCodeProviders.first { $0.effectiveOpenCodePlan == .go })
        XCTAssertEqual(goProvider.accounts.map(\.label), ["Go Primary", "Go Backup"])
        XCTAssertEqual(goProvider.thirdPartyEffectiveModelID(forAccountID: primaryAccountID), "deepseek-v4.1-flash")
        XCTAssertEqual(
            goProvider.thirdPartyEffectiveModelID(forAccountID: goProvider.accounts.last?.id),
            "deepseek-v4-pro"
        )
        let zenProvider = try XCTUnwrap(store.openCodeProviders.first { $0.effectiveOpenCodePlan == .zen })
        XCTAssertEqual(zenProvider.accounts.map(\.label), ["Zen"])
        XCTAssertEqual(zenProvider.baseURL, CodexBarOpenCodePlan.zen.defaultBaseURL)
        XCTAssertEqual(zenProvider.thirdPartyEffectiveModelID, "gpt-6.1-sol")
        XCTAssertEqual(store.genericThirdPartyModelProviders.count, 0)
    }

    func testRefreshOpenCodeModelCatalogStoresCatalogAndMenuNames() async throws {
        let fetchedAt = Date()
        let snapshot = OpenCodeModelCatalogSnapshot(
            models: [
                OpenCodeModel(
                    id: "deepseek-v4.1-flash",
                    name: "DeepSeek V4.1 Flash",
                    family: "deepseek-flash",
                    canonicalID: nil,
                    contextLimit: 1_000_000,
                    outputLimit: 384_000,
                    supportsTools: true,
                    reasoningEfforts: ["low", "high"],
                    inputModalities: ["text"],
                    nativeAPIs: ["chat-completions"],
                    responsesBaseURL: nil,
                    inputUSDPerMillion: 0.15,
                    outputUSDPerMillion: 0.6,
                    cacheReadUSDPerMillion: 0.003,
                    cacheWriteUSDPerMillion: nil
                ),
                OpenCodeModel(
                    id: "gpt-6.1-sol",
                    name: "GPT-6.1 Sol",
                    family: "gpt-sol",
                    canonicalID: nil,
                    contextLimit: 1_050_000,
                    outputLimit: 128_000,
                    supportsTools: true,
                    reasoningEfforts: ["low", "medium", "high"],
                    inputModalities: ["text"],
                    nativeAPIs: ["responses"],
                    responsesBaseURL: CodexBarOpenCodePlan.go.defaultBaseURL,
                    inputUSDPerMillion: 2,
                    outputUSDPerMillion: 10,
                    cacheReadUSDPerMillion: 0.1,
                    cacheWriteUSDPerMillion: 2.5
                ),
            ],
            fetchedAt: fetchedAt
        )
        let catalogService = OpenCodeModelCatalogServiceSpy(result: snapshot)
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            openCodeCatalogService: catalogService
        )
        try store.addThirdPartyModelProvider(
            provider: .openCode,
            label: "OpenCode Go",
            baseURL: CodexBarOpenCodePlan.go.defaultBaseURL,
            selectedModelID: "deepseek-v4.1-flash",
            pinnedModelIDs: ["deepseek-v4.1-flash"],
            accountLabel: "Go",
            apiKey: "sk-opencode-go",
            openCodePlan: .go
        )
        let providerID = try XCTUnwrap(store.openCodeProviders.first?.id)
        let accountID = try XCTUnwrap(store.openCodeProviders.first?.activeAccountId)

        try await store.refreshOpenCodeModelCatalog(providerID: providerID, accountID: accountID, force: true)

        let provider = try XCTUnwrap(store.openCodeProviders.first)
        XCTAssertEqual(catalogService.fetchCount, 1)
        XCTAssertEqual(provider.thirdPartyMenuModelOptions(forAccountID: accountID).map(\.name), [
            "DeepSeek V4.1 Flash",
        ])
        XCTAssertEqual(
            provider.accounts.first?.thirdPartyModelSelection?.cachedModelCatalog.map(\.name),
            ["DeepSeek V4.1 Flash", "GPT-6.1 Sol"]
        )
        XCTAssertEqual(
            provider.accounts.first?.thirdPartyModelSelection?.cachedModelCatalog.count,
            2
        )
        XCTAssertEqual(provider.thirdPartyEffectiveModelID(forAccountID: accountID), "deepseek-v4.1-flash")
    }

    func testOpenCodeGoUsageRefreshStoresOfficialPercentWindows() async throws {
        let fetchedAt = Date()
        let usageSnapshot = OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(status: "ok", percent: 11, resetsAt: fetchedAt.addingTimeInterval(3600)),
            weekly: OpenCodeUsageWindow(status: "ok", percent: 4, resetsAt: fetchedAt.addingTimeInterval(86400)),
            monthly: OpenCodeUsageWindow(status: "ok", percent: 2, resetsAt: fetchedAt.addingTimeInterval(86400 * 7)),
            fetchedAt: fetchedAt
        )
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            openCodeUsageService: OpenCodeUsageServiceSpy(result: usageSnapshot)
        )
        try store.addThirdPartyModelProvider(
            provider: .openCode,
            label: "OpenCode Go",
            baseURL: CodexBarOpenCodePlan.go.defaultBaseURL,
            selectedModelID: "deepseek-v4.1-flash",
            pinnedModelIDs: ["deepseek-v4.1-flash"],
            accountLabel: "Go",
            apiKey: "sk-opencode-go",
            openCodePlan: .go
        )
        let providerID = try XCTUnwrap(store.openCodeProviders.first?.id)

        store.refreshProviderUsage(providerID: providerID)
        let state = try self.waitForProviderUsageState(store, providerID: providerID, expectedSnapshotCount: 1)

        XCTAssertEqual(state.data?.unit, "%")
        XCTAssertEqual(state.data?.planName, "OpenCode Go")
        XCTAssertEqual(state.data?.today.used, 11)
        XCTAssertEqual(state.data?.today.remaining, 89)
        XCTAssertEqual(state.data?.weekly.used, 4)
        XCTAssertEqual(state.data?.monthly.used, 2)
        XCTAssertNotNil(state.data?.today.resetAt)
    }

    func testRemovingThirdPartyProviderAccountRemovesOnlyTargetAccount() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addThirdPartyModelProvider(
            provider: .deepSeek,
            label: "",
            baseURL: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL,
            selectedModelID: "deepseek-v4-pro",
            pinnedModelIDs: ["deepseek-v4-pro"],
            accountLabel: "Primary",
            apiKey: "sk-deepseek-primary"
        )
        try store.addThirdPartyModelProvider(
            provider: .deepSeek,
            label: "",
            baseURL: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL,
            selectedModelID: "deepseek-v4-flash",
            pinnedModelIDs: ["deepseek-v4-flash"],
            accountLabel: "Backup",
            apiKey: "sk-deepseek-backup"
        )

        let initialProvider = try XCTUnwrap(store.thirdPartyModelProviders.first(where: { $0.thirdPartyModelProvider == .deepSeek }))
        let primaryAccount = try XCTUnwrap(initialProvider.accounts.first(where: { $0.label == "Primary" }))
        let backupAccount = try XCTUnwrap(initialProvider.accounts.first(where: { $0.label == "Backup" }))

        try store.removeCustomProviderAccount(providerID: initialProvider.id, accountID: backupAccount.id)

        let provider = try XCTUnwrap(store.thirdPartyModelProviders.first(where: { $0.thirdPartyModelProvider == .deepSeek }))
        XCTAssertEqual(provider.accounts.map(\.id), [primaryAccount.id])
        XCTAssertEqual(provider.accounts.map(\.label), ["Primary"])
        XCTAssertEqual(provider.thirdPartyEffectiveModelID(forAccountID: primaryAccount.id), "deepseek-v4-pro")
    }

    func testOpenRouterManualModelFallbackWorksWithoutCatalog() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-manual", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "fixture-model")
        XCTAssertTrue(store.openRouterProvider?.cachedModelCatalog.isEmpty ?? true)

        try store.updateOpenRouterSelectedModel("google/gemini-2.5-pro")

        XCTAssertEqual(store.openRouterProvider?.selectedModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertTrue(store.openRouterProvider?.cachedModelCatalog.isEmpty ?? true)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openRouterProvider()?.selectedModelID, "google/gemini-2.5-pro")
    }

    func testOpenRouterPinnedModelsRemainAfterSwitchingCurrentModel() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_500)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(store.openRouterProvider?.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "openai/gpt-4.1")

        try store.updateOpenRouterSelectedModel("google/gemini-2.5-pro")

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(store.openRouterProvider?.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(store.openRouterProvider?.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
    }

    func testOpenRouterModelPickerDisplayPinsSelectedModelsAndRequiresSearchForUnselected() {
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
        ]
        let selected = Set(["google/gemini-2.5-pro"])

        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selected,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: ""
            ).map(\.id),
            ["google/gemini-2.5-pro"]
        )
        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selected,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: "claude"
            ).map(\.id),
            ["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"]
        )
    }

    func testOpenRouterModelPickerDisplayDoesNotRepinNewSelectionsAfterOpen() {
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
        ]
        let selectedAfterOpen = Set(["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"])

        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selectedAfterOpen,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: "claude"
            ).map(\.id),
            ["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"]
        )
        XCTAssertEqual(
            OpenRouterModelPickerDisplay.models(
                cachedModels: catalog,
                selectedModelIDs: selectedAfterOpen,
                initiallyPinnedModelIDs: ["google/gemini-2.5-pro"],
                searchText: ""
            ).map(\.id),
            ["google/gemini-2.5-pro", "anthropic/claude-3.7-sonnet"]
        )
    }

    func testOpenRouterMenuModelOptionsShowAllPinnedModelsWithoutSelectedModel() throws {
        let account = CodexBarProviderAccount(
            id: "acct-openrouter-menu-models",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary",
            openRouterSelection: CodexBarOpenRouterSelection(
                selectedModelID: nil,
                pinnedModelIDs: [
                    "bytedance-seed/seed-2.0-mini",
                    "bytedance-seed/seed-1.6",
                    "custom/model-without-cache",
                ],
                cachedModelCatalog: [
                    CodexBarOpenRouterModel(id: "bytedance-seed/seed-1.6", name: "Seed 1.6"),
                    CodexBarOpenRouterModel(id: "bytedance-seed/seed-2.0-mini", name: "Seed 2.0 Mini"),
                ]
            )
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            activeAccountId: account.id,
            accounts: [account]
        )

        XCTAssertEqual(
            provider.openRouterMenuModelOptions(forAccountID: account.id),
            [
                CodexBarOpenRouterModel(id: "bytedance-seed/seed-1.6", name: "Seed 1.6"),
                CodexBarOpenRouterModel(id: "bytedance-seed/seed-2.0-mini", name: "Seed 2.0 Mini"),
                CodexBarOpenRouterModel(id: "custom/model-without-cache"),
            ]
        )
    }

    func testOpenRouterModelPickerCacheStatusLocalizesTimestamp() throws {
        let originalOverride = L.languageOverride
        defer {
            L.languageOverride = originalOverride
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let updatedAt = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 5,
                    day: 19,
                    hour: 9,
                    minute: 20
                )
            )
        )

        L.languageOverride = false
        XCTAssertEqual(
            L.openRouterModelPickerCacheStatus(count: 356, fetchedAt: updatedAt),
            "356 cached models • updated May 19, 2026 at 9:20"
        )

        L.languageOverride = true
        XCTAssertEqual(
            L.openRouterModelPickerCacheStatus(count: 356, fetchedAt: updatedAt),
            "已缓存 356 个模型 • 更新于 2026年5月19日 9:20"
        )
    }

    func testUpdateOpenRouterProviderEditsActiveKeyAndModelSelection() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_700)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            accountLabel: "Primary",
            apiKey: "sk-or-v1-old",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )
        let accountID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.updateOpenRouterProvider(
            request: OpenRouterProviderUpdate(
                accountID: accountID,
                accountLabel: "Updated Primary",
                apiKey: "sk-or-v1-new",
                selectedModelID: "google/gemini-2.5-pro",
                pinnedModelIDs: ["google/gemini-2.5-pro", "openai/gpt-4.1"],
                cachedModelCatalog: catalog,
                fetchedAt: fetchedAt
            )
        )

        let provider = try XCTUnwrap(store.openRouterProvider)
        XCTAssertEqual(provider.activeAccount?.label, "Updated Primary")
        XCTAssertEqual(provider.activeAccount?.apiKey, "sk-or-v1-new")
        XCTAssertEqual(provider.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(provider.pinnedModelIDs, ["google/gemini-2.5-pro", "openai/gpt-4.1"])
        XCTAssertEqual(provider.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(provider.modelCatalogFetchedAt, fetchedAt)
    }

    func testAddingOpenRouterKeyDoesNotInheritSelectedModels() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_800)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            accountLabel: "Primary",
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )
        let primaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.addOpenRouterProviderAccount(
            label: "Secondary",
            apiKey: "sk-or-v1-secondary"
        , selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let secondaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)
        let provider = try XCTUnwrap(store.openRouterProvider)

        XCTAssertNotEqual(primaryID, secondaryID)
        let secondarySelection = provider.openRouterSelection(forAccountID: secondaryID)
        XCTAssertEqual(secondarySelection.selectedModelID, "fixture-model")
        XCTAssertEqual(secondarySelection.pinnedModelIDs, ["fixture-model"])
        XCTAssertTrue(secondarySelection.cachedModelCatalog.isEmpty)
        XCTAssertEqual(secondarySelection.modelCatalogFetchedAt, fetchedAt)
        XCTAssertEqual(provider.openRouterEffectiveModelID(forAccountID: secondaryID), "fixture-model")
    }

    func testUpdateOpenRouterProviderRejectsMissingRequestModelWithoutChangingKey() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_900)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        let accountID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        XCTAssertThrowsError(try store.updateOpenRouterProvider(
            request: OpenRouterProviderUpdate(
                accountID: accountID,
                accountLabel: "Renamed",
                apiKey: "sk-or-v1-updated",
                selectedModelID: nil,
                pinnedModelIDs: ["google/gemini-2.5-pro"],
                cachedModelCatalog: catalog,
                fetchedAt: fetchedAt
            )
        ))

        let provider = try XCTUnwrap(store.openRouterProvider)
        let selection = provider.openRouterSelection(forAccountID: accountID)
        XCTAssertEqual(provider.activeAccount?.label, "Primary")
        XCTAssertEqual(provider.activeAccount?.apiKey, "sk-or-v1-primary")
        XCTAssertEqual(selection.selectedModelID, "fixture-model")
        XCTAssertEqual(selection.pinnedModelIDs, ["fixture-model"])
        XCTAssertEqual(provider.openRouterEffectiveModelID(forAccountID: accountID), "fixture-model")
    }

    func testRefreshOpenRouterModelCatalogCachesFetchedModels() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: [
                        CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                        CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
                    ],
                    fetchedAt: fetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        try await store.refreshOpenRouterModelCatalog()

        XCTAssertEqual(catalogService.requestedAPIKeys, ["sk-or-v1-primary"])
        XCTAssertEqual(
            store.openRouterProvider?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "openai/gpt-4.1"]
        )
        XCTAssertEqual(store.openRouterProvider?.modelCatalogFetchedAt, fetchedAt)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openRouterProvider()?.pinnedModelIDs, ["fixture-model"])
        XCTAssertTrue(reloaded.openRouterProvider()?.cachedModelCatalog.isEmpty ?? false)
        XCTAssertNil(reloaded.openRouterProvider()?.modelCatalogFetchedAt)
    }

    func testRefreshOpenRouterModelCatalogForKeyDoesNotOverwriteOtherKeySelection() async throws {
        let firstFetchedAt = Date(timeIntervalSince1970: 1_710_000_100)
        let secondFetchedAt = Date(timeIntervalSince1970: 1_710_000_200)
        let firstCatalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]
        let secondCatalog = [
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
            CodexBarOpenRouterModel(id: "meta-llama/llama-4-maverick", name: "Llama 4 Maverick"),
        ]
        let refreshedCatalog = [
            CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
            CodexBarOpenRouterModel(id: "qwen/qwen3-235b-a22b", name: "Qwen3 235B A22B"),
        ]
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: refreshedCatalog,
                    fetchedAt: secondFetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(
            accountLabel: "Primary",
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: firstCatalog,
            fetchedAt: firstFetchedAt
        )
        let primaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try store.addOpenRouterProvider(
            accountLabel: "Secondary",
            apiKey: "sk-or-v1-secondary",
            selectedModelID: "anthropic/claude-3.7-sonnet",
            pinnedModelIDs: ["anthropic/claude-3.7-sonnet", "meta-llama/llama-4-maverick"],
            cachedModelCatalog: secondCatalog,
            fetchedAt: firstFetchedAt
        )
        let secondaryID = try XCTUnwrap(store.openRouterProvider?.activeAccountId)

        try await store.refreshOpenRouterModelCatalog(accountID: secondaryID)

        let provider = try XCTUnwrap(store.openRouterProvider)
        let primarySelection = provider.openRouterSelection(forAccountID: primaryID)
        let secondarySelection = provider.openRouterSelection(forAccountID: secondaryID)

        XCTAssertEqual(catalogService.requestedAPIKeys, ["sk-or-v1-secondary"])
        XCTAssertEqual(primarySelection.selectedModelID, "openai/gpt-4.1")
        XCTAssertEqual(primarySelection.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(primarySelection.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(primarySelection.modelCatalogFetchedAt, firstFetchedAt)
        XCTAssertEqual(secondarySelection.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(secondarySelection.pinnedModelIDs, ["anthropic/claude-3.7-sonnet", "meta-llama/llama-4-maverick"])
        XCTAssertEqual(secondarySelection.cachedModelCatalog.map(\.id), ["anthropic/claude-3.7-sonnet", "qwen/qwen3-235b-a22b"])
        XCTAssertEqual(secondarySelection.modelCatalogFetchedAt, secondFetchedAt)
        XCTAssertEqual(provider.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(provider.cachedModelCatalog.map(\.id), ["anthropic/claude-3.7-sonnet", "qwen/qwen3-235b-a22b"])
    }

    func testRefreshOpenRouterCatalogFailurePreservesSelectedModelAndCache() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_100)
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: [
                        CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                        CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
                    ],
                    fetchedAt: fetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary", selectedModelID: "fixture-model", pinnedModelIDs: ["fixture-model"])
        try store.updateOpenRouterSelectedModel("anthropic/claude-3.7-sonnet")
        try await store.refreshOpenRouterModelCatalog()

        catalogService.result = .failure(URLError(.notConnectedToInternet))

        do {
            try await store.refreshOpenRouterModelCatalog()
            XCTFail("Expected refresh to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(
            store.openRouterProvider?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "google/gemini-2.5-pro"]
        )
        XCTAssertEqual(store.openRouterProvider?.modelCatalogFetchedAt, fetchedAt)
    }

    private func makeValidCodexApp(named relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let appURL = root.appendingPathComponent(relativePath)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let executableURL = resourcesURL.appendingPathComponent("codex")
        try Data().write(to: executableURL)
        return appURL
    }

    private func waitForProviderUsageState(
        _ store: TokenStore,
        providerID: String,
        expectedSnapshotCount: Int = 1,
        timeout: TimeInterval = 3
    ) throws -> CodexBarProviderUsageState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = store.config.provider(id: providerID)?.usageState,
               state.accountSnapshots.count >= expectedSnapshotCount {
                return state
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return try XCTUnwrap(store.config.provider(id: providerID)?.usageState)
    }

    private func makeTokenStore(
        openAIAccountGatewayService: OpenAIAccountGatewayControlling = OpenAIAccountGatewayControllerStub(),
        openRouterGatewayService: OpenRouterGatewayControlling = OpenRouterGatewayControllerStub(),
        openRouterCatalogService: any OpenRouterModelCatalogFetching,
        openCodeCatalogService: any OpenCodeModelCatalogFetching = OpenCodeModelCatalogServiceSpy(result: nil),
        openCodeUsageService: any OpenCodeUsageFetching = OpenCodeUsageServiceSpy(result: nil),
        providerUsageService: ProviderUsageService = ProviderUsageService()
    ) -> TokenStore {
        TokenStore(
            syncService: CodexSyncServiceNoOp(),
            openAIAccountGatewayService: openAIAccountGatewayService,
            openRouterGatewayService: openRouterGatewayService,
            openRouterModelCatalogService: openRouterCatalogService,
            openCodeModelCatalogService: openCodeCatalogService,
            openCodeUsageService: openCodeUsageService,
            providerUsageService: providerUsageService,
            gatewayRouteJournalStore: AggregateRouteJournalStoreStub(),
            codexRunningProcessIDs: { [] }
        )
    }
}

private final class CodexSyncServiceNoOp: CodexSynchronizing {
    func synchronize(config _: CodexBarConfig) throws {}
}

private final class OpenAIAccountGatewayControllerStub: OpenAIAccountGatewayControlling {

    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts _: [TokenAccount],
        accountUsageMode _: CodexBarOpenAIAccountUsageMode,
        routeTarget _: OpenAIAccountGatewayRouteTarget
    ) {}

    func currentRoutedAccountID() -> String? { nil }
}

private final class OpenCodeModelCatalogServiceSpy: OpenCodeModelCatalogFetching {
    var result: OpenCodeModelCatalogSnapshot?
    var error: Error?
    private(set) var fetchCount = 0

    init(result: OpenCodeModelCatalogSnapshot?, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func fetchCatalog(plan _: CodexBarOpenCodePlan, apiKey _: String) async throws -> OpenCodeModelCatalogSnapshot {
        self.fetchCount += 1
        if let error { throw error }
        guard let result else { throw URLError(.notConnectedToInternet) }
        return result
    }

    func loadCachedCatalog(plan _: CodexBarOpenCodePlan) -> OpenCodeModelCatalogSnapshot? {
        self.result
    }
}

private final class OpenCodeUsageServiceSpy: OpenCodeUsageFetching {
    var result: OpenCodeUsageSnapshot?
    var error: Error?

    init(result: OpenCodeUsageSnapshot?, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func fetchGoUsage(apiKey _: String) async throws -> OpenCodeUsageSnapshot {
        if let error { throw error }
        guard let result else { throw URLError(.notConnectedToInternet) }
        return result
    }
}

private final class OpenRouterGatewayControllerStub: OpenRouterGatewayControlling {

    func startIfNeeded() {}
    func stop() {}
    func updateState(provider _: CodexBarProvider?, isActiveProvider _: Bool) {}
}

private final class AggregateRouteJournalStoreStub: OpenAIGatewayRouteJournalStoring {
    func recordRoute(threadID _: String, accountID _: String, timestamp _: Date) {}
    func routeHistory() -> [OpenAIGatewayRouteRecord] { [] }
}

private final class OpenRouterModelCatalogServiceSpy: OpenRouterModelCatalogFetching {
    var result: Result<OpenRouterModelCatalogSnapshot, Error>
    private(set) var requestedAPIKeys: [String] = []

    init(result: Result<OpenRouterModelCatalogSnapshot, Error>) {
        self.result = result
    }

    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        self.requestedAPIKeys.append(apiKey)
        return try self.result.get()
    }
}
