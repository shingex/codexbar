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
        XCTAssertEqual(transportDiagnostic.target, "openAIAggregate")
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
            routeJournalStore: OpenAIAggregateRouteJournalStore(
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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
            routeJournalStore: OpenAIAggregateRouteJournalStore(
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

    func testResponsesPOSTRecordsRouteForStickySession() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)

        let account = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        _ = try await self.postToGateway(
            service: service,
            stickyKey: "thread-aggregate-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        let routeHistory = routeJournalStore.routeHistory()
        XCTAssertEqual(routeHistory.count, 1)
        XCTAssertEqual(routeHistory.first?.threadID, "thread-aggregate-1")
        XCTAssertEqual(routeHistory.first?.accountID, "acct-alpha")
    }

    func testStickyBindingsSnapshotAndClearOnlyAffectInMemoryBinding() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        _ = try await self.postToGateway(
            service: service,
            stickyKey: "thread-sticky-clear",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(service.stickyBindingsSnapshot().map(\.threadID), ["thread-sticky-clear"])
        XCTAssertTrue(service.clearStickyBinding(threadID: "thread-sticky-clear"))
        XCTAssertTrue(service.stickyBindingsSnapshot().isEmpty)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.threadID), ["thread-sticky-clear"])
    }

    func testResponsesProbeGETBuildsWebSocketHandshakeWhenHeadersAndAccountExist() async throws {
        let service = self.makeService()

        let account = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let response = service.webSocketUpgradeProbeForTesting(request: request)

        XCTAssertEqual(response.statusCode, 101)
        XCTAssertEqual(
            response.headers["Sec-WebSocket-Accept"],
            "jbsNjU5oGfarrt3XvjT/Dv7jeRU="
        )
        XCTAssertEqual(response.headers["Upgrade"], "websocket")
        XCTAssertEqual(response.headers["Connection"], "Upgrade")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testWebSocketReadyBudgetIsInjectableAndObservable() async throws {
        let service = self.makeService(
            upstreamTransportConfiguration: .init(
                requestTimeout: 11,
                resourceTimeout: 13,
                webSocketReadyBudget: 7,
                waitsForConnectivity: false
            )
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
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        var observedBudgets: [TimeInterval] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
            account,
            requestedProtocol,
            readyBudget in
            observedBudgets.append(readyBudget)
            XCTAssertEqual(account.accountId, "acct-alpha")
            XCTAssertNil(requestedProtocol)
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-alpha")
        XCTAssertEqual(observedBudgets, [7])
    }

    func testResponsesWebSocketTransportFailureDoesNotFailoverAcrossAccounts() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-transport-failure"))
        )

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account,
                _,
                _ in
                attemptedAccountIDs.append(account.accountId)
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
            }
            XCTFail("expected websocket transport failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            XCTAssertEqual(failure.failoverDisposition, .doNotFailover)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha"])
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesWebSocketProtocolFailureDoesNotFailoverWithoutStickyBinding() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-protocol-no-sticky-binding"))
        )

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account, _, _ in
                attemptedAccountIDs.append(account.accountId)
                throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.cannotParseResponse))
            }
            XCTFail("expected websocket protocol failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            XCTAssertEqual(failure.failoverDisposition, .doNotFailover)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha"])
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesWebSocketTransportFailureRecoversOnceInStickyContext() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-transport-sticky-context"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        var attemptedAccountIDs: [String] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(
            request: request,
            bindOnSuccess: true
        ) { account, _, _ in
            attemptedAccountIDs.append(account.accountId)
            if account.accountId == "acct-alpha" {
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.networkConnectionLost))
            }
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-beta")
        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
    }

    func testResponsesWebSocketProtocolFailureRecoversOnceInStickyContext() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-protocol-sticky-context"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        var attemptedAccountIDs: [String] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(
            request: request,
            bindOnSuccess: true
        ) { account, _, _ in
            attemptedAccountIDs.append(account.accountId)
            if account.accountId == "acct-alpha" {
                throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.cannotParseResponse))
            }
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-beta")
        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
    }

    func testResponsesWebSocketStickyContextRecoveryIsBoundedToOneAlternateCandidate() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let tertiary = self.makeGatewayAccount(
            email: "gamma@example.com",
            accountId: "acct-gamma",
            openAIAccountId: "openai-gamma",
            accessToken: "token-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma",
            planType: "free",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )
        service.updateState(
            accounts: [primary, secondary, tertiary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-bounded-sticky-context"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account, _, _ in
                attemptedAccountIDs.append(account.accountId)
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
            }
            XCTFail("expected bounded websocket transport failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            XCTAssertEqual(failure.failoverDisposition, .doNotFailover)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
    }

    func testResponsesWebSocketStickyContextRecoveryStopsAfterAlternateCandidateAccountStatusFailure() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let tertiary = self.makeGatewayAccount(
            email: "gamma@example.com",
            accountId: "acct-gamma",
            openAIAccountId: "openai-gamma",
            accessToken: "token-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma",
            planType: "free",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )
        service.updateState(
            accounts: [primary, secondary, tertiary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-bounded-sticky-context-account-status"))
        )

        let seeded = service.webSocketUpgradeProbeForTesting(request: request)
        XCTAssertEqual(seeded.statusCode, 101)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        var attemptedAccountIDs: [String] = []
        do {
            _ = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account, _, _ in
                attemptedAccountIDs.append(account.accountId)
                if account.accountId == "acct-alpha" {
                    throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
                }
                throw OpenAIAccountGatewayUpstreamFailure.accountStatus(429)
            }
            XCTFail("expected bounded websocket sticky-context failure")
        } catch let failure as OpenAIAccountGatewayUpstreamFailure {
            if case .accountStatus(let statusCode) = failure {
                XCTAssertEqual(statusCode, 429)
            } else {
                XCTFail("expected account status failure, got \(failure)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
    }

    func testResponsesWebSocketAccountStatusesStillFailOver() async throws {
        for statusCode in [401, 403, 429] {
            let service = self.makeService()
            let primary = self.makeGatewayAccount(
                email: "alpha@example.com",
                accountId: "acct-alpha",
                openAIAccountId: "openai-alpha",
                accessToken: "token-alpha",
                refreshToken: "refresh-alpha",
                idToken: "id-alpha",
                planType: "plus"
            )
            let secondary = self.makeGatewayAccount(
                email: "beta@example.com",
                accountId: "acct-beta",
                openAIAccountId: "openai-beta",
                accessToken: "token-beta",
                refreshToken: "refresh-beta",
                idToken: "id-beta",
                planType: "free"
            )
            service.updateState(
                accounts: [primary, secondary],
                quotaSortSettings: .init(),
                accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
            )

            let request = try XCTUnwrap(
                service.parseRequestForTesting(
                    from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-account-\(statusCode)")
                )
            )

            var attemptedAccountIDs: [String] = []
            let selection = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
                account,
                _,
                _ in
                attemptedAccountIDs.append(account.accountId)
                if account.accountId == "acct-alpha" {
                    throw OpenAIAccountGatewayUpstreamFailure.accountStatus(statusCode)
                }
                return nil
            }

            XCTAssertEqual(selection.accountID, "acct-beta", "status \(statusCode) should fail over")
            XCTAssertEqual(
                attemptedAccountIDs,
                ["acct-alpha", "acct-beta"],
                "status \(statusCode) should try the next account"
            )
        }
    }

    func testResponsesWebSocketRetainsExisting5xxFailoverSemantics() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-5xx"))
        )

        var attemptedAccountIDs: [String] = []
        let selection = try await service.establishResponsesWebSocketProbeForTesting(request: request) {
            account,
            _,
            _ in
            attemptedAccountIDs.append(account.accountId)
            if account.accountId == "acct-alpha" {
                throw OpenAIAccountGatewayUpstreamFailure.upstreamStatus(502)
            }
            return nil
        }

        XCTAssertEqual(selection.accountID, "acct-beta")
        XCTAssertEqual(attemptedAccountIDs, ["acct-alpha", "acct-beta"])
    }

    func testResponsesPOSTPrefersEarlierResetWhenWeightedQuotaTies() async throws {
        let service = self.makeService()

        let laterResetPlus = TokenAccount(
            email: "plus@example.com",
            accountId: "acct-plus",
            openAIAccountId: "openai-plus",
            accessToken: "token-plus",
            refreshToken: "refresh-plus",
            idToken: "id-plus",
            planType: "plus",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90,
            primaryResetAt: Date(timeIntervalSinceNow: 2 * 60 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        )
        let earlierResetFree = TokenAccount(
            email: "free@example.com",
            accountId: "acct-free",
            openAIAccountId: "openai-free",
            accessToken: "token-free",
            refreshToken: "refresh-free",
            idToken: "id-free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 60 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 6 * 24 * 60 * 60)
        )

        service.updateState(
            accounts: [laterResetPlus, earlierResetFree],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.tieBreakObserved")
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []

        MockURLProtocol.handler = { request in
            observedQueue.sync {
                forwardedAuthorizations.append(request.value(forHTTPHeaderField: "authorization") ?? "")
                forwardedAccountIDs.append(request.value(forHTTPHeaderField: "chatgpt-account-id") ?? "")
            }

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
            stickyKey: "session-reset-tie",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: ok\n\n")
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-free"]
        )
        XCTAssertEqual(
            observedQueue.sync { forwardedAccountIDs },
            ["openai-free"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-free")
    }

    func testResponsesPOSTUsesProWeightInsteadOfFreeFallback() async throws {
        let service = self.makeService()

        let free = self.makeGatewayAccount(
            email: "free@example.com",
            accountId: "acct-free",
            openAIAccountId: "openai-free",
            accessToken: "token-free",
            refreshToken: "refresh-free",
            idToken: "id-free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let pro = self.makeGatewayAccount(
            email: "pro@example.com",
            accountId: "acct-pro",
            openAIAccountId: "openai-pro",
            accessToken: "token-pro",
            refreshToken: "refresh-pro",
            idToken: "id-pro",
            planType: "pro",
            primaryUsedPercent: 92,
            secondaryUsedPercent: 92
        )

        service.updateState(
            accounts: [free, pro],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.proObserved")
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []

        MockURLProtocol.handler = { request in
            observedQueue.sync {
                forwardedAuthorizations.append(request.value(forHTTPHeaderField: "authorization") ?? "")
                forwardedAccountIDs.append(request.value(forHTTPHeaderField: "chatgpt-account-id") ?? "")
            }

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
            stickyKey: "session-pro-default",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-pro"]
        )
        XCTAssertEqual(
            observedQueue.sync { forwardedAccountIDs },
            ["openai-pro"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-pro")
    }

    func testResponsesPOSTClampsCustomProRatioToMinimumWhenRankingCandidates() async throws {
        let service = self.makeService()

        let free = self.makeGatewayAccount(
            email: "free@example.com",
            accountId: "acct-free",
            openAIAccountId: "openai-free",
            accessToken: "token-free",
            refreshToken: "refresh-free",
            idToken: "id-free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let pro = self.makeGatewayAccount(
            email: "pro@example.com",
            accountId: "acct-pro",
            openAIAccountId: "openai-pro",
            accessToken: "token-pro",
            refreshToken: "refresh-pro",
            idToken: "id-pro",
            planType: "pro",
            primaryUsedPercent: 79,
            secondaryUsedPercent: 79
        )

        service.updateState(
            accounts: [free, pro],
            quotaSortSettings: .init(
                plusRelativeWeight: 1,
                proRelativeToPlusMultiplier: 1.0,
                teamRelativeToPlusMultiplier: 2
            ),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.proCustomObserved")
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []

        MockURLProtocol.handler = { request in
            observedQueue.sync {
                forwardedAuthorizations.append(request.value(forHTTPHeaderField: "authorization") ?? "")
                forwardedAccountIDs.append(request.value(forHTTPHeaderField: "chatgpt-account-id") ?? "")
            }

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
            stickyKey: "session-pro-custom",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-pro"]
        )
        XCTAssertEqual(
            observedQueue.sync { forwardedAccountIDs },
            ["openai-pro"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-pro")
    }

    func testResponsesPOSTFailoverRebindsStickySessionAndRewritesHeaders() async throws {
        let service = self.makeService()

        let primary = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        let secondary = TokenAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )

        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.observed")
        var forwardedURLs: [String] = []
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []
        var forwardedOriginators: [String] = []
        var forwardedBodies: [[String: Any]] = []

        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            let accountID = request.value(forHTTPHeaderField: "chatgpt-account-id") ?? ""
            let originator = request.value(forHTTPHeaderField: "originator") ?? ""
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
                forwardedURLs.append(url)
                forwardedAuthorizations.append(authorization)
                forwardedAccountIDs.append(accountID)
                forwardedOriginators.append(originator)
                forwardedBodies.append(body)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                statusCode = 429
                payload = "retry alpha"
            case "Bearer token-beta":
                statusCode = 200
                payload = "data: ok\n\n"
            default:
                statusCode = 500
                payload = "unexpected"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"service_tier":"priority","max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"again"}]}],"service_tier":"priority","max_output_tokens":64,"temperature":0.2,"top_p":0.5}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(firstResponse.body, "data: ok\n\n")
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.body, "data: ok\n\n")

        let observed = observedQueue.sync {
            (
                forwardedURLs,
                forwardedAuthorizations,
                forwardedAccountIDs,
                forwardedOriginators,
                forwardedBodies
            )
        }

        XCTAssertEqual(
            observed.0,
            [
                "https://example.invalid/v1/responses",
                "https://example.invalid/v1/responses",
                "https://example.invalid/v1/responses",
            ]
        )
        XCTAssertEqual(
            observed.1,
            ["Bearer token-alpha", "Bearer token-beta", "Bearer token-beta"]
        )
        XCTAssertEqual(
            observed.2,
            ["openai-alpha", "openai-beta", "openai-beta"]
        )
        XCTAssertEqual(
            observed.3,
            ["codexbar", "codexbar", "codexbar"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")

        self.assertNormalizedBody(observed.4[0], expectedText: "hello", expectedServiceTier: "priority")
        self.assertNormalizedBody(observed.4[1], expectedText: "hello", expectedServiceTier: "priority")
        self.assertNormalizedBody(observed.4[2], expectedText: "again", expectedServiceTier: "priority")
    }

    func testResponsesPOSTTransportFailureDoesNotFailoverAcrossAccounts() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.transportObserved")
        var forwardedAuthorizations: [String] = []

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.timedOut)
            case "Bearer token-beta":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data("data: unexpected beta\n\n".utf8))
            default:
                throw URLError(.badServerResponse)
            }
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-transport-failure",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-alpha"]
        )
        XCTAssertNil(service.currentRoutedAccountIDForTesting())
    }

    func testResponsesPOSTTransportFailureRecoversOnceInStickyContext() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let seeded = try await self.postToGateway(
            service: service,
            stickyKey: "post-transport-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.transportStickyObserved")
        var secondAttemptAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                secondAttemptAuthorizations.append(authorization)
            }

            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.networkConnectionLost)
            case "Bearer token-beta":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data("data: recovered beta\n\n".utf8))
            default:
                throw URLError(.badServerResponse)
            }
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-transport-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: recovered beta\n\n")
        XCTAssertEqual(
            observedQueue.sync { secondAttemptAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
    }

    func testResponsesPOSTProtocolFailureRecoversOnceInStickyContext() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let seeded = try await self.postToGateway(
            service: service,
            stickyKey: "post-protocol-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().count, 1)

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.protocolStickyObserved")
        var secondAttemptAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                secondAttemptAuthorizations.append(authorization)
            }

            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.badServerResponse)
            case "Bearer token-beta":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data("data: recovered beta protocol\n\n".utf8))
            default:
                throw URLError(.cannotParseResponse)
            }
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-protocol-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: recovered beta protocol\n\n")
        XCTAssertEqual(
            observedQueue.sync { secondAttemptAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
    }

    func testResponsesPOSTStickyContextRecoveryIsBoundedToOneAlternateCandidate() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let tertiary = self.makeGatewayAccount(
            email: "gamma@example.com",
            accountId: "acct-gamma",
            openAIAccountId: "openai-gamma",
            accessToken: "token-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma",
            planType: "free",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )
        service.updateState(
            accounts: [primary, secondary, tertiary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let seeded = try await self.postToGateway(
            service: service,
            stickyKey: "post-bounded-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.boundedStickyObserved")
        var attemptedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                attemptedAuthorizations.append(authorization)
            }
            throw URLError(.timedOut)
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-bounded-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(
            observedQueue.sync { attemptedAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
    }

    func testResponsesPOSTStickyContextRecoveryStopsAfterAlternateCandidateAccountStatusFailure() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let tertiary = self.makeGatewayAccount(
            email: "gamma@example.com",
            accountId: "acct-gamma",
            openAIAccountId: "openai-gamma",
            accessToken: "token-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma",
            planType: "free",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )
        service.updateState(
            accounts: [primary, secondary, tertiary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let seeded = try await self.postToGateway(
            service: service,
            stickyKey: "post-sticky-account-status",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.stickyAccountStatusObserved")
        var attemptedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                attemptedAuthorizations.append(authorization)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.networkConnectionLost)
            case "Bearer token-beta":
                statusCode = 429
                payload = "retry beta"
            default:
                statusCode = 200
                payload = "unexpected gamma"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data(payload.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-sticky-account-status",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.body, "retry beta")
        XCTAssertEqual(
            observedQueue.sync { attemptedAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
    }

    func testResponsesCompactPOSTStickyTransportFailureUsesSharedRecoveryLogic() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":"alpha"}"#.utf8))
        }

        let seeded = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "compact-transport-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed compact"}]}],"service_tier":"priority","store":true}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.compactStickyObserved")
        var secondAttemptAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                secondAttemptAuthorizations.append(authorization)
            }

            switch authorization {
            case "Bearer token-alpha":
                throw URLError(.networkConnectionLost)
            case "Bearer token-beta":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"ok":"beta"}"#.utf8))
            default:
                throw URLError(.badServerResponse)
            }
        }

        let response = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "compact-transport-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry compact"}]}],"service_tier":"priority","store":true}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"ok":"beta"}"#)
        XCTAssertEqual(
            observedQueue.sync { secondAttemptAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
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

        let routeJournalStore = OpenAIAggregateRouteJournalStore(
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let routeJournalStore = OpenAIAggregateRouteJournalStore(
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let routeJournalStore = OpenAIAggregateRouteJournalStore(
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

    func testResponsesPOSTProductionPathRecoversFromPreByteDisconnectInStickyContext() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let upstreamServer = try ScriptedLocalHTTPResponseServer { request in
            let authorization = request.headers["authorization"] ?? ""
            let bodyText = String(data: request.body, encoding: .utf8) ?? ""

            switch authorization {
            case "Bearer token-alpha":
                if bodyText.contains("\"seed\"") {
                    return .respond(
                        statusCode: 200,
                        contentType: "text/event-stream",
                        body: Data("data: ok\n\n".utf8)
                    )
                }
                return .closeAfterHeaders(
                    statusCode: 200,
                    contentType: "text/event-stream",
                    declaredContentLength: 12
                )
            case "Bearer token-beta":
                return .respond(
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: Data("data: recovered prod\n\n".utf8)
                )
            default:
                return .respond(
                    statusCode: 500,
                    contentType: "text/plain",
                    body: Data("unexpected".utf8)
                )
            }
        }
        defer { upstreamServer.stop() }

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

        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings(),
            accountUsageMode: CodexBarOpenAIAccountUsageMode.aggregateGateway,
            routeTarget: .openAIAggregate
        )
        service.startIfNeeded()

        let seeded = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "prod-prebyte-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(seeded.body, "data: ok\n\n")
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")

        let response = try await self.postToRunningGateway(
            port: gatewayPort,
            stickyKey: "prod-prebyte-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "data: recovered prod\n\n")
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha", "acct-beta"])
        XCTAssertEqual(
            upstreamServer.requests.map { $0.headers["authorization"] ?? "" },
            ["Bearer token-alpha", "Bearer token-alpha", "Bearer token-beta"]
        )
    }

    func testResponsesPOSTStickyContextDoesNotRecoverOnNonPreByteConsumptionFailure() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

        let seeded = try await self.postToGateway(
            service: service,
            stickyKey: "post-consume-sticky",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"seed"}]}]}
            """
        )
        XCTAssertEqual(seeded.statusCode, 200)
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.consumeFailureObserved")
        var attemptedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                attemptedAuthorizations.append(authorization)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: would-have-streamed\n\n".utf8))
        }

        let retryBody = #"{"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"retry"}]}]}"#
        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenAIAccountGatewayConfiguration.apiKey)",
                        "chatgpt-account-id: local-placeholder",
                        "session_id: post-consume-sticky",
                        "Content-Length: \(Data(retryBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: retryBody
                )
            )
        )

        let response = await service.postResponsesConsumeFailureProbeForTesting(
            request: request,
            failure: URLError(.networkConnectionLost)
        )

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(
            String(data: response.body, encoding: .utf8),
            #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
        )
        XCTAssertEqual(
            observedQueue.sync { attemptedAuthorizations },
            ["Bearer token-alpha"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
    }

    func testResponsesPOSTAccountStatusesStillFailOver() async throws {
        for statusCode in [401, 403, 429] {
            let service = self.makeService()
            let primary = self.makeGatewayAccount(
                email: "alpha@example.com",
                accountId: "acct-alpha",
                openAIAccountId: "openai-alpha",
                accessToken: "token-alpha",
                refreshToken: "refresh-alpha",
                idToken: "id-alpha",
                planType: "plus"
            )
            let secondary = self.makeGatewayAccount(
                email: "beta@example.com",
                accountId: "acct-beta",
                openAIAccountId: "openai-beta",
                accessToken: "token-beta",
                refreshToken: "refresh-beta",
                idToken: "id-beta",
                planType: "free"
            )
            service.updateState(
                accounts: [primary, secondary],
                quotaSortSettings: .init(),
                accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
            )

            let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.accountStatus\(statusCode)")
            var forwardedAuthorizations: [String] = []
            MockURLProtocol.handler = { request in
                let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
                observedQueue.sync {
                    forwardedAuthorizations.append(authorization)
                }

                let status: Int
                let payload: String
                switch authorization {
                case "Bearer token-alpha":
                    status = statusCode
                    payload = "retry alpha"
                case "Bearer token-beta":
                    status = 200
                    payload = "data: ok\n\n"
                default:
                    status = 500
                    payload = "unexpected"
                }

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (response, Data(payload.utf8))
            }

            let response = try await self.postToGateway(
                service: service,
                stickyKey: "post-account-\(statusCode)",
                body: """
                {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
                """
            )

            XCTAssertEqual(response.statusCode, 200, "status \(statusCode) should fail over")
            XCTAssertEqual(
                observedQueue.sync { forwardedAuthorizations },
                ["Bearer token-alpha", "Bearer token-beta"],
                "status \(statusCode) should try the next account"
            )
            XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        }
    }

    func testResponsesPOST429WithoutRetryAfterDoesNotBlockSingleAccountForFutureCandidates() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "solo@example.com",
            accountId: "acct-solo",
            openAIAccountId: "openai-solo",
            accessToken: "token-solo",
            refreshToken: "refresh-solo",
            idToken: "id-solo",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.retryable429Observed")
        var forwardedAuthorizations: [String] = []
        var attempt = 0
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
                attempt += 1
            }

            let statusCode = observedQueue.sync { attempt == 1 ? 429 : 200 }
            let payload = statusCode == 429 ? "retry solo" : "data: ok\n\n"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-429-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"first"}]}]}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-429-2",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"second"}]}]}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 429)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-solo", "Bearer token-solo"]
        )
    }

    func testResponsesPOST429WithRetryAfterStillBlocksSingleAccountForFutureCandidates() async throws {
        let service = self.makeService()
        let account = self.makeGatewayAccount(
            email: "solo@example.com",
            accountId: "acct-solo",
            openAIAccountId: "openai-solo",
            accessToken: "token-solo",
            refreshToken: "refresh-solo",
            idToken: "id-solo",
            planType: "plus"
        )
        service.updateState(
            accounts: [account],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.retryAfterObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/event-stream",
                    "Retry-After": "120",
                ]
            )!
            return (response, Data("retry later".utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-retry-after-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"first"}]}]}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "single-retry-after-2",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"second"}]}]}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 429)
        XCTAssertEqual(secondResponse.statusCode, 503)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-solo"]
        )
    }

    func testResponsesPOSTRetainsExisting5xxFailoverSemantics() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus"
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.5xxObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                statusCode = 502
                payload = "retry alpha"
            case "Bearer token-beta":
                statusCode = 200
                payload = "data: ok\n\n"
            default:
                statusCode = 500
                payload = "unexpected"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "post-5xx",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
    }

    func testResponsesPOSTInBandUsageLimitErrorFailsOverAndBlocksExhaustedAccount() async throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 60 * 60)
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.inBandUsageLimitObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            observedQueue.sync {
                forwardedAuthorizations.append(authorization)
            }

            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                payload = """
                data: {\"type\":\"response.created\"}

                data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"usage_limit_exceeded\",\"message\":\"You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Apr 22nd, 2026 3:50 PM.\"}}}

                """
            case "Bearer token-beta":
                payload = "data: ok\\n\\n"
            default:
                payload = "data: unexpected\\n\\n"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            stickyKey: "post-inband-usage-limit-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            stickyKey: "post-inband-usage-limit-2",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"again"}]}]}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertTrue(firstResponse.body.contains("data: ok"))
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertTrue(secondResponse.body.contains("data: ok"))
        XCTAssertEqual(
            observedQueue.sync { forwardedAuthorizations },
            ["Bearer token-alpha", "Bearer token-beta", "Bearer token-beta"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
    }

    func testResponsesWebSocketRecoversFromInBandUsageLimitBeforeForwardingAnyFrames() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 60 * 60)
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "plus",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 0
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-inband-usage-limit-recovery")
            )
        )

        let result = try await service.recoverableResponsesWebSocketPreviewProbeForTesting(
            request: request,
            messagesByAccountID: [
                "acct-alpha": [
                    .string(#"{"type":"response.created"}"#),
                    .string(#"{"type":"response.failed","response":{"status":"failed","error":{"code":"usage_limit_exceeded","message":"You've hit your usage limit."}}}"#),
                ],
                "acct-beta": [
                    .string(#"{"type":"response.created"}"#),
                    .string(#"{"type":"response.output_text.delta","delta":"B"}"#),
                ],
            ],
            bindOnSuccess: true
        )

        XCTAssertEqual(result.accountID, "acct-beta")
        XCTAssertEqual(
            result.previewedTexts,
            [
                #"{"type":"response.created"}"#,
                #"{"type":"response.output_text.delta","delta":"B"}"#,
            ]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-beta"])
    }

    func testWebSocketInBandUsageLimitSignalBlocksAccountForFutureCandidates() throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 60 * 60)
        )
        let secondary = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "plus"
        )
        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let noted = service.noteInBandAccountSignalForTesting(
            #"{"type":"error","code":"usage_limit_exceeded","message":"You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Apr 22nd, 2026 3:50 PM."}"#,
            accountID: "acct-alpha",
            stickyKey: "ws-usage-limit"
        )
        XCTAssertTrue(noted)

        let request = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.makeWebSocketUpgradeRequest(stickyKey: "ws-usage-limit-next")
            )
        )
        let response = service.webSocketUpgradeProbeForTesting(request: request)

        XCTAssertEqual(response.statusCode, 101)
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")
    }

    func testInBandUsageLimitSignalWithoutRetryAtFallsBackToDefaultRuntimeBlockWhenQuotaAvailable() throws {
        let service = self.makeService()
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 60 * 60)
        )
        service.updateState(
            accounts: [primary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let noted = service.noteInBandAccountSignalForTesting(
            #"{"type":"error","code":"usage_limit_exceeded","message":"You've hit your usage limit."}"#,
            accountID: "acct-alpha",
            stickyKey: nil
        )
        XCTAssertTrue(noted)

        let blockedUntil = try XCTUnwrap(service.runtimeBlockedUntilForTesting(accountID: "acct-alpha"))
        let remaining = blockedUntil.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 8 * 60)
        XCTAssertLessThan(remaining, 12 * 60)
    }

    func testInBandUsageLimitSignalWithoutRetryAtStillUsesResetAtWhenQuotaExhausted() throws {
        let service = self.makeService()
        let resetAt = Date(timeIntervalSinceNow: 5 * 60 * 60)
        let primary = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: resetAt
        )
        service.updateState(
            accounts: [primary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let noted = service.noteInBandAccountSignalForTesting(
            #"{"type":"error","code":"usage_limit_exceeded","message":"You've hit your usage limit."}"#,
            accountID: "acct-alpha",
            stickyKey: nil
        )
        XCTAssertTrue(noted)

        let blockedUntil = try XCTUnwrap(service.runtimeBlockedUntilForTesting(accountID: "acct-alpha"))
        XCTAssertEqual(blockedUntil.timeIntervalSince1970, resetAt.timeIntervalSince1970, accuracy: 2)
    }

    func testResponsesCompactPOSTUsesCompactUpstreamAndRetainsFailoverSemantics() async throws {
        let service = self.makeService()

        let primary = TokenAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        let secondary = TokenAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )

        service.updateState(
            accounts: [primary, secondary],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.compactObserved")
        var forwardedURLs: [String] = []
        var forwardedAuthorizations: [String] = []
        var forwardedAccountIDs: [String] = []
        var forwardedOriginators: [String] = []
        var forwardedBodies: [[String: Any]] = []

        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
            let accountID = request.value(forHTTPHeaderField: "chatgpt-account-id") ?? ""
            let originator = request.value(forHTTPHeaderField: "originator") ?? ""
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
                forwardedURLs.append(url)
                forwardedAuthorizations.append(authorization)
                forwardedAccountIDs.append(accountID)
                forwardedOriginators.append(originator)
                forwardedBodies.append(body)
            }

            let statusCode: Int
            let payload: String
            switch authorization {
            case "Bearer token-alpha":
                statusCode = 429
                payload = "retry alpha compact"
            case "Bearer token-beta":
                statusCode = 200
                payload = #"{"ok":true}"#
            default:
                statusCode = 500
                payload = "unexpected"
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }

        let firstResponse = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "compact-session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact hello"}]}],"previous_response_id":"resp_prev_compact","service_tier":"priority","prompt_cache_key":"compact-cache-seed","metadata":{"drop":true},"reasoning":{"effort":"high"},"store":true,"max_output_tokens":128,"temperature":0.7,"top_p":0.9,"stream":false,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )
        let secondResponse = try await self.postToGateway(
            service: service,
            path: "/v1/responses/compact",
            stickyKey: "compact-session-1",
            body: """
            {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"compact again"}]}],"previous_response_id":"resp_next_compact","service_tier":"priority","prompt_cache_key":"compact-cache-next","metadata":{"drop":true},"store":true,"max_output_tokens":64,"temperature":0.2,"top_p":0.5,"include":["reasoning.encrypted_content"],"tools":[{"type":"noop"}],"parallel_tool_calls":true}
            """
        )

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(firstResponse.body, #"{"ok":true}"#)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.body, #"{"ok":true}"#)

        let observed = observedQueue.sync {
            (
                forwardedURLs,
                forwardedAuthorizations,
                forwardedAccountIDs,
                forwardedOriginators,
                forwardedBodies
            )
        }

        XCTAssertEqual(
            observed.0,
            [
                "https://example.invalid/v1/responses/compact",
                "https://example.invalid/v1/responses/compact",
                "https://example.invalid/v1/responses/compact",
            ]
        )
        XCTAssertEqual(
            observed.1,
            ["Bearer token-alpha", "Bearer token-beta", "Bearer token-beta"]
        )
        XCTAssertEqual(
            observed.2,
            ["openai-alpha", "openai-beta", "openai-beta"]
        )
        XCTAssertEqual(
            observed.3,
            ["codexbar", "codexbar", "codexbar"]
        )
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-beta")

        self.assertCompactBody(
            observed.4[0],
            expectedText: "compact hello",
            expectedPreviousResponseID: "resp_prev_compact"
        )
        self.assertCompactBody(
            observed.4[1],
            expectedText: "compact hello",
            expectedPreviousResponseID: "resp_prev_compact"
        )
        self.assertCompactBody(
            observed.4[2],
            expectedText: "compact again",
            expectedPreviousResponseID: "resp_next_compact"
        )
        XCTAssertEqual(observed.4[0]["prompt_cache_key"] as? String, "compact-cache-seed")
        XCTAssertEqual(observed.4[0]["service_tier"] as? String, "priority")
        XCTAssertEqual((observed.4[0]["metadata"] as? [String: Any])?["drop"] as? Bool, true)
        XCTAssertEqual((observed.4[0]["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual(observed.4[0]["store"] as? Bool, true)
        XCTAssertEqual(observed.4[0]["stream"] as? Bool, false)
        XCTAssertEqual((observed.4[0]["tools"] as? [[String: Any]])?.first?["type"] as? String, "noop")
        XCTAssertEqual(observed.4[0]["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(observed.4[0]["max_output_tokens"] as? Int, 128)
        XCTAssertEqual(observed.4[0]["temperature"] as? Double, 0.7)
        XCTAssertEqual(observed.4[0]["top_p"] as? Double, 0.9)
        XCTAssertEqual(observed.4[1]["prompt_cache_key"] as? String, "compact-cache-seed")
        XCTAssertEqual(observed.4[2]["prompt_cache_key"] as? String, "compact-cache-next")
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

    func testResponsesCompactPOSTUsesPromptCacheKeyAsStickyFallback() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let alpha = self.makeGatewayAccount(
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
        let beta = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 95,
            secondaryUsedPercent: 95
        )
        service.updateState(
            accounts: [alpha, beta],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.compactPromptCacheObserved")
        var forwardedAuthorizations: [String] = []
        var forwardedAccepts: [String] = []
        var forwardedVersions: [String] = []
        var forwardedBetas: [String] = []
        var forwardedSessionIDs: [String] = []
        var forwardedConversationIDs: [String] = []
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
                forwardedAuthorizations.append(request.value(forHTTPHeaderField: "authorization") ?? "")
                forwardedAccepts.append(request.value(forHTTPHeaderField: "accept") ?? "")
                forwardedVersions.append(request.value(forHTTPHeaderField: "version") ?? "")
                forwardedBetas.append(request.value(forHTTPHeaderField: "OpenAI-Beta") ?? "")
                forwardedSessionIDs.append(request.value(forHTTPHeaderField: "session_id") ?? "")
                forwardedConversationIDs.append(request.value(forHTTPHeaderField: "conversation_id") ?? "")
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

        let compactBody = """
        {"model":"gpt-5.4","input":[{"role":"user","content":[{"type":"input_text","text":"sticky compact"}]}],"prompt_cache_key":"compact-sticky-seed","store":true,"stream":false}
        """
        let firstRequest = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses/compact HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenAIAccountGatewayConfiguration.apiKey)",
                        "chatgpt-account-id: local-placeholder",
                        "Content-Length: \(Data(compactBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: compactBody
                )
            )
        )
        let firstResponse = try await service.postResponsesProbeForTesting(request: firstRequest)
        XCTAssertEqual(firstResponse.statusCode, 200)

        let alphaAfterUsageIncrease = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "free",
            primaryUsedPercent: 95,
            secondaryUsedPercent: 95
        )
        let betaAfterUsageDrop = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "pro",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        service.updateState(
            accounts: [alphaAfterUsageIncrease, betaAfterUsageDrop],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let secondRequest = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses/compact HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenAIAccountGatewayConfiguration.apiKey)",
                        "chatgpt-account-id: local-placeholder",
                        "Content-Length: \(Data(compactBody.utf8).count)",
                        "Connection: close",
                    ],
                    body: compactBody
                )
            )
        )
        let secondResponse = try await service.postResponsesProbeForTesting(request: secondRequest)
        XCTAssertEqual(secondResponse.statusCode, 200)

        let observed = observedQueue.sync {
            (
                forwardedAuthorizations,
                forwardedAccepts,
                forwardedVersions,
                forwardedBetas,
                forwardedSessionIDs,
                forwardedConversationIDs,
                forwardedBodies
            )
        }
        XCTAssertEqual(observed.0, ["Bearer token-alpha", "Bearer token-alpha"])
        XCTAssertEqual(observed.1, ["application/json", "application/json"])
        XCTAssertEqual(observed.2, ["0.125.0", "0.125.0"])
        XCTAssertEqual(observed.3, ["responses=experimental", "responses=experimental"])
        XCTAssertEqual(observed.4, ["compact-sticky-seed", "compact-sticky-seed"])
        XCTAssertEqual(observed.5, ["compact-sticky-seed", "compact-sticky-seed"])
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.threadID), ["compact-sticky-seed"])
        XCTAssertEqual(routeJournalStore.routeHistory().map(\.accountID), ["acct-alpha"])
        XCTAssertEqual(observed.6.count, 2)
        for body in observed.6 {
            self.assertCompactBody(body, expectedText: "sticky compact")
        }
    }

    func testResponsesPOSTDoesNotUsePromptCacheKeyAsStickyFallback() async throws {
        let routeJournalStore = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        )
        let service = self.makeService(routeJournalStore: routeJournalStore)
        let alpha = self.makeGatewayAccount(
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
        let beta = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "free",
            primaryUsedPercent: 95,
            secondaryUsedPercent: 95
        )
        service.updateState(
            accounts: [alpha, beta],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.responsesPromptCacheObserved")
        var forwardedAuthorizations: [String] = []
        MockURLProtocol.handler = { request in
            observedQueue.sync {
                forwardedAuthorizations.append(request.value(forHTTPHeaderField: "authorization") ?? "")
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let body = #"{"model":"gpt-5.4","input":"hello","prompt_cache_key":"responses-sticky-seed","store":true}"#
        let firstRequest = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenAIAccountGatewayConfiguration.apiKey)",
                        "chatgpt-account-id: local-placeholder",
                        "Content-Length: \(Data(body.utf8).count)",
                        "Connection: close",
                    ],
                    body: body
                )
            )
        )
        let firstResponse = try await service.postResponsesProbeForTesting(request: firstRequest)
        XCTAssertEqual(firstResponse.statusCode, 200)

        let alphaAfterUsageIncrease = self.makeGatewayAccount(
            email: "alpha@example.com",
            accountId: "acct-alpha",
            openAIAccountId: "openai-alpha",
            accessToken: "token-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha",
            planType: "free",
            primaryUsedPercent: 95,
            secondaryUsedPercent: 95
        )
        let betaAfterUsageDrop = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "pro",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        service.updateState(
            accounts: [alphaAfterUsageIncrease, betaAfterUsageDrop],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let secondRequest = try XCTUnwrap(
            service.parseRequestForTesting(
                from: self.rawRequest(
                    lines: [
                        "POST /v1/responses HTTP/1.1",
                        "Host: 127.0.0.1:1456",
                        "Content-Type: application/json",
                        "Authorization: Bearer \(OpenAIAccountGatewayConfiguration.apiKey)",
                        "chatgpt-account-id: local-placeholder",
                        "Content-Length: \(Data(body.utf8).count)",
                        "Connection: close",
                    ],
                    body: body
                )
            )
        )
        let secondResponse = try await service.postResponsesProbeForTesting(request: secondRequest)
        XCTAssertEqual(secondResponse.statusCode, 200)

        XCTAssertEqual(observedQueue.sync { forwardedAuthorizations }, ["Bearer token-alpha", "Bearer token-beta"])
        XCTAssertTrue(routeJournalStore.routeHistory().isEmpty)
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
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
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

    func testResponsesPOSTForwardsInvalidEncryptedContentWithoutScrubRetry() async throws {
        let service = self.makeService()
        let alpha = self.makeGatewayAccount(
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
        let beta = self.makeGatewayAccount(
            email: "beta@example.com",
            accountId: "acct-beta",
            openAIAccountId: "openai-beta",
            accessToken: "token-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )
        service.updateState(
            accounts: [alpha, beta],
            quotaSortSettings: .init(),
            accountUsageMode: .aggregateGateway,
            routeTarget: .openAIAggregate
        )

        let observedQueue = DispatchQueue(label: "OpenAIAccountGatewayServiceTests.invalidEncryptedObserved")
        var forwardedAuthorizations: [String] = []
        var forwardedBodies: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "authorization") ?? ""
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
                forwardedAuthorizations.append(authorization)
                forwardedBodies.append(body)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(
                    #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_encrypted_content","message":"The encrypted content 当前进度 could not be verified."},"status":400}"#.utf8
                )
            )
        }

        let response = try await self.postToGateway(
            service: service,
            stickyKey: "invalid-encrypted-session",
            body: #"{"model":"gpt-5.4","input":[{"type":"reasoning","encrypted_content":"当前进度"},{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"include":["reasoning.encrypted_content"],"prompt_cache_key":"invalid-encrypted-session"}"#
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(response.body.contains("invalid_encrypted_content"))
        let observed = observedQueue.sync { (forwardedAuthorizations, forwardedBodies) }
        XCTAssertEqual(observed.0, ["Bearer token-alpha"])
        XCTAssertEqual((observed.1.first?["input"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(observed.1.first?["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(service.currentRoutedAccountIDForTesting(), "acct-alpha")
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
            quotaSortSettings: .init(),
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
            quotaSortSettings: .init(),
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
            quotaSortSettings: .init(),
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
            quotaSortSettings: .init(),
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
            quotaSortSettings: .init(),
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
            quotaSortSettings: .init(),
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
            quotaSortSettings: .init(),
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
        body: String
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

    private func makeService(
        upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .live,
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .init(
            host: "127.0.0.1",
            port: 1456,
            upstreamResponsesURL: URL(string: "https://example.invalid/v1/responses")!,
            upstreamResponsesCompactURL: URL(string: "https://example.invalid/v1/responses/compact")!
        ),
        routeJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(
            fileURL: CodexPaths.openAIGatewayRouteJournalURL
        ),
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = { _ in }
    ) -> OpenAIAccountGatewayService {
        OpenAIAccountGatewayService(
            urlSession: self.makeMockSession(),
            upstreamTransportConfiguration: upstreamTransportConfiguration,
            runtimeConfiguration: runtimeConfiguration,
            routeJournalStore: routeJournalStore,
            diagnosticsReporter: diagnosticsReporter
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
