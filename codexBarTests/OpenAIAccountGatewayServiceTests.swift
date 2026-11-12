import Foundation
import Network
import XCTest

final class OpenAIAccountGatewayServiceTests: CodexBarTestCase {
    func testDefaultServiceUsesDedicatedUpstreamSessionConfiguration() {
        let service = OpenAIAccountGatewayService()

        XCTAssertTrue(service.usesDedicatedUpstreamSessionForTesting())

        let configuration = service.upstreamTransportConfigurationForTesting()
        XCTAssertEqual(configuration.requestTimeout, 30)
        XCTAssertEqual(configuration.resourceTimeout, 120)
        XCTAssertEqual(configuration.webSocketReadyBudget, 8)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testLoopbackProxySafePolicyOnlyAppliesToLoopbackProxySnapshots() {
        let loopbackConfiguration = self.makeTransportConfiguration(
            proxyResolutionMode: .loopbackProxySafe,
            snapshot: self.makeProxySnapshot(
                httpHost: "127.0.0.1",
                httpPort: 1082,
                httpsHost: "localhost",
                httpsPort: 1082
            )
        )
        let loopbackService = self.makeService(upstreamTransportConfiguration: loopbackConfiguration)
        let loopbackPolicy = loopbackService.upstreamTransportPolicyForTesting()

        XCTAssertTrue(loopbackPolicy.loopbackProxySafeApplied)
        XCTAssertEqual(loopbackPolicy.systemProxySnapshot?.http?.host, "127.0.0.1")
        XCTAssertNil(loopbackPolicy.effectiveProxySnapshot?.http)
        XCTAssertNil(loopbackPolicy.effectiveProxySnapshot?.https)

        let corpConfiguration = self.makeTransportConfiguration(
            proxyResolutionMode: .loopbackProxySafe,
            snapshot: self.makeProxySnapshot(
                httpHost: "corp-proxy.example.com",
                httpPort: 8080,
                httpsHost: "corp-proxy.example.com",
                httpsPort: 8080
            )
        )
        let corpService = self.makeService(upstreamTransportConfiguration: corpConfiguration)
        let corpPolicy = corpService.upstreamTransportPolicyForTesting()

        XCTAssertFalse(corpPolicy.loopbackProxySafeApplied)
        XCTAssertEqual(corpPolicy.effectiveProxySnapshot?.http?.host, "corp-proxy.example.com")
        XCTAssertEqual(corpPolicy.effectiveProxySnapshot?.https?.host, "corp-proxy.example.com")
    }

    func testLoopbackProxySafePolicyKeepsLoopbackProxyForNonLoopbackUpstreamURLs() {
        let configuration = self.makeTransportConfiguration(
            proxyResolutionMode: .loopbackProxySafe,
            snapshot: self.makeProxySnapshot(
                httpHost: "127.0.0.1",
                httpPort: 7897,
                httpsHost: "127.0.0.1",
                httpsPort: 7897
            )
        )

        let providerPolicy = configuration.resolvedTransportPolicy(
            for: URL(string: "https://provider.example/v1/responses/compact")
        )
        XCTAssertFalse(providerPolicy.loopbackProxySafeApplied)
        XCTAssertEqual(providerPolicy.effectiveProxySnapshot?.http?.host, "127.0.0.1")
        XCTAssertEqual(providerPolicy.effectiveProxySnapshot?.https?.host, "127.0.0.1")

        let localGatewayPolicy = configuration.resolvedTransportPolicy(
            for: URL(string: "http://127.0.0.1:1456/v1/responses/compact")
        )
        XCTAssertTrue(localGatewayPolicy.loopbackProxySafeApplied)
        XCTAssertNil(localGatewayPolicy.effectiveProxySnapshot)
    }

    func testRouteTargetResponsesUseModerateTimeoutAndCompactUsesExtendedTimeout() throws {
        let service = self.makeService()

        let responsesOverride = try XCTUnwrap(
            service.routeTargetPOSTTransportConfigurationOverrideForTesting(
                routePath: "/v1/responses"
            )
        )
        XCTAssertEqual(responsesOverride.requestTimeout, 60)
        XCTAssertEqual(responsesOverride.resourceTimeout, 200)
        XCTAssertEqual(responsesOverride.webSocketReadyBudget, 12)
        XCTAssertFalse(responsesOverride.waitsForConnectivity)

        let compactOverride = try XCTUnwrap(
            service.routeTargetPOSTTransportConfigurationOverrideForTesting(
                routePath: "/v1/responses/compact"
            )
        )
        XCTAssertEqual(compactOverride.requestTimeout, 180)
        XCTAssertEqual(compactOverride.resourceTimeout, 600)
        XCTAssertEqual(compactOverride.webSocketReadyBudget, 30)
        XCTAssertFalse(compactOverride.waitsForConnectivity)
    }

    func testResponsesWebSocketUpgradeRejectsCompatibleProviderRouteTarget() throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "provider@example.com",
            accountId: "acct-provider",
            openAIAccountId: "openai-provider",
            accessToken: "token-provider",
            refreshToken: "refresh-provider",
            idToken: "id-provider",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1/",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "GET /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Connection: Upgrade",
                        "Upgrade: websocket",
                        "Sec-WebSocket-Version: 13",
                        "Sec-WebSocket-Key: dGVzdC1jb2RleGJhcg==",
                    ]
                )
            )
        )

        let response = service.routeTargetWebSocketUpgradeProbeForTesting(request: request)

        XCTAssertEqual(response.statusCode, 426)
        XCTAssertNil(response.headers["Upgrade"])
        XCTAssertNil(response.headers["Sec-WebSocket-Accept"])
        let body = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("not supported for provider routes"))
    }

    func testPOSTFailureDiagnosticsExposeFailureClassOutput() throws {
        let service = self.makeService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: self.makeProxySnapshot(
                    httpsHost: "127.0.0.1",
                    httpsPort: 1082
                )
            )
        )

        let transportDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: .transport(URLError(.timedOut))
            )
        )
        XCTAssertEqual(transportDiagnostic.route, "compact")
        XCTAssertEqual(transportDiagnostic.target, "openai_account")
        XCTAssertEqual(transportDiagnostic.failureClass, .transport)
        XCTAssertEqual(transportDiagnostic.errorDomain, NSURLErrorDomain)
        XCTAssertEqual(transportDiagnostic.errorCode, URLError.timedOut.rawValue)
        XCTAssertTrue(transportDiagnostic.loopbackProxySafeApplied)

        let providerDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                target: "compatibleProvider",
                upstreamURL: URL(string: "https://provider.example/v1/responses/compact"),
                failure: .transport(URLError(.cannotConnectToHost))
            )
        )
        XCTAssertEqual(providerDiagnostic.target, "compatibleProvider")
        XCTAssertEqual(providerDiagnostic.upstreamHost, "provider.example")
        XCTAssertEqual(providerDiagnostic.upstreamPath, "/v1/responses/compact")
        XCTAssertEqual(providerDiagnostic.systemProxySummary, "https=127.0.0.1:1082")
        XCTAssertEqual(providerDiagnostic.effectiveProxySummary, "https=127.0.0.1:1082")
        XCTAssertFalse(providerDiagnostic.loopbackProxySafeApplied)

        let upstreamStatusDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: .upstreamStatus(502)
            )
        )
        XCTAssertEqual(upstreamStatusDiagnostic.failureClass, .upstreamStatus)
        XCTAssertEqual(upstreamStatusDiagnostic.statusCode, 502)

        let protocolFailure = service.classifyPOSTFailureForTesting(URLError(.badServerResponse))
        XCTAssertEqual(protocolFailure.failureClass, .protocolViolation)
        let protocolDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: protocolFailure
            )
        )
        XCTAssertEqual(protocolDiagnostic.failureClass, .protocolViolation)
        XCTAssertEqual(protocolDiagnostic.errorCode, URLError.badServerResponse.rawValue)

        let accountStatusDiagnostic = try XCTUnwrap(
            service.upstreamFailureDiagnosticForTesting(
                routePath: "/v1/responses/compact",
                failure: .accountStatus(429)
            )
        )
        XCTAssertEqual(accountStatusDiagnostic.failureClass, .accountStatus)
        XCTAssertEqual(accountStatusDiagnostic.statusCode, 429)
    }

    func testResponsesCompactPOSTLoopbackProxySafePolicyAvoidsSynthetic502OnEquivalentRuntimePath() async throws {
        let upstreamServer = try LocalHTTPResponseServer(
            statusCode: 200,
            contentType: "application/json",
            responseBody: #"{"ok":true}"#
        )
        let rejectingProxy = try RejectingHTTPProxyServer()
        defer {
            upstreamServer.stop()
            rejectingProxy.stop()
        }

        let runtimeConfiguration = OpenAIAccountGatewayRuntimeConfiguration(
            host: "127.0.0.1",
            port: 1456,
            upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
            upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
        )
        let proxySnapshot = self.makeProxySnapshot(
            httpHost: "127.0.0.1",
            httpPort: Int(rejectingProxy.port)
        )
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )

        let legacyDiagnosticsQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.legacyDiagnostics")
        var legacyDiagnostics: [OpenAIAccountGatewayUpstreamFailureDiagnostic] = []
        let legacyService = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .systemDefault,
                snapshot: proxySnapshot
            ),
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            ),
            diagnosticsReporter: { diagnostic in
                legacyDiagnosticsQueue.sync {
                    legacyDiagnostics.append(diagnostic)
                }
            }
        )
        legacyService.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )

        let legacyResponse = try await self.postToGateway(
            service: legacyService,
            path: "/v1/responses/compact",
            stickyKey: "compact-loopback-legacy",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact hello"}]}],"service_tier":"priority","store":true,"max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )

        XCTAssertEqual(legacyResponse.statusCode, 502)
        XCTAssertEqual(
            legacyResponse.body,
            #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
        )
        let proxyHitsAfterLegacy = rejectingProxy.connectionCount
        XCTAssertGreaterThanOrEqual(proxyHitsAfterLegacy, 1)
        XCTAssertTrue(upstreamServer.requests.isEmpty)
        XCTAssertEqual(legacyDiagnosticsQueue.sync { legacyDiagnostics.last?.route }, "compact")
        XCTAssertEqual(legacyDiagnosticsQueue.sync { legacyDiagnostics.last?.loopbackProxySafeApplied }, false)

        let fixedDiagnosticsQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.fixedDiagnostics")
        var fixedDiagnostics: [OpenAIAccountGatewayUpstreamFailureDiagnostic] = []
        let fixedService = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: proxySnapshot
            ),
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            ),
            diagnosticsReporter: { diagnostic in
                fixedDiagnosticsQueue.sync {
                    fixedDiagnostics.append(diagnostic)
                }
            }
        )
        fixedService.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )

        let fixedResponse = try await self.postToGateway(
            service: fixedService,
            path: "/v1/responses/compact",
            stickyKey: "compact-loopback-fixed",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact hello"}]}],"service_tier":"priority","store":true,"max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )

        XCTAssertEqual(fixedResponse.statusCode, 200)
        XCTAssertEqual(fixedResponse.body, #"{"ok":true}"#)
        XCTAssertEqual(rejectingProxy.connectionCount, proxyHitsAfterLegacy)
        XCTAssertEqual(upstreamServer.requests.count, 1)
        XCTAssertEqual(upstreamServer.requests.first?.path, "/v1/responses/compact")
        let compactBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try XCTUnwrap(upstreamServer.requests.first?.body)
            ) as? [String: Any]
        )
        self.assertCompactBody(compactBody, expectedText: "compact hello")
        XCTAssertTrue(fixedDiagnosticsQueue.sync { fixedDiagnostics.isEmpty })
    }

    func testResponsesPOSTReturnsUnavailableWhenRouteTargetIsNone() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .none
        )

        MockURLProtocol.handler = { _ in
            XCTFail("route target .none must not forward to upstream")
            throw URLError(.userAuthenticationRequired)
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "route-none",
            body: #"{"model":"gpt-5.4","input":"hello"}"#
        )

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.body, #"{"error":{"message":"codexbar gateway unavailable: no routed target"}}"#)
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testRouteTargetChangeClearsLastRoutedAccountID() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: ok\n\n".utf8))
        }

        let routedResponse = try await self.postToGateway(
            service: service,
            stickyKey: "route-change-clear",
            body: #"{"model":"gpt-5.4","input":"hello"}"#
        )
        XCTAssertEqual(routedResponse.statusCode, 200)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesPOSTGatewayPromptPatchAppendsInstructions() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.setGatewayPromptPatchConfiguration(
            CodexBarOpenAISettings.GatewayPromptPatchSettings(
                isEnabled: true,
                instructions: "Spend more time before finalizing."
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            let bodyData =
                request.httpBody ??
                (URLProtocol.property(
                    forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                    in: request
                ) as? Data) ??
                Data()
            observedBody = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: ok\n\n".utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "prompt-patch",
            body: """
            {"model":"gpt-5.4","instructions":"Existing instruction.","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        let instructions = try XCTUnwrap(observedBody?["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Existing instruction."))
        XCTAssertTrue(instructions.contains("Spend more time before finalizing."))
    }

    func testResponsesPOSTStreamsEventChunksAcrossSmallSSEFragments() async throws {
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            .stream(
                statusCode: 200,
                contentType: "text/event-stream",
                chunks: [
                    Data("data: first\n".utf8),
                    Data("\n".utf8),
                    Data("data: second\n\n".utf8),
                ]
            )
        }
        defer { upstreamServer.stop() }

        let routeJournalStore = OpenAIGatewayRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let gatewayPort = UInt16(47_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
            ),
            routeJournalStore: routeJournalStore
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.startIfNeeded()

        let response = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "sse-fragments",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: first\n\ndata: second\n\n")
    }

    func testOpenAIAccountRouteStreamsEventChunksThroughRunningGateway() async throws {
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            .stream(
                statusCode: 200,
                contentType: "text/event-stream",
                chunks: [
                    Data("data: first\n\n".utf8),
                    Data("data: second\n\n".utf8),
                ]
            )
        }
        defer { upstreamServer.stop() }

        let routeJournalStore = OpenAIGatewayRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let gatewayPort = UInt16(48_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
            ),
            routeJournalStore: routeJournalStore
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "token-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.startIfNeeded()

        let response = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "openai-account-live",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: first\n\ndata: second\n\n")
    }

    func testModelsGETProxiesUpstreamCatalogWithClientVersionAndOAuthHeaders() async throws {
        let catalogBody = Data(#"{"models":[{"slug":"gpt-6.1-sol"}]}"#.utf8)
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            .respond(statusCode: 200, contentType: "application/json", body: catalogBody)
        }
        defer { upstreamServer.stop() }

        let gatewayPort = UInt16(50_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact"),
                upstreamModelsURL: upstreamServer.url(path: "/backend-api/codex/models")
            ),
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            )
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "token-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.startIfNeeded()

        let response = try await self.getFromRunningGateway(
            port: gatewayPort,
            path: "/v1/models?client_version=9.9.9"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, String(data: catalogBody, encoding: .utf8))
        let upstreamRequest = try XCTUnwrap(upstreamServer.requests.first)
        XCTAssertEqual(upstreamRequest.path, "/backend-api/codex/models?client_version=9.9.9")
        XCTAssertEqual(upstreamRequest.headers["authorization"], "Bearer token-oauth")
        XCTAssertEqual(upstreamRequest.headers["chatgpt-account-id"], "openai-oauth")
    }

    func testModelsGETFallsBackToLocalCatalogWhenNoOAuthAccountExists() async throws {
        let gatewayPort = UInt16(51_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: URL(string: "http://127.0.0.1:1/v1/responses")!,
                upstreamResponsesCompactURL: URL(string: "http://127.0.0.1:1/v1/responses/compact")!,
                upstreamModelsURL: URL(string: "http://127.0.0.1:1/backend-api/codex/models")!
            ),
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            )
        )
        defer { service.stop() }

        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OC",
                    baseURL: "https://opencode.ai/inference/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "provider-key",
                    modelID: "deepseek-v4.1-flash-free",
                    thirdPartyModelProvider: .custom
                )
            )
        )
        service.startIfNeeded()

        let response = try await self.getFromRunningGateway(
            port: gatewayPort,
            path: "/v1/models?client_version=9.9.9",
            authorization: "provider-key"
        )

        XCTAssertEqual(response.statusCode, 200)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        let models = try XCTUnwrap(payload["models"] as? [[String: Any]])
        let slugs = models.compactMap { $0["slug"] as? String }
        XCTAssertTrue(slugs.contains("gpt-6.1-sol"))
        XCTAssertTrue(slugs.contains("gpt-5.5"))
        XCTAssertTrue(slugs.contains("deepseek-v4.1-flash-free"))
        for model in models {
            XCTAssertNotNil(model["display_name"] as? String)
            XCTAssertNotNil(model["supported_reasoning_levels"] as? [[String: Any]])
            XCTAssertNotNil(model["shell_type"] as? String)
            XCTAssertEqual(model["visibility"] as? String, "list")
            XCTAssertNotNil(model["supported_in_api"] as? Bool)
            XCTAssertNotNil(model["priority"] as? Int)
            XCTAssertNotNil(model["truncation_policy"] as? [String: Any])
            XCTAssertNotNil(model["experimental_supported_tools"] as? [Any])
            XCTAssertFalse((model["base_instructions"] as? String ?? "").isEmpty)
        }
    }

    func testModelsGETNormalizesOpenAICapabilitiesForProviderRoutes() async throws {
        let catalogBody = Data(
            #"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","description":"x","supported_reasoning_levels":[],"shell_type":"shell_command","visibility":"list","supported_in_api":true,"priority":1,"availability_nux":null,"upgrade":null,"support_verbosity":true,"default_verbosity":"low","apply_patch_tool_type":"freeform","truncation_policy":{"mode":"tokens","limit":10000},"experimental_supported_tools":[],"tool_mode":"code_mode_only","use_responses_lite":true,"multi_agent_version":"v2","multi_agent_reasoning_effort":"xhigh","guardian":{"mode":"strict"}}]}"#.utf8
        )
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            .respond(statusCode: 200, contentType: "application/json", body: catalogBody)
        }
        defer { upstreamServer.stop() }

        let gatewayPort = UInt16(53_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact"),
                upstreamModelsURL: upstreamServer.url(path: "/backend-api/codex/models")
            ),
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            )
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "token-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OC",
                    baseURL: "https://opencode.ai/inference/go/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "provider-key",
                    modelID: "deepseek-v4.1-flash",
                    thirdPartyModelProvider: .custom
                )
            )
        )
        service.startIfNeeded()

        let response = try await self.getFromRunningGateway(
            port: gatewayPort,
            path: "/v1/models?client_version=9.9.9",
            authorization: "provider-key"
        )

        XCTAssertEqual(response.statusCode, 200)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        let models = try XCTUnwrap(payload["models"] as? [[String: Any]])
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model["tool_mode"] as? String, "direct")
        XCTAssertEqual(model["use_responses_lite"] as? Bool, false)
        XCTAssertNil(model["multi_agent_version"])
        XCTAssertNil(model["multi_agent_reasoning_effort"])
        XCTAssertNil(model["guardian"])
        XCTAssertEqual(model["slug"] as? String, "gpt-6.1-sol")
    }

    func testModelsGETUsesCachedCatalogWhenUpstreamIsUnavailable() async throws {
        let cachedBody = Data(#"{"models":[{"slug":"cached-model"}]}"#.utf8)
        try CodexPaths.writeSecureFile(cachedBody, to: CodexPaths.openAIGatewayModelsCacheURL)

        let gatewayPort = UInt16(52_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 1,
                resourceTimeout: 1,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: URL(string: "http://127.0.0.1:1/v1/responses")!,
                upstreamResponsesCompactURL: URL(string: "http://127.0.0.1:1/v1/responses/compact")!,
                upstreamModelsURL: URL(string: "http://127.0.0.1:1/backend-api/codex/models")!
            ),
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            )
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "token-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.startIfNeeded()

        let response = try await self.getFromRunningGateway(
            port: gatewayPort,
            path: "/v1/models?client_version=9.9.9"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, String(data: cachedBody, encoding: .utf8))
    }

    func testOpenAIAccountRouteRetriesSelectedStatusCodesThroughRunningGateway() async throws {
        let selectedStatusCodes = [429, 500, 503, 504]
        let upstreamStatusCodes = [
            429, 200,
            500, 200,
            503, 200,
            504, 200,
            503, 503, 200,
            503, 503, 503,
        ]
        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.liveBackoffObserved")
        var observedDelays: [TimeInterval] = []
        var upstreamHitCount = 0
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            upstreamHitCount += 1
            let statusCode = upstreamStatusCodes[upstreamHitCount - 1]
            let body = statusCode == 200
                ? Data(#"{"ok":true}"#.utf8)
                : Data(#"{"error":{"message":"temporary upstream failure"}}"#.utf8)
            return .respond(statusCode: statusCode, contentType: "application/json", body: body)
        }
        defer { upstreamServer.stop() }

        let gatewayPort = UInt16(49_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
            ),
            routeJournalStore: OpenAIGatewayRouteJournalStore(
                fileURL: CodexPaths.openAIGatewayRouteJournalURL
            ),
            retryDelaySleeper: { delay in
                observedQueue.sync {
                    observedDelays.append(delay)
                }
            },
            retryJitterMultiplier: { 1 }
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "token-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .hybridProvider,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    routeTargetRetryAttempts: 2,
                    retryableStatusCodes: selectedStatusCodes,
                    retryUpstreamCapacityErrors: false
                )
            )
        )
        service.startIfNeeded()

        for selectedStatusCode in selectedStatusCodes {
            let response = try await self.postToRunningGateway(
                port: gatewayPort,
                stickyKey: "openai-account-selected-status-\(selectedStatusCode)",
                body: #"{"model":"gpt-5.4","input":"hello"}"#
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, #"{"ok":true}"#)
        }

        let mergedSuccessResponse = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "openai-account-merged-retry-success",
            body: #"{"model":"gpt-5.4","input":"hello"}"#
        )
        XCTAssertEqual(mergedSuccessResponse.statusCode, 200)

        let mergedFailureResponse = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "openai-account-merged-retry-failure",
            body: #"{"model":"gpt-5.4","input":"hello"}"#
        )
        XCTAssertEqual(mergedFailureResponse.statusCode, 503)

        XCTAssertEqual(upstreamHitCount, 14)
        XCTAssertEqual(observedQueue.sync { observedDelays }, [1, 1, 1, 1, 1, 2, 1, 2])

        let snapshot = service.reasoningRetryGuardSnapshot()
        let retryEntries = snapshot.logEntries.filter { $0.kind == .retry }
        XCTAssertEqual(retryEntries.count, 6)
        XCTAssertEqual(Set(retryEntries.map(\.id)).count, retryEntries.count)
        XCTAssertEqual(retryEntries[retryEntries.count - 2].retryCount, 2)
        XCTAssertEqual(retryEntries[retryEntries.count - 2].retryResult, .succeeded)
        XCTAssertTrue(retryEntries[retryEntries.count - 2].message.contains("attempts=2/2"))
        XCTAssertTrue(retryEntries[retryEntries.count - 2].message.contains("final_status=200"))
        XCTAssertEqual(retryEntries.last?.retryCount, 2)
        XCTAssertEqual(retryEntries.last?.retryResult, .failed)
        XCTAssertTrue(retryEntries.last?.message.contains("final_status=503") == true)
    }

    func testResponsesPOSTStreamsCRLFEventChunksAcrossSmallSSEFragments() async throws {
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            .stream(
                statusCode: 200,
                contentType: "text/event-stream",
                chunks: [
                    Data("data: first\r\n".utf8),
                    Data("\r\n".utf8),
                    Data("data: second\r\n\r\n".utf8),
                ]
            )
        }
        defer { upstreamServer.stop() }

        let routeJournalStore = OpenAIGatewayRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let gatewayPort = UInt16(47_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
            ),
            routeJournalStore: routeJournalStore
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.startIfNeeded()

        let response = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "sse-crlf-fragments",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: first\r\n\r\ndata: second\r\n\r\n")
    }

    func testResponsesPOSTStreamsLongSSEChunkWithoutDelimiterUntilTheEnd() async throws {
        let longPayload = String(repeating: "x", count: 2_048)
        let upstreamServer = try ScriptedLocalHTTPResponseServer { _ in
            .stream(
                statusCode: 200,
                contentType: "text/event-stream",
                chunks: [
                    Data("data: \(longPayload)\n".utf8),
                    Data("\n".utf8),
                ]
            )
        }
        defer { upstreamServer.stop() }

        let routeJournalStore = OpenAIGatewayRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let gatewayPort = UInt16(47_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                requestTimeout: 2,
                resourceTimeout: 2,
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: nil
            ),
            runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration(
                host: "127.0.0.1",
                port: gatewayPort,
                upstreamResponsesURL: upstreamServer.url(path: "/v1/responses"),
                upstreamResponsesCompactURL: upstreamServer.url(path: "/v1/responses/compact")
            ),
            routeJournalStore: routeJournalStore
        )
        defer { service.stop() }

        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )
        service.startIfNeeded()

        let response = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "sse-long-fragment",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: \(longPayload)\n\n")
    }

    func testResponsesCompactPOSTAcceptsSub2APIAliasPathsAndQueries() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.compactAliasObserved")
        var forwardedURLs: [String] = []
        var forwardedBodies: [[String: Any]] = []

        MockURLProtocol.handler = { request in
            let bodyData =
                request.httpBody ??
                (URLProtocol.property(
                    forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                    in: request
                ) as? Data) ??
                Data()
            let body =
                (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ??
                [:]

            observedQueue.sync {
                forwardedURLs.append(request.url?.absoluteString ?? "")
                forwardedBodies.append(body)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        for path in [
            "/responses/compact",
            "/backend-api/codex/responses/compact",
            "/v1/responses/compact?source=codex",
        ] {
            let response = try await self.postToGateway(
                service: service,
                path: path,
                stickyKey: "compact-alias-\(path.hashValue)",
                body: """
                {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"alias compact"}]}],"service_tier":"priority","prompt_cache_key":"drop-me","store":true,"stream":false}
                """
            )
            XCTAssertEqual(response.statusCode, 200, "path \(path)")
        }

        let observed = observedQueue.sync { (forwardedURLs, forwardedBodies) }
        XCTAssertEqual(
            observed.0,
            [
                "https://example.invalid/v1/responses/compact",
                "https://example.invalid/v1/responses/compact",
                "https://example.invalid/v1/responses/compact",
            ]
        )
        XCTAssertEqual(observed.1.count, 3)
        for body in observed.1 {
            self.assertCompactBody(body, expectedText: "alias compact")
        }
    }

    func testResponsesPOSTPreservesPreviousResponseIDForNativeResponses() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "pro",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        service.updateState(
            accounts: [account],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: account.accountId)
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.previousResponseObserved")
        var forwardedBodies: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            let bodyData =
                request.httpBody ??
                (URLProtocol.property(
                    forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                    in: request
                ) as? Data) ??
                Data()
            let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            observedQueue.sync {
                forwardedBodies.append(body)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "history-session-1",
            body: #"{"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"history hello"}]}],"previous_response_id":"resp-history-1","prompt_cache_key":"history-cache-seed","reasoning":{"effort":"high"},"include":["reasoning.encrypted_content"],"store":true,"stream":false}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"ok":true}"#)

        let observed = observedQueue.sync { forwardedBodies }
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0]["previous_response_id"] as? String, "resp-history-1")
        XCTAssertEqual(observed[0]["prompt_cache_key"] as? String, "history-cache-seed")
        XCTAssertEqual(observed[0]["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testCompatibleProviderTargetForwardsToProviderWithProviderAPIKey() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1/",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedTimeout: TimeInterval?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedTimeout = request.timeoutInterval
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-target",
            body: #"{"model":"gpt-5.4","input":[{"type":"reasoning","encrypted_content":"当前进度"},{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"include":["reasoning.encrypted_content","file_search_call.results"]}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedURL?.absoluteString, "https://provider.example/v1/responses")
        XCTAssertEqual(observedAuthorization, "Bearer sk-provider")
        XCTAssertEqual(observedTimeout, 60)
        XCTAssertEqual(observedBody?["model"] as? String, "provider-model")
        XCTAssertEqual(observedBody?["include"] as? [String], ["file_search_call.results"])
        let input = try XCTUnwrap(observedBody?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    func testCompatibleProviderCompactUsesProviderCompactEndpointAndPreservesCodexFields() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1/",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedOpenAIAccountID: String?
        var observedTimeout: TimeInterval?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedOpenAIAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id")
            observedTimeout = request.timeoutInterval
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "provider-compact",
            body: #"{"model":"gpt-5.4","input":"compact me","stream":true,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"temperature":0.7}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedURL?.absoluteString, "https://provider.example/v1/responses/compact")
        XCTAssertEqual(observedAuthorization, "Bearer sk-provider")
        XCTAssertNil(observedOpenAIAccountID)
        XCTAssertEqual(observedTimeout, 180)
        XCTAssertEqual(observedBody?["model"] as? String, "provider-model")
        XCTAssertEqual(observedBody?["input"] as? String, "compact me")
        XCTAssertEqual(observedBody?["stream"] as? Bool, true)
        XCTAssertNil(observedBody?["include"])
        XCTAssertEqual((observedBody?["tools"] as? [[String: Any]])?.first?["type"] as? String, "noop")
        XCTAssertEqual(observedBody?["temperature"] as? Double, 0.7)
    }

    func testDeepSeekThirdPartyProviderUsesChatCompletionsGatewayAdapter() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "deepseek",
                    providerLabel: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    accountID: "acct-deepseek",
                    apiKey: "sk-deepseek",
                    modelID: "deepseek-v4-pro",
                    thirdPartyModelProvider: .deepSeek
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedAPIKey: String?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedAPIKey = request.value(forHTTPHeaderField: "api-key")
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_ds","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "deepseek-third-party",
            body: #"{"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"max_output_tokens":123,"reasoning":{"effort":"xhigh"},"tools":[{"type":"function","name":"lookup","description":"Lookup","parameters":{"type":"object"}}],"tool_choice":"auto"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedURL?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(observedAuthorization, "Bearer sk-deepseek")
        XCTAssertNil(observedAPIKey)
        XCTAssertEqual(observedBody?["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(observedBody?["stream"] as? Bool, false)
        XCTAssertEqual(observedBody?["max_tokens"] as? Int, 123)
        XCTAssertEqual(observedBody?["reasoning_effort"] as? String, "max")
        XCTAssertEqual((observedBody?["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.dropFirst().first?["role"] as? String, "user")
        XCTAssertEqual(messages.dropFirst().first?["content"] as? String, "hello")
        let tools = try XCTUnwrap(observedBody?["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "lookup")
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        XCTAssertEqual(responseObject["model"] as? String, "gpt-5.4")
        XCTAssertTrue(response.body.contains(#""output_text":"ok""#))
    }

    func testDeepSeekThirdPartyProviderBuildsValidChatBodyForEmptyLegacySessionBody() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "deepseek",
                    providerLabel: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    accountID: "acct-deepseek",
                    apiKey: "sk-deepseek",
                    modelID: "deepseek-v4-pro",
                    thirdPartyModelProvider: .deepSeek
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_ds","choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "mimo-session-after-deepseek-switch",
            body: ""
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedBody?["model"] as? String, "deepseek-v4-pro")
        XCTAssertNil(observedBody?["max_tokens"])
        XCTAssertEqual((observedBody?["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.dropFirst().first?["role"] as? String, "user")
        XCTAssertEqual(messages.dropFirst().first?["content"] as? String, "")
        XCTAssertTrue(response.body.contains(#""output_text":"ok""#))
    }

    func testDeepSeekThirdPartyProviderMapsCodexDeveloperContextToSystemRole() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "deepseek",
                    providerLabel: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    accountID: "acct-deepseek",
                    apiKey: "sk-deepseek",
                    modelID: "deepseek-v4-pro",
                    thirdPartyModelProvider: .deepSeek
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_ds","choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "deepseek-developer-context",
            body: #"{"input":[{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are Codex."}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"Deepseek，只回复ok"}]}]}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertFalse(messages.contains { ($0["role"] as? String) == "developer" })
        XCTAssertTrue(messages.contains { ($0["role"] as? String) == "system" && ($0["content"] as? String)?.contains("You are Codex.") == true })
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "Deepseek，只回复ok")
        XCTAssertTrue(response.body.contains(#""output_text":"ok""#))
    }

    func testDeepSeekThirdPartyProviderGroupsParallelFunctionCallsBeforeToolOutputs() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "deepseek",
                    providerLabel: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    accountID: "acct-deepseek",
                    apiKey: "sk-deepseek",
                    modelID: "deepseek-v4-pro",
                    thirdPartyModelProvider: .deepSeek
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_ds","choices":[{"message":{"role":"assistant","content":"这是一个 Electron 项目。"}}]}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "deepseek-parallel-tools",
            body: #"{"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"你能理解这个项目吗？"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"让我先快速了解一下这个项目的结构。"}]},{"type":"function_call","call_id":"call_ls","name":"exec_command","arguments":"{\"cmd\":\"ls -la\"}"},{"type":"function_call","call_id":"call_readme","name":"exec_command","arguments":"{\"cmd\":\"head -60 README.md\"}"},{"type":"function_call","call_id":"call_pkg","name":"exec_command","arguments":"{\"cmd\":\"cat package.json\"}"},{"type":"function_call_output","call_id":"call_ls","output":"Output:\nREADME.md\npackage.json\napp/"},{"type":"function_call_output","call_id":"call_readme","output":"Output:\n# Stretchly\nThe break time reminder app"},{"type":"function_call_output","call_id":"call_pkg","output":"Output:\n{\"name\":\"Stretchly\",\"main\":\"app/main.js\",\"type\":\"module\"}"}]}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        let toolCallMessageIndex = try XCTUnwrap(messages.firstIndex { ($0["tool_calls"] as? [[String: Any]])?.isEmpty == false })
        let toolCalls = try XCTUnwrap(messages[toolCallMessageIndex]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 3)
        XCTAssertEqual(messages[toolCallMessageIndex]["role"] as? String, "assistant")
        XCTAssertEqual(messages[toolCallMessageIndex + 1]["role"] as? String, "tool")
        XCTAssertEqual(messages[toolCallMessageIndex + 1]["tool_call_id"] as? String, "call_ls")
        XCTAssertEqual(messages[toolCallMessageIndex + 2]["role"] as? String, "tool")
        XCTAssertEqual(messages[toolCallMessageIndex + 2]["tool_call_id"] as? String, "call_readme")
        XCTAssertEqual(messages[toolCallMessageIndex + 3]["role"] as? String, "tool")
        XCTAssertEqual(messages[toolCallMessageIndex + 3]["tool_call_id"] as? String, "call_pkg")
        XCTAssertTrue(response.body.contains(#""output_text":"这是一个 Electron 项目。""#))
    }

    func testDeepSeekThirdPartyProviderConvertsContextRecordsWithoutToolCallIDs() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "deepseek",
                    providerLabel: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    accountID: "acct-deepseek",
                    apiKey: "sk-deepseek",
                    modelID: "deepseek-v4-pro",
                    thirdPartyModelProvider: .deepSeek
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_ds","choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "deepseek-context-records",
            body: #"{"input":[{"type":"function_call","call_id":"call_ls","name":"exec_command","arguments":"{}"},{"type":"function_call_output","id":"fco_page","name":"codex_apps_open_page","namespace":"agent","output":"{\"page_id\":null}"},{"type":"function_call_output","call_id":"call_ls","output":"README.md"}]}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "assistant", "tool", "user"])
        XCTAssertEqual(messages[3]["content"] as? String, "codex_apps_open_page: {\"page_id\":null}")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_ls")
        XCTAssertFalse(messages.contains { ($0["tool_call_id"] as? String) == "call_codexbar" })
    }

    func testMimoThirdPartyProviderUsesAPIKeyHeaderAndMaxCompletionTokens() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "mimo",
                    providerLabel: "MiMo",
                    baseURL: "https://api.xiaomimimo.com/v1",
                    accountID: "acct-mimo",
                    apiKey: "mimo-secret",
                    modelID: "mimo-v2.5-pro",
                    thirdPartyModelProvider: .mimo
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedAPIKey: String?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedAPIKey = request.value(forHTTPHeaderField: "api-key")
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_mimo","choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "mimo-third-party",
            body: #"{"input":"summarize","max_output_tokens":456}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedURL?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertNil(observedAuthorization)
        XCTAssertEqual(observedAPIKey, "mimo-secret")
        XCTAssertEqual(observedBody?["model"] as? String, "mimo-v2.5-pro")
        XCTAssertEqual(observedBody?["max_completion_tokens"] as? Int, 456)
        XCTAssertNil(observedBody?["max_tokens"])
        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.dropFirst().first?["role"] as? String, "user")
        XCTAssertEqual(messages.dropFirst().first?["content"] as? String, "summarize")
        XCTAssertTrue(response.body.contains(#""output_text":"done""#))
    }

    func testCustomThirdPartyProviderUsesBearerAndOpenAICompatibleBody() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "custom-nim",
                    providerLabel: "NVIDIA NIM",
                    baseURL: "https://integrate.api.nvidia.com/v1",
                    accountID: "acct-nim",
                    apiKey: "nim-secret",
                    modelID: "qwen/qwen3.5-122b-a10b",
                    thirdPartyModelProvider: .custom
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedAPIKey: String?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedAPIKey = request.value(forHTTPHeaderField: "api-key")
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_custom","choices":[{"message":{"role":"assistant","content":"custom ok"}}]}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "custom-third-party",
            body: #"{"input":"ping","max_output_tokens":321,"reasoning":{"effort":"high"}}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedURL?.absoluteString, "https://integrate.api.nvidia.com/v1/chat/completions")
        XCTAssertEqual(observedAuthorization, "Bearer nim-secret")
        XCTAssertNil(observedAPIKey)
        XCTAssertEqual(observedBody?["model"] as? String, "qwen/qwen3.5-122b-a10b")
        XCTAssertEqual(observedBody?["max_tokens"] as? Int, 321)
        XCTAssertNil(observedBody?["max_completion_tokens"])
        XCTAssertNil(observedBody?["thinking"])
        XCTAssertNil(observedBody?["reasoning_effort"])
        XCTAssertTrue(response.body.contains(#""output_text":"custom ok""#))
    }

    func testThirdPartyResponsesStreamCompletesOnlyAfterUpstreamDoneMarker() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "mimo",
                    providerLabel: "MiMo",
                    baseURL: "https://api.xiaomimimo.com/v1",
                    accountID: "acct-mimo",
                    apiKey: "mimo-secret",
                    modelID: "mimo-v2.5-pro",
                    thirdPartyModelProvider: .mimo
                )
            )
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"content":"你好"},"finish_reason":"stop"}]}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "mimo-stream",
            body: #"{"input":"summarize","stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        let body = response.body
        XCTAssertTrue(body.contains(#""type":"response.output_text.delta""#))
        XCTAssertTrue(body.contains(#""type":"response.completed""#))
        XCTAssertLessThan(
            body.range(of: #"response.output_text.delta"#)!.lowerBound,
            body.range(of: #"response.completed"#)!.lowerBound
        )
    }

    func testThirdPartyResponsesStreamDoesNotExposeReasoningContentAsOutputText() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "mimo",
                    providerLabel: "MiMo",
                    baseURL: "https://api.xiaomimimo.com/v1",
                    accountID: "acct-mimo",
                    apiKey: "mimo-secret",
                    modelID: "mimo-v2.5",
                    thirdPartyModelProvider: .mimo
                )
            )
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"reasoning_content":"I should inspect the code first."}}]}

                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"content":"我会先看代码。"},"finish_reason":"stop"}]}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "mimo-reasoning",
            body: #"{"input":"请用中文总结","stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.body.contains("I should inspect the code first."))
        XCTAssertTrue(response.body.contains("我会先看代码。"))
    }

    func testThirdPartyResponsesStreamEmitsFunctionCallArgumentsDone() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "mimo",
                    providerLabel: "MiMo",
                    baseURL: "https://api.xiaomimimo.com/v1",
                    accountID: "acct-mimo",
                    apiKey: "mimo-secret",
                    modelID: "mimo-v2.5",
                    thirdPartyModelProvider: .mimo
                )
            )
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_lookup","type":"function","function":{"name":"exec_command","arguments":"{\\"cmd\\":"}}]}}]}

                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"pwd\\"}"}}]},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "mimo-tool-call",
            body: #"{"input":"查一下当前目录","tools":[{"type":"function","name":"exec_command","parameters":{"type":"object"}}],"stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains(#""type":"response.function_call_arguments.done""#))
        XCTAssertLessThan(
            response.body.range(of: #"response.function_call_arguments.done"#)!.lowerBound,
            response.body.range(of: #"response.output_item.done"#)!.lowerBound
        )
    }

    func testThirdPartyResponsesStreamMapsApplyPatchBackToCustomToolCall() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "mimo",
                    providerLabel: "MiMo",
                    baseURL: "https://api.xiaomimimo.com/v1",
                    accountID: "acct-mimo",
                    apiKey: "mimo-secret",
                    modelID: "mimo-v2.5",
                    thirdPartyModelProvider: .mimo
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_patch","type":"function","function":{"name":"apply_patch","arguments":"{\\"input\\":\\"*** Begin Patch\\\\n"}}]}}]}

                data: {"id":"chatcmpl_mimo","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"*** Update File: a.txt\\\\n@@\\\\n-old\\\\n+new\\\\n*** End Patch\\"}"}}]},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "mimo-apply-patch",
            body: #"{"input":"移除 Preset","tools":[{"type":"apply_patch"}],"stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        let tools = try XCTUnwrap(observedBody?["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "apply_patch")
        let parameters = try XCTUnwrap((tools.first?["function"] as? [String: Any])?["parameters"] as? [String: Any])
        XCTAssertNotNil(parameters["properties"])
        XCTAssertTrue(response.body.contains(#""type":"custom_tool_call""#))
        XCTAssertTrue(response.body.contains(#""type":"response.custom_tool_call_input.done""#))
        XCTAssertTrue(response.body.contains(#""name":"apply_patch""#))
        XCTAssertTrue(response.body.contains(#"*** Begin Patch"#))
        XCTAssertFalse(response.body.contains(#""type":"function_call","status":"completed","call_id":"call_patch","name":"apply_patch""#))
    }

    func testThirdPartyResponsesStreamMapsExecCodeModeToolBackToCustomToolCall() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OC",
                    baseURL: "https://opencode.ai/inference/go/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "oc-secret",
                    modelID: "deepseek-v4.1-flash",
                    thirdPartyModelProvider: .custom
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"id":"chatcmpl_oc","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_exec","type":"function","function":{"name":"exec","arguments":"{\\"input\\":\\"const r = await tools.exec_command"}}]}}]}

                data: {"id":"chatcmpl_oc","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"({cmd: \\"ls\\"}); text(r.output);\\"}"}}]},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "oc-exec",
            body: #"{"input":"列出文件","tools":[{"type":"custom","name":"exec","description":"Run JS","format":{"type":"grammar","syntax":"lark","definition":"start: /.+/"}}],"stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        let tools = try XCTUnwrap(observedBody?["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "exec")
        let parameters = try XCTUnwrap((tools.first?["function"] as? [String: Any])?["parameters"] as? [String: Any])
        XCTAssertNotNil(parameters["properties"])
        XCTAssertTrue(response.body.contains(#""type":"custom_tool_call""#))
        XCTAssertTrue(response.body.contains(#""type":"response.custom_tool_call_input.done""#))
        XCTAssertTrue(response.body.contains(#""name":"exec""#))
        XCTAssertTrue(response.body.contains("tools.exec_command"))
        XCTAssertFalse(response.body.contains(#""type":"function_call","status":"completed""#))
    }

    func testOpenCodeResponsesUsesNativeResponsesEndpointAndRewritesModel() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OpenCode Go",
                    baseURL: "https://opencode.ai/inference/go/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "oc-secret",
                    modelID: "deepseek-v4.1-flash",
                    thirdPartyModelProvider: .openCode
                )
            )
        )

        var capturedURL: URL?
        var capturedBody: [String: Any]?
        var capturedHeaders: [String: String] = [:]
        MockURLProtocol.handler = { request in
            capturedURL = request.url
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"type":"response.completed","response":{"id":"resp_upstream","status":"completed","output":[],"usage":{"input_tokens":120,"output_tokens":30,"cost":0.75}}}

                """.utf8
            )
            return (response, body)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "opencode-native-session",
            body: #"{"model":"gpt-6.1-sol","input":"hi","stream":true,"access_programs":{"cyber":true},"stream_options":{"include_usage":true},"prompt_cache_key":"thread-1","client_metadata":{"thread_id":"thread-1"}}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains(#""usage":{"input_tokens":120,"output_tokens":30,"cost":0.75}"#))
        XCTAssertTrue(response.body.contains(#""type":"response.completed""#))
        XCTAssertEqual(capturedURL?.path, "/inference/go/openai/v1/responses")
        XCTAssertEqual(capturedBody?["model"] as? String, "deepseek-v4.1-flash")
        XCTAssertEqual(capturedBody?["stream"] as? Bool, true)
        XCTAssertNil(capturedBody?["access_programs"])
        XCTAssertNil(capturedBody?["stream_options"])
        XCTAssertNil(capturedBody?["prompt_cache_key"])
        XCTAssertNil(capturedBody?["client_metadata"])
        XCTAssertEqual(capturedHeaders["Authorization"], "Bearer oc-secret")
        XCTAssertEqual(capturedHeaders["session_id"], "opencode-native-session")
        XCTAssertEqual(capturedHeaders["x-opencode-session"], "opencode-native-session")
    }

    func testOpenCodeResponsesConvertsCompactionItemToInstructions() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OpenCode Go",
                    baseURL: "https://opencode.ai/inference/go/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "oc-secret",
                    modelID: "deepseek-v4.1-flash",
                    thirdPartyModelProvider: .openCode
                )
            )
        )

        var capturedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: {\"type\":\"response.completed\",\"response\":{}}\n\n".utf8))
        }

        let encoded = Data("SUMMARY".utf8).base64EncodedString()
        let body = #"{"model":"gpt-6.1-sol","instructions":"BASE","input":[{"type":"compaction","encrypted_content":"\#(encoded)"},{"type":"message","role":"user","content":"continue"}],"stream":true}"#

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "opencode-compaction-replay",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["type"] as? String, "message")
        let instructions = try XCTUnwrap(capturedBody?["instructions"] as? String)
        XCTAssertTrue(instructions.contains("BASE"))
        XCTAssertTrue(instructions.contains("Earlier conversation summary:\nSUMMARY"))
    }

    func testThirdPartyCompactionRequestReturnsSingleCompactionItem() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OC",
                    baseURL: "https://opencode.ai/inference/go/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "oc-secret",
                    modelID: "deepseek-v4.1-flash",
                    thirdPartyModelProvider: .custom
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"SUMMARY_TEXT"}}]}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "oc-compaction",
            body: #"{"model":"gpt-6.1-sol","input":[{"type":"message","role":"user","content":"请重构项目"},{"type":"compaction_trigger"}],"stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.body.contains("compaction_trigger"))
        let events = response.body
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard line.hasPrefix("data: ") else { return nil }
                let payload = line.dropFirst("data: ".count)
                guard payload != "[DONE]" else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            }
        let compactionItems = events.compactMap { event -> [String: Any]? in
            guard event["type"] as? String == "response.output_item.done",
                  let item = event["item"] as? [String: Any],
                  item["type"] as? String == "compaction" else {
                return nil
            }
            return item
        }
        XCTAssertEqual(compactionItems.count, 1)
        let encrypted = try XCTUnwrap(compactionItems.first?["encrypted_content"] as? String)
        let summary = try XCTUnwrap(
            Data(base64Encoded: encrypted).flatMap { String(data: $0, encoding: .utf8) }
        )
        XCTAssertTrue(summary.hasPrefix("SUMMARY_TEXT"))
        XCTAssertTrue(summary.contains("Recent transcript"))
        XCTAssertTrue(summary.contains("请重构项目"))

        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("请重构项目") == true })
    }

    func testThirdPartyCompactionItemBecomesSystemSummaryOnNextRequest() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "oc",
                    providerLabel: "OC",
                    baseURL: "https://opencode.ai/inference/go/openai/v1",
                    accountID: "acct-oc",
                    apiKey: "oc-secret",
                    modelID: "deepseek-v4.1-flash",
                    thirdPartyModelProvider: .custom
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8))
        }

        let encoded = Data("SUMMARY".utf8).base64EncodedString()
        let body = #"{"model":"gpt-6.1-sol","input":[{"type":"compaction","encrypted_content":"\#(encoded)"},{"type":"message","role":"user","content":"继续"}],"stream":true}"#

        _ = try await self.postToGateway(
            service: service,
            path: "/v1/responses",
            stickyKey: "oc-compaction-replay",
            body: body
        )

        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { message in
            message["role"] as? String == "system" &&
                (message["content"] as? String)?.contains("Earlier conversation summary") == true &&
                (message["content"] as? String)?.contains("SUMMARY") == true
        })
    }

    func testThirdPartyRequestAddsUserLanguageInstructionToSystemPrompt() async throws {
        let service = self.makeService()
        service.updateState(
            accounts: [],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "mimo",
                    providerLabel: "MiMo",
                    baseURL: "https://api.xiaomimimo.com/v1",
                    accountID: "acct-mimo",
                    apiKey: "mimo-secret",
                    modelID: "mimo-v2.5-pro",
                    thirdPartyModelProvider: .mimo
                )
            )
        )

        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"chatcmpl_mimo","choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8)
            )
        }

        _ = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "mimo-language",
            body: #"{"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"请用中文总结"}]}]}"#
        )

        let messages = try XCTUnwrap(observedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemPrompt.contains("请使用用户当前使用的语言回复"))
        XCTAssertTrue(systemPrompt.contains("简体中文"))
    }

    func testCompatibleProviderTargetBridgesWebSocketThroughResponsesPOST() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1/",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedTimeout: TimeInterval?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedTimeout = request.timeoutInterval
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = Data(
                """
                data: {"type":"response.created"}

                data: {"type":"response.completed"}

                data: [DONE]

                """.utf8
            )
            return (response, body)
        }

        let result = try await service.routeTargetWebSocketBridgeProbeForTesting(
            #"{"type":"response.create","response":{"input":"hello"}}"#
        )

        XCTAssertEqual(result.events, [#"{"type":"response.created"}"#, #"{"type":"response.completed"}"#])
        XCTAssertEqual(result.closeCode, 1000)
        XCTAssertEqual(observedURL?.absoluteString, "https://provider.example/v1/responses")
        XCTAssertEqual(observedAuthorization, "Bearer sk-provider")
        XCTAssertEqual(observedTimeout, 60)
        XCTAssertEqual(observedBody?["model"] as? String, "provider-model")
        XCTAssertEqual(observedBody?["input"] as? String, "hello")
        XCTAssertEqual(observedBody?["stream"] as? Bool, true)
        XCTAssertEqual(observedBody?["store"] as? Bool, false)
    }

    func testCompatibleProviderTargetWebSocketBridgeRetriesInBandCapacityError() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1/",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(routeTargetRetryAttempts: 2)
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            if upstreamHitCount == 1 {
                return (
                    response,
                    Data(
                        """
                        data: {"type":"response.failed","response":{"status":"failed","error":{"codex_error_info":"server_overloaded"}}}

                        """.utf8
                    )
                )
            }
            return (
                response,
                Data(
                    """
                    data: {"type":"response.created"}

                    data: {"type":"response.completed"}

                    data: [DONE]

                    """.utf8
                )
            )
        }

        let result = try await service.routeTargetWebSocketBridgeProbeForTesting(
            #"{"type":"response.create","response":{"input":"hello"}}"#
        )

        XCTAssertEqual(result.events, [#"{"type":"response.created"}"#, #"{"type":"response.completed"}"#])
        XCTAssertEqual(result.closeCode, 1000)
        XCTAssertEqual(upstreamHitCount, 2)

        let retryEntries = service.reasoningRetryGuardSnapshot().logEntries.filter { $0.kind == .retry }
        XCTAssertEqual(retryEntries.count, 1)
        XCTAssertEqual(retryEntries.first?.retryCount, 1)
        XCTAssertEqual(retryEntries.first?.retryResult, .succeeded)
        XCTAssertTrue(retryEntries.first?.message.contains("path=responses_ws_bridge") == true)
        XCTAssertTrue(retryEntries.first?.message.contains("status=503") == true)
        XCTAssertTrue(retryEntries.first?.message.contains("final_status=200") == true)
    }

    func testProviderTargetRejectsForgedLocalBearer() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        MockURLProtocol.handler = { _ in
            XCTFail("unauthorized requests must not reach upstream")
            throw URLError(.userAuthenticationRequired)
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-unauthorized",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "forged"
        )

        XCTAssertEqual(response.statusCode, 401)
    }

    func testProviderCompactFailureReportsUpstreamDiagnostic() async throws {
        var diagnostics: [OpenAIAccountGatewayUpstreamFailureDiagnostic] = []
        let diagnosticsQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.providerDiagnostics")
        let service = self.makeService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(
                proxyResolutionMode: .loopbackProxySafe,
                snapshot: self.makeProxySnapshot(
                    httpsHost: "127.0.0.1",
                    httpsPort: 7897
                )
            ),
            diagnosticsReporter: { diagnostic in
                diagnosticsQueue.sync {
                    diagnostics.append(diagnostic)
                }
            }
        )
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "provider-diagnostic",
            body: #"{"model":"gpt-5.4","input":"compact me"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(response.body, #"{"error":{"message":"codexbar gateway failed to reach provider upstream"}}"#)

        let diagnostic = try XCTUnwrap(diagnosticsQueue.sync { diagnostics.last })
        XCTAssertEqual(diagnostic.route, "compact")
        XCTAssertEqual(diagnostic.target, "compatibleProvider")
        XCTAssertEqual(diagnostic.upstreamHost, "provider.example")
        XCTAssertEqual(diagnostic.upstreamPath, "/v1/responses/compact")
        XCTAssertEqual(diagnostic.failureClass, .transport)
        XCTAssertEqual(diagnostic.errorDomain, NSURLErrorDomain)
        XCTAssertEqual(diagnostic.errorCode, URLError.cannotConnectToHost.rawValue)
        XCTAssertFalse(diagnostic.loopbackProxySafeApplied)
        XCTAssertEqual(diagnostic.systemProxySummary, "https=127.0.0.1:7897")
        XCTAssertEqual(diagnostic.effectiveProxySummary, "https=127.0.0.1:7897")
    }

    func testOpenRouterTargetUsesOpenRouterNormalization() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .openRouter(
                .init(
                    providerID: "openrouter",
                    accountID: "acct-openrouter",
                    apiKey: "sk-or-v1-primary",
                    modelID: "anthropic/claude-sonnet-4.5"
                )
            )
        )

        var observedURL: URL?
        var observedAuthorization: String?
        var observedTimeout: TimeInterval?
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            observedURL = request.url
            observedAuthorization = request.value(forHTTPHeaderField: "authorization")
            observedTimeout = request.timeoutInterval
            if let body = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                observedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "openrouter-target",
            body: #"{"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"store":true,"stream":true,"tools":[{"type":"noop"}],"temperature":0.7}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(observedURL?.absoluteString, "https://openrouter.ai/api/v1/responses")
        XCTAssertEqual(observedAuthorization, "Bearer sk-or-v1-primary")
        XCTAssertEqual(observedTimeout, 180)
        XCTAssertEqual(observedBody?["model"] as? String, "anthropic/claude-sonnet-4.5")
        XCTAssertNil(observedBody?["store"])
        XCTAssertNil(observedBody?["stream"])
        XCTAssertNil(observedBody?["tools"])
    }

    func testProviderTargetDoesNotFailOverOnProviderErrorStatus() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":{"message":"limited"}}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-no-failover",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.body, #"{"error":{"message":"limited"}}"#)
        XCTAssertEqual(upstreamHitCount, 1)
    }

    func testProviderTargetRetriesSelected502InHybridRoute() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(routeTargetRetryAttempts: 5)
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let statusCode = upstreamHitCount == 1 ? 502 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = statusCode == 502
                ? #"{"error":{"message":"bad gateway"}}"#
                : #"{"ok":true}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-5xx-retry",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"ok":true}"#)
        XCTAssertEqual(upstreamHitCount, 2)
    }

    func testProviderTargetRetriesSelected429500503And504InHybridRoute() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    routeTargetRetryAttempts: 2,
                    retryableStatusCodes: [429, 500, 502, 503, 504],
                    retryUpstreamCapacityErrors: false
                )
            )
        )

        for selectedStatusCode in [429, 500, 503, 504] {
            var upstreamHitCount = 0
            MockURLProtocol.handler = { request in
                upstreamHitCount += 1
                let statusCode = upstreamHitCount == 1 ? selectedStatusCode : 200
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = statusCode == 200
                    ? #"{"ok":true}"#
                    : #"{"error":{"message":"temporary upstream failure"}}"#
                return (response, Data(body.utf8))
            }

            let response = try await self.postToGateway(
                service: service,
                stickyKey: "provider-selected-status-\(selectedStatusCode)",
                body: #"{"model":"gpt-5.4","input":"hello"}"#,
                authorizationBearer: "access-oauth"
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, #"{"ok":true}"#)
            XCTAssertEqual(upstreamHitCount, 2)
        }
    }

    func testProviderTargetUsesExponentialBackoffWhenRetryAfterIsMissing() async throws {
        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.backoffObserved")
        var observedDelays: [TimeInterval] = []
        let service = self.makeService(
            retryDelaySleeper: { delay in
                observedQueue.sync {
                    observedDelays.append(delay)
                }
            },
            retryJitterMultiplier: { 1 }
        )
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    routeTargetRetryAttempts: 4,
                    retryableStatusCodes: [503],
                    retryUpstreamCapacityErrors: false
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let statusCode = upstreamHitCount <= 4 ? 503 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = statusCode == 200
                ? #"{"ok":true}"#
                : #"{"error":{"message":"unavailable"}}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-exponential-backoff",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(upstreamHitCount, 5)
        XCTAssertEqual(observedQueue.sync { observedDelays }, [1, 2, 4, 8])
    }

    func testProviderTargetPrefersRetryAfterOverExponentialBackoff() async throws {
        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.retryAfterDelayObserved")
        var observedDelays: [TimeInterval] = []
        let service = self.makeService(
            retryDelaySleeper: { delay in
                observedQueue.sync {
                    observedDelays.append(delay)
                }
            },
            retryJitterMultiplier: { 1 }
        )
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    routeTargetRetryAttempts: 1,
                    retryableStatusCodes: [503],
                    retryUpstreamCapacityErrors: false
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let statusCode = upstreamHitCount == 1 ? 503 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "Retry-After": "12",
                ]
            )!
            let body = statusCode == 200
                ? #"{"ok":true}"#
                : #"{"error":{"message":"unavailable"}}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-retry-after-backoff",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(upstreamHitCount, 2)
        let delays = observedQueue.sync { observedDelays }
        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(try XCTUnwrap(delays.first), 12, accuracy: 0.05)
    }

    func testProviderTargetReturnsUnselected503WithoutRetry() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    routeTargetRetryAttempts: 5,
                    retryableStatusCodes: [502],
                    retryUpstreamCapacityErrors: false
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":{"message":"unavailable"}}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-unselected-503",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.body, #"{"error":{"message":"unavailable"}}"#)
        XCTAssertEqual(upstreamHitCount, 1)
    }

    func testProviderTargetRetriesUpstreamCapacityErrorInHybridRoute() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(routeTargetRetryAttempts: 5)
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let statusCode = upstreamHitCount == 1 ? 429 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = statusCode == 429
                ? #"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#
                : #"{"ok":true}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-capacity-retry",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"ok":true}"#)
        XCTAssertEqual(upstreamHitCount, 2)
    }

    func testProviderTargetRetriesInBandUpstreamCapacityErrorInHybridRoute() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(routeTargetRetryAttempts: 5)
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let isCapacityError = upstreamHitCount == 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": isCapacityError ? "text/event-stream" : "application/json",
                ]
            )!
            let body = isCapacityError
                ? "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Selected model is at capacity. Please try a different model.\"}}\n\n"
                : #"{"ok":true}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-in-band-capacity-retry",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"ok":true}"#)
        XCTAssertEqual(upstreamHitCount, 2)
    }

    func testProviderTargetDoesNotRetrySuccessfulBodyMentioningCapacityError() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"output_text":"Selected model is at capacity. Please try a different model."}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-capacity-mention",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(upstreamHitCount, 1)
    }

    func testProviderTargetDoesNotRetryCompletedEnvelopeWithNullErrorAndCapacityCodeInOutput() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = """
            data: {"type":"response.completed","response":{"status":"completed","error":null,"output":[{"type":"message","content":[{"type":"output_text","text":"server_overloaded"}]}]}}

            data: [DONE]

            """
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-capacity-code-output",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains(#""type":"response.completed""#))
        XCTAssertEqual(upstreamHitCount, 1)
    }

    func testProviderTargetDoesNotRetryUpstreamCapacityErrorWhenDisabled() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    routeTargetRetryAttempts: 5,
                    retryUpstreamCapacityErrors: false
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-capacity-retry-disabled",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.body, #"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#)
        XCTAssertEqual(upstreamHitCount, 1)
    }

    func testProviderTargetRetriesReasoningGuard502InHybridRoute() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    isEnabled: true,
                    routeTargetRetryAttempts: 5
                )
            )
        )

        var upstreamHitCount = 0
        MockURLProtocol.handler = { request in
            upstreamHitCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if upstreamHitCount == 1 {
                return (
                    response,
                    Data(#"{"usage":{"output_tokens_details":{"reasoning_tokens":516}},"output_text":"blocked"}"#.utf8)
                )
            }
            return (response, Data(#"{"output_text":"ok"}"#.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-reasoning-guard-retry",
            body: #"{"model":"gpt-5.4","input":"hello"}"#,
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"output_text":"ok"}"#)
        XCTAssertEqual(upstreamHitCount, 2)
        let snapshot = service.reasoningRetryGuardSnapshot()
        XCTAssertEqual(snapshot.metrics.inspectedResponseCount, 2)
        XCTAssertEqual(snapshot.metrics.matchedResponseCount, 1)
        XCTAssertEqual(snapshot.metrics.blockedResponseCount, 1)
    }

    func testResponsesPOSTReasoning516CautiousModeAllowsNormalStreamingText() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: oauth.accountId)
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    isEnabled: true,
                    matchMode: .cautious
                )
            )
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let longDelta = String(repeating: "normal response text ", count: 20)
            let body = """
            data: {"type":"response.output_text.delta","delta":"\(longDelta)"}

            data: {"type":"response.completed","response":{"usage":{"output_tokens":180,"output_tokens_details":{"reasoning_tokens":516}}}}

            """
            return (response, Data(body.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "reasoning-516-cautious-normal",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains("normal response text"))
        let snapshot = service.reasoningRetryGuardSnapshot()
        XCTAssertEqual(snapshot.metrics.inspectedResponseCount, 1)
        XCTAssertEqual(snapshot.metrics.matchedResponseCount, 0)
        XCTAssertEqual(snapshot.metrics.blockedResponseCount, 0)
        XCTAssertEqual(snapshot.metrics.reasoning516Count, 1)
    }

    func testResponsesCompactPOSTReasoning516CautiousModeBlocksLowOutputShortFinal() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: oauth.accountId)
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    isEnabled: true,
                    matchMode: .cautious,
                    routeTargetRetryAttempts: 0
                )
            )
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"usage":{"output_tokens":12,"output_tokens_details":{"reasoning_tokens":516}},"output_text":"Done."}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "reasoning-516-cautious-short",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertTrue(response.body.contains(#""reasoning_tokens":516"#))
        XCTAssertFalse(response.body.contains("Done."))
        let snapshot = service.reasoningRetryGuardSnapshot()
        XCTAssertEqual(snapshot.metrics.inspectedResponseCount, 1)
        XCTAssertEqual(snapshot.metrics.matchedResponseCount, 1)
        XCTAssertEqual(snapshot.metrics.blockedResponseCount, 1)
        XCTAssertEqual(snapshot.logEntries.last?.kind, .interception)
        XCTAssertTrue(snapshot.logEntries.last?.message.contains("low_output_tokens") == true)
    }

    func testResponsesPOSTReasoning1034InJSONIsBlockedByDefaultGuardSet() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: oauth.accountId)
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(isEnabled: true, routeTargetRetryAttempts: 0)
            )
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"usage":{"output_tokens_details":{"reasoning_tokens":1034}},"output_text":"blocked"}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "reasoning-1034-json",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertTrue(response.body.contains(#""reasoning_tokens":1034"#))
        XCTAssertFalse(response.body.contains(#""output_text":"blocked""#))
        XCTAssertEqual(service.reasoningRetryGuardSnapshot().metrics.observedReasoningCounts[1034], 1)
        XCTAssertEqual(service.reasoningRetryGuardSnapshot().metrics.blockedResponseCount, 1)
    }

    func testResponsesPOSTReasoning516NonStreamingObserveOnlyWhenInterceptDisabled() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: oauth.accountId)
        )
        service.setReasoningRetryGuardConfiguration(
            OpenAIAccountGatewayReasoningRetryGuardConfiguration(
                settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
                    isEnabled: true,
                    interceptStreaming: true,
                    interceptNonStreaming: false
                )
            )
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"usage":{"output_tokens_details":{"reasoning_tokens":516}},"output_text":"observed"}"#.utf8)
            )
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "reasoning-516-observe-only",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains("observed"))
        let snapshot = service.reasoningRetryGuardSnapshot()
        XCTAssertEqual(snapshot.metrics.inspectedResponseCount, 1)
        XCTAssertEqual(snapshot.metrics.matchedResponseCount, 1)
        XCTAssertEqual(snapshot.metrics.blockedResponseCount, 0)
        XCTAssertEqual(snapshot.metrics.matchedNonStreamingCount, 1)
        XCTAssertEqual(snapshot.metrics.blockedNonStreamingCount, 0)
    }

    func testCompatibleProviderGatewayPreservesLongRequestContent() async throws {
        let service = self.makeService()
        let oauth = self.makeGatewayAccount(
            email: "oauth@example.com",
            accountId: "acct-oauth",
            openAIAccountId: "openai-oauth",
            accessToken: "access-oauth",
            refreshToken: "refresh-oauth",
            idToken: "id-oauth",
            planType: "plus"
        )
        service.updateState(
            accounts: [oauth],
            accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(
                .init(
                    providerID: "provider",
                    providerLabel: "Provider",
                    baseURL: "https://provider.example/v1/",
                    accountID: "acct-provider",
                    apiKey: "sk-provider",
                    modelID: "provider-model"
                )
            )
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.longRequestObserved")
        var observedBody: [String: Any]?
        MockURLProtocol.handler = { request in
            if let bodyData = URLProtocol.property(
                forKey: OpenAIAccountGatewayService.mockRequestBodyPropertyKey,
                in: request
            ) as? Data {
                let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                observedQueue.sync {
                    observedBody = body
                }
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let longText = (0..<200).map { "provider line \($0): preserve this content exactly" }.joined(separator: "\n")
        let requestBodyData = try JSONSerialization.data(
            withJSONObject: [
                "model": "gpt-5.4",
                "input": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": longText,
                            ],
                        ],
                    ],
                ],
            ],
            options: []
        )
        let response = try await self.postToGateway(
            service: service,
            stickyKey: "provider-long-request",
            body: String(data: requestBodyData, encoding: .utf8) ?? "",
            authorizationBearer: "access-oauth"
        )

        XCTAssertEqual(response.statusCode, 200)
        let input = try XCTUnwrap(observedQueue.sync { observedBody?["input"] as? [[String: Any]] })
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let forwardedText = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertEqual(forwardedText, longText)
        XCTAssertEqual(observedQueue.sync { observedBody?["model"] as? String }, "provider-model")
    }

    private func postToGateway(
        service: OpenAIAccountGatewayService,
        path: String = "/v1/responses",
        stickyKey: String,
        body: String,
        authorizationBearer: String = OpenAIAccountGatewayConfiguration.apiKey
    ) async throws -> (statusCode: Int, body: String) {
        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST \(path) HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(authorizationBearer)",
                        "chatgpt-account-id: local-placeholder",
                        "session_id: \(stickyKey)",
                        "Content-Length: \(Data(body.utf8).count)",
                        "Connection: close",
                    ],
                    body: body
                )
            )
        )

        let response = try await service.postResponsesProbeForTesting(request: request)
        return (response.statusCode, String(data: response.body, encoding: .utf8) ?? "")
    }

    private func postToRunningGateway(
        port: UInt16,
        path: String = "/v1/responses",
        stickyKey: String,
        body: String,
        headers: [String: String] = [:]
    ) async throws -> (statusCode: Int, body: String) {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!

        var lastError: Error?
        for _ in 0..<20 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(OpenAIAccountGatewayConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("local-placeholder", forHTTPHeaderField: "chatgpt-account-id")
            request.setValue(stickyKey, forHTTPHeaderField: "session_id")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

            do {
                let (data, response) = try await session.data(for: request)
                let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
                return (httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        throw try XCTUnwrap(lastError)
    }

    private func getFromRunningGateway(
        port: UInt16,
        path: String,
        authorization: String = OpenAIAccountGatewayConfiguration.apiKey
    ) async throws -> (statusCode: Int, body: String) {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!

        var lastError: Error?
        for _ in 0..<20 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await session.data(for: request)
                let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
                return (httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        throw try XCTUnwrap(lastError)
    }

    private func rawRequest(lines: [String], body: String = "") -> Data {
        var text = lines.joined(separator: "\r\n")
        text += "\r\n\r\n"
        text += body
        return Data(text.utf8)
    }

    func testModelRoutingKeepsOfficialRequestAndCredentialsSeparateFromSelectedProvider() async throws {
        let upstream = try ScriptedLocalHTTPResponseServer { _ in
            .respond(statusCode: 200, contentType: "application/json", body: Data(#"{"id":"ok"}"#.utf8))
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream, targetModel: "vendor-first")
        defer { service.stop() }
        let nativeBody = "{\"model\":\"gpt-native\", \"previous_response_id\":\"resp-original\",\"input\":[],\"service_tier\":\"fast\"}"
        let headers = ["authorization": "Bearer native-access", "chatgpt-account-id": "native-remote", "originator": "codex-desktop", "x-custom": "preserved"]
        let native = try await self.postToRunningGateway(port: port, path: "/v1/responses?test=one", stickyKey: "native", body: nativeBody, headers: headers)
        XCTAssertEqual(native.statusCode, 200)
        let received = try XCTUnwrap(upstream.requests.first)
        XCTAssertEqual(received.body, Data(nativeBody.utf8))
        XCTAssertEqual(received.path, "/v1/responses?test=one")
        XCTAssertEqual(received.headers["authorization"], "Bearer native-access")
        XCTAssertEqual(received.headers["chatgpt-account-id"], "native-remote")
        XCTAssertEqual(received.headers["originator"], "codex-desktop")
        XCTAssertEqual(received.headers["x-custom"], "preserved")
        let alias = try await self.postToRunningGateway(port: port, stickyKey: "alias", body: #"{"model":"codexbar","input":[]}"#, headers: headers)
        XCTAssertEqual(alias.statusCode, 200)
        let routed = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(routed.headers["authorization"], "Bearer vendor-key")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: routed.body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "vendor-first")
    }

    func testModelRoutingOfficialCompactAndModelsPreserveBodiesQueriesAndErrorsWithoutReplay() async throws {
        let errorBody = Data(#"{"error":{"code":"rate_limit_exceeded","message":"wait"}}"#.utf8)
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .respond(statusCode: 429, contentType: "application/json", body: errorBody) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let body = #"{"model":"gpt-native","previous_response_id":"resp-old","input":[{"type":"reasoning","encrypted_content":"keep"}]}"#
        let response = try await self.postToRunningGateway(port: port, path: "/v1/responses/compact?mode=full", stickyKey: "compact", body: body,
            headers: ["authorization": "Bearer native-access", "chatgpt-account-id": "native-remote"])
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.body, String(decoding: errorBody, as: UTF8.self))
        XCTAssertEqual(upstream.requests.count, 1)
        XCTAssertEqual(upstream.requests[0].path, "/v1/responses/compact?mode=full")
        XCTAssertEqual(upstream.requests[0].body, Data(body.utf8))
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models?client_version=0.167.0")!)
        request.setValue("Bearer native-access", forHTTPHeaderField: "authorization")
        let (data, raw) = try await session.data(for: request)
        XCTAssertEqual((raw as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(data, errorBody)
        XCTAssertEqual(upstream.requests.last?.path, "/models?client_version=0.167.0")
    }

    func testModelRoutingSelectedOpenAIAccountDoesNotReplaceOfficialCredentials() async throws {
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .respond(statusCode: 200, contentType: "application/json", body: Data("{}".utf8)) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let native = self.routingAccount(id: "native", token: "native-access")
        let selected = self.routingAccount(id: "selected", token: "selected-access")
        service.updateState(accounts: [native, selected], accountUsageMode: .switchAccount,
            routeTarget: .openAIAccount(accountID: selected.accountId))
        service.setModelRoutingEnabled(true, openAIModelID: "gpt-selected")
        let headers = ["authorization": "Bearer native-access", "chatgpt-account-id": "native-remote"]
        _ = try await self.postToRunningGateway(port: port, stickyKey: "alias", body: #"{"model":"codexbar","input":[]}"#, headers: headers)
        XCTAssertEqual(upstream.requests.last?.headers["authorization"], "Bearer selected-access")
        let routed = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(upstream.requests.last).body) as? [String: Any])
        XCTAssertEqual(routed["model"] as? String, "gpt-selected")
        let nativeBody = #"{"model":"gpt-native","input":[]}"#
        _ = try await self.postToRunningGateway(port: port, stickyKey: "native", body: nativeBody, headers: headers)
        XCTAssertEqual(upstream.requests.last?.headers["authorization"], "Bearer native-access")
        XCTAssertEqual(upstream.requests.last?.body, Data(nativeBody.utf8))
    }

    func testModelRoutingDeclinesWebSocketImmediatelyWithoutContactingUpstream() async throws {
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .respond(statusCode: 500, contentType: "application/json", body: Data()) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        // Wait for the listener using the same bounded connection-start retry as POST tests.
        _ = try await self.postToRunningGateway(port: port, stickyKey: "warmup", body: #"{"model":"codexbar","input":[]}"#)
        let before = upstream.requests.count
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.setValue("Bearer native-access", forHTTPHeaderField: "authorization")
        request.setValue("websocket", forHTTPHeaderField: "upgrade")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 426)
        XCTAssertEqual(upstream.requests.count, before)
    }

    func testModelRoutingOfficialWaitsForHeadersBeyondLegacyRequestBudget() async throws {
        let upstream = try ScriptedLocalHTTPResponseServer { _ in
            .delayed(delay: 0.3, statusCode: 200, contentType: "text/event-stream", body: Data("data: first\n\ndata: done\n\n".utf8))
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let result = try await self.postToRunningGateway(port: port, stickyKey: "delay", body: #"{"model":"gpt-native","input":[]}"#,
            headers: ["authorization": "Bearer native-access"])
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, "data: first\n\ndata: done\n\n")
        XCTAssertEqual(upstream.requests.count, 1)
    }

    func testModelRoutingOfficialStreamOutlivesLegacyTotalBudgetAndForwardsPartialSSE() async throws {
        let chunks = ["data: {\"partial\":", "true}\n\n", "data: [DONE]\n\n"].map { Data($0.utf8) }
        let upstream = try ScriptedLocalHTTPResponseServer { _ in
            .timedStream(interval: 0.15, chunks: chunks)
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let result = try await self.postToRunningGateway(port: port, stickyKey: "long", body: #"{"model":"gpt-native","input":[]}"#,
            headers: ["authorization": "Bearer native-access"])
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, chunks.map { String(decoding: $0, as: UTF8.self) }.joined())
        XCTAssertEqual(upstream.requests.count, 1)
    }

    func testModelRoutingClientCancellationCancelsUpstreamBeforeHeaders() async throws {
        let received = expectation(description: "upstream received request")
        let disconnected = expectation(description: "upstream cancelled")
        let upstream = try ScriptedLocalHTTPResponseServer { _ in
            received.fulfill()
            return .stall(onDisconnect: { disconnected.fulfill() })
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let warmup = try await self.postToRunningGateway(port: port, stickyKey: "warmup", body: "{}", headers: ["authorization": "Bearer rejected"])
        XCTAssertEqual(warmup.statusCode, 401)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"gpt-native","input":[]}"#.utf8)
        request.setValue("Bearer native-access", forHTTPHeaderField: "authorization")
        let session = URLSession(configuration: .ephemeral)
        let work = Task { try await session.data(for: request) }
        await fulfillment(of: [received], timeout: 2)
        work.cancel()
        _ = try? await work.value
        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertEqual(upstream.requests.count, 1)
    }

    func testModelRoutingOfficialStallReturnsTimeoutWithoutReplay() async throws {
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .stall(onDisconnect: {}) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream, officialRequestTimeout: 0.15)
        defer { service.stop() }
        let response = try await self.postToRunningGateway(port: port, stickyKey: "stall", body: #"{"model":"gpt-native","input":[]}"#,
            headers: ["authorization": "Bearer native-access"])
        XCTAssertEqual(response.statusCode, 504)
        XCTAssertEqual(upstream.requests.count, 1)
    }

    func testModelRoutingHotSwitchKeepsInFlightProviderSnapshot() async throws {
        let received = expectation(description: "first request received")
        var first = true
        let upstream = try ScriptedLocalHTTPResponseServer { request in
            if first { first = false; received.fulfill() }
            return .delayed(delay: 0.15, statusCode: 200, contentType: "application/json", body: request.body)
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream, targetModel: "first-model")
        defer { service.stop() }
        let original = Task { try await self.postToRunningGateway(port: port, stickyKey: "first", body: #"{"model":"codexbar","input":[]}"#) }
        await fulfillment(of: [received], timeout: 2)
        service.updateModelRoutingState(accounts: [self.routingAccount(id: "native", token: "native-access")], accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(.init(providerID: "vendor", providerLabel: "Vendor", baseURL: upstream.url(path: "/provider").absoluteString,
                accountID: "second-account", apiKey: "second-key", modelID: "second-model", thirdPartyModelProvider: nil)),
            enabled: true, openAIModelID: "gpt-selected")
        let second = try await self.postToRunningGateway(port: port, stickyKey: "second", body: #"{"model":"codexbar","input":[]}"#)
        let firstResponse = try await original.value
        XCTAssertTrue(firstResponse.body.contains("first-model"))
        XCTAssertTrue(second.body.contains("second-model"))
        XCTAssertEqual(upstream.requests.first?.headers["authorization"], "Bearer vendor-key")
        XCTAssertEqual(upstream.requests.last?.headers["authorization"], "Bearer second-key")
    }

    func testCapacityRetriesOfficialAndSelectedProviderWithoutChangingRequest() async throws {
        for model in ["gpt-native", "codexbar"] {
            var attempts = 0
            var waits: [TimeInterval] = []
            let upstream = try ScriptedLocalHTTPResponseServer { _ in
                attempts += 1
                if attempts == 1 { return .respond(statusCode: 503, contentType: "application/json", body: Data(#"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#.utf8)) }
                return .respond(statusCode: 200, contentType: "application/json", body: Data(#"{"id":"ok"}"#.utf8))
            }
            let (service, port) = self.startModelRoutingGateway(upstream: upstream, retryDelaySleeper: { waits.append($0) })
            let response = try await self.postToRunningGateway(port: port, stickyKey: "capacity", body: "{\"model\":\"\(model)\",\"input\":[]}", headers: ["authorization": "Bearer native-access"])
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(upstream.requests.count, 2)
            XCTAssertEqual(upstream.requests.first, upstream.requests.last)
            XCTAssertEqual(waits, [5])
            service.stop(); upstream.stop()
        }
    }

    func testCapacityExhaustionReturnsTheFifthErrorAndEndsSSE() async throws {
        let error = Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Selected model is at capacity. Please try a different model.\"}}}\n\n".utf8)
        var waits: [TimeInterval] = []
        let upstream = try ScriptedLocalHTTPResponseServer { _ in
            .stream(statusCode: 200, contentType: "text/event-stream", chunks: [Data(error.prefix(19)), Data(error.dropFirst(19)), Data("data: [DONE]\n\n".utf8)])
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream, retryDelaySleeper: { waits.append($0) })
        defer { service.stop() }
        let response = try await self.postToRunningGateway(port: port, stickyKey: "exhausted", body: #"{"model":"codexbar","input":[]}"#)
        XCTAssertEqual(upstream.requests.count, 5)
        XCTAssertEqual(waits, [5, 10, 20, 30])
        XCTAssertTrue(response.body.hasPrefix(String(decoding: error, as: UTF8.self)))
        XCTAssertEqual(response.body.components(separatedBy: "response.failed").count - 1, 1)
    }

    func testCapacityAfterToolOutputDoesNotReplayAndQuotedTextIsNotAnError() async throws {
        let business = "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"name\":\"test\"}}\n\n"
        let failure = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Selected model is at capacity. Please try a different model.\"}}}\n\n"
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .stream(statusCode: 200, contentType: "text/event-stream", chunks: [Data(business.utf8), Data(failure.utf8)]) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let response = try await self.postToRunningGateway(port: port, stickyKey: "tool", body: #"{"model":"gpt-native","input":[]}"#, headers: ["authorization": "Bearer native-access"])
        XCTAssertEqual(upstream.requests.count, 1)
        XCTAssertEqual(response.body, business + failure)
    }

    func testCapacityRejectionCancelsStalledUpstreamBeforeRetrying() async throws {
        let disconnected = expectation(description: "capacity upstream closed")
        let error = Data("data: {\"type\":\"error\",\"message\":\"Selected model is at capacity. Please try a different model.\"}\n\n".utf8)
        var count = 0
        let upstream = try ScriptedLocalHTTPResponseServer { _ in
            count += 1
            if count == 1 { return .capacityThenStall(body: error, onDisconnect: { disconnected.fulfill() }) }
            return .respond(statusCode: 200, contentType: "application/json", body: Data(#"{"id":"ok"}"#.utf8))
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let response = try await self.postToRunningGateway(port: port, stickyKey: "stalled-capacity", body: #"{"model":"gpt-native","input":[]}"#, headers: ["authorization": "Bearer native-access"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(upstream.requests.count, 2)
        await fulfillment(of: [disconnected], timeout: 2)
    }

    func testClientCancellationInterruptsCapacityBackoff() async throws {
        let waiting = expectation(description: "capacity backoff started")
        let cancelled = expectation(description: "capacity backoff cancelled")
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .respond(statusCode: 503, contentType: "application/json", body: Data(#"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#.utf8)) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream, retryDelaySleeper: { _ in
            waiting.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { cancelled.fulfill(); throw error }
        })
        defer { service.stop() }
        let request = Task { try await self.postToRunningGateway(port: port, stickyKey: "cancel-backoff", body: #"{"model":"codexbar","input":[]}"#) }
        await fulfillment(of: [waiting], timeout: 2)
        request.cancel()
        _ = try? await request.value
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(upstream.requests.count, 1)
    }

    func testCapacityRetriesKeepTheInitialTargetAcrossHotSwitch() async throws {
        var count = 0
        let upstream = try ScriptedLocalHTTPResponseServer { request in
            count += 1
            if count == 1 { return .respond(statusCode: 503, contentType: "application/json", body: Data(#"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#.utf8)) }
            return .respond(statusCode: 200, contentType: "application/json", body: request.body)
        }
        defer { upstream.stop() }
        var gateway: OpenAIAccountGatewayService?
        let (service, port) = self.startModelRoutingGateway(upstream: upstream, targetModel: "first-model", retryDelaySleeper: { _ in
            gateway?.updateModelRoutingState(accounts: [self.routingAccount(id: "native", token: "native-access")], accountUsageMode: .hybridProvider,
                routeTarget: .compatibleProvider(.init(providerID: "vendor", providerLabel: "Vendor", baseURL: upstream.url(path: "/provider").absoluteString,
                    accountID: "second", apiKey: "second-key", modelID: "second-model", thirdPartyModelProvider: nil)), enabled: true, openAIModelID: "gpt-selected")
        })
        gateway = service
        defer { service.stop() }
        let response = try await self.postToRunningGateway(port: port, stickyKey: "snapshot", body: #"{"model":"codexbar","input":[]}"#)
        XCTAssertTrue(response.body.contains("first-model"))
        XCTAssertEqual(upstream.requests[0], upstream.requests[1])
        let later = try await self.postToRunningGateway(port: port, stickyKey: "later", body: #"{"model":"codexbar","input":[]}"#)
        XCTAssertTrue(later.body.contains("second-model"))
        XCTAssertEqual(upstream.requests.last?.headers["authorization"], "Bearer second-key")
    }

    func testCapacityCompactRetriesButModelDiscoveryDoesNot() async throws {
        let error = Data(#"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#.utf8)
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .respond(statusCode: 503, contentType: "application/json", body: error) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        let compact = try await self.postToRunningGateway(port: port, path: "/v1/responses/compact", stickyKey: "compact-capacity", body: #"{"model":"gpt-native","input":[]}"#, headers: ["authorization": "Bearer native-access"])
        XCTAssertEqual(compact.statusCode, 503)
        XCTAssertEqual(upstream.requests.count, 5)
        let models = try await self.getFromRunningGateway(port: port, path: "/models", authorization: "native-access")
        XCTAssertEqual(models.statusCode, 503)
        XCTAssertEqual(upstream.requests.count, 6)
    }

    func testProtocolFallbackAlsoSharesTheFiveRequestBudget() async throws {
        let error = Data(#"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#.utf8)
        let upstream = try ScriptedLocalHTTPResponseServer { request in
            .respond(statusCode: request.path.hasSuffix("/responses") ? 404 : 503, contentType: "application/json", body: error)
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        service.updateModelRoutingState(accounts: [self.routingAccount(id: "native", token: "native-access")], accountUsageMode: .hybridProvider,
            routeTarget: .compatibleProvider(.init(providerID: "vendor", providerLabel: "Vendor", baseURL: upstream.url(path: "/v1").absoluteString,
                accountID: "vendor-account", apiKey: "vendor-key", modelID: "deepseek-v4.1-flash", thirdPartyModelProvider: .openCode)), enabled: true, openAIModelID: "gpt-selected")
        let response = try await self.postToRunningGateway(port: port, stickyKey: "fallback-capacity", body: #"{"model":"codexbar","input":[]}"#)
        XCTAssertEqual(upstream.requests.count, 5)
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertTrue(response.body.contains("Selected model is at capacity"))
    }

    func testRemoteCompactionCapacityIsNotReplacedByASuccessfulFallback() async throws {
        let error = Data(#"{"error":{"message":"Selected model is at capacity. Please try a different model."}}"#.utf8)
        let upstream = try ScriptedLocalHTTPResponseServer { _ in .respond(statusCode: 503, contentType: "application/json", body: error) }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        service.updateModelRoutingState(accounts: [self.routingAccount(id: "native", token: "native-access")], accountUsageMode: .hybridProvider,
            routeTarget: .compatibleProvider(.init(providerID: "vendor", providerLabel: "Vendor", baseURL: upstream.url(path: "/v1").absoluteString,
                accountID: "vendor-account", apiKey: "vendor-key", modelID: "flash", thirdPartyModelProvider: .deepSeek)), enabled: true, openAIModelID: "gpt-selected")
        let response = try await self.postToRunningGateway(port: port, stickyKey: "remote-compact", body: #"{"model":"codexbar","input":[{"type":"compaction_trigger"}]}"#)
        XCTAssertEqual(upstream.requests.count, 5)
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.body, String(decoding: error, as: UTF8.self))
    }

    func testNativeContextRecordsAreValidOnBothOfficialAndProviderWirePaths() async throws {
        let upstream = try ScriptedLocalHTTPResponseServer { request in
            .respond(statusCode: 200, contentType: "application/json", body: request.body)
        }
        defer { upstream.stop() }
        let (service, port) = self.startModelRoutingGateway(upstream: upstream)
        defer { service.stop() }
        for model in ["gpt-native", "codexbar"] {
            let input: [[String: Any]] = [
                ["type": "function_call", "id": "fc_exec", "call_id": "call_exec", "name": "exec_command", "arguments": "{}"],
                ["type": "function_call_output", "id": "fco_page", "call_id": "", "name": "codex_apps_open_page", "namespace": "agent", "output": "page snapshot"],
                ["type": "function_call_output", "call_id": "call_exec", "output": "tool result"],
            ]
            let body = String(decoding: try JSONSerialization.data(withJSONObject: ["model": model, "input": input]), as: UTF8.self)
            let response = try await self.postToRunningGateway(port: port, stickyKey: model, body: body, headers: ["authorization": "Bearer native-access"])
            XCTAssertEqual(response.statusCode, 200)
            let root = try JSONSerialization.jsonObject(with: XCTUnwrap(upstream.requests.last).body) as! [String: Any]
            let forwarded = root["input"] as! [[String: Any]]
            let calls = forwarded.filter { ($0["type"] as? String) == "function_call" }
            let results = forwarded.filter { ($0["type"] as? String) == "function_call_output" }
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0]["call_id"] as? String, calls[0]["call_id"] as? String)
            XCTAssertTrue(String(decoding: upstream.requests.last!.body, as: UTF8.self).contains("page snapshot"))
            XCTAssertEqual(forwarded.last?["type"] as? String, "message")
        }
    }

    private func routingAccount(id: String, token: String) -> TokenAccount {
        self.makeGatewayAccount(email: id + "@example.test", accountId: id, openAIAccountId: id + "-remote", accessToken: token,
            refreshToken: "test-refresh", idToken: "test-id", planType: "plus")
    }

    private func startModelRoutingGateway(upstream: ScriptedLocalHTTPResponseServer, targetModel: String = "vendor-model", officialRequestTimeout: TimeInterval = 1,
        retryDelaySleeper: @escaping (TimeInterval) async throws -> Void = { _ in }) -> (OpenAIAccountGatewayService, UInt16) {
        let ready = DispatchSemaphore(value: 0)
        var port: UInt16 = 0
        let service = OpenAIAccountGatewayService(
            upstreamTransportConfiguration: self.makeTransportConfiguration(requestTimeout: 0.1, resourceTimeout: 0.2),
            runtimeConfiguration: .init(host: "127.0.0.1", port: 0,
                upstreamResponsesURL: upstream.url(path: "/v1/responses"), upstreamResponsesCompactURL: upstream.url(path: "/v1/responses/compact"),
                upstreamModelsURL: upstream.url(path: "/models")),
            officialTransportConfiguration: self.makeTransportConfiguration(requestTimeout: officialRequestTimeout, resourceTimeout: 3),
            retryDelaySleeper: retryDelaySleeper, retryJitterMultiplier: { 1 },
            onListenerReady: { port = $0; ready.signal() }
        )
        service.updateState(accounts: [self.routingAccount(id: "native", token: "native-access")], accountUsageMode: .switchAccount,
            routeTarget: .compatibleProvider(.init(providerID: "vendor", providerLabel: "Vendor", baseURL: upstream.url(path: "/provider").absoluteString,
                accountID: "vendor-account", apiKey: "vendor-key", modelID: targetModel, thirdPartyModelProvider: nil)))
        service.setModelRoutingEnabled(true, openAIModelID: "gpt-selected")
        service.startIfNeeded()
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        return (service, port)
    }

    private func makeService(
        upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .live,
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .init(
            host: "127.0.0.1",
            port: 1456,
            upstreamResponsesURL: URL(string: "https://example.invalid/v1/responses")!,
            upstreamResponsesCompactURL: URL(string: "https://example.invalid/v1/responses/compact")!
        ),
        routeJournalStore: OpenAIGatewayRouteJournalStoring = OpenAIGatewayRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        ),
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = { _ in },
        retryDelaySleeper: @escaping (TimeInterval) async throws -> Void = { _ in },
        retryJitterMultiplier: @escaping () -> Double = { 1 }
    ) -> OpenAIAccountGatewayService {
        OpenAIAccountGatewayService(
            urlSession: self.makeMockSession(),
            upstreamTransportConfiguration: upstreamTransportConfiguration,
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: routeJournalStore,
            diagnosticsReporter: diagnosticsReporter,
            retryDelaySleeper: retryDelaySleeper,
            retryJitterMultiplier: retryJitterMultiplier
        )
    }

    private func makeWebSocketUpgradeRequest(stickyKey: String) -> Data {
        self.rawRequest(
            lines: [
                "GET /v1/responses HTTP/1.1",
                "Host: 127.0.0.1:1456",
                "Connection: Upgrade",
                "Upgrade: websocket",
                "Sec-WebSocket-Version: 13",
                "Sec-WebSocket-Key: dGVzdC1jb2RleGJhcg==",
                "session_id: \(stickyKey)",
            ]
        )
    }

    private func makeGatewayAccount(
        email: String,
        accountId: String,
        openAIAccountId: String,
        accessToken: String,
        refreshToken: String,
        idToken: String,
        planType: String,
        primaryUsedPercent: Double = 10,
        secondaryUsedPercent: Double = 10,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            openAIAccountId: openAIAccountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt
        )
    }

    private func makeTransportConfiguration(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        webSocketReadyBudget: TimeInterval = 8,
        waitsForConnectivity: Bool = false,
        proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode = .loopbackProxySafe,
        snapshot: OpenAIAccountGatewaySystemProxySnapshot? = nil
    ) -> OpenAIAccountGatewayUpstreamTransportConfiguration {
        OpenAIAccountGatewayUpstreamTransportConfiguration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            webSocketReadyBudget: webSocketReadyBudget,
            waitsForConnectivity: waitsForConnectivity,
            proxyResolutionMode: proxyResolutionMode,
            proxySnapshotProvider: { snapshot }
        )
    }

    private func makeProxySnapshot(
        httpHost: String? = nil,
        httpPort: Int? = nil,
        httpsHost: String? = nil,
        httpsPort: Int? = nil,
        socksHost: String? = nil,
        socksPort: Int? = nil
    ) -> OpenAIAccountGatewaySystemProxySnapshot? {
        let http = self.makeProxyEndpoint(kind: "http", host: httpHost, port: httpPort)
        let https = self.makeProxyEndpoint(kind: "https", host: httpsHost, port: httpsPort)
        let socks = self.makeProxyEndpoint(kind: "socks", host: socksHost, port: socksPort)
        if http == nil, https == nil, socks == nil {
            return nil
        }
        return OpenAIAccountGatewaySystemProxySnapshot(http: http, https: https, socks: socks)
    }

    private func makeProxyEndpoint(
        kind: String,
        host: String?,
        port: Int?
    ) -> OpenAIAccountGatewaySystemProxyEndpoint? {
        guard let host, host.isEmpty == false,
              let port, port > 0 else {
            return nil
        }
        return OpenAIAccountGatewaySystemProxyEndpoint(kind: kind, host: host, port: port)
    }

    private func assertNormalizedBody(
        _ body: [String: Any],
        expectedText: String,
        expectedServiceTier: String
    ) {
        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        XCTAssertEqual(body["service_tier"] as? String, expectedServiceTier)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])

        let tools = body["tools"] as? [Any]
        XCTAssertEqual(tools?.count, 0)

        let includes = body["include"] as? [String]
        XCTAssertEqual(includes, ["reasoning.encrypted_content"])

        let text = (((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, expectedText)
    }

    private func assertCompactBody(
        _ body: [String: Any],
        expectedText: String,
        expectedPreviousResponseID: String? = nil
    ) {
        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        XCTAssertEqual(body["instructions"] as? String, "")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        if let expectedPreviousResponseID {
            XCTAssertEqual(body["previous_response_id"] as? String, expectedPreviousResponseID)
        } else {
            XCTAssertNil(body["previous_response_id"])
        }

        let text = (((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, expectedText)
    }
}

private struct RecordedHTTPRequest: Equatable {
    let path: String
    let body: Data
}

private final class LocalHTTPResponseServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPResponseServer.queue")
    private let responseData: Data
    private let contentType: String

    private(set) var port: UInt16 = 0
    private var recordedRequests: [RecordedHTTPRequest] = []

    var requests: [RecordedHTTPRequest] {
        self.queue.sync { self.recordedRequests }
    }

    init(
        statusCode: Int,
        contentType: String,
        responseBody: String
    ) throws {
        self.responseData = Data(responseBody.utf8)
        self.contentType = contentType
        self.listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        self.listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, statusCode: statusCode)
        }
        self.listener.start(queue: self.queue)
        ready.wait()
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        self.listener.cancel()
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(self.port)\(path)")!
    }

    private func handle(connection: NWConnection, statusCode: Int) {
        connection.start(queue: self.queue)
        self.receive(on: connection, buffer: Data(), statusCode: statusCode)
    }

    private func receive(
        on connection: NWConnection,
        buffer: Data,
        statusCode: Int
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var combined = buffer
            if let data {
                combined.append(data)
            }

            if let request = self.parseRequest(from: combined) {
                self.recordedRequests.append(request)
                let header = [
                    "HTTP/1.1 \(statusCode) OK",
                    "Content-Type: \(self.contentType)",
                    "Content-Length: \(self.responseData.count)",
                    "Connection: close",
                    "",
                    "",
                ].joined(separator: "\r\n")
                connection.send(
                    content: Data(header.utf8) + self.responseData,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: combined, statusCode: statusCode)
        }
    }

    private func parseRequest(from data: Data) -> RecordedHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }

        let bodyOffset = headerRange.upperBound
        guard data.count >= bodyOffset + contentLength else {
            return nil
        }

        return RecordedHTTPRequest(
            path: String(requestParts[1]),
            body: data.subdata(in: bodyOffset..<(bodyOffset + contentLength))
        )
    }
}

private final class RejectingHTTPProxyServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RejectingHTTPProxyServer.queue")

    private(set) var port: UInt16 = 0
    private var acceptedConnections = 0

    var connectionCount: Int {
        self.queue.sync { self.acceptedConnections }
    }

    init() throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        self.listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptedConnections += 1
                connection.start(queue: self?.queue ?? .main)
                connection.cancel()
            }
        }
        self.listener.start(queue: self.queue)
        ready.wait()
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        self.listener.cancel()
    }
}

private struct ScriptedHTTPRequest: Equatable {
    let path: String
    let headers: [String: String]
    let body: Data
}

private enum ScriptedHTTPResponseAction {
    case stall(onDisconnect: () -> Void)
    case capacityThenStall(body: Data, onDisconnect: () -> Void)
    case delayed(delay: TimeInterval, statusCode: Int, contentType: String, body: Data)
    case timedStream(interval: TimeInterval, chunks: [Data])
    case respond(statusCode: Int, contentType: String, body: Data)
    case stream(statusCode: Int, contentType: String, chunks: [Data])
    case closeAfterHeaders(statusCode: Int, contentType: String, declaredContentLength: Int)
}

private final class ScriptedLocalHTTPResponseServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScriptedLocalHTTPResponseServer.queue")
    private let handler: (ScriptedHTTPRequest) -> ScriptedHTTPResponseAction

    private(set) var port: UInt16 = 0
    private var recordedRequests: [ScriptedHTTPRequest] = []

    var requests: [ScriptedHTTPRequest] {
        self.queue.sync { self.recordedRequests }
    }

    init(handler: @escaping (ScriptedHTTPRequest) -> ScriptedHTTPResponseAction) throws {
        self.handler = handler
        self.listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        self.listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        self.listener.start(queue: self.queue)
        ready.wait()
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        self.listener.cancel()
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(self.port)\(path)")!
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var combined = buffer
            if let data {
                combined.append(data)
            }

            if let request = self.parseRequest(from: combined) {
                self.recordedRequests.append(request)
                self.send(self.handler(request), on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: combined)
        }
    }

    private func send(_ action: ScriptedHTTPResponseAction, on connection: NWConnection) {
        let payload: Data
        switch action {
        case .capacityThenStall(let body, let onDisconnect):
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: headers + body, completion: .contentProcessed { _ in
                self.send(.stall(onDisconnect: onDisconnect), on: connection)
            })
            return
        case .stall(let onDisconnect):
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { onDisconnect(); connection.cancel() }
            }
            return
        case .delayed(let delay, let status, let contentType, let body):
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.send(.respond(statusCode: status, contentType: contentType, body: body), on: connection)
            }
            return
        case .timedStream(let interval, let chunks):
            let head = self.httpResponseData(statusCode: 200, contentType: "text/event-stream", contentLength: chunks.reduce(0) { $0 + $1.count }, body: Data())
            connection.send(content: head, completion: .contentProcessed { _ in
                for (index, chunk) in chunks.enumerated() {
                    self.queue.asyncAfter(deadline: .now() + interval * Double(index + 1)) {
                        connection.send(content: chunk, completion: .contentProcessed { _ in
                            if index == chunks.count - 1 { connection.cancel() }
                        })
                    }
                }
            })
            return
        case .respond(let statusCode, let contentType, let body):
            payload = self.httpResponseData(
                statusCode: statusCode,
                contentType: contentType,
                contentLength: body.count,
                body: body
            )
        case .stream(let statusCode, let contentType, let chunks):
            let head = self.httpResponseData(
                statusCode: statusCode,
                contentType: contentType,
                contentLength: chunks.reduce(0) { $0 + $1.count },
                body: Data()
            )
            connection.send(content: head, completion: .contentProcessed { _ in
                self.sendStreamChunks(chunks, on: connection)
            })
            return
        case .closeAfterHeaders(let statusCode, let contentType, let declaredContentLength):
            payload = self.httpResponseData(
                statusCode: statusCode,
                contentType: contentType,
                contentLength: declaredContentLength,
                body: Data()
            )
        }

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStreamChunks(_ chunks: [Data], on connection: NWConnection) {
        guard let first = chunks.first else {
            connection.cancel()
            return
        }

        let remaining = Array(chunks.dropFirst())
        connection.send(content: first, completion: .contentProcessed { _ in
            if remaining.isEmpty {
                connection.cancel()
            } else {
                self.sendStreamChunks(remaining, on: connection)
            }
        })
    }

    private func httpResponseData(
        statusCode: Int,
        contentType: String,
        contentLength: Int,
        body: Data
    ) -> Data {
        let head = [
            "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }

    private func parseRequest(from data: Data) -> ScriptedHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        let bodyOffset = headerRange.upperBound
        guard data.count >= bodyOffset + contentLength else {
            return nil
        }

        return ScriptedHTTPRequest(
            path: String(requestParts[1]),
            headers: headers,
            body: data.subdata(in: bodyOffset..<(bodyOffset + contentLength))
        )
    }
}
