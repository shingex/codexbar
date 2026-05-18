import CFNetwork
import CryptoKit
import Foundation
import Network

extension Notification.Name {
    static let openAIAccountGatewayDidRouteAccount = Notification.Name(
        "lzl.codexbar.openai-gateway.did-route-account"
    )
}

protocol OpenAIAccountGatewayControlling: AnyObject {
    func startIfNeeded()
    func stop()
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        routeTarget: OpenAIAccountGatewayRouteTarget
    )
    func currentRoutedAccountID() -> String?
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot]
    @discardableResult func clearStickyBinding(threadID: String) -> Bool
}

enum OpenAIAccountGatewayConfiguration {
    static let listenHost = "0.0.0.0"
    static let clientHost = "127.0.0.1"
    static let port: UInt16 = 1456
    static let apiKey = "codexbar-local-gateway"
    static let originator = "codexbar"
    static let defaultCodexCLIVersion = "0.125.0"
    static let reasoningIncludeMarker = "reasoning.encrypted_content"
    static let upstreamResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let upstreamResponsesCompactURL = URL(string: "https://chatgpt.com/backend-api/codex/responses/compact")!

    static var baseURLString: String {
        "http://\(self.clientHost):\(self.port)/v1"
    }
}

enum OpenAIAccountGatewayRouteTarget: Equatable {
    case none
    case openAIAggregate
    case compatibleProvider(CompatibleProvider)
    case openRouter(OpenRouter)

    struct CompatibleProvider: Equatable {
        var providerID: String
        var providerLabel: String
        var baseURL: String
        var accountID: String
        var apiKey: String
        var modelID: String
    }

    struct OpenRouter: Equatable {
        var providerID: String
        var accountID: String
        var apiKey: String
        var modelID: String
    }

    var requiresListener: Bool {
        switch self {
        case .none:
            return false
        case .openAIAggregate, .compatibleProvider, .openRouter:
            return true
        }
    }

    var diagnosticName: String {
        switch self {
        case .none:
            return "none"
        case .openAIAggregate:
            return "openai_aggregate"
        case .compatibleProvider:
            return "compatible_provider"
        case .openRouter:
            return "openrouter"
        }
    }
}

struct OpenAIAccountGatewayRuntimeConfiguration {
    var host: String
    var port: UInt16
    var upstreamResponsesURL: URL
    var upstreamResponsesCompactURL: URL

    static let live = OpenAIAccountGatewayRuntimeConfiguration(
        host: OpenAIAccountGatewayConfiguration.listenHost,
        port: OpenAIAccountGatewayConfiguration.port,
        upstreamResponsesURL: OpenAIAccountGatewayConfiguration.upstreamResponsesURL,
        upstreamResponsesCompactURL: OpenAIAccountGatewayConfiguration.upstreamResponsesCompactURL
    )
}

enum OpenAIAccountGatewayUpstreamProxyResolutionMode: Equatable {
    case systemDefault
    case loopbackProxySafe
}

private enum OpenAIAccountGatewaySystemProxyKind: CaseIterable {
    case http
    case https
    case socks

    var enableKey: String {
        switch self {
        case .http:
            return kCFNetworkProxiesHTTPEnable as String
        case .https:
            return kCFNetworkProxiesHTTPSEnable as String
        case .socks:
            return kCFNetworkProxiesSOCKSEnable as String
        }
    }

    var hostKey: String {
        switch self {
        case .http:
            return kCFNetworkProxiesHTTPProxy as String
        case .https:
            return kCFNetworkProxiesHTTPSProxy as String
        case .socks:
            return kCFNetworkProxiesSOCKSProxy as String
        }
    }

    var portKey: String {
        switch self {
        case .http:
            return kCFNetworkProxiesHTTPPort as String
        case .https:
            return kCFNetworkProxiesHTTPSPort as String
        case .socks:
            return kCFNetworkProxiesSOCKSPort as String
        }
    }
}

struct OpenAIAccountGatewaySystemProxyEndpoint: Equatable {
    let kind: String
    let host: String
    let port: Int

    var isLoopback: Bool {
        let normalizedHost = self.host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalizedHost == "localhost" || normalizedHost == "127.0.0.1" || normalizedHost == "::1"
    }
}

struct OpenAIAccountGatewaySystemProxySnapshot: Equatable {
    let http: OpenAIAccountGatewaySystemProxyEndpoint?
    let https: OpenAIAccountGatewaySystemProxyEndpoint?
    let socks: OpenAIAccountGatewaySystemProxyEndpoint?

    var hasEnabledProxy: Bool {
        self.http != nil || self.https != nil || self.socks != nil
    }

    static func captureCurrent() -> OpenAIAccountGatewaySystemProxySnapshot? {
        guard let unmanagedSettings = CFNetworkCopySystemProxySettings() else {
            return nil
        }
        let settings = unmanagedSettings.takeRetainedValue() as NSDictionary
        return self.init(settings: settings as? [AnyHashable: Any] ?? [:])
    }

    init(http: OpenAIAccountGatewaySystemProxyEndpoint?, https: OpenAIAccountGatewaySystemProxyEndpoint?, socks: OpenAIAccountGatewaySystemProxyEndpoint?) {
        self.http = http
        self.https = https
        self.socks = socks
    }

    init?(settings: [AnyHashable: Any]) {
        let http = Self.proxyEndpoint(kind: .http, settings: settings)
        let https = Self.proxyEndpoint(kind: .https, settings: settings)
        let socks = Self.proxyEndpoint(kind: .socks, settings: settings)
        if http == nil, https == nil, socks == nil {
            return nil
        }
        self.init(http: http, https: https, socks: socks)
    }

    func applyingLoopbackSafePolicy() -> (effectiveSnapshot: OpenAIAccountGatewaySystemProxySnapshot?, applied: Bool) {
        let filtered = OpenAIAccountGatewaySystemProxySnapshot(
            http: self.http?.isLoopback == true ? nil : self.http,
            https: self.https?.isLoopback == true ? nil : self.https,
            socks: self.socks?.isLoopback == true ? nil : self.socks
        )
        let applied = filtered != self
        return (
            effectiveSnapshot: filtered.hasEnabledProxy ? filtered : nil,
            applied: applied
        )
    }

    var connectionProxyDictionary: [AnyHashable: Any] {
        var dictionary = Self.disabledConnectionProxyDictionary
        if let http = self.http {
            dictionary[kCFNetworkProxiesHTTPEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPProxy as String] = http.host
            dictionary[kCFNetworkProxiesHTTPPort as String] = http.port
        }
        if let https = self.https {
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = https.host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = https.port
        }
        if let socks = self.socks {
            dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy as String] = socks.host
            dictionary[kCFNetworkProxiesSOCKSPort as String] = socks.port
        }
        return dictionary
    }

    static var disabledConnectionProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
        ]
    }

    private static func proxyEndpoint(
        kind: OpenAIAccountGatewaySystemProxyKind,
        settings: [AnyHashable: Any]
    ) -> OpenAIAccountGatewaySystemProxyEndpoint? {
        guard self.boolValue(settings[kind.enableKey]) == true,
              let host = (settings[kind.hostKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let port = self.intValue(settings[kind.portKey]),
              port > 0 else {
            return nil
        }

        return OpenAIAccountGatewaySystemProxyEndpoint(
            kind: String(describing: kind),
            host: host,
            port: port
        )
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as Int:
            return value != 0
        case let value as String:
            return Int(value).map { $0 != 0 }
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}

struct OpenAIAccountGatewayResolvedUpstreamTransportPolicy: Equatable {
    let proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode
    let systemProxySnapshot: OpenAIAccountGatewaySystemProxySnapshot?
    let effectiveProxySnapshot: OpenAIAccountGatewaySystemProxySnapshot?
    let loopbackProxySafeApplied: Bool

    var connectionProxyDictionary: [AnyHashable: Any]? {
        if let effectiveProxySnapshot {
            return effectiveProxySnapshot.connectionProxyDictionary
        }
        if self.loopbackProxySafeApplied {
            return OpenAIAccountGatewaySystemProxySnapshot.disabledConnectionProxyDictionary
        }
        return nil
    }

    static func resolve(
        proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode,
        systemProxySnapshot: OpenAIAccountGatewaySystemProxySnapshot?
    ) -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        switch proxyResolutionMode {
        case .systemDefault:
            return OpenAIAccountGatewayResolvedUpstreamTransportPolicy(
                proxyResolutionMode: proxyResolutionMode,
                systemProxySnapshot: systemProxySnapshot,
                effectiveProxySnapshot: systemProxySnapshot,
                loopbackProxySafeApplied: false
            )
        case .loopbackProxySafe:
            guard let systemProxySnapshot else {
                return OpenAIAccountGatewayResolvedUpstreamTransportPolicy(
                    proxyResolutionMode: proxyResolutionMode,
                    systemProxySnapshot: nil,
                    effectiveProxySnapshot: nil,
                    loopbackProxySafeApplied: false
                )
            }
            let resolved = systemProxySnapshot.applyingLoopbackSafePolicy()
            return OpenAIAccountGatewayResolvedUpstreamTransportPolicy(
                proxyResolutionMode: proxyResolutionMode,
                systemProxySnapshot: systemProxySnapshot,
                effectiveProxySnapshot: resolved.effectiveSnapshot,
                loopbackProxySafeApplied: resolved.applied
            )
        }
    }
}

struct OpenAIAccountGatewayUpstreamTransportConfiguration {
    var requestTimeout: TimeInterval
    var resourceTimeout: TimeInterval
    var webSocketReadyBudget: TimeInterval
    var waitsForConnectivity: Bool
    var proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode
    var proxySnapshotProvider: () -> OpenAIAccountGatewaySystemProxySnapshot?

    init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        webSocketReadyBudget: TimeInterval,
        waitsForConnectivity: Bool,
        proxyResolutionMode: OpenAIAccountGatewayUpstreamProxyResolutionMode = .loopbackProxySafe,
        proxySnapshotProvider: @escaping () -> OpenAIAccountGatewaySystemProxySnapshot? = {
            OpenAIAccountGatewaySystemProxySnapshot.captureCurrent()
        }
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.webSocketReadyBudget = webSocketReadyBudget
        self.waitsForConnectivity = waitsForConnectivity
        self.proxyResolutionMode = proxyResolutionMode
        self.proxySnapshotProvider = proxySnapshotProvider
    }

    static let live = OpenAIAccountGatewayUpstreamTransportConfiguration(
        requestTimeout: 30,
        resourceTimeout: 120,
        webSocketReadyBudget: 8,
        waitsForConnectivity: false
    )

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        self.resolvedURLSessionConfiguration().configuration
    }

    func resolvedTransportPolicy() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        OpenAIAccountGatewayResolvedUpstreamTransportPolicy.resolve(
            proxyResolutionMode: self.proxyResolutionMode,
            systemProxySnapshot: self.proxySnapshotProvider()
        )
    }

    func resolvedURLSessionConfiguration() -> (
        configuration: URLSessionConfiguration,
        policy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = self.requestTimeout
        configuration.timeoutIntervalForResource = self.resourceTimeout
        configuration.waitsForConnectivity = self.waitsForConnectivity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let policy = self.resolvedTransportPolicy()
        if let connectionProxyDictionary = policy.connectionProxyDictionary {
            configuration.connectionProxyDictionary = connectionProxyDictionary
        }
        return (configuration, policy)
    }
}

enum OpenAIAccountGatewayFailoverDisposition: Equatable {
    case failover
    case doNotFailover
}

enum OpenAIAccountGatewayFailureClass: String, Equatable {
    case accountStatus
    case upstreamStatus
    case transport
    case protocolViolation
}

enum OpenAIAccountGatewayUpstreamFailure: Error {
    case accountStatus(Int)
    case upstreamStatus(Int)
    case transport(Error)
    case protocolViolation(Error)

    var failoverDisposition: OpenAIAccountGatewayFailoverDisposition {
        switch self {
        case .accountStatus, .upstreamStatus:
            return .failover
        case .transport, .protocolViolation:
            return .doNotFailover
        }
    }

    var failureClass: OpenAIAccountGatewayFailureClass {
        switch self {
        case .accountStatus:
            return .accountStatus
        case .upstreamStatus:
            return .upstreamStatus
        case .transport:
            return .transport
        case .protocolViolation:
            return .protocolViolation
        }
    }

    var statusCode: Int? {
        switch self {
        case .accountStatus(let statusCode), .upstreamStatus(let statusCode):
            return statusCode
        case .transport, .protocolViolation:
            return nil
        }
    }

    var underlyingError: Error? {
        switch self {
        case .transport(let error), .protocolViolation(let error):
            return error
        case .accountStatus, .upstreamStatus:
            return nil
        }
    }
}

struct OpenAIAccountGatewayUpstreamFailureDiagnostic: Equatable {
    let route: String
    let failureClass: OpenAIAccountGatewayFailureClass
    let statusCode: Int?
    let errorDomain: String?
    let errorCode: Int?
    let loopbackProxySafeApplied: Bool
}

private struct OpenAIAccountGatewaySnapshot {
    var accounts: [TokenAccount]
    var quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var routeTarget: OpenAIAccountGatewayRouteTarget
    var stickyBindings: [String: StickyBinding]
    var runtimeBlockedUntilByAccountID: [String: Date]
}

private struct StickyBinding {
    let accountID: String
    let updatedAt: Date
}

private struct RuntimeBlockedAccount {
    let retryAt: Date
}

private struct OpenAIAccountProtocolSignal {
    let message: String?
    let retryAt: Date?
}

private enum OpenAIAccountGatewayProtocolPreviewDecision {
    case needMoreData
    case streamNow
    case accountSignal(OpenAIAccountProtocolSignal)
}

private enum OpenAIAccountGatewayWebSocketPreviewDecision {
    case forward([URLSessionWebSocketTask.Message])
    case accountSignal(OpenAIAccountProtocolSignal)
}

private enum OpenAIAccountGatewayPOSTDisposition {
    case streamed(bindSticky: Bool)
    case accountSignal(OpenAIAccountProtocolSignal)
}

private enum OpenAIAccountGatewayPOSTAttemptOutcome<Success> {
    case completed(Success, bindSticky: Bool)
    case retryNextCandidate
}

private struct OpenAIAccountGatewayPreBytePOSTFailure: Error {
    let failure: OpenAIAccountGatewayUpstreamFailure
}

private struct OpenAIAccountGatewayTimingContext {
    let id: String
    let route: String
    let target: String
    let startedAt: Date
}

struct ParsedGatewayRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct ParsedWebSocketFrame {
    let opcode: UInt8
    let payload: Data
    let isFinal: Bool
}

private struct WebSocketFragmentState {
    var opcode: UInt8?
    var payload = Data()
}

private enum OpenAIAccountGatewayResponsesRoute: Equatable {
    case responses
    case compact

    init?(requestPath: String) {
        switch Self.normalizedPath(from: requestPath) {
        case "/v1/responses",
             "/responses",
             "/backend-api/codex/responses",
             "/openai/v1/responses":
            self = .responses
        case "/v1/responses/compact",
             "/responses/compact",
             "/backend-api/codex/responses/compact",
             "/openai/v1/responses/compact":
            self = .compact
        default:
            return nil
        }
    }

    private static func normalizedPath(from requestPath: String) -> String {
        let trimmed = requestPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPath = URLComponents(string: trimmed)?.path ?? trimmed
        var path = parsedPath.isEmpty ? trimmed : parsedPath
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    func upstreamURL(using configuration: OpenAIAccountGatewayRuntimeConfiguration) -> URL {
        switch self {
        case .responses:
            return configuration.upstreamResponsesURL
        case .compact:
            return configuration.upstreamResponsesCompactURL
        }
    }

    var diagnosticName: String {
        switch self {
        case .responses:
            return "responses"
        case .compact:
            return "compact"
        }
    }
}

final class OpenAIAccountGatewayService: OpenAIAccountGatewayControlling {
    static let shared = OpenAIAccountGatewayService()
    nonisolated static let mockRequestBodyPropertyKey = "codexbar.mockRequestBody"
    private nonisolated static let timingLogPrefix = "codexbar gateway timing"

    private let listenerQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.listener")
    private let stateQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.state")
    private let urlSession: URLSession
    private let upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration
    private let upstreamTransportPolicy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    private let runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration
    private let routeJournalStore: OpenAIAggregateRouteJournalStoring
    private let diagnosticsReporter: (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void

    private var listener: NWListener?
    private var accounts: [TokenAccount] = []
    private var quotaSortSettings = CodexBarOpenAISettings.QuotaSortSettings()
    private var accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount
    private var routeTarget: OpenAIAccountGatewayRouteTarget = .none
    private var stickyBindings: [String: StickyBinding] = [:]
    private var runtimeBlockedAccounts: [String: RuntimeBlockedAccount] = [:]
    private var lastRoutedAccountID: String?

    init(
        urlSession: URLSession? = nil,
        upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .live,
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .live,
        routeJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(),
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = OpenAIAccountGatewayService.liveDiagnosticsReporter
    ) {
        let resolvedTransportConfiguration = upstreamTransportConfiguration.resolvedURLSessionConfiguration()
        self.urlSession = urlSession ?? Self.makeDedicatedUpstreamSession(using: resolvedTransportConfiguration.configuration)
        self.upstreamTransportConfiguration = upstreamTransportConfiguration
        self.upstreamTransportPolicy = resolvedTransportConfiguration.policy
        self.runtimeConfiguration = runtimeConfiguration
        self.routeJournalStore = routeJournalStore
        self.diagnosticsReporter = diagnosticsReporter
    }

    private static func makeDedicatedUpstreamSession(
        using configuration: URLSessionConfiguration
    ) -> URLSession {
        URLSession(configuration: configuration)
    }

    nonisolated private static func liveDiagnosticsReporter(
        _ diagnostic: OpenAIAccountGatewayUpstreamFailureDiagnostic
    ) {
        let status = diagnostic.statusCode.map(String.init) ?? "-"
        let errorDomain = diagnostic.errorDomain ?? "-"
        let errorCode = diagnostic.errorCode.map(String.init) ?? "-"
        NSLog(
            "codexbar OpenAI gateway upstream failure route=%@ failureClass=%@ status=%@ errorDomain=%@ errorCode=%@ loopbackProxySafe=%@",
            diagnostic.route,
            diagnostic.failureClass.rawValue,
            status,
            errorDomain,
            errorCode,
            diagnostic.loopbackProxySafeApplied ? "true" : "false"
        )
    }

    nonisolated private static func makeTimingContext(
        route: String,
        target: String
    ) -> OpenAIAccountGatewayTimingContext {
        let id = UUID().uuidString.prefix(8)
        return OpenAIAccountGatewayTimingContext(
            id: String(id),
            route: route,
            target: target,
            startedAt: Date()
        )
    }

    nonisolated private static func elapsedMilliseconds(
        since start: Date,
        now: Date = Date()
    ) -> Int {
        Int((now.timeIntervalSince(start) * 1000).rounded())
    }

    nonisolated private static func logTiming(
        _ event: String,
        context: OpenAIAccountGatewayTimingContext,
        statusCode: Int? = nil,
        isEventStream: Bool? = nil,
        bytes: Int? = nil,
        events: Int? = nil,
        extra: String? = nil,
        now: Date = Date()
    ) {
        let status = statusCode.map(String.init) ?? "-"
        let stream = isEventStream.map { $0 ? "true" : "false" } ?? "-"
        let byteText = bytes.map(String.init) ?? "-"
        let eventText = events.map(String.init) ?? "-"
        let extraText = extra ?? "-"
        NSLog(
            "%@ id=%@ event=%@ route=%@ target=%@ elapsed_ms=%d status=%@ sse=%@ bytes=%@ events=%@ extra=%@",
            Self.timingLogPrefix,
            context.id,
            event,
            context.route,
            context.target,
            Self.elapsedMilliseconds(since: context.startedAt, now: now),
            status,
            stream,
            byteText,
            eventText,
            extraText
        )
    }

    func startIfNeeded() {
        self.listenerQueue.async {
            guard self.listener == nil else { return }

            do {
                let port = NWEndpoint.Port(rawValue: self.runtimeConfiguration.port)!
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(self.runtimeConfiguration.host),
                    port: .any
                )
                let listener = try NWListener(using: parameters, on: port)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    connection.start(queue: self.listenerQueue)
                    self.receiveRequest(on: connection, accumulated: Data())
                }
                listener.stateUpdateHandler = { state in
                    if case .failed = state {
                        self.listenerQueue.async {
                            self.listener = nil
                        }
                    }
                }
                self.listener = listener
                listener.start(queue: self.listenerQueue)
            } catch {
                NSLog("codexbar OpenAI gateway failed to start: %@", error.localizedDescription)
            }
        }
    }

    func stop() {
        self.listenerQueue.sync {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) {
        self.stateQueue.async {
            self.accounts = accounts
            self.quotaSortSettings = quotaSortSettings
            self.accountUsageMode = accountUsageMode
            self.routeTarget = routeTarget
            let knownIDs = Set(accounts.map(\.accountId))
            self.stickyBindings = self.stickyBindings.filter { knownIDs.contains($0.value.accountID) }
            self.runtimeBlockedAccounts = self.runtimeBlockedAccounts.filter { knownIDs.contains($0.key) }
            if let lastRoutedAccountID = self.lastRoutedAccountID,
               knownIDs.contains(lastRoutedAccountID) == false {
                self.lastRoutedAccountID = nil
            }
            self.pruneStickyBindingsLocked()
            self.pruneRuntimeBlockedAccountsLocked()
        }
    }

    func currentRoutedAccountID() -> String? {
        self.stateQueue.sync {
            self.lastRoutedAccountID
        }
    }

    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] {
        self.stateQueue.sync {
            self.stickyBindings.map { key, value in
                OpenAIAggregateStickyBindingSnapshot(
                    threadID: key,
                    accountID: value.accountID,
                    updatedAt: value.updatedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.threadID < rhs.threadID
            }
        }
    }

    @discardableResult
    func clearStickyBinding(threadID: String) -> Bool {
        self.stateQueue.sync {
            self.stickyBindings.removeValue(forKey: threadID) != nil
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("codexbar OpenAI gateway receive failed: %@", error.localizedDescription)
                connection.cancel()
                return
            }

            var combined = accumulated
            if let data {
                combined.append(data)
            }

            if let request = self.parseRequest(from: combined) {
                self.handle(request: request, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, accumulated: combined)
        }
    }

    private func parseRequest(from data: Data) -> ParsedGatewayRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return nil }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyOffset = headerRange.upperBound
        guard data.count >= bodyOffset + contentLength else { return nil }

        let body = data.subdata(in: bodyOffset..<(bodyOffset + contentLength))
        return ParsedGatewayRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func handle(request: ParsedGatewayRequest, on connection: NWConnection) {
        let method = request.method.uppercased()
        let route = OpenAIAccountGatewayResponsesRoute(requestPath: request.path)
        let snapshot = self.snapshot()

        if self.requiresLocalAuthorization(snapshot.routeTarget),
           self.isLocallyAuthorized(request: request, snapshot: snapshot) == false {
            self.sendJSONResponse(
                on: connection,
                statusCode: 401,
                body: #"{"error":{"message":"codexbar gateway unauthorized"}}"#
            )
            return
        }

        switch (method, route) {
        case ("GET", .responses):
            switch snapshot.routeTarget {
            case .openAIAggregate:
                Task {
                    await self.handleResponsesWebSocketUpgrade(request: request, on: connection)
                }
            case .compatibleProvider, .openRouter:
                Task {
                    await self.handleRouteTargetWebSocketUpgrade(
                        request: request,
                        on: connection,
                        routeTarget: snapshot.routeTarget
                    )
                }
            case .none:
                self.sendJSONResponse(
                    on: connection,
                    statusCode: 503,
                    body: #"{"error":{"message":"codexbar gateway unavailable: no routed target"}}"#
                )
            }
        case ("POST", let route?):
            Task {
                await self.forwardResponsesRequest(request, on: connection, route: route, routeTarget: snapshot.routeTarget)
            }
        default:
            self.sendJSONResponse(
                on: connection,
                statusCode: 404,
                body: #"{"error":{"message":"not found"}}"#
            )
        }
    }

    private func requiresLocalAuthorization(_ routeTarget: OpenAIAccountGatewayRouteTarget) -> Bool {
        switch routeTarget {
        case .compatibleProvider, .openRouter:
            return true
        case .none, .openAIAggregate:
            return false
        }
    }

    private func isLocallyAuthorized(
        request: ParsedGatewayRequest,
        snapshot: OpenAIAccountGatewaySnapshot
    ) -> Bool {
        guard let authorization = request.headers["authorization"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              authorization.lowercased().hasPrefix("bearer ") else {
            return false
        }
        let tokenStart = authorization.index(authorization.startIndex, offsetBy: "bearer ".count)
        let token = authorization[tokenStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else { return false }
        return snapshot.accounts.contains { $0.accessToken == token }
    }

    private func handleResponsesWebSocketUpgrade(
        request: ParsedGatewayRequest,
        on connection: NWConnection
    ) async {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              let secKey = request.headers["sec-websocket-key"],
              secKey.isEmpty == false else {
            self.sendJSONResponse(
                on: connection,
                statusCode: 400,
                body: #"{"error":{"message":"websocket upgrade headers are missing"}}"#
            )
            return
        }

        let stickyKey = self.stickySessionKey(for: request.headers)
        do {
            var established = try await self.establishUpstreamWebSocket(
                request: request,
                stickyKey: stickyKey
            )
            let previewedMessages: [URLSessionWebSocketTask.Message]
            while true {
                switch try await self.previewUpstreamWebSocketMessages(established.task) {
                case .forward(let messages):
                    previewedMessages = messages
                    break
                case .accountSignal(let signal):
                    self.runtimeBlockAccount(established.account, suggestedRetryAt: signal.retryAt)
                    self.clearBinding(stickyKey: stickyKey, accountID: established.account.accountId)
                    established.task.cancel(with: .goingAway, reason: nil)
                    established = try await self.establishUpstreamWebSocket(
                        request: request,
                        stickyKey: stickyKey
                    )
                    continue
                }
                break
            }

            self.bind(stickyKey: stickyKey, accountID: established.account.accountId)
            let response = self.makeWebSocketHandshakeResponse(
                for: secKey,
                selectedProtocol: established.selectedProtocol
            )
            try await self.send(Data(response.utf8), on: connection)

            self.pipeUpstreamMessages(
                upstreamTask: established.task,
                to: connection,
                stickyKey: stickyKey,
                accountID: established.account.accountId,
                initialMessages: previewedMessages
            )
            self.receiveClientWebSocketMessages(
                on: connection,
                upstreamTask: established.task,
                buffer: Data(),
                fragments: WebSocketFragmentState(),
                stickyKey: stickyKey,
                accountID: established.account.accountId
            )
        } catch {
            self.sendJSONResponse(
                on: connection,
                statusCode: 502,
                body: #"{"error":{"message":"failed to establish upstream websocket"}}"#
            )
        }
    }

    private func handleRouteTargetWebSocketUpgrade(
        request: ParsedGatewayRequest,
        on connection: NWConnection,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              let secKey = request.headers["sec-websocket-key"],
              secKey.isEmpty == false else {
            self.sendJSONResponse(
                on: connection,
                statusCode: 400,
                body: #"{"error":{"message":"websocket upgrade headers are missing"}}"#
            )
            return
        }

        do {
            try await self.send(Data(self.makeWebSocketHandshakeResponse(for: secKey).utf8), on: connection)
            self.receiveRouteTargetWebSocketMessages(
                on: connection,
                buffer: Data(),
                fragments: WebSocketFragmentState(),
                routeTarget: routeTarget
            )
        } catch {
            connection.cancel()
        }
    }

    private func snapshot() -> OpenAIAccountGatewaySnapshot {
        self.stateQueue.sync {
            OpenAIAccountGatewaySnapshot(
                accounts: self.accounts,
                quotaSortSettings: self.quotaSortSettings,
                accountUsageMode: self.accountUsageMode,
                routeTarget: self.routeTarget,
                stickyBindings: self.stickyBindings,
                runtimeBlockedUntilByAccountID: self.runtimeBlockedAccounts.mapValues(\.retryAt)
            )
        }
    }

    private func stickySessionKey(for headers: [String: String]) -> String? {
        let candidates = [
            headers["session_id"],
            headers["conversation_id"],
            headers["x-codex-window-id"],
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }

    private func stickySessionKey(
        for request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute
    ) -> String? {
        if let headerKey = self.stickySessionKey(for: request.headers) {
            return headerKey
        }
        guard route == .compact else { return nil }
        return self.compactSessionSeed(from: request.body)
    }

    private func compactSessionSeed(from body: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        let candidates = [
            json["prompt_cache_key"] as? String,
            json["session_id"] as? String,
            json["conversation_id"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }

    private func candidates(for snapshot: OpenAIAccountGatewaySnapshot, stickyKey: String?) -> [TokenAccount] {
        guard snapshot.accountUsageMode == .aggregateGateway,
              snapshot.routeTarget == .openAIAggregate else { return [] }

        let now = Date()
        let usable = snapshot.accounts.filter {
            $0.isAvailableForNextUseRouting &&
            (snapshot.runtimeBlockedUntilByAccountID[$0.accountId]?.timeIntervalSince(now) ?? 0) <= 0
        }
        var ordered = usable.sorted {
            OpenAIAccountListLayout.accountPrecedes(
                $0,
                $1,
                quotaSortSettings: snapshot.quotaSortSettings
            )
        }

        if let stickyKey,
           let stickyAccountID = snapshot.stickyBindings[stickyKey]?.accountID,
           let index = ordered.firstIndex(where: { $0.accountId == stickyAccountID }) {
            let stickyAccount = ordered.remove(at: index)
            ordered.insert(stickyAccount, at: 0)
        }

        return ordered
    }

    private func bind(stickyKey: String?, accountID: String) {
        var routeChanged = false
        var shouldRecordRoute = false
        self.stateQueue.sync {
            if self.lastRoutedAccountID != accountID {
                self.lastRoutedAccountID = accountID
                routeChanged = true
            }
            if let stickyKey, stickyKey.isEmpty == false {
                if self.stickyBindings[stickyKey]?.accountID != accountID {
                    shouldRecordRoute = true
                }
                self.stickyBindings[stickyKey] = StickyBinding(
                    accountID: accountID,
                    updatedAt: Date()
                )
            }
            self.pruneStickyBindingsLocked()
        }
        if shouldRecordRoute, let stickyKey, stickyKey.isEmpty == false {
            self.routeJournalStore.recordRoute(
                threadID: stickyKey,
                accountID: accountID,
                timestamp: Date()
            )
        }
        if routeChanged {
            NotificationCenter.default.post(
                name: .openAIAccountGatewayDidRouteAccount,
                object: self,
                userInfo: ["accountID": accountID]
            )
        }
    }

    private func clearBinding(stickyKey: String?, accountID: String) {
        guard let stickyKey, stickyKey.isEmpty == false else { return }
        self.stateQueue.sync {
            guard self.stickyBindings[stickyKey]?.accountID == accountID else { return }
            self.stickyBindings.removeValue(forKey: stickyKey)
        }
    }

    private func pruneStickyBindingsLocked() {
        let expirationInterval: TimeInterval = 60 * 60 * 6
        let cutoff = Date().addingTimeInterval(-expirationInterval)
        self.stickyBindings = self.stickyBindings.filter { $0.value.updatedAt >= cutoff }

        let maxEntries = 256
        guard self.stickyBindings.count > maxEntries else { return }
        let sortedKeys = self.stickyBindings
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .map(\.key)
        for key in sortedKeys.prefix(self.stickyBindings.count - maxEntries) {
            self.stickyBindings.removeValue(forKey: key)
        }
    }

    private func pruneRuntimeBlockedAccountsLocked(now: Date = Date()) {
        self.runtimeBlockedAccounts = self.runtimeBlockedAccounts.filter {
            $0.value.retryAt.timeIntervalSince(now) > 0
        }
    }

    private func runtimeBlockAccount(
        _ account: TokenAccount,
        suggestedRetryAt: Date?
    ) {
        let retryAt = self.resolvedRuntimeBlockRetryAt(
            for: account,
            suggestedRetryAt: suggestedRetryAt
        )
        self.stateQueue.sync {
            self.runtimeBlockedAccounts[account.accountId] = RuntimeBlockedAccount(retryAt: retryAt)
            if self.lastRoutedAccountID == account.accountId {
                self.lastRoutedAccountID = nil
            }
            self.pruneRuntimeBlockedAccountsLocked()
        }
    }

    private func resolvedRuntimeBlockRetryAt(
        for account: TokenAccount,
        suggestedRetryAt: Date?
    ) -> Date {
        let now = Date()
        if let suggestedRetryAt,
           suggestedRetryAt.timeIntervalSince(now) > 0 {
            return suggestedRetryAt
        }
        if account.quotaExhausted,
           let availabilityResetAt = account.availabilityResetAt(now: now),
           availabilityResetAt.timeIntervalSince(now) > 0 {
            return availabilityResetAt
        }
        return now.addingTimeInterval(10 * 60)
    }

    private func runtimeBlockAccountStatusIfNeeded(
        statusCode: Int,
        response: HTTPURLResponse?,
        account: TokenAccount
    ) {
        guard statusCode == 429 else { return }
        guard let retryAt = self.retryAt(from: response) else { return }
        self.runtimeBlockAccount(
            account,
            suggestedRetryAt: retryAt
        )
    }

    private func retryAt(from response: HTTPURLResponse?) -> Date? {
        guard let retryAfter = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return self.retryAt(fromRetryAfterValue: retryAfter)
    }

    private func retryAt(fromRetryAfterValue value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed) {
            return Date().addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed)
    }

    private func handleInBandAccountSignalIfNeeded(
        text: String,
        accountID: String,
        stickyKey: String?
    ) -> Bool {
        guard let signal = self.accountProtocolSignal(in: text),
              let account = self.account(withID: accountID) else {
            return false
        }

        self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
        self.clearBinding(stickyKey: stickyKey, accountID: accountID)
        return true
    }

    private func account(withID accountID: String) -> TokenAccount? {
        self.stateQueue.sync {
            self.accounts.first(where: { $0.accountId == accountID })
        }
    }

    private func forwardResponsesRequest(
        _ request: ParsedGatewayRequest,
        on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async {
        let timing = Self.makeTimingContext(
            route: route.diagnosticName,
            target: routeTarget.diagnosticName
        )
        Self.logTiming("request_received", context: timing, extra: request.method.uppercased())

        switch routeTarget {
        case .compatibleProvider(let target):
            await self.forwardProviderResponsesRequest(
                request,
                on: connection,
                route: route,
                target: target,
                timing: timing
            )
            return
        case .openRouter(let target):
            await self.forwardOpenRouterResponsesRequest(
                request,
                on: connection,
                route: route,
                target: target,
                timing: timing
            )
            return
        case .none, .openAIAggregate:
            break
        }

        _ = await self.routePOSTResponsesCandidates(
            request,
            route: route,
            onNoCandidates: {
                self.sendJSONResponse(
                    on: connection,
                    statusCode: 503,
                    body: #"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#
                )
            },
            onSyntheticGatewayFailure: {
                self.sendJSONResponse(
                    on: connection,
                    statusCode: 502,
                    body: #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
                )
            }
        ) { response, bytes, account, stickyKey, allowInBandFailover in
            let disposition = try await self.stream(
                result: (response, bytes),
                account: account,
                stickyKey: stickyKey,
                to: connection,
                allowInBandFailover: allowInBandFailover,
                timing: timing
            )
            switch disposition {
            case .streamed(let bindSticky):
                return .completed((), bindSticky: bindSticky)
            case .accountSignal:
                return .retryNextCandidate
            }
        }
    }

    private func forwardProviderResponsesRequest(
        _ request: ParsedGatewayRequest,
        on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider,
        timing: OpenAIAccountGatewayTimingContext
    ) async {
        do {
            let result = try await self.proxyProviderPOSTResponses(request, route: route, target: target)
            try await self.streamHTTPResponse(result, to: connection, timing: timing)
        } catch {
            Self.logTiming("request_failed", context: timing, extra: (error as NSError).domain)
            self.sendJSONResponse(
                on: connection,
                statusCode: 502,
                body: #"{"error":{"message":"codexbar gateway failed to reach provider upstream"}}"#
            )
        }
    }

    private func forwardOpenRouterResponsesRequest(
        _ request: ParsedGatewayRequest,
        on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.OpenRouter,
        timing: OpenAIAccountGatewayTimingContext
    ) async {
        do {
            let result = try await self.proxyOpenRouterPOSTResponses(request, route: route, target: target)
            try await self.streamHTTPResponse(result, to: connection, timing: timing)
        } catch {
            Self.logTiming("request_failed", context: timing, extra: (error as NSError).domain)
            self.sendJSONResponse(
                on: connection,
                statusCode: 502,
                body: #"{"error":{"message":"codexbar gateway failed to reach OpenRouter upstream"}}"#
            )
        }
    }

    private func proxyRouteTargetPOSTResponses(
        body: Data,
        route: OpenAIAccountGatewayResponsesRoute,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        switch routeTarget {
        case .compatibleProvider(let target):
            return try await self.proxyProviderPOSTResponses(
                body: body,
                inboundHeaders: [:],
                route: route,
                target: target
            )
        case .openRouter(let target):
            return try await self.proxyOpenRouterPOSTResponses(
                body: body,
                inboundHeaders: [:],
                route: route,
                target: target
            )
        case .none, .openAIAggregate:
            throw URLError(.userAuthenticationRequired)
        }
    }

    private func proxyPOSTResponses(
        _ request: ParsedGatewayRequest,
        account: TokenAccount,
        route: OpenAIAccountGatewayResponsesRoute
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let normalizedBody = self.normalizeRequestBody(request.body, route: route)
        var upstreamRequest = URLRequest(url: route.upstreamURL(using: self.runtimeConfiguration))
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = normalizedBody
        let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            normalizedBody,
            forKey: Self.mockRequestBodyPropertyKey,
            in: mutableRequest
        )
        upstreamRequest = mutableRequest as URLRequest

        for (name, value) in request.headers {
            switch name {
            case "host", "content-length", "authorization", "chatgpt-account-id", "connection", "originator":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
        upstreamRequest.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        upstreamRequest.setValue(OpenAIAccountGatewayConfiguration.originator, forHTTPHeaderField: "originator")
        upstreamRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        if route == .compact {
            upstreamRequest.setValue("application/json", forHTTPHeaderField: "accept")
            if upstreamRequest.value(forHTTPHeaderField: "version") == nil {
                upstreamRequest.setValue(OpenAIAccountGatewayConfiguration.defaultCodexCLIVersion, forHTTPHeaderField: "version")
            }
            if let compactSessionSeed = self.compactSessionSeed(from: request.body) {
                if upstreamRequest.value(forHTTPHeaderField: "session_id") == nil {
                    upstreamRequest.setValue(compactSessionSeed, forHTTPHeaderField: "session_id")
                }
                if upstreamRequest.value(forHTTPHeaderField: "conversation_id") == nil {
                    upstreamRequest.setValue(compactSessionSeed, forHTTPHeaderField: "conversation_id")
                }
            }
        }

        let (bytes, response) = try await self.urlSession.bytes(for: upstreamRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
        }

        return (httpResponse, bytes)
    }

    private func proxyProviderPOSTResponses(
        _ request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        try await self.proxyProviderPOSTResponses(
            body: request.body,
            inboundHeaders: request.headers,
            route: route,
            target: target
        )
    }

    private func proxyProviderPOSTResponses(
        body: Data,
        inboundHeaders: [String: String],
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let normalizedBody = self.normalizeProviderRequestBody(
            body,
            route: route,
            selectedModelID: target.modelID
        )
        var upstreamRequest = URLRequest(url: try self.providerResponsesURL(baseURL: target.baseURL, route: route))
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = normalizedBody
        let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            normalizedBody,
            forKey: Self.mockRequestBodyPropertyKey,
            in: mutableRequest
        )
        upstreamRequest = mutableRequest as URLRequest

        for (name, value) in inboundHeaders {
            switch name {
            case "host", "content-length", "authorization", "chatgpt-account-id", "connection", "originator":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        upstreamRequest.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "authorization")
        let (bytes, response) = try await self.urlSession.bytes(for: upstreamRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
        }
        return (httpResponse, bytes)
    }

    private func proxyOpenRouterPOSTResponses(
        _ request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.OpenRouter
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        try await self.proxyOpenRouterPOSTResponses(
            body: request.body,
            inboundHeaders: request.headers,
            route: route,
            target: target
        )
    }

    private func proxyOpenRouterPOSTResponses(
        body: Data,
        inboundHeaders: [String: String],
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.OpenRouter
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        let normalizedBody = self.normalizeOpenRouterRequestBody(
            body,
            route: route,
            selectedModelID: target.modelID
        )
        var upstreamRequest = URLRequest(url: self.openRouterResponsesURL(route: route))
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = normalizedBody
        let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            normalizedBody,
            forKey: Self.mockRequestBodyPropertyKey,
            in: mutableRequest
        )
        upstreamRequest = mutableRequest as URLRequest

        for (name, value) in inboundHeaders {
            switch name {
            case "host", "content-length", "authorization", "chatgpt-account-id", "connection", "originator":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        upstreamRequest.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "authorization")
        let (bytes, response) = try await self.urlSession.bytes(for: upstreamRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
        }
        return (httpResponse, bytes)
    }

    private func streamHTTPResponse(
        _ result: (response: HTTPURLResponse, bytes: URLSession.AsyncBytes),
        to connection: NWConnection,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws {
        let headers = self.renderResponseHeaders(from: result.response)
        let isEventStream = result.response
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true
        Self.logTiming(
            "upstream_headers",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream
        )
        try await self.send(Data(headers.utf8), on: connection)

        var buffer = Data()
        var eventAccumulator = SSEEventStreamAccumulator()
        var totalBytes = 0
        var eventCount = 0
        var didWriteBody = false

        for try await byte in result.bytes {
            totalBytes += 1
            if isEventStream {
                if let eventChunk = eventAccumulator.append(byte) {
                    try await self.send(eventChunk, on: connection)
                    eventCount += 1
                    if didWriteBody == false {
                        didWriteBody = true
                        Self.logTiming(
                            "first_downstream_body",
                            context: timing,
                            statusCode: result.response.statusCode,
                            isEventStream: isEventStream,
                            bytes: totalBytes,
                            events: eventCount
                        )
                    }
                }
            } else {
                buffer.append(byte)
                if buffer.count < 8192 {
                    continue
                }
                try await self.send(buffer, on: connection)
                if didWriteBody == false {
                    didWriteBody = true
                    Self.logTiming(
                        "first_downstream_body",
                        context: timing,
                        statusCode: result.response.statusCode,
                        isEventStream: isEventStream,
                        bytes: totalBytes
                    )
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if isEventStream {
            if let remaining = eventAccumulator.flush() {
                try await self.send(remaining, on: connection)
                if didWriteBody == false {
                    didWriteBody = true
                    Self.logTiming(
                        "first_downstream_body",
                        context: timing,
                        statusCode: result.response.statusCode,
                        isEventStream: isEventStream,
                        bytes: totalBytes,
                        events: eventCount
                    )
                }
            }
        } else if buffer.isEmpty == false {
            try await self.send(buffer, on: connection)
            if didWriteBody == false {
                didWriteBody = true
                Self.logTiming(
                    "first_downstream_body",
                    context: timing,
                    statusCode: result.response.statusCode,
                    isEventStream: isEventStream,
                    bytes: totalBytes,
                    events: eventCount
                )
            }
        }
        Self.logTiming(
            "request_completed",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream,
            bytes: totalBytes,
            events: eventCount
        )
        connection.cancel()
    }

    private struct SSEEventStreamAccumulator {
        private var buffer = Data()
        private var previousByteWasLineFeed = false

        mutating func append(_ byte: UInt8) -> Data? {
            self.buffer.append(byte)
            if byte == 0x0A {
                if self.previousByteWasLineFeed {
                    let eventChunk = self.buffer
                    self.buffer.removeAll(keepingCapacity: true)
                    self.previousByteWasLineFeed = false
                    return eventChunk
                }
                self.previousByteWasLineFeed = true
            } else {
                self.previousByteWasLineFeed = false
            }
            return nil
        }

        mutating func flush() -> Data? {
            guard self.buffer.isEmpty == false else {
                return nil
            }
            let remaining = self.buffer
            self.buffer.removeAll(keepingCapacity: true)
            self.previousByteWasLineFeed = false
            return remaining
        }
    }

    private func readAllBytes(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func normalizeRequestBody(_ body: Data, route: OpenAIAccountGatewayResponsesRoute) -> Data {
        switch route {
        case .responses:
            return self.normalizeResponsesRequestBody(body)
        case .compact:
            return self.normalizeCompactRequestBody(body)
        }
    }

    private func providerResponsesURL(
        baseURL: String,
        route: OpenAIAccountGatewayResponsesRoute
    ) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else {
            throw URLError(.badURL)
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        switch route {
        case .responses:
            path += "/responses"
        case .compact:
            path += "/responses"
        }
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func openRouterResponsesURL(route _: OpenAIAccountGatewayResponsesRoute) -> URL {
        OpenRouterGatewayConfiguration.upstreamResponsesURL
    }

    private func normalizeProviderRequestBody(
        _ body: Data,
        route: OpenAIAccountGatewayResponsesRoute,
        selectedModelID: String
    ) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        json = self.unwrapResponseCreateEnvelopeIfNeeded(json)
        json["model"] = selectedModelID
        switch route {
        case .responses:
            json["store"] = false
            json["stream"] = true
            json.removeValue(forKey: "max_output_tokens")
            json.removeValue(forKey: "temperature")
            json.removeValue(forKey: "top_p")
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
        case .compact:
            json.removeValue(forKey: "store")
            json.removeValue(forKey: "stream")
            json.removeValue(forKey: "include")
            json.removeValue(forKey: "tools")
            json.removeValue(forKey: "tool_choice")
            json.removeValue(forKey: "parallel_tool_calls")
            json.removeValue(forKey: "max_output_tokens")
            json.removeValue(forKey: "temperature")
            json.removeValue(forKey: "top_p")
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
        }
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return data
    }

    private func normalizeOpenRouterRequestBody(
        _ body: Data,
        route: OpenAIAccountGatewayResponsesRoute,
        selectedModelID: String
    ) -> Data {
        let object = try? JSONSerialization.jsonObject(with: body)
        let normalizedObject: [String: Any]

        if let json = object as? [String: Any] {
            normalizedObject = self.normalizeOpenRouterRequestObject(
                json,
                route: route,
                selectedModelID: selectedModelID
            )
        } else if let inputArray = object as? [Any] {
            normalizedObject = self.normalizeOpenRouterRequestObject(
                ["input": inputArray],
                route: route,
                selectedModelID: selectedModelID
            )
        } else {
            return body
        }

        guard JSONSerialization.isValidJSONObject(normalizedObject),
              let data = try? JSONSerialization.data(withJSONObject: normalizedObject) else {
            return body
        }
        return data
    }

    private func normalizeOpenRouterRequestObject(
        _ original: [String: Any],
        route: OpenAIAccountGatewayResponsesRoute,
        selectedModelID: String
    ) -> [String: Any] {
        var json = self.unwrapResponseCreateEnvelopeIfNeeded(original)
        json["model"] = selectedModelID
        if let normalizedInput = self.normalizeOpenRouterInput(json["input"]) {
            json["input"] = normalizedInput
        }

        if route == .compact {
            json.removeValue(forKey: "store")
            json.removeValue(forKey: "stream")
            json.removeValue(forKey: "include")
            json.removeValue(forKey: "tools")
            json.removeValue(forKey: "tool_choice")
            json.removeValue(forKey: "parallel_tool_calls")
            json.removeValue(forKey: "max_output_tokens")
            json.removeValue(forKey: "temperature")
            json.removeValue(forKey: "top_p")
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
        } else {
            json["store"] = false
            json["stream"] = true
            json.removeValue(forKey: "max_output_tokens")
            json.removeValue(forKey: "temperature")
            json.removeValue(forKey: "top_p")
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
            let normalizedTools = self.normalizeOpenRouterTools(json["tools"])
            json["tools"] = normalizedTools
            json["tool_choice"] = normalizedTools.isEmpty ? "none" : (json["tool_choice"] ?? "auto")
            if json["parallel_tool_calls"] == nil || json["parallel_tool_calls"] is NSNull {
                json["parallel_tool_calls"] = false
            }
        }

        return json
    }

    private func unwrapResponseCreateEnvelopeIfNeeded(_ json: [String: Any]) -> [String: Any] {
        guard json["input"] == nil,
              let type = json["type"] as? String,
              type == "response.create",
              let response = json["response"] as? [String: Any] else {
            return json
        }
        return response
    }

    private func normalizeOpenRouterInput(_ input: Any?) -> Any? {
        guard let input else { return nil }
        guard let items = input as? [Any] else { return input }

        return items.enumerated().map { index, item in
            guard var message = item as? [String: Any] else { return item }
            if message["type"] == nil,
               let role = message["role"] as? String,
               role.isEmpty == false {
                message["type"] = "message"
            }
            if let role = (message["role"] as? String)?.lowercased(),
               role == "assistant" {
                if (message["status"] as? String)?.isEmpty != false {
                    message["status"] = "completed"
                }
                if (message["id"] as? String)?.isEmpty != false {
                    message["id"] = "msg_codexbar_\(index)"
                }
            }
            return message
        }
    }

    private func normalizeOpenRouterTools(_ tools: Any?) -> [[String: Any]] {
        guard let items = tools as? [Any] else { return [] }
        return items.compactMap { item in
            guard var tool = item as? [String: Any],
                  var type = tool["type"] as? String,
                  type.isEmpty == false else {
                return nil
            }
            if type == "datetime" {
                type = "openrouter:datetime"
                tool["type"] = type
            }
            return tool
        }
    }

    private func makeUpstreamWebSocketTask(
        request: ParsedGatewayRequest,
        account: TokenAccount
    ) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(
            url: self.runtimeConfiguration.upstreamResponsesURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        components.scheme = "wss"
        guard let upstreamURL = components.url else { throw URLError(.badURL) }

        var upstreamRequest = URLRequest(url: upstreamURL)
        for (name, value) in request.headers {
            switch name {
            case "host",
                 "connection",
                 "upgrade",
                 "sec-websocket-version",
                 "sec-websocket-key",
                  "sec-websocket-extensions",
                 "authorization",
                 "chatgpt-account-id",
                 "originator":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
        upstreamRequest.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        upstreamRequest.setValue(OpenAIAccountGatewayConfiguration.originator, forHTTPHeaderField: "originator")

        let task = self.urlSession.webSocketTask(with: upstreamRequest)
        task.resume()
        return task
    }

    private func normalizeResponsesRequestBody(_ body: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }

        json["store"] = false
        json["stream"] = true
        json.removeValue(forKey: "max_output_tokens")
        json.removeValue(forKey: "temperature")
        json.removeValue(forKey: "top_p")

        if json["instructions"] == nil || json["instructions"] is NSNull {
            json["instructions"] = ""
        }
        if json["tools"] == nil || json["tools"] is NSNull {
            json["tools"] = []
        }
        if json["parallel_tool_calls"] == nil || json["parallel_tool_calls"] is NSNull {
            json["parallel_tool_calls"] = false
        }

        var includes = (json["include"] as? [Any]) ?? []
        let hasReasoningMarker = includes.contains {
            ($0 as? String) == OpenAIAccountGatewayConfiguration.reasoningIncludeMarker
        }
        if hasReasoningMarker == false {
            includes.append(OpenAIAccountGatewayConfiguration.reasoningIncludeMarker)
        }
        json["include"] = includes

        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return data
    }

    private func normalizeCompactRequestBody(_ body: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }

        let allowedFields = [
            "model",
            "input",
            "instructions",
            "previous_response_id",
        ]
        json = json.filter { allowedFields.contains($0.key) }

        if json["instructions"] == nil || json["instructions"] is NSNull {
            json["instructions"] = ""
        }

        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return data
    }

    private func routeUpstreamWebSocketCandidate<TaskType>(
        request: ParsedGatewayRequest,
        stickyKey: String?,
        attempt: (_ account: TokenAccount, _ requestedProtocol: String?, _ readyBudget: TimeInterval) async throws
            -> (task: TaskType, selectedProtocol: String?)
    ) async throws -> (task: TaskType, account: TokenAccount, selectedProtocol: String?) {
        let snapshot = self.snapshot()
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)
        guard candidates.isEmpty == false else {
            throw URLError(.userAuthenticationRequired)
        }

        let requestedProtocol = request.headers["sec-websocket-protocol"]
        let readyBudget = self.upstreamTransportConfiguration.webSocketReadyBudget
        var lastFailure: Error = URLError(.cannotConnectToHost)
        var usedStickyContextRecovery = false

        for (index, account) in candidates.enumerated() {
            do {
                let established = try await attempt(account, requestedProtocol, readyBudget)
                return (established.task, account, established.selectedProtocol)
            } catch {
                let failure = self.classifyWebSocketFailure(error)
                lastFailure = failure
                if case .accountStatus(let statusCode) = failure {
                    self.runtimeBlockAccountStatusIfNeeded(
                        statusCode: statusCode,
                        response: nil,
                        account: account
                    )
                }
                if usedStickyContextRecovery {
                    throw failure
                }
                if failure.failoverDisposition == .failover,
                   index < candidates.count - 1 {
                    continue
                }
                if self.shouldAttemptStickyContextRecovery(
                    failure: failure,
                    snapshot: snapshot,
                    stickyKey: stickyKey,
                    failedAccountID: account.accountId,
                    candidateIndex: index,
                    candidateCount: candidates.count,
                    usedStickyContextRecovery: usedStickyContextRecovery
                ) {
                    usedStickyContextRecovery = true
                    continue
                }
                throw failure
            }
        }

        throw lastFailure
    }

    private func shouldAttemptStickyContextRecovery(
        failure: OpenAIAccountGatewayUpstreamFailure,
        snapshot: OpenAIAccountGatewaySnapshot,
        stickyKey: String?,
        failedAccountID: String,
        candidateIndex: Int,
        candidateCount: Int,
        usedStickyContextRecovery: Bool
    ) -> Bool {
        guard usedStickyContextRecovery == false,
              candidateIndex == 0,
              candidateCount > 1,
              let stickyKey,
              stickyKey.isEmpty == false,
              snapshot.stickyBindings[stickyKey]?.accountID == failedAccountID else {
            return false
        }

        switch failure {
        case .transport, .protocolViolation:
            return true
        case .accountStatus, .upstreamStatus:
            return false
        }
    }

    private func establishUpstreamWebSocket(
        request: ParsedGatewayRequest,
        stickyKey: String?
    ) async throws -> (task: URLSessionWebSocketTask, account: TokenAccount, selectedProtocol: String?) {
        try await self.routeUpstreamWebSocketCandidate(request: request, stickyKey: stickyKey) {
            account,
            requestedProtocol,
            readyBudget in
            let task = try self.makeUpstreamWebSocketTask(request: request, account: account)
            do {
                let selectedProtocol = try await self.awaitUpstreamWebSocketReady(
                    task,
                    requestedProtocol: requestedProtocol,
                    readyBudget: readyBudget
                )
                return (task, selectedProtocol)
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                throw error
            }
        }
    }

    private func awaitUpstreamWebSocketReady(
        _ task: URLSessionWebSocketTask,
        requestedProtocol: String?,
        readyBudget: TimeInterval
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                do {
                    try await self.sendPing(on: task)
                } catch {
                    throw self.classifyWebSocketReadyFailure(error, response: task.response)
                }
                return try self.validateUpstreamWebSocketHandshake(
                    task.response,
                    requestedProtocol: requestedProtocol
                )
            }
            group.addTask {
                let nanoseconds = UInt64((readyBudget * 1_000_000_000).rounded())
                try await Task.sleep(nanoseconds: nanoseconds)
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
            }

            guard let result = try await group.next() else {
                throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.timedOut))
            }
            group.cancelAll()
            return result
        }
    }

    private func sendPing(on task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated private func validateUpstreamWebSocketHandshake(
        _ response: URLResponse?,
        requestedProtocol: String?
    ) throws -> String? {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAccountGatewayUpstreamFailure.transport(URLError(.cannotParseResponse))
        }

        if httpResponse.statusCode != 101 {
            if let failure = self.failureForHTTPStatus(httpResponse.statusCode) {
                throw failure
            }
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
        }

        let negotiatedProtocol = httpResponse.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let requestedProtocol,
           requestedProtocol.isEmpty == false,
           let negotiatedProtocol,
           negotiatedProtocol.isEmpty {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.cannotParseResponse))
        }
        return negotiatedProtocol
    }

    nonisolated private func classifyPOSTFailure(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }
        if let urlError = error as? URLError,
           urlError.code == .badServerResponse || urlError.code == .cannotParseResponse {
            return .protocolViolation(urlError)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == URLError.badServerResponse.rawValue ||
            nsError.code == URLError.cannotParseResponse.rawValue {
            return .protocolViolation(error)
        }
        return .transport(error)
    }

    nonisolated private func classifyWebSocketFailure(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }
        return .transport(error)
    }

    nonisolated private func classifyWebSocketReadyFailure(
        _ error: Error,
        response: URLResponse?
    ) -> OpenAIAccountGatewayUpstreamFailure {
        if let failure = error as? OpenAIAccountGatewayUpstreamFailure {
            return failure
        }

        if let httpResponse = response as? HTTPURLResponse {
            if let failure = self.failureForHTTPStatus(httpResponse.statusCode) {
                return failure
            }
            if httpResponse.statusCode != 101 {
                return .protocolViolation(error)
            }
        }

        return .transport(error)
    }

    nonisolated private func failureForHTTPStatus(_ statusCode: Int) -> OpenAIAccountGatewayUpstreamFailure? {
        if self.isAccountScopedStatus(statusCode) {
            return .accountStatus(statusCode)
        }
        if (500...599).contains(statusCode) {
            return .upstreamStatus(statusCode)
        }
        return nil
    }

    nonisolated private func isAccountScopedStatus(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403 || statusCode == 429
    }

    nonisolated private func shouldRetry(statusCode: Int) -> Bool {
        switch self.failureForHTTPStatus(statusCode)?.failoverDisposition {
        case .failover?:
            return true
        default:
            return false
        }
    }

    private func resolvedPOSTFailure(from error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let preByteFailure = error as? OpenAIAccountGatewayPreBytePOSTFailure {
            return preByteFailure.failure
        }
        return self.classifyPOSTFailure(error)
    }

    private func routePOSTResponsesCandidates<Success>(
        _ request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute,
        onNoCandidates: () -> Success,
        onSyntheticGatewayFailure: () -> Success,
        consumeResult: (
            _ response: HTTPURLResponse,
            _ bytes: URLSession.AsyncBytes,
            _ account: TokenAccount,
            _ stickyKey: String?,
            _ allowInBandFailover: Bool
        ) async throws -> OpenAIAccountGatewayPOSTAttemptOutcome<Success>
    ) async -> Success {
        let snapshot = self.snapshot()
        let stickyKey = self.stickySessionKey(for: request, route: route)
        let candidates = self.candidates(for: snapshot, stickyKey: stickyKey)
        var usedStickyContextRecovery = false

        guard candidates.isEmpty == false else {
            return onNoCandidates()
        }

        for (index, account) in candidates.enumerated() {
            let canTryNextCandidate = usedStickyContextRecovery == false && index < candidates.count - 1
            do {
                let result = try await self.proxyPOSTResponses(request, account: account, route: route)
                let responseFailure = self.failureForHTTPStatus(result.response.statusCode)
                if let failure = responseFailure {
                    self.reportPOSTFailureDiagnostic(route: route, failure: failure)
                }
                if self.shouldRetry(statusCode: result.response.statusCode) {
                    self.runtimeBlockAccountStatusIfNeeded(
                        statusCode: result.response.statusCode,
                        response: result.response,
                        account: account
                    )
                }
                if self.shouldRetry(statusCode: result.response.statusCode),
                   canTryNextCandidate {
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    continue
                }

                do {
                    let outcome = try await consumeResult(
                        result.response,
                        result.bytes,
                        account,
                        stickyKey,
                        canTryNextCandidate
                    )
                    switch outcome {
                    case .completed(let success, let bindSticky):
                        if self.shouldBindStickyAfterPOSTCompletion(
                            response: result.response,
                            usedStickyContextRecovery: usedStickyContextRecovery,
                            allowsBinding: bindSticky
                        ) {
                            self.bind(stickyKey: stickyKey, accountID: account.accountId)
                        }
                        return success
                    case .retryNextCandidate:
                        continue
                    }
                } catch {
                    let failure = self.resolvedPOSTFailure(from: error)
                    self.reportPOSTFailureDiagnostic(route: route, failure: failure)
                    if case .accountStatus(let statusCode) = failure {
                        self.runtimeBlockAccountStatusIfNeeded(
                            statusCode: statusCode,
                            response: nil,
                            account: account
                        )
                    }
                    if failure.failoverDisposition == .failover,
                       canTryNextCandidate {
                        self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                        continue
                    }
                    if error is OpenAIAccountGatewayPreBytePOSTFailure,
                       self.shouldAttemptStickyContextRecovery(
                            failure: failure,
                            snapshot: snapshot,
                            stickyKey: stickyKey,
                            failedAccountID: account.accountId,
                            candidateIndex: index,
                            candidateCount: candidates.count,
                            usedStickyContextRecovery: usedStickyContextRecovery
                       ) {
                        usedStickyContextRecovery = true
                        continue
                    }
                    return onSyntheticGatewayFailure()
                }
            } catch {
                let failure = self.resolvedPOSTFailure(from: error)
                self.reportPOSTFailureDiagnostic(route: route, failure: failure)
                if case .accountStatus(let statusCode) = failure {
                    self.runtimeBlockAccountStatusIfNeeded(
                        statusCode: statusCode,
                        response: nil,
                        account: account
                    )
                }
                if failure.failoverDisposition == .failover,
                   canTryNextCandidate {
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    continue
                }
                if self.shouldAttemptStickyContextRecovery(
                    failure: failure,
                    snapshot: snapshot,
                    stickyKey: stickyKey,
                    failedAccountID: account.accountId,
                    candidateIndex: index,
                    candidateCount: candidates.count,
                    usedStickyContextRecovery: usedStickyContextRecovery
                ) {
                    usedStickyContextRecovery = true
                    continue
                }
                return onSyntheticGatewayFailure()
            }
        }

        return onSyntheticGatewayFailure()
    }

    private func shouldBindStickyAfterPOSTCompletion(
        response: HTTPURLResponse,
        usedStickyContextRecovery: Bool,
        allowsBinding: Bool
    ) -> Bool {
        guard allowsBinding else { return false }
        guard usedStickyContextRecovery else { return true }
        return self.failureForHTTPStatus(response.statusCode) == nil
    }

    private func reportPOSTFailureDiagnostic(
        route: OpenAIAccountGatewayResponsesRoute,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) {
        self.diagnosticsReporter(self.makePOSTFailureDiagnostic(route: route, failure: failure))
    }

    private func makePOSTFailureDiagnostic(
        route: OpenAIAccountGatewayResponsesRoute,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) -> OpenAIAccountGatewayUpstreamFailureDiagnostic {
        let underlyingError = failure.underlyingError as NSError?
        return OpenAIAccountGatewayUpstreamFailureDiagnostic(
            route: route.diagnosticName,
            failureClass: failure.failureClass,
            statusCode: failure.statusCode,
            errorDomain: underlyingError?.domain,
            errorCode: underlyingError?.code,
            loopbackProxySafeApplied: self.upstreamTransportPolicy.loopbackProxySafeApplied
        )
    }

    private func stream(
        result: (response: HTTPURLResponse, bytes: URLSession.AsyncBytes),
        account: TokenAccount,
        stickyKey: String?,
        to connection: NWConnection,
        allowInBandFailover: Bool,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws -> OpenAIAccountGatewayPOSTDisposition {
        let headers = self.renderResponseHeaders(from: result.response)
        let isEventStream = result.response
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true
        Self.logTiming(
            "upstream_headers",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream
        )
        var didSendHeaders = false
        var didAttemptDownstreamWrite = false
        var totalBytes = 0
        var didWriteBody = false

        var buffer = Data()
        var iterator = result.bytes.makeAsyncIterator()
        while true {
            let nextByte: UInt8?
            do {
                nextByte = try await iterator.next()
            } catch {
                if didAttemptDownstreamWrite == false {
                    throw OpenAIAccountGatewayPreBytePOSTFailure(
                        failure: self.classifyPOSTFailure(error)
                    )
                }
                throw error
            }

            guard let byte = nextByte else { break }
            buffer.append(byte)
            totalBytes += 1
            if didSendHeaders == false {
                switch self.protocolPreviewDecision(
                    buffer: buffer,
                    isEventStream: isEventStream,
                    isFinal: false
                ) {
                case .needMoreData:
                    continue
                case .streamNow:
                    didAttemptDownstreamWrite = true
                    try await self.send(Data(headers.utf8), on: connection)
                    didSendHeaders = true
                case .accountSignal(let signal):
                    self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                    self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                    if allowInBandFailover {
                        return .accountSignal(signal)
                    }
                    didAttemptDownstreamWrite = true
                    try await self.send(Data(headers.utf8), on: connection)
                    didSendHeaders = true
                }
            }
            if buffer.count >= 8192 {
                didAttemptDownstreamWrite = true
                try await self.send(buffer, on: connection)
                if didWriteBody == false {
                    didWriteBody = true
                    Self.logTiming(
                        "first_downstream_body",
                        context: timing,
                        statusCode: result.response.statusCode,
                        isEventStream: isEventStream,
                        bytes: totalBytes
                    )
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }

        var bindSticky = true
        if didSendHeaders == false {
            switch self.protocolPreviewDecision(
                buffer: buffer,
                isEventStream: isEventStream,
                isFinal: true
            ) {
            case .needMoreData, .streamNow:
                didAttemptDownstreamWrite = true
                try await self.send(Data(headers.utf8), on: connection)
                didSendHeaders = true
            case .accountSignal(let signal):
                self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                bindSticky = false
                if allowInBandFailover {
                    return .accountSignal(signal)
                }
                didAttemptDownstreamWrite = true
                try await self.send(Data(headers.utf8), on: connection)
                didSendHeaders = true
            }
        }

        if buffer.isEmpty == false {
            didAttemptDownstreamWrite = true
            try await self.send(buffer, on: connection)
            if didWriteBody == false {
                didWriteBody = true
                Self.logTiming(
                    "first_downstream_body",
                    context: timing,
                    statusCode: result.response.statusCode,
                    isEventStream: isEventStream,
                    bytes: totalBytes
                )
            }
        }

        Self.logTiming(
            "request_completed",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream,
            bytes: totalBytes
        )
        connection.cancel()
        return .streamed(bindSticky: bindSticky)
    }

    private func protocolPreviewDecision(
        buffer: Data,
        isEventStream: Bool,
        isFinal: Bool
    ) -> OpenAIAccountGatewayProtocolPreviewDecision {
        let previewLimit = 64 * 1024
        guard let text = String(data: buffer, encoding: .utf8) else {
            if isFinal || buffer.count >= previewLimit {
                return .streamNow
            }
            return .needMoreData
        }

        if isEventStream {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            let endsWithDelimiter = normalized.hasSuffix("\n\n")
            let components = normalized.components(separatedBy: "\n\n")
            let completeComponents = endsWithDelimiter ? components : Array(components.dropLast())

            if completeComponents.isEmpty {
                if isFinal || buffer.count >= previewLimit {
                    if let signal = self.accountProtocolSignal(in: normalized) {
                        return .accountSignal(signal)
                    }
                    return .streamNow
                }
                return .needMoreData
            }

            for component in completeComponents {
                let payload = self.ssePayload(from: component)
                if let signal = self.accountProtocolSignal(in: payload) {
                    return .accountSignal(signal)
                }
                if self.shouldKeepBufferingSSEPayload(payload) == false {
                    return .streamNow
                }
            }

            if isFinal || buffer.count >= previewLimit {
                return .streamNow
            }
            return .needMoreData
        }

        if isFinal {
            if let signal = self.accountProtocolSignal(in: text) {
                return .accountSignal(signal)
            }
            return .streamNow
        }

        if buffer.count >= previewLimit {
            if let signal = self.accountProtocolSignal(in: text) {
                return .accountSignal(signal)
            }
            return .streamNow
        }

        return .needMoreData
    }

    private func ssePayload(from event: String) -> String {
        let dataLines = event
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                if line.hasPrefix("data:") {
                    return line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }

        if dataLines.isEmpty == false {
            return dataLines.joined(separator: "\n")
        }

        return event.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldKeepBufferingSSEPayload(_ payload: String) -> Bool {
        guard let json = self.jsonObject(from: payload),
              let type = json["type"] as? String else {
            return false
        }

        switch type {
        case "response.created",
             "response.in_progress",
             "response.output_item.added",
             "response.content_part.added":
            return true
        default:
            return false
        }
    }

    private func webSocketMessageText(_ message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    private func webSocketMessageByteCount(_ message: URLSessionWebSocketTask.Message) -> Int {
        switch message {
        case .string(let text):
            return text.utf8.count
        case .data(let data):
            return data.count
        @unknown default:
            return 0
        }
    }

    private func webSocketPreviewDecision(
        afterAppending message: URLSessionWebSocketTask.Message,
        buffered: inout [URLSessionWebSocketTask.Message],
        bufferedBytes: inout Int,
        previewLimitBytes: Int,
        previewLimitMessages: Int
    ) -> OpenAIAccountGatewayWebSocketPreviewDecision? {
        buffered.append(message)
        bufferedBytes += self.webSocketMessageByteCount(message)

        if let text = self.webSocketMessageText(message),
           let signal = self.accountProtocolSignal(in: text) {
            return .accountSignal(signal)
        }

        guard let text = self.webSocketMessageText(message),
              self.shouldKeepBufferingSSEPayload(text),
              bufferedBytes < previewLimitBytes,
              buffered.count < previewLimitMessages else {
            return .forward(buffered)
        }

        return nil
    }

    private func previewBufferedWebSocketMessages(
        _ messages: [URLSessionWebSocketTask.Message],
        previewLimitBytes: Int = 64 * 1024,
        previewLimitMessages: Int = 16
    ) -> OpenAIAccountGatewayWebSocketPreviewDecision {
        var buffered: [URLSessionWebSocketTask.Message] = []
        var bufferedBytes = 0

        for message in messages {
            if let decision = self.webSocketPreviewDecision(
                afterAppending: message,
                buffered: &buffered,
                bufferedBytes: &bufferedBytes,
                previewLimitBytes: previewLimitBytes,
                previewLimitMessages: previewLimitMessages
            ) {
                return decision
            }
        }

        return .forward(buffered)
    }

    private func previewUpstreamWebSocketMessages(
        _ task: URLSessionWebSocketTask,
        previewLimitBytes: Int = 64 * 1024,
        previewLimitMessages: Int = 16
    ) async throws -> OpenAIAccountGatewayWebSocketPreviewDecision {
        var buffered: [URLSessionWebSocketTask.Message] = []
        var bufferedBytes = 0

        while true {
            let message = try await task.receive()
            if let decision = self.webSocketPreviewDecision(
                afterAppending: message,
                buffered: &buffered,
                bufferedBytes: &bufferedBytes,
                previewLimitBytes: previewLimitBytes,
                previewLimitMessages: previewLimitMessages
            ) {
                return decision
            }
        }
    }

    private func accountProtocolSignal(in payload: String) -> OpenAIAccountProtocolSignal? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if let json = self.jsonObject(from: trimmed),
           let signal = self.accountProtocolSignal(in: json, rawText: trimmed) {
            return signal
        }

        if self.isRuntimeLimitSignal(code: nil, errorType: nil, message: trimmed) {
            return OpenAIAccountProtocolSignal(
                message: trimmed,
                retryAt: self.retryAt(fromHumanMessage: trimmed)
            )
        }

        return nil
    }

    private func accountProtocolSignal(
        in object: [String: Any],
        rawText: String
    ) -> OpenAIAccountProtocolSignal? {
        if let signal = self.makeProtocolSignal(
            code: object["code"] as? String,
            errorType: object["type"] as? String,
            message: object["message"] as? String,
            object: object,
            rawText: rawText
        ) {
            return signal
        }

        if let error = object["error"] as? [String: Any],
           let signal = self.makeProtocolSignal(
               code: error["code"] as? String,
               errorType: error["type"] as? String ?? object["type"] as? String,
               message: error["message"] as? String,
               object: error,
               rawText: rawText
           ) {
            return signal
        }

        if let response = object["response"] as? [String: Any] {
            if let signal = self.makeProtocolSignal(
                code: response["code"] as? String,
                errorType: response["type"] as? String ?? object["type"] as? String,
                message: response["message"] as? String,
                object: response,
                rawText: rawText
            ) {
                return signal
            }

            if let error = response["error"] as? [String: Any],
               let signal = self.makeProtocolSignal(
                   code: error["code"] as? String,
                   errorType: error["type"] as? String ?? response["type"] as? String ?? object["type"] as? String,
                   message: error["message"] as? String,
                   object: error,
                   rawText: rawText
               ) {
                return signal
            }
        }

        return nil
    }

    private func makeProtocolSignal(
        code: String?,
        errorType: String?,
        message: String?,
        object: [String: Any],
        rawText: String
    ) -> OpenAIAccountProtocolSignal? {
        guard self.isRuntimeLimitSignal(code: code, errorType: errorType, message: message ?? rawText) else {
            return nil
        }

        let retryAt =
            self.retryAt(fromJSONObject: object) ??
            message.flatMap(self.retryAt(fromHumanMessage:)) ??
            self.retryAt(fromHumanMessage: rawText)
        return OpenAIAccountProtocolSignal(message: message, retryAt: retryAt)
    }

    private func isRuntimeLimitSignal(
        code: String?,
        errorType: String?,
        message: String?
    ) -> Bool {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedType = errorType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if normalizedCode.contains("usage_limit") ||
            normalizedCode.contains("rate_limit") ||
            normalizedCode.contains("insufficient_quota") {
            return true
        }

        if normalizedType.contains("usage_limit") || normalizedType.contains("rate_limit") {
            return true
        }

        if normalizedMessage.contains("usage limit") &&
            (normalizedMessage.contains("hit") || normalizedMessage.contains("reached")) {
            return true
        }

        if normalizedMessage.contains("rate limit") &&
            (normalizedMessage.contains("hit") || normalizedMessage.contains("reached") || normalizedMessage.contains("exceeded")) {
            return true
        }

        return false
    }

    private func retryAt(fromJSONObject object: [String: Any]) -> Date? {
        if let retryAfter = object["retry_after"] as? String {
            return self.retryAt(fromRetryAfterValue: retryAfter)
        }
        if let retryAfter = object["retry_after"] as? Double {
            return Date().addingTimeInterval(retryAfter)
        }
        if let retryAfterSeconds = object["retry_after_seconds"] as? Double {
            return Date().addingTimeInterval(retryAfterSeconds)
        }
        if let resetAt = object["reset_at"] as? TimeInterval {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetsAt = object["resets_at"] as? TimeInterval {
            return Date(timeIntervalSince1970: resetsAt)
        }
        return nil
    }

    private func retryAt(fromHumanMessage message: String) -> Date? {
        let pattern = #"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}(?:st|nd|rd|th)?(?:,\s*\d{4})?\s+\d{1,2}:\d{2}\s*(?:AM|PM)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let matchRange = Range(match.range, in: message) else {
            return nil
        }

        let rawDate = String(message[matchRange])
            .replacingOccurrences(
                of: #"(\d)(st|nd|rd|th)"#,
                with: "$1",
                options: .regularExpression
            )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = rawDate.contains(",")
            ? "MMM d, yyyy h:mm a"
            : "MMM d h:mm a"

        guard let parsed = formatter.date(from: rawDate) else { return nil }
        if rawDate.contains(",") {
            return parsed
        }

        let currentYear = Calendar.current.component(.year, from: Date())
        var components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: parsed)
        components.year = currentYear
        return Calendar.current.date(from: components)
    }

    private func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func renderResponseHeaders(from response: HTTPURLResponse) -> String {
        var lines = ["HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)"]

        for (nameAny, valueAny) in response.allHeaderFields {
            guard let name = nameAny as? String,
                  let value = valueAny as? String else {
                continue
            }
            let lowercased = name.lowercased()
            if lowercased == "content-length" || lowercased == "transfer-encoding" || lowercased == "connection" {
                continue
            }
            lines.append("\(name): \(value)")
        }

        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func makeWebSocketHandshakeResponse(
        for secWebSocketKey: String,
        selectedProtocol: String? = nil
    ) -> String {
        let accept = self.secWebSocketAcceptValue(for: secWebSocketKey)
        var lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
        ]
        if let selectedProtocol,
           selectedProtocol.isEmpty == false {
            lines.append("Sec-WebSocket-Protocol: \(selectedProtocol)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func secWebSocketAcceptValue(for key: String) -> String {
        let value = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
    }

    private func receiveClientWebSocketMessages(
        on connection: NWConnection,
        upstreamTask: URLSessionWebSocketTask,
        buffer: Data,
        fragments: WebSocketFragmentState,
        stickyKey: String?,
        accountID: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task {
                if let error {
                    upstreamTask.cancel(with: .goingAway, reason: nil)
                    self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                    connection.cancel()
                    NSLog("codexbar websocket receive failed: %@", error.localizedDescription)
                    return
                }

                var buffer = buffer
                if let data {
                    buffer.append(data)
                }

                var fragments = fragments
                do {
                    while let frame = try self.parseNextWebSocketFrame(from: &buffer) {
                        try await self.handleClientWebSocketFrame(
                            frame,
                            fragments: &fragments,
                            connection: connection,
                            upstreamTask: upstreamTask,
                            stickyKey: stickyKey,
                            accountID: accountID
                        )
                    }
                } catch {
                    try? await self.send(
                        self.makeWebSocketFrame(
                            opcode: 0x8,
                            payload: self.makeWebSocketClosePayload(code: 1002)
                        ),
                        on: connection
                    )
                    upstreamTask.cancel(with: .protocolError, reason: nil)
                    self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                    connection.cancel()
                    return
                }

                if isComplete {
                    upstreamTask.cancel(with: .goingAway, reason: nil)
                    self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                    connection.cancel()
                    return
                }

                self.receiveClientWebSocketMessages(
                    on: connection,
                    upstreamTask: upstreamTask,
                    buffer: buffer,
                    fragments: fragments,
                    stickyKey: stickyKey,
                    accountID: accountID
                )
            }
        }
    }

    private func receiveRouteTargetWebSocketMessages(
        on connection: NWConnection,
        buffer: Data,
        fragments: WebSocketFragmentState,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task {
                if error != nil {
                    connection.cancel()
                    return
                }

                var buffer = buffer
                if let data {
                    buffer.append(data)
                }

                var fragments = fragments
                do {
                    while let frame = try self.parseNextWebSocketFrame(from: &buffer) {
                        let shouldContinue = try await self.handleRouteTargetWebSocketFrame(
                            frame,
                            fragments: &fragments,
                            connection: connection,
                            routeTarget: routeTarget
                        )
                        if shouldContinue == false {
                            return
                        }
                    }
                } catch {
                    try? await self.send(
                        self.makeWebSocketFrame(
                            opcode: 0x8,
                            payload: self.makeWebSocketClosePayload(code: 1002)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }

                if isComplete {
                    connection.cancel()
                    return
                }

                self.receiveRouteTargetWebSocketMessages(
                    on: connection,
                    buffer: buffer,
                    fragments: fragments,
                    routeTarget: routeTarget
                )
            }
        }
    }

    private func handleRouteTargetWebSocketFrame(
        _ frame: ParsedWebSocketFrame,
        fragments: inout WebSocketFragmentState,
        connection: NWConnection,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async throws -> Bool {
        switch frame.opcode {
        case 0x0:
            guard let fragmentedOpcode = fragments.opcode else {
                throw URLError(.cannotParseResponse)
            }
            fragments.payload.append(frame.payload)
            guard frame.isFinal else { return true }
            let payload = fragments.payload
            fragments = WebSocketFragmentState()
            return try await self.handleCompletedRouteTargetWebSocketPayload(
                opcode: fragmentedOpcode,
                payload: payload,
                connection: connection,
                routeTarget: routeTarget
            )
        case 0x1, 0x2:
            if frame.isFinal {
                return try await self.handleCompletedRouteTargetWebSocketPayload(
                    opcode: frame.opcode,
                    payload: frame.payload,
                    connection: connection,
                    routeTarget: routeTarget
                )
            }
            fragments.opcode = frame.opcode
            fragments.payload = frame.payload
            return true
        case 0x8:
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0x8, payload: frame.payload),
                on: connection
            )
            connection.cancel()
            return false
        case 0x9:
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0xA, payload: frame.payload),
                on: connection
            )
            return true
        case 0xA:
            return true
        default:
            throw URLError(.cannotParseResponse)
        }
    }

    private func handleCompletedRouteTargetWebSocketPayload(
        opcode: UInt8,
        payload: Data,
        connection: NWConnection,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async throws -> Bool {
        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let timing = Self.makeTimingContext(
                route: "responses_ws_bridge",
                target: routeTarget.diagnosticName
            )
            Self.logTiming("request_received", context: timing, extra: "WEBSOCKET")
            let closeCode = try await self.streamRouteTargetWebSocketBridge(
                text: text,
                connection: connection,
                routeTarget: routeTarget,
                timing: timing
            )
            try await self.send(
                self.makeWebSocketFrame(
                    opcode: 0x8,
                    payload: self.makeWebSocketClosePayload(code: closeCode)
                ),
                on: connection
            )
            connection.cancel()
            return false
        case 0x2:
            try await self.send(
                self.makeWebSocketFrame(
                    opcode: 0x8,
                    payload: self.makeWebSocketClosePayload(code: 1003)
                ),
                on: connection
            )
            connection.cancel()
            return false
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func streamRouteTargetWebSocketBridge(
        text: String,
        connection: NWConnection,
        routeTarget: OpenAIAccountGatewayRouteTarget,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws -> UInt16 {
        let result = try await self.proxyRouteTargetPOSTResponses(
            body: Data(text.utf8),
            route: .responses,
            routeTarget: routeTarget
        )
        let isEventStream = result.response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true
        Self.logTiming(
            "upstream_headers",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream
        )

        guard (200...299).contains(result.response.statusCode) else {
            let errorBody = try await self.readAllBytes(from: result.bytes)
            let payload = String(data: errorBody, encoding: .utf8) ?? #"{"error":{"message":"provider upstream error"}}"#
            try await self.send(
                self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                on: connection
            )
            Self.logTiming(
                "request_completed",
                context: timing,
                statusCode: result.response.statusCode,
                isEventStream: isEventStream,
                bytes: errorBody.count,
                extra: "upstream_error"
            )
            return 1011
        }

        if isEventStream {
            var buffer = Data()
            let delimiter = Data("\n\n".utf8)
            var totalBytes = 0
            var eventCount = 0
            var didWriteBody = false

            for try await byte in result.bytes {
                buffer.append(byte)
                totalBytes += 1

                while let range = buffer.range(of: delimiter) {
                    let eventData = buffer.subdata(in: 0..<range.lowerBound)
                    buffer.removeSubrange(0..<range.upperBound)

                    guard let eventText = String(data: eventData, encoding: .utf8) else {
                        continue
                    }
                    let payload = self.ssePayload(from: eventText)
                    guard payload.isEmpty == false else { continue }
                    if payload == "[DONE]" {
                        Self.logTiming(
                            "request_completed",
                            context: timing,
                            statusCode: result.response.statusCode,
                            isEventStream: isEventStream,
                            bytes: totalBytes,
                            events: eventCount,
                            extra: "done"
                        )
                        return 1000
                    }
                    try await self.send(
                        self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                        on: connection
                    )
                    eventCount += 1
                    if didWriteBody == false {
                        didWriteBody = true
                        Self.logTiming(
                            "first_downstream_body",
                            context: timing,
                            statusCode: result.response.statusCode,
                            isEventStream: isEventStream,
                            bytes: totalBytes,
                            events: eventCount
                        )
                    }
                }
            }

            if buffer.isEmpty == false, let eventText = String(data: buffer, encoding: .utf8) {
                let payload = self.ssePayload(from: eventText)
                if payload.isEmpty == false && payload != "[DONE]" {
                    try await self.send(
                        self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                        on: connection
                    )
                    eventCount += 1
                    if didWriteBody == false {
                        didWriteBody = true
                        Self.logTiming(
                            "first_downstream_body",
                            context: timing,
                            statusCode: result.response.statusCode,
                            isEventStream: isEventStream,
                            bytes: totalBytes,
                            events: eventCount
                        )
                    }
                }
            }
            Self.logTiming(
                "request_completed",
                context: timing,
                statusCode: result.response.statusCode,
                isEventStream: isEventStream,
                bytes: totalBytes,
                events: eventCount
            )
            return 1000
        }

        let responseBody = try await self.readAllBytes(from: result.bytes)
        try await self.send(
            self.makeWebSocketFrame(opcode: 0x1, payload: responseBody),
            on: connection
        )
        Self.logTiming(
            "first_downstream_body",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream,
            bytes: responseBody.count
        )
        Self.logTiming(
            "request_completed",
            context: timing,
            statusCode: result.response.statusCode,
            isEventStream: isEventStream,
            bytes: responseBody.count
        )
        return 1000
    }

    private func handleClientWebSocketFrame(
        _ frame: ParsedWebSocketFrame,
        fragments: inout WebSocketFragmentState,
        connection: NWConnection,
        upstreamTask: URLSessionWebSocketTask,
        stickyKey: String?,
        accountID: String
    ) async throws {
        switch frame.opcode {
        case 0x0:
            guard let fragmentedOpcode = fragments.opcode else {
                throw URLError(.cannotParseResponse)
            }
            fragments.payload.append(frame.payload)
            guard frame.isFinal else { return }
            let payload = fragments.payload
            fragments = WebSocketFragmentState()
            try await self.forwardWebSocketMessage(
                opcode: fragmentedOpcode,
                payload: payload,
                upstreamTask: upstreamTask
            )
        case 0x1, 0x2:
            if frame.isFinal {
                try await self.forwardWebSocketMessage(
                    opcode: frame.opcode,
                    payload: frame.payload,
                    upstreamTask: upstreamTask
                )
            } else {
                fragments.opcode = frame.opcode
                fragments.payload = frame.payload
            }
        case 0x8:
            let payload = frame.payload
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0x8, payload: payload),
                on: connection
            )
            upstreamTask.cancel(with: .normalClosure, reason: payload)
            self.clearBinding(stickyKey: stickyKey, accountID: accountID)
            connection.cancel()
        case 0x9:
            try? await self.send(
                self.makeWebSocketFrame(opcode: 0xA, payload: frame.payload),
                on: connection
            )
        case 0xA:
            break
        default:
            throw URLError(.cannotParseResponse)
        }
    }

    private func forwardWebSocketMessage(
        opcode: UInt8,
        payload: Data,
        upstreamTask: URLSessionWebSocketTask
    ) async throws {
        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            try await self.sendUpstreamWebSocketMessage(.string(text), on: upstreamTask)
        case 0x2:
            try await self.sendUpstreamWebSocketMessage(.data(payload), on: upstreamTask)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func sendUpstreamWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func pipeUpstreamMessages(
        upstreamTask: URLSessionWebSocketTask,
        to connection: NWConnection,
        stickyKey: String?,
        accountID: String,
        initialMessages: [URLSessionWebSocketTask.Message] = []
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                for message in initialMessages {
                    try await self.forwardUpstreamWebSocketMessage(
                        message,
                        to: connection,
                        stickyKey: stickyKey,
                        accountID: accountID
                    )
                }
                while true {
                    let message = try await upstreamTask.receive()
                    try await self.forwardUpstreamWebSocketMessage(
                        message,
                        to: connection,
                        stickyKey: stickyKey,
                        accountID: accountID
                    )
                }
            } catch {
                try? await self.send(
                    self.makeWebSocketFrame(
                        opcode: 0x8,
                        payload: self.makeWebSocketClosePayload(code: 1000)
                    ),
                    on: connection
                )
                upstreamTask.cancel(with: .goingAway, reason: nil)
                self.clearBinding(stickyKey: stickyKey, accountID: accountID)
                connection.cancel()
            }
        }
    }

    private func forwardUpstreamWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        to connection: NWConnection,
        stickyKey: String?,
        accountID: String
    ) async throws {
        let frame: Data
        switch message {
        case .string(let text):
            _ = self.handleInBandAccountSignalIfNeeded(
                text: text,
                accountID: accountID,
                stickyKey: stickyKey
            )
            frame = self.makeWebSocketFrame(opcode: 0x1, payload: Data(text.utf8))
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                _ = self.handleInBandAccountSignalIfNeeded(
                    text: text,
                    accountID: accountID,
                    stickyKey: stickyKey
                )
            }
            frame = self.makeWebSocketFrame(opcode: 0x2, payload: data)
        @unknown default:
            frame = self.makeWebSocketFrame(
                opcode: 0x8,
                payload: self.makeWebSocketClosePayload(code: 1011)
            )
        }
        try await self.send(frame, on: connection)
    }

    private func parseNextWebSocketFrame(from buffer: inout Data) throws -> ParsedWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let isFinal = (first & 0x80) != 0
        let reservedBits = first & 0x70
        let opcode = first & 0x0F
        let isMasked = (second & 0x80) != 0

        guard reservedBits == 0 else {
            throw URLError(.cannotParseResponse)
        }
        guard isMasked else {
            throw URLError(.cannotParseResponse)
        }

        var payloadLength = Int(second & 0x7F)
        var cursor = 2

        if payloadLength == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            payloadLength = Int(buffer[cursor]) << 8 | Int(buffer[cursor + 1])
            cursor += 2
        } else if payloadLength == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            let length = buffer[cursor..<(cursor + 8)].reduce(UInt64(0)) { partial, byte in
                (partial << 8) | UInt64(byte)
            }
            guard length <= UInt64(Int.max) else {
                throw URLError(.cannotDecodeRawData)
            }
            payloadLength = Int(length)
            cursor += 8
        }

        if opcode >= 0x8 {
            guard isFinal, payloadLength <= 125 else {
                throw URLError(.cannotParseResponse)
            }
        }

        let maskLength = isMasked ? 4 : 0
        guard buffer.count >= cursor + maskLength + payloadLength else { return nil }

        let mask: [UInt8]
        if isMasked {
            mask = Array(buffer[cursor..<(cursor + 4)])
            cursor += 4
        } else {
            mask = []
        }

        var payload = Data(buffer[cursor..<(cursor + payloadLength)])
        if isMasked {
            for index in payload.indices {
                let offset = payload.distance(from: payload.startIndex, to: index)
                payload[index] ^= mask[offset % 4]
            }
        }

        buffer.removeSubrange(0..<(cursor + payloadLength))
        return ParsedWebSocketFrame(opcode: opcode, payload: payload, isFinal: isFinal)
    }

    private func makeWebSocketFrame(
        opcode: UInt8,
        payload: Data = Data(),
        isFinal: Bool = true
    ) -> Data {
        var frame = Data()
        frame.append((isFinal ? 0x80 : 0x00) | opcode)

        switch payload.count {
        case 0...125:
            frame.append(UInt8(payload.count))
        case 126...65_535:
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }

    private func makeWebSocketClosePayload(code: UInt16) -> Data {
        Data([
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ])
    }

    private func sendJSONResponse(on connection: NWConnection, statusCode: Int, body: String) {
        let data = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)",
            "Content-Type: application/json",
            "Content-Length: \(data.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

#if DEBUG
struct OpenAIAccountGatewayTestResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct OpenAIAccountGatewayWebSocketBridgeProbeResult {
    let events: [String]
    let closeCode: UInt16
}

extension OpenAIAccountGatewayService {
    func currentRoutedAccountIDForTesting() -> String? {
        self.currentRoutedAccountID()
    }

    func runtimeBlockedUntilForTesting(accountID: String) -> Date? {
        self.snapshot().runtimeBlockedUntilByAccountID[accountID]
    }

    func usesDedicatedUpstreamSessionForTesting() -> Bool {
        self.urlSession !== URLSession.shared
    }

    func upstreamTransportConfigurationForTesting() -> OpenAIAccountGatewayUpstreamTransportConfiguration {
        self.upstreamTransportConfiguration
    }

    func upstreamTransportPolicyForTesting() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        self.upstreamTransportPolicy
    }

    func classifyPOSTFailureForTesting(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        self.classifyPOSTFailure(error)
    }

    func upstreamFailureDiagnosticForTesting(
        routePath: String,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) -> OpenAIAccountGatewayUpstreamFailureDiagnostic? {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: routePath) else {
            return nil
        }
        return self.makePOSTFailureDiagnostic(route: route, failure: failure)
    }

    func noteInBandAccountSignalForTesting(
        _ payload: String,
        accountID: String,
        stickyKey: String?
    ) -> Bool {
        self.handleInBandAccountSignalIfNeeded(
            text: payload,
            accountID: accountID,
            stickyKey: stickyKey
        )
    }

    func recoverableResponsesWebSocketPreviewProbeForTesting(
        request: ParsedGatewayRequest,
        messagesByAccountID: [String: [URLSessionWebSocketTask.Message]],
        bindOnSuccess: Bool = false
    ) async throws -> (accountID: String, previewedTexts: [String]) {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["sec-websocket-key"]?.isEmpty == false else {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badURL))
        }

        let stickyKey = self.stickySessionKey(for: request.headers)
        var messagesByAccountID = messagesByAccountID

        while true {
            let established = try await self.routeUpstreamWebSocketCandidate(
                request: request,
                stickyKey: stickyKey
            ) { account, _, _ in
                (
                    messagesByAccountID.removeValue(forKey: account.accountId) ?? [],
                    nil
                )
            }

            switch self.previewBufferedWebSocketMessages(established.task) {
            case .forward(let messages):
                if bindOnSuccess {
                    self.bind(stickyKey: stickyKey, accountID: established.account.accountId)
                }
                return (
                    established.account.accountId,
                    messages.compactMap(self.webSocketMessageText)
                )
            case .accountSignal(let signal):
                self.runtimeBlockAccount(established.account, suggestedRetryAt: signal.retryAt)
                self.clearBinding(stickyKey: stickyKey, accountID: established.account.accountId)
                continue
            }
        }
    }

    func parseRequestForTesting(from data: Data) -> ParsedGatewayRequest? {
        self.parseRequest(from: data)
    }

    func webSocketUpgradeProbeForTesting(
        request: ParsedGatewayRequest
    ) -> OpenAIAccountGatewayTestResponse {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              let secKey = request.headers["sec-websocket-key"],
              secKey.isEmpty == false else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"websocket upgrade headers are missing"}}"#.utf8)
            )
        }

        let snapshot = self.snapshot()
        let stickyKey = self.stickySessionKey(for: request.headers)
        guard let account = self.candidates(for: snapshot, stickyKey: stickyKey).first else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#.utf8)
            )
        }

        self.bind(stickyKey: stickyKey, accountID: account.accountId)
        return OpenAIAccountGatewayTestResponse(
            statusCode: 101,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": self.secWebSocketAcceptValue(for: secKey),
            ],
            body: Data()
        )
    }

    func establishResponsesWebSocketProbeForTesting(
        request: ParsedGatewayRequest,
        bindOnSuccess: Bool = false,
        attempt: (_ account: TokenAccount, _ requestedProtocol: String?, _ readyBudget: TimeInterval) async throws
            -> String?
    ) async throws -> (accountID: String, selectedProtocol: String?) {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["sec-websocket-key"]?.isEmpty == false else {
            throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badURL))
        }

        let stickyKey = self.stickySessionKey(for: request.headers)
        let established = try await self.routeUpstreamWebSocketCandidate(
            request: request,
            stickyKey: stickyKey
        ) { account, requestedProtocol, readyBudget in
            let selectedProtocol = try await attempt(account, requestedProtocol, readyBudget)
            return ((), selectedProtocol)
        }

        if bindOnSuccess {
            self.bind(stickyKey: stickyKey, accountID: established.account.accountId)
        }

        return (established.account.accountId, established.selectedProtocol)
    }

    func postResponsesProbeForTesting(
        request: ParsedGatewayRequest
    ) async throws -> OpenAIAccountGatewayTestResponse {
        try await self.bufferedResponsesRequestForTesting(request)
    }

    func routeTargetWebSocketBridgeProbeForTesting(
        _ text: String
    ) async throws -> OpenAIAccountGatewayWebSocketBridgeProbeResult {
        try await self.collectRouteTargetWebSocketBridgeProbe(
            text: text,
            routeTarget: self.snapshot().routeTarget
        )
    }

    func postResponsesConsumeFailureProbeForTesting(
        request: ParsedGatewayRequest,
        failure: Error
    ) async -> OpenAIAccountGatewayTestResponse {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: request.path) else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"not found"}}"#.utf8)
            )
        }

        return await self.routePOSTResponsesCandidates(
            request,
            route: route,
            onNoCandidates: {
                OpenAIAccountGatewayTestResponse(
                    statusCode: 503,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#.utf8)
                )
            },
            onSyntheticGatewayFailure: {
                OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
                )
            }
        ) { _, _, _, _, _ in
            throw failure
        }
    }

    private func bufferedResponsesRequestForTesting(
        _ request: ParsedGatewayRequest
    ) async throws -> OpenAIAccountGatewayTestResponse {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: request.path) else {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"not found"}}"#.utf8)
            )
        }

        let snapshot = self.snapshot()
        if self.requiresLocalAuthorization(snapshot.routeTarget),
           self.isLocallyAuthorized(request: request, snapshot: snapshot) == false {
            return OpenAIAccountGatewayTestResponse(
                statusCode: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"codexbar gateway unauthorized"}}"#.utf8)
            )
        }

        switch snapshot.routeTarget {
        case .compatibleProvider(let target):
            let result = try await self.proxyProviderPOSTResponses(request, route: route, target: target)
            let body = try await self.readAllBytesForTesting(from: result.bytes)
            return OpenAIAccountGatewayTestResponse(
                statusCode: result.response.statusCode,
                headers: self.responseHeadersForTesting(from: result.response),
                body: body
            )
        case .openRouter(let target):
            let result = try await self.proxyOpenRouterPOSTResponses(request, route: route, target: target)
            let body = try await self.readAllBytesForTesting(from: result.bytes)
            return OpenAIAccountGatewayTestResponse(
                statusCode: result.response.statusCode,
                headers: self.responseHeadersForTesting(from: result.response),
                body: body
            )
        case .none, .openAIAggregate:
            break
        }

        return await self.routePOSTResponsesCandidates(
            request,
            route: route,
            onNoCandidates: {
                OpenAIAccountGatewayTestResponse(
                    statusCode: 503,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"aggregate gateway unavailable: no routable OpenAI account"}}"#.utf8)
                )
            },
            onSyntheticGatewayFailure: {
                OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
                )
            }
        ) { response, bytes, account, stickyKey, allowInBandFailover in
            let body = try await self.readAllBytesForTesting(from: bytes)
            if let signal = self.accountProtocolSignal(in: String(data: body, encoding: .utf8) ?? "") {
                self.runtimeBlockAccount(account, suggestedRetryAt: signal.retryAt)
                self.clearBinding(stickyKey: stickyKey, accountID: account.accountId)
                if allowInBandFailover {
                    return .retryNextCandidate
                }
                return .completed(
                    OpenAIAccountGatewayTestResponse(
                        statusCode: 429,
                        headers: ["Content-Type": "application/json", "Connection": "close"],
                        body: Data(
                            self.gatewayErrorBody(
                                message: signal.message ?? "You've hit your usage limit."
                            ).utf8
                        )
                    ),
                    bindSticky: false
                )
            }

            return .completed(
                OpenAIAccountGatewayTestResponse(
                    statusCode: response.statusCode,
                    headers: self.responseHeadersForTesting(from: response),
                    body: body
                ),
                bindSticky: true
            )
        }
    }

    private func collectRouteTargetWebSocketBridgeProbe(
        text: String,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async throws -> OpenAIAccountGatewayWebSocketBridgeProbeResult {
        let result = try await self.proxyRouteTargetPOSTResponses(
            body: Data(text.utf8),
            route: .responses,
            routeTarget: routeTarget
        )

        guard (200...299).contains(result.response.statusCode) else {
            let errorBody = try await self.readAllBytesForTesting(from: result.bytes)
            let payload = String(data: errorBody, encoding: .utf8) ?? #"{"error":{"message":"provider upstream error"}}"#
            return OpenAIAccountGatewayWebSocketBridgeProbeResult(events: [payload], closeCode: 1011)
        }

        if result.response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            let events = try await self.collectSSEEventsForTesting(from: result.bytes)
            if let last = events.last, last == "[DONE]" {
                return OpenAIAccountGatewayWebSocketBridgeProbeResult(
                    events: Array(events.dropLast()),
                    closeCode: 1000
                )
            }
            return OpenAIAccountGatewayWebSocketBridgeProbeResult(events: events, closeCode: 1000)
        }

        let responseBody = try await self.readAllBytesForTesting(from: result.bytes)
        let payload = String(data: responseBody, encoding: .utf8) ?? "{}"
        return OpenAIAccountGatewayWebSocketBridgeProbeResult(events: [payload], closeCode: 1000)
    }

    private func collectSSEEventsForTesting(from bytes: URLSession.AsyncBytes) async throws -> [String] {
        var buffer = Data()
        var events: [String] = []
        let delimiter = Data("\n\n".utf8)

        for try await byte in bytes {
            buffer.append(byte)

            while let range = buffer.range(of: delimiter) {
                let eventData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)

                guard let eventText = String(data: eventData, encoding: .utf8) else {
                    continue
                }
                let payload = self.ssePayload(from: eventText)
                guard payload.isEmpty == false else { continue }
                events.append(payload)
            }
        }

        if buffer.isEmpty == false, let eventText = String(data: buffer, encoding: .utf8) {
            let payload = self.ssePayload(from: eventText)
            if payload.isEmpty == false {
                events.append(payload)
            }
        }

        return events
    }

    private func responseHeadersForTesting(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (nameAny, valueAny) in response.allHeaderFields {
            guard let name = nameAny as? String,
                  let value = valueAny as? String else {
                continue
            }
            let lowercased = name.lowercased()
            if lowercased == "content-length" || lowercased == "transfer-encoding" || lowercased == "connection" {
                continue
            }
            headers[name] = value
        }
        headers["Connection"] = "close"
        return headers
    }

    private func gatewayErrorBody(message: String) -> String {
        let payload: [String: Any] = ["error": ["message": message]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else {
            return #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
        }
        return body
    }

    private func readAllBytesForTesting(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        var iterator = bytes.makeAsyncIterator()
        while true {
            let nextByte: UInt8?
            do {
                nextByte = try await iterator.next()
            } catch {
                if data.isEmpty {
                    throw OpenAIAccountGatewayPreBytePOSTFailure(
                        failure: self.classifyPOSTFailure(error)
                    )
                }
                throw error
            }

            guard let byte = nextByte else { break }
            data.append(byte)
        }
        return data
    }
}
#endif
