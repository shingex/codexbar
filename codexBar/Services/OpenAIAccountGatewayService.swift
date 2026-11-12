import CFNetwork
import CryptoKit
import Foundation
import Network

extension Notification.Name {
    static let openAIAccountGatewayDidRouteAccount = Notification.Name(
        "lzl.codexbar.openai-gateway.did-route-account"
    )
    static let openAIAccountGatewayReasoningRetryGuardDidUpdate = Notification.Name(
        "lzl.codexbar.openai-gateway.reasoning-retry-guard.did-update"
    )
}

struct OpenAIAccountGatewayReasoningRetryGuardConfiguration: Equatable {
    var isEnabled: Bool
    var matchMode: CodexBarOpenAISettings.ReasoningRetryGuardMatchMode
    var reasoningEquals: Set<Int>
    var interceptStreaming: Bool
    var interceptNonStreaming: Bool
    var routeTargetRetryAttempts: Int
    var retryableStatusCodes: Set<Int>
    var retryUpstreamCapacityErrors: Bool
    var nonStreamStatusCode: Int
    var streamAction: CodexBarOpenAISettings.ReasoningRetryStreamAction
    var logMatch: Bool
    var endpoints: [String]

    static let disabled = Self(settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings(
        routeTargetRetryAttempts: 0, retryUpstreamCapacityErrors: false
    ))

    init(settings: CodexBarOpenAISettings.ReasoningRetryGuardSettings) {
        self.isEnabled = settings.isEnabled
        self.matchMode = settings.matchMode
        self.reasoningEquals = Set(settings.reasoningEquals)
        self.interceptStreaming = settings.interceptStreaming
        self.interceptNonStreaming = settings.interceptNonStreaming
        self.routeTargetRetryAttempts = settings.routeTargetRetryAttempts
        self.retryableStatusCodes = Set(settings.retryableStatusCodes)
        self.retryUpstreamCapacityErrors = settings.retryUpstreamCapacityErrors
        self.nonStreamStatusCode = settings.nonStreamStatusCode
        self.streamAction = settings.streamAction
        self.logMatch = settings.logMatch
        self.endpoints = settings.endpoints
    }
}

struct OpenAIAccountGatewayReasoningRetryGuardMetrics: Equatable {
    var startedAt: Date
    var totalProxyRequestCount: Int
    var inspectedResponseCount: Int
    var matchedResponseCount: Int
    var matchedStreamingCount: Int
    var matchedNonStreamingCount: Int
    var blockedResponseCount: Int
    var blockedStreamingCount: Int
    var blockedNonStreamingCount: Int
    var observedReasoningCounts: [Int: Int]

    init(
        startedAt: Date = Date(),
        totalProxyRequestCount: Int = 0,
        inspectedResponseCount: Int = 0,
        matchedResponseCount: Int = 0,
        matchedStreamingCount: Int = 0,
        matchedNonStreamingCount: Int = 0,
        blockedResponseCount: Int = 0,
        blockedStreamingCount: Int = 0,
        blockedNonStreamingCount: Int = 0,
        observedReasoningCounts: [Int: Int] = [:]
    ) {
        self.startedAt = startedAt
        self.totalProxyRequestCount = totalProxyRequestCount
        self.inspectedResponseCount = inspectedResponseCount
        self.matchedResponseCount = matchedResponseCount
        self.matchedStreamingCount = matchedStreamingCount
        self.matchedNonStreamingCount = matchedNonStreamingCount
        self.blockedResponseCount = blockedResponseCount
        self.blockedStreamingCount = blockedStreamingCount
        self.blockedNonStreamingCount = blockedNonStreamingCount
        self.observedReasoningCounts = observedReasoningCounts
    }

    var reasoning516Count: Int {
        self.observedReasoningCounts[516, default: 0]
    }

    var reasoning516Ratio: Double {
        guard self.inspectedResponseCount > 0 else { return 0 }
        return Double(self.reasoning516Count) / Double(self.inspectedResponseCount)
    }

    var blockedResponseRatio: Double {
        guard self.inspectedResponseCount > 0 else { return 0 }
        return Double(self.blockedResponseCount) / Double(self.inspectedResponseCount)
    }
}

enum OpenAIAccountGatewayReasoningRetryGuardLogKind: Equatable {
    case configuration
    case interception
    case retry
}

enum OpenAIAccountGatewayRetryLogResult: Equatable {
    case retrying
    case succeeded
    case failed
}

struct OpenAIAccountGatewayReasoningRetryGuardLogEntry: Identifiable, Equatable {
    let id: Int
    let recordedAt: Date
    let kind: OpenAIAccountGatewayReasoningRetryGuardLogKind
    let batchID: String?
    let retryCount: Int
    let retryResult: OpenAIAccountGatewayRetryLogResult?
    let message: String
}

struct OpenAIAccountGatewayReasoningRetryGuardSnapshot: Equatable {
    var configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    var metrics: OpenAIAccountGatewayReasoningRetryGuardMetrics
    var logEntries: [OpenAIAccountGatewayReasoningRetryGuardLogEntry]

    static let empty = Self(
        configuration: .disabled,
        metrics: OpenAIAccountGatewayReasoningRetryGuardMetrics(),
        logEntries: []
    )
}

struct SSEEventStreamAccumulator {
    private var buffer: [UInt8] = []
    var bufferedByteCount: Int { self.buffer.count }

    init() {
        self.buffer.reserveCapacity(4096)
    }

    mutating func append(_ byte: UInt8) -> Data? {
        self.buffer.append(byte)
        guard self.hasEventDelimiter else {
            return nil
        }

        let eventChunk = Data(self.buffer)
        self.buffer.removeAll(keepingCapacity: true)
        return eventChunk
    }

    mutating func flush() -> Data? {
        guard self.buffer.isEmpty == false else {
            return nil
        }
        let remaining = Data(self.buffer)
        self.buffer.removeAll(keepingCapacity: true)
        return remaining
    }

    mutating func append(contentsOf data: Data) -> [Data] {
        guard data.isEmpty == false else { return [] }

        self.buffer.append(contentsOf: data)
        var eventChunks: [Data] = []

        while let delimiterRange = self.firstEventDelimiterRange() {
            eventChunks.append(Data(self.buffer[0..<delimiterRange.upperBound]))
            self.buffer.removeSubrange(0..<delimiterRange.upperBound)
        }

        return eventChunks
    }

    private var hasEventDelimiter: Bool {
        let count = self.buffer.count
        if count >= 2,
           self.buffer[count - 2] == 0x0A,
           self.buffer[count - 1] == 0x0A {
            return true
        }
        if count >= 4,
           self.buffer[count - 4] == 0x0D,
           self.buffer[count - 3] == 0x0A,
           self.buffer[count - 2] == 0x0D,
           self.buffer[count - 1] == 0x0A {
            return true
        }
        return false
    }

    private func firstEventDelimiterRange() -> Range<Int>? {
        let count = self.buffer.count
        guard count >= 2 else { return nil }

        var index = 0
        while index < count {
            if index + 1 < count,
               self.buffer[index] == 0x0A,
               self.buffer[index + 1] == 0x0A {
                return index..<(index + 2)
            }
            if index + 3 < count,
               self.buffer[index] == 0x0D,
               self.buffer[index + 1] == 0x0A,
               self.buffer[index + 2] == 0x0D,
               self.buffer[index + 3] == 0x0A {
                return index..<(index + 4)
            }
            index += 1
        }
        return nil
    }
}

private struct OpenAIAccountGatewayHTTPStream {
    let response: HTTPURLResponse
    let chunks: AsyncThrowingStream<Data, Error>
}

private protocol OpenAIAccountGatewayHTTPStreamingClient: AnyObject {
    nonisolated func stream(
        for request: URLRequest,
        transportConfigurationOverride: OpenAIAccountGatewayUpstreamTransportConfiguration?
    ) async throws -> OpenAIAccountGatewayHTTPStream
}

private enum OpenAIAccountGatewayStreamStartRetry {
    nonisolated static func shouldRetry(error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain &&
            (error.code == URLError.cannotConnectToHost.rawValue || error.code == URLError.cannotFindHost.rawValue)
    }
}

private final class OpenAIAccountGatewayURLSessionChunkStreamingClient: OpenAIAccountGatewayHTTPStreamingClient {
    private let transportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration
    private let reusesSession: Bool
    private let poolLock = NSLock()
    private var pooledSession: URLSession?
    private var pooledPolicy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy?

    nonisolated init(transportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration, reusesSession: Bool = false) {
        self.transportConfiguration = transportConfiguration
        self.reusesSession = reusesSession
    }

    deinit { self.pooledSession?.invalidateAndCancel() }

    nonisolated private func reusableSession(
        configuration: URLSessionConfiguration, policy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    ) -> URLSession {
        self.poolLock.withGatewayLock {
            if self.pooledPolicy == policy, let session = self.pooledSession { return session }
            self.pooledSession?.finishTasksAndInvalidate()
            let session = URLSession(configuration: configuration)
            self.pooledPolicy = policy
            self.pooledSession = session
            return session
        }
    }

    nonisolated func stream(
        for request: URLRequest,
        transportConfigurationOverride: OpenAIAccountGatewayUpstreamTransportConfiguration?
    ) async throws -> OpenAIAccountGatewayHTTPStream {
        let resolved = (transportConfigurationOverride ?? self.transportConfiguration)
            .resolvedURLSessionConfiguration(for: request.url)
        let configuration = resolved.configuration

        let maxAttempts = (transportConfigurationOverride ?? self.transportConfiguration).streamStartMaxAttempts
        var lastError: Error?
        for attempt in 1...maxAttempts {
            try GatewayCapacityRetryPolicy.requestBudget?.consume()
            let delegate = OpenAIAccountGatewayHTTPChunkStreamDelegate()
            let session = self.reusesSession
                ? self.reusableSession(configuration: configuration, policy: resolved.policy)
                : URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let stream = delegate.makeStream()
            let task = session.dataTask(with: request)
            if self.reusesSession { task.delegate = delegate }
            delegate.attach(session: session, task: task, ownsSession: !self.reusesSession)
            task.resume()

            do {
                let response = try await withTaskCancellationHandler {
                    try await delegate.awaitResponse()
                } onCancel: { delegate.cancelStream() }
                return OpenAIAccountGatewayHTTPStream(response: response, chunks: stream)
            } catch {
                task.cancel()
                if !self.reusesSession { session.invalidateAndCancel() }
                lastError = error
                guard attempt < maxAttempts,
                      OpenAIAccountGatewayStreamStartRetry.shouldRetry(error: error) else {
                    throw error
                }
                NSLog("codexbar OpenAI gateway retrying upstream stream start url=%@ attempt=%ld", request.url?.absoluteString ?? "", attempt)
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }
}

private final class OpenAIAccountGatewayURLSessionAsyncBytesStreamingClient: OpenAIAccountGatewayHTTPStreamingClient {
    private let urlSession: URLSession

    nonisolated init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    nonisolated func stream(
        for request: URLRequest,
        transportConfigurationOverride: OpenAIAccountGatewayUpstreamTransportConfiguration?
    ) async throws -> OpenAIAccountGatewayHTTPStream {
        var request = request
        if let transportConfigurationOverride {
            request.timeoutInterval = transportConfigurationOverride.requestTimeout
        }
        let maxAttempts = transportConfigurationOverride?.streamStartMaxAttempts ?? 2
        var lastError: Error?
        for attempt in 1...maxAttempts {
            try GatewayCapacityRetryPolicy.requestBudget?.consume()
            do {
                let (bytes, response) = try await self.urlSession.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIAccountGatewayUpstreamFailure.protocolViolation(URLError(.badServerResponse))
                }

                let chunks = AsyncThrowingStream<Data, Error> { continuation in
                    let task = Task {
                        do {
                            for try await byte in bytes {
                                continuation.yield(Data([byte]))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                    }
                }
                return OpenAIAccountGatewayHTTPStream(response: httpResponse, chunks: chunks)
            } catch {
                lastError = error
                guard attempt < maxAttempts,
                      OpenAIAccountGatewayStreamStartRetry.shouldRetry(error: error) else {
                    throw error
                }
                NSLog("codexbar OpenAI gateway retrying upstream stream start url=%@ attempt=%ld", request.url?.absoluteString ?? "", attempt)
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }
}

private final class GatewayHTTPStreamLease {
    let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { self.cancel() }
}

private final class OpenAIAccountGatewayHTTPChunkStreamDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var session: URLSession?
    private var ownsSession = true
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var responseResult: Result<HTTPURLResponse, Error>?
    private var nextContinuation: CheckedContinuation<Data?, Error>?
    private var chunks: [Data] = []
    private var bufferedBytes = 0
    private var suspended = false
    private var completed = false
    private var completionError: Error?
    private let highWaterMark = 2 * 1_024 * 1_024
    private let lowWaterMark = 1_024 * 1_024

    nonisolated func attach(session: URLSession, task: URLSessionDataTask, ownsSession: Bool = true) {
        self.lock.withGatewayLock { self.session = session; self.task = task; self.ownsSession = ownsSession }
    }

    nonisolated func makeStream() -> AsyncThrowingStream<Data, Error> {
        let lease = GatewayHTTPStreamLease { [weak self] in self?.cancelStream() }
        return AsyncThrowingStream(unfolding: { [lease] in
            defer { withExtendedLifetime(lease) {} }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await self.nextChunk()
            } onCancel: { self.cancelStream() }
        })
    }

    nonisolated func awaitResponse() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let result = self.lock.withGatewayLock { () -> Result<HTTPURLResponse, Error>? in
                if let responseResult { return responseResult }
                self.responseContinuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    nonisolated private func nextChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if !self.chunks.isEmpty {
                let chunk = self.chunks.removeFirst()
                self.bufferedBytes -= chunk.count
                if self.suspended && self.bufferedBytes <= self.lowWaterMark {
                    self.suspended = false
                    self.task?.resume()
                }
                self.lock.unlock()
                continuation.resume(returning: chunk)
            } else if self.completed {
                let error = self.completionError
                self.lock.unlock()
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: nil) }
            } else {
                self.nextContinuation = continuation
                self.lock.unlock()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            self.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        self.lock.lock()
        guard !self.completed else { self.lock.unlock(); completionHandler(.cancel); return }
        self.responseResult = .success(response)
        let continuation = self.responseContinuation
        self.responseContinuation = nil
        self.lock.unlock()
        continuation?.resume(returning: response)
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        self.lock.lock()
        guard !self.completed else { self.lock.unlock(); return }
        let continuation = self.nextContinuation
        self.nextContinuation = nil
        if continuation == nil {
            self.chunks.append(data)
            self.bufferedBytes += data.count
            if self.bufferedBytes >= self.highWaterMark && !self.suspended {
                self.suspended = true
                dataTask.suspend()
            }
        }
        self.lock.unlock()
        continuation?.resume(returning: data)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.finish(throwing: error)
    }

    nonisolated private func finish(throwing error: Error?) {
        self.lock.lock()
        guard !self.completed else { self.lock.unlock(); return }
        self.completed = true
        self.completionError = error
        if self.responseResult == nil { self.responseResult = .failure(error ?? URLError(.badServerResponse)) }
        let response = self.responseContinuation
        self.responseContinuation = nil
        let next = self.nextContinuation
        self.nextContinuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        self.lock.unlock()
        response?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error { next?.resume(throwing: error) } else { next?.resume(returning: nil) }
        if self.ownsSession { session?.finishTasksAndInvalidate() }
    }

    nonisolated func cancelStream() {
        let pair = self.lock.withGatewayLock { (self.task, self.session) }
        self.finish(throwing: CancellationError())
        pair.0?.cancel()
        if self.ownsSession { pair.1?.invalidateAndCancel() }
    }
}

private extension NSLock {
    nonisolated func withGatewayLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        self.lock()
        defer { self.unlock() }
        return try body()
    }
}


protocol OpenAIAccountGatewayControlling: AnyObject {
    func startIfNeeded()
    func stop()
    func updateState(
        accounts: [TokenAccount],
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        routeTarget: OpenAIAccountGatewayRouteTarget
    )
    func updateModelRoutingState(accounts: [TokenAccount],
        accountUsageMode: CodexBarOpenAIAccountUsageMode, routeTarget: OpenAIAccountGatewayRouteTarget,
        enabled: Bool, openAIModelID: String?)
    func setModelRoutingEnabled(_ enabled: Bool, openAIModelID: String?)
    func setGatewayPromptPatchConfiguration(_ settings: CodexBarOpenAISettings.GatewayPromptPatchSettings)
    func setReasoningRetryGuardConfiguration(_ configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration)
    func reasoningRetryGuardSnapshot() -> OpenAIAccountGatewayReasoningRetryGuardSnapshot
    func currentRoutedAccountID() -> String?
}

extension OpenAIAccountGatewayControlling {
    func updateModelRoutingState(accounts: [TokenAccount],
        accountUsageMode: CodexBarOpenAIAccountUsageMode, routeTarget: OpenAIAccountGatewayRouteTarget,
        enabled: Bool, openAIModelID: String?) {
        self.updateState(accounts: accounts, accountUsageMode: accountUsageMode, routeTarget: routeTarget)
        self.setModelRoutingEnabled(enabled, openAIModelID: openAIModelID)
    }

    func setModelRoutingEnabled(_: Bool, openAIModelID: String?) {}
    func setGatewayPromptPatchConfiguration(_: CodexBarOpenAISettings.GatewayPromptPatchSettings) {}
    func setReasoningRetryGuardConfiguration(_: OpenAIAccountGatewayReasoningRetryGuardConfiguration) {}
    func reasoningRetryGuardSnapshot() -> OpenAIAccountGatewayReasoningRetryGuardSnapshot { .empty }
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
    static let upstreamModelsURL = URL(string: "https://chatgpt.com/backend-api/codex/models")!

    static var baseURLString: String {
        "http://\(self.clientHost):\(self.port)/v1"
    }
}

enum OpenAIAccountGatewayRouteTarget: Equatable {
    case none
    case openAIAccount(accountID: String)
    case compatibleProvider(CompatibleProvider)
    case openRouter(OpenRouter)

    struct CompatibleProvider: Equatable {
        var providerID: String
        var providerLabel: String
        var baseURL: String
        var accountID: String
        var apiKey: String
        var modelID: String
        var thirdPartyModelProvider: CodexBarThirdPartyModelProvider?
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
        case .openAIAccount, .compatibleProvider, .openRouter:
            return true
        }
    }

    var diagnosticName: String {
        switch self {
        case .none:
            return "none"
        case .openAIAccount:
            return "openai_account"
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
    var upstreamModelsURL: URL = OpenAIAccountGatewayConfiguration.upstreamModelsURL

    static let live = OpenAIAccountGatewayRuntimeConfiguration(
        host: OpenAIAccountGatewayConfiguration.listenHost,
        port: OpenAIAccountGatewayConfiguration.port,
        upstreamResponsesURL: OpenAIAccountGatewayConfiguration.upstreamResponsesURL,
        upstreamResponsesCompactURL: OpenAIAccountGatewayConfiguration.upstreamResponsesCompactURL,
        upstreamModelsURL: OpenAIAccountGatewayConfiguration.upstreamModelsURL
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
        Self.isLoopbackHost(self.host)
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalizedHost = host
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

    var diagnosticSummary: String {
        let entries = [
            self.http.map { "http=\($0.host):\($0.port)" },
            self.https.map { "https=\($0.host):\($0.port)" },
            self.socks.map { "socks=\($0.host):\($0.port)" },
        ].compactMap { $0 }
        return entries.isEmpty ? "none" : entries.joined(separator: ",")
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
    var streamStartMaxAttempts: Int = 2
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

    static let official = OpenAIAccountGatewayUpstreamTransportConfiguration(
        requestTimeout: 300, resourceTimeout: 604_800, webSocketReadyBudget: 8, waitsForConnectivity: false
    ).withoutStreamStartRetry()

    private func withoutStreamStartRetry() -> Self {
        var copy = self
        copy.streamStartMaxAttempts = 1
        return copy
    }

    static let live = OpenAIAccountGatewayUpstreamTransportConfiguration(
        requestTimeout: 30,
        resourceTimeout: 120,
        webSocketReadyBudget: 8,
        waitsForConnectivity: false
    )

    static let routeTargetResponses = OpenAIAccountGatewayUpstreamTransportConfiguration(
        requestTimeout: 60,
        resourceTimeout: 200,
        webSocketReadyBudget: 12,
        waitsForConnectivity: false
    ).withoutStreamStartRetry()

    static let routeTargetCompact = OpenAIAccountGatewayUpstreamTransportConfiguration(
        requestTimeout: 180,
        resourceTimeout: 600,
        webSocketReadyBudget: 30,
        waitsForConnectivity: false
    ).withoutStreamStartRetry()

    nonisolated func makeURLSessionConfiguration() -> URLSessionConfiguration {
        self.resolvedURLSessionConfiguration().configuration
    }

    nonisolated func resolvedTransportPolicy() -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        OpenAIAccountGatewayResolvedUpstreamTransportPolicy.resolve(
            proxyResolutionMode: self.proxyResolutionMode,
            systemProxySnapshot: self.proxySnapshotProvider()
        )
    }

    nonisolated func resolvedURLSessionConfiguration() -> (
        configuration: URLSessionConfiguration,
        policy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    ) {
        self.resolvedURLSessionConfiguration(for: nil)
    }

    nonisolated func resolvedURLSessionConfiguration(for upstreamURL: URL?) -> (
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
        let policy = self.resolvedTransportPolicy(for: upstreamURL)
        if let connectionProxyDictionary = policy.connectionProxyDictionary {
            configuration.connectionProxyDictionary = connectionProxyDictionary
        }
        return (configuration, policy)
    }

    nonisolated func resolvedTransportPolicy(for upstreamURL: URL?) -> OpenAIAccountGatewayResolvedUpstreamTransportPolicy {
        guard let upstreamURL else {
            return self.resolvedTransportPolicy()
        }
        guard self.proxyResolutionMode == .loopbackProxySafe,
              OpenAIAccountGatewaySystemProxyEndpoint.isLoopbackHost(upstreamURL.host) == false else {
            return self.resolvedTransportPolicy()
        }

        return OpenAIAccountGatewayResolvedUpstreamTransportPolicy.resolve(
            proxyResolutionMode: .systemDefault,
            systemProxySnapshot: self.proxySnapshotProvider()
        )
    }
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
    let target: String
    let upstreamHost: String?
    let upstreamPath: String?
    let failureClass: OpenAIAccountGatewayFailureClass
    let statusCode: Int?
    let errorDomain: String?
    let errorCode: Int?
    let loopbackProxySafeApplied: Bool
    let systemProxySummary: String?
    let effectiveProxySummary: String?
}

private struct OpenAIAccountGatewaySnapshot {
    var accounts: [TokenAccount]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var modelRoutingEnabled: Bool
    var modelRoutingOpenAIModelID: String?
    var routeTarget: OpenAIAccountGatewayRouteTarget
}

private struct OpenAIAccountGatewayReasoningGuardMatch: Equatable {
    let reasoningTokens: Int
    let evidence: [String]
}

private struct OpenAIAccountGatewayReasoningGuardAssessment: Equatable {
    let reasoningTokens: Int
    let evidence: [String]

    var shouldMatch: Bool {
        self.evidence.isEmpty == false
    }

    var match: OpenAIAccountGatewayReasoningGuardMatch {
        OpenAIAccountGatewayReasoningGuardMatch(
            reasoningTokens: self.reasoningTokens,
            evidence: self.evidence
        )
    }
}

private struct OpenAIAccountGatewayRouteTargetBufferedResponse {
    let response: HTTPURLResponse
    let body: Data
    let isEventStream: Bool
    let totalBytes: Int
    let guardMatch: OpenAIAccountGatewayReasoningGuardMatch?
    let shouldBlockGuardMatch: Bool
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
    var headers: [String: String]
    var body: Data
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

enum OpenAIAccountGatewayResponsesRoute: Equatable {
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

    var requestPath: String {
        switch self {
        case .responses:
            return "/v1/responses"
        case .compact:
            return "/v1/responses/compact"
        }
    }

    var retryGuardEndpointAliases: [String] {
        switch self {
        case .responses:
            return ["/responses", "/v1/responses", "/backend-api/codex/responses", "/openai/v1/responses"]
        case .compact:
            return [
                "/responses/compact",
                "/v1/responses/compact",
                "/backend-api/codex/responses/compact",
                "/openai/v1/responses/compact",
            ]
        }
    }
}

enum OpenAIAccountGatewayModelsRoute: Equatable {
    case models

    init?(requestPath: String) {
        switch Self.normalizedPath(from: requestPath) {
        case "/v1/models",
             "/models",
             "/backend-api/codex/models",
             "/openai/v1/models":
            self = .models
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
}

final class OpenAIAccountGatewayService: OpenAIAccountGatewayControlling {
    static let shared = OpenAIAccountGatewayService()
    nonisolated static let mockRequestBodyPropertyKey = "codexbar.mockRequestBody"
    private nonisolated static let timingLogPrefix = "codexbar gateway timing"
    private nonisolated static let thirdPartyCustomToolNames: Set<String> = [
        "apply_patch",
        "exec",
    ]
    private nonisolated static let maxReasoningRetryGuardLogEntries = 200

    private let listenerQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.listener")
    private let stateQueue = DispatchQueue(label: "lzl.codexbar.openai-gateway.state")
    private let urlSession: URLSession
    private let officialStreamingClient: OpenAIAccountGatewayHTTPStreamingClient
    private let httpStreamingClient: OpenAIAccountGatewayHTTPStreamingClient
    private let upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration
    private let upstreamTransportPolicy: OpenAIAccountGatewayResolvedUpstreamTransportPolicy
    private let officialTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration
    private let runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration
    private let routeJournalStore: OpenAIGatewayRouteJournalStoring
    private let diagnosticsReporter: (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void
    private let retryDelaySleeper: (TimeInterval) async throws -> Void
    private let retryJitterMultiplier: () -> Double
    private let onListenerReady: (UInt16) -> Void
    private var listener: NWListener?
    private var accounts: [TokenAccount] = []
    private var accountUsageMode: CodexBarOpenAIAccountUsageMode = .switchAccount
    private var modelRoutingOpenAIModelID: String?
    private var modelRoutingEnabled = false
    private var routeTarget: OpenAIAccountGatewayRouteTarget = .none
    private var gatewayPromptPatchSettings = CodexBarOpenAISettings.GatewayPromptPatchSettings()
    private var reasoningRetryGuardConfiguration: OpenAIAccountGatewayReasoningRetryGuardConfiguration = .disabled
    private var reasoningRetryGuardMetrics = OpenAIAccountGatewayReasoningRetryGuardMetrics()
    private var reasoningRetryGuardLogEntries: [OpenAIAccountGatewayReasoningRetryGuardLogEntry] = []
    private var nextReasoningRetryGuardLogID = 1
    private var lastRoutedAccountID: String?
    private var cachedModelsResponse: (data: Data, etag: String?)?

    init(
        urlSession: URLSession? = nil,
        upstreamTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .live,
        runtimeConfiguration: OpenAIAccountGatewayRuntimeConfiguration = .live,
        officialTransportConfiguration: OpenAIAccountGatewayUpstreamTransportConfiguration = .official,
        routeJournalStore: OpenAIGatewayRouteJournalStoring = OpenAIGatewayRouteJournalStore(),
        diagnosticsReporter: @escaping (OpenAIAccountGatewayUpstreamFailureDiagnostic) -> Void = OpenAIAccountGatewayService.liveDiagnosticsReporter,
        retryDelaySleeper: @escaping (TimeInterval) async throws -> Void = { delay in
            guard delay.isFinite else { return }
            let maxSleepSeconds = TimeInterval(UInt64.max / 1_000_000_000)
            let safeDelay = min(max(0, delay), maxSleepSeconds)
            let nanoseconds = UInt64((safeDelay * 1_000_000_000).rounded(.down))
            guard nanoseconds > 0 else { return }
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        retryJitterMultiplier: @escaping () -> Double = {
            Double.random(in: 1...1.2)
        },
        onListenerReady: @escaping (UInt16) -> Void = { _ in }
    ) {
        let resolvedTransportConfiguration = upstreamTransportConfiguration.resolvedURLSessionConfiguration()
        self.urlSession = urlSession ?? Self.makeDedicatedUpstreamSession(using: resolvedTransportConfiguration.configuration)
        self.httpStreamingClient = urlSession.map(OpenAIAccountGatewayURLSessionAsyncBytesStreamingClient.init(urlSession:))
            ?? OpenAIAccountGatewayURLSessionChunkStreamingClient(transportConfiguration: upstreamTransportConfiguration)
        self.upstreamTransportConfiguration = upstreamTransportConfiguration
        self.upstreamTransportPolicy = resolvedTransportConfiguration.policy
        self.officialStreamingClient = urlSession.map(OpenAIAccountGatewayURLSessionAsyncBytesStreamingClient.init(urlSession:))
            ?? OpenAIAccountGatewayURLSessionChunkStreamingClient(transportConfiguration: officialTransportConfiguration, reusesSession: true)
        self.officialTransportConfiguration = officialTransportConfiguration
        self.runtimeConfiguration = runtimeConfiguration
        self.routeJournalStore = routeJournalStore
        self.diagnosticsReporter = diagnosticsReporter
        self.onListenerReady = onListenerReady
        self.retryDelaySleeper = retryDelaySleeper
        self.retryJitterMultiplier = retryJitterMultiplier
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
        let upstreamHost = diagnostic.upstreamHost ?? "-"
        let upstreamPath = diagnostic.upstreamPath ?? "-"
        let systemProxy = diagnostic.systemProxySummary ?? "-"
        let effectiveProxy = diagnostic.effectiveProxySummary ?? "-"
        NSLog(
            "codexbar OpenAI gateway upstream failure route=%@ target=%@ upstreamHost=%@ upstreamPath=%@ failureClass=%@ status=%@ errorDomain=%@ errorCode=%@ loopbackProxySafe=%@ systemProxy=%@ effectiveProxy=%@",
            diagnostic.route,
            diagnostic.target,
            upstreamHost,
            upstreamPath,
            diagnostic.failureClass.rawValue,
            status,
            errorDomain,
            errorCode,
            diagnostic.loopbackProxySafeApplied ? "true" : "false",
            systemProxy,
            effectiveProxy
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
                listener.stateUpdateHandler = { [weak listener] state in
                    if case .ready = state, let port = listener?.port?.rawValue { self.onListenerReady(port) }
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
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) {
        self.stateQueue.async {
            let routeTargetChanged = self.routeTarget != routeTarget
            self.accounts = accounts
            self.accountUsageMode = accountUsageMode
            self.routeTarget = routeTarget
            let knownIDs = Set(accounts.map(\.accountId))
            if routeTargetChanged {
                self.lastRoutedAccountID = nil
            } else if let lastRoutedAccountID = self.lastRoutedAccountID,
               knownIDs.contains(lastRoutedAccountID) == false {
                self.lastRoutedAccountID = nil
            }
        }
    }

    func updateModelRoutingState(accounts: [TokenAccount],
        accountUsageMode: CodexBarOpenAIAccountUsageMode, routeTarget: OpenAIAccountGatewayRouteTarget,
        enabled: Bool, openAIModelID: String?) {
        self.stateQueue.sync {
            if self.routeTarget != routeTarget { self.lastRoutedAccountID = nil }
            self.accounts = accounts
            self.accountUsageMode = accountUsageMode
            self.routeTarget = routeTarget
            self.modelRoutingEnabled = enabled
            self.modelRoutingOpenAIModelID = openAIModelID
        }
    }

    func setModelRoutingEnabled(_ enabled: Bool, openAIModelID: String?) {
        self.stateQueue.sync {
            self.modelRoutingEnabled = enabled
            self.modelRoutingOpenAIModelID = openAIModelID
        }
    }

    func setGatewayPromptPatchConfiguration(_ settings: CodexBarOpenAISettings.GatewayPromptPatchSettings) {
        self.stateQueue.sync {
            self.gatewayPromptPatchSettings = settings
        }
    }

    func setReasoningRetryGuardConfiguration(_ configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration) {
        self.stateQueue.sync {
            guard self.reasoningRetryGuardConfiguration != configuration else { return }
            self.reasoningRetryGuardConfiguration = configuration
            self.recordReasoningRetryGuardLogLocked(
                kind: .configuration,
                message: "updated enabled=\(configuration.isEnabled) reasoning_equals=\(configuration.reasoningEquals.sorted().map(String.init).joined(separator: ",")) endpoints=\(configuration.endpoints.joined(separator: ","))"
            )
        }
    }

    func reasoningRetryGuardSnapshot() -> OpenAIAccountGatewayReasoningRetryGuardSnapshot {
        self.stateQueue.sync {
            self.reasoningRetryGuardSnapshotLocked()
        }
    }

    func currentRoutedAccountID() -> String? {
        self.stateQueue.sync {
            self.lastRoutedAccountID
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

        if snapshot.modelRoutingEnabled {
            self.handleModelRouting(request: request, on: connection, snapshot: snapshot)
            return
        }

        if self.requiresLocalAuthorization(snapshot.routeTarget),
           self.isLocallyAuthorized(request: request, snapshot: snapshot) == false {
            self.sendJSONResponse(
                on: connection,
                statusCode: 401,
                body: #"{"error":{"message":"codexbar gateway unauthorized"}}"#
            )
            return
        }

        if method == "GET", OpenAIAccountGatewayModelsRoute(requestPath: request.path) != nil {
            Task {
                await self.handleModelsRequest(request: request, on: connection, snapshot: snapshot)
            }
            return
        }

        switch (method, route) {
        case ("GET", .responses):
            self.sendJSONResponse(on: connection, statusCode: 426,
                body: #"{"error":{"message":"use HTTP responses"}}"#)
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

    private func handleModelRouting(
        request: ParsedGatewayRequest, on connection: NWConnection,
        snapshot: OpenAIAccountGatewaySnapshot
    ) {
        guard self.isLocallyAuthorized(request: request, snapshot: snapshot) else {
            self.sendJSONResponse(on: connection, statusCode: 401,
                body: #"{"error":{"message":"codexbar gateway unauthorized"}}"#)
            return
        }
        let method = request.method.uppercased()
        let route = OpenAIAccountGatewayResponsesRoute(requestPath: request.path)
        if method == "GET", route == .responses {
            self.sendJSONResponse(on: connection, statusCode: 426,
                body: #"{"error":{"message":"use HTTP responses"}}"#)
            return
        }
        let models = method == "GET" && OpenAIAccountGatewayModelsRoute(requestPath: request.path) != nil
        guard models || (method == "POST" && route != nil) else {
            self.sendJSONResponse(on: connection, statusCode: 404, body: #"{"error":{"message":"not found"}}"#)
            return
        }
        if !models, let model = self.requestModelID(from: request.body),
           let config = try? CodexBarConfigStore().load(),
           model.hasPrefix("codexbar-") || (model == "codexbar" && config.openAI.modelRoutingStyle == .catalog) {
            let registry = CodexExportRegistry.load()
            let entry = model == "codexbar" ? registry.legacy : registry.entries.first { $0.id == model }
            guard let entry, let target = CodexExportRegistry.target(entry, config: config), let route else {
                self.sendJSONResponse(on: connection, statusCode: 503, body: #"{"error":{"message":"selected managed model is unavailable"}}"#)
                return
            }
            let work = Task {
                if case .openAIAccount(let id) = target {
                    await self.forwardAliasOpenAIRequest(request, on: connection, route: route,
                        account: snapshot.accounts.first { $0.accountId == id }, modelID: entry.model)
                } else { await self.forwardSelectedCapacityRequest(request, on: connection, route: route, target: target) }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in if complete || error != nil { work.cancel() } }
            connection.stateUpdateHandler = { state in if case .cancelled = state { work.cancel() }; if case .failed = state { work.cancel() } }
            return
        }
        let isAlias = !models && self.requestModelID(from: request.body) == CodexModelRouting.modelID
        let aliasModel = snapshot.modelRoutingOpenAIModelID
        let work = Task {
            if isAlias, let route, case .openAIAccount(let accountID) = snapshot.routeTarget {
                await self.forwardAliasOpenAIRequest(request, on: connection, route: route,
                    account: snapshot.accounts.first { $0.accountId == accountID }, modelID: aliasModel)
            } else if isAlias, let route {
                await self.forwardSelectedCapacityRequest(request, on: connection, route: route, target: snapshot.routeTarget)
            } else {
                await self.forwardOfficialRequest(request, on: connection, route: route, models: models)
            }
        }
        // There is no further request body to read. A peer disconnect must also stop
        // an upstream that has not produced response headers yet.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            if complete || error != nil { work.cancel() }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed: work.cancel()
            default: break
            }
        }
    }

    private func officialRequest(
        _ request: ParsedGatewayRequest, route: OpenAIAccountGatewayResponsesRoute?, models: Bool
    ) throws -> URLRequest {
        let base = models ? self.runtimeConfiguration.upstreamModelsURL
            : (route ?? .responses).upstreamURL(using: self.runtimeConfiguration)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = URLComponents(string: request.path)?.percentEncodedQuery
        var upstream = URLRequest(url: components.url!)
        upstream.httpMethod = request.method
        if request.method.uppercased() != "GET" { upstream.httpBody = try ToolHistoryCompatibility.normalize(request.body) }
        let hopHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "upgrade", "keep-alive", "proxy-authorization", "proxy-authenticate", "te", "trailer"]
        for (name, value) in request.headers where !hopHeaders.contains(name.lowercased()) {
            upstream.setValue(value, forHTTPHeaderField: name)
        }
        upstream.timeoutInterval = self.officialTransportConfiguration.requestTimeout
        return upstream
    }

    private func forwardOfficialRequest(
        _ request: ParsedGatewayRequest, on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute?, models: Bool
    ) async {
        let timing = Self.makeTimingContext(route: models ? "models" : (route ?? .responses).diagnosticName, target: "official")
        Self.logTiming("request_received", context: timing)
        await self.forwardCapacityRetryingResponse(to: connection, timing: timing, retryEnabled: !models) {
            let result = try await self.officialStreamingClient.stream(
                for: try self.officialRequest(request, route: route, models: models),
                transportConfigurationOverride: self.officialTransportConfiguration
            )
            if !models, (200...299).contains(result.response.statusCode) { self.recordOfficialRoute(request) }
            return (result.response, result.chunks)
        }
    }

    private func forwardSelectedCapacityRequest(
        _ request: ParsedGatewayRequest, on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute, target: OpenAIAccountGatewayRouteTarget
    ) async {
        let body: Data
        do { body = try ToolHistoryCompatibility.normalize(self.applyGatewayPromptPatchIfNeeded(request.body)) }
        catch { self.sendJSONResponse(on: connection, statusCode: 400, body: #"{"error":{"message":"tool history has ambiguous call_id associations"}}"#); return }
        let timing = Self.makeTimingContext(route: route.diagnosticName, target: target.diagnosticName)
        await self.forwardCapacityRetryingResponse(to: connection, timing: timing) {
            switch target {
            case .compatibleProvider(let provider): return try await self.proxyProviderPOSTResponses(body: body, inboundHeaders: request.headers, route: route, target: provider)
            case .openRouter(let provider): return try await self.proxyOpenRouterPOSTResponses(body: body, inboundHeaders: request.headers, route: route, target: provider)
            default: throw URLError(.userAuthenticationRequired)
            }
        }
    }

    private func forwardCapacityRetryingResponse(
        to connection: NWConnection, timing: OpenAIAccountGatewayTimingContext, retryEnabled: Bool = true,
        request: () async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>)
    ) async {
        await GatewayCapacityRetryPolicy.$requestBudget.withValue(retryEnabled ? GatewayCapacityRequestBudget() : nil) {
            await self.runCapacityRetryingResponse(to: connection, timing: timing, retryEnabled: retryEnabled, request: request)
        }
    }

    private func runCapacityRetryingResponse(
        to connection: NWConnection, timing: OpenAIAccountGatewayTimingContext, retryEnabled: Bool = true,
        request: () async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>)
    ) async {
        var sent = false
        var lastRejection: (response: HTTPURLResponse, body: Data)?
        do {
            for attempt in 1...(retryEnabled ? GatewayCapacityRetryPolicy.maximumAttempts : 1) {
                try Task.checkCancellation()
                guard let rejection = try await self.performCapacityAttempt(to: connection, timing: timing,
                    retryEnabled: retryEnabled, attempt: attempt, sent: &sent, request: request) else { return }
                lastRejection = rejection
                if attempt < GatewayCapacityRetryPolicy.maximumAttempts,
                   GatewayCapacityRetryPolicy.requestBudget?.hasRemaining != false,
                   let delay = GatewayCapacityRetryPolicy.delay(attempt: attempt,
                        retryAfter: rejection.response.value(forHTTPHeaderField: "Retry-After"), jitter: self.retryJitterMultiplier()) {
                    Self.logTiming("capacity_retry", context: timing, statusCode: rejection.response.statusCode,
                        extra: "attempt=\(attempt) max_attempts=5 delay_ms=\(Int(delay * 1000))")
                    try await self.retryDelaySleeper(delay)
                    continue
                }
                Self.logTiming("capacity_retry_finished", context: timing, statusCode: rejection.response.statusCode,
                    extra: "attempt=\(attempt)")
                try await self.send(Data(self.renderResponseHeaders(from: rejection.response).utf8), on: connection)
                sent = true
                try await self.send(rejection.body, on: connection)
                connection.cancel()
                return
            }
        } catch {
            if error is ToolHistoryCompatibility.InvalidAssociation, !sent {
                self.sendJSONResponse(on: connection, statusCode: 400, body: #"{"error":{"message":"tool history has ambiguous call_id associations"}}"#)
                return
            }
            if error is GatewayCapacityRequestBudget.Exhausted, let rejection = lastRejection, !sent, !Task.isCancelled {
                try? await self.send(Data(self.renderResponseHeaders(from: rejection.response).utf8), on: connection)
                try? await self.send(rejection.body, on: connection)
                connection.cancel()
                return
            }
            Self.logTiming("request_failed", context: timing, extra: "code=\((error as NSError).code)")
            if !sent && !Task.isCancelled {
                self.sendJSONResponse(on: connection,
                    statusCode: (error as NSError).code == URLError.timedOut.rawValue ? 504 : 502,
                    body: #"{"error":{"message":"upstream request failed"}}"#)
            } else { connection.cancel() }
        }
    }

    // Keep the upstream stream scoped to one attempt, releasing/cancelling it before the backoff.
    private func performCapacityAttempt(
        to connection: NWConnection, timing: OpenAIAccountGatewayTimingContext, retryEnabled: Bool,
        attempt: Int, sent: inout Bool,
        request: () async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>)
    ) async throws -> (response: HTTPURLResponse, body: Data)? {
        let result: (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>)
        do { result = try await request() }
        catch let rejection as GatewayCapacityRejection { return (rejection.response, rejection.body) }
        Self.logTiming("upstream_headers", context: timing, statusCode: result.response.statusCode, extra: "attempt=\(attempt)")
        if !retryEnabled {
            sent = true
            try await self.streamRawResponse(result: result, to: connection, timing: timing)
            return nil
        }
        guard let body = try await self.streamCapacityAttempt(result: result, to: connection, timing: timing, sent: &sent) else { return nil }
        return (result.response, body)
    }

    /// Returns a rejection only while no business output has been committed downstream.
    private func streamCapacityAttempt(
        result: (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>),
        to connection: NWConnection, timing: OpenAIAccountGatewayTimingContext, sent: inout Bool
    ) async throws -> Data? {
        let isSSE = result.response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        var prefix = Data()
        var events = SSEEventStreamAccumulator()
        var first = true
        var total = 0
        for try await chunk in result.bytes {
            try Task.checkCancellation()
            if first { Self.logTiming("first_chunk", context: timing); first = false }
            total += chunk.count
            var business = false
            var capacity = false
            if isSSE {
                if events.bufferedByteCount + chunk.count <= GatewayCapacityRetryPolicy.prefixLimit {
                    for event in events.append(contentsOf: chunk) {
                        switch GatewayCapacityRetryPolicy.disposition(event) {
                        case .business: business = true
                        case .capacity: capacity = true
                        case .lifecycle: break
                        }
                    }
                } else { events = SSEEventStreamAccumulator(); business = true }
            }
            if !sent {
                if prefix.count + chunk.count > GatewayCapacityRetryPolicy.prefixLimit {
                    try await self.send(Data(self.renderResponseHeaders(from: result.response).utf8), on: connection)
                    sent = true
                    if !prefix.isEmpty { try await self.send(prefix, on: connection) }
                    prefix.removeAll()
                    try await self.send(chunk, on: connection)
                } else {
                    prefix.append(chunk)
                    if GatewayCapacityRetryPolicy.isCapacityBody(prefix, statusCode: result.response.statusCode) { return prefix }
                    if isSSE {
                        business = business || GatewayCapacityRetryPolicy.hasBusinessPrefix(prefix)
                        if capacity && !business { return prefix }
                    } else {
                        if GatewayCapacityRetryPolicy.isCapacityBody(prefix, statusCode: result.response.statusCode) { return prefix }
                        business = (try? JSONSerialization.jsonObject(with: prefix)) != nil
                    }
                    if business {
                        try await self.send(Data(self.renderResponseHeaders(from: result.response).utf8), on: connection)
                        sent = true
                        try await self.send(prefix, on: connection)
                        prefix.removeAll()
                    }
                }
            } else { try await self.send(chunk, on: connection) }
            if capacity { connection.cancel(); return nil }
        }
        if !sent {
            if isSSE, let remaining = events.flush(), GatewayCapacityRetryPolicy.disposition(remaining) == .capacity { return prefix }
            if !isSSE && GatewayCapacityRetryPolicy.isCapacityBody(prefix, statusCode: result.response.statusCode) { return prefix }
            try await self.send(Data(self.renderResponseHeaders(from: result.response).utf8), on: connection)
            sent = true
            if !prefix.isEmpty { try await self.send(prefix, on: connection) }
        }
        Self.logTiming("request_completed", context: timing, statusCode: result.response.statusCode, bytes: total)
        connection.cancel()
        return nil
    }

    private func forwardAliasOpenAIRequest(
        _ request: ParsedGatewayRequest, on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute, account: TokenAccount?, modelID: String?
    ) async {
        guard let account, let modelID,
              var object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            self.sendJSONResponse(on: connection, statusCode: 503,
                body: #"{"error":{"message":"selected OpenAI account or model is unavailable"}}"#)
            return
        }
        object["model"] = modelID
        var routed = request
        routed.body = (try? JSONSerialization.data(withJSONObject: object)) ?? request.body
        routed.headers["authorization"] = "Bearer " + account.accessToken
        routed.headers["chatgpt-account-id"] = account.remoteAccountId
        await self.forwardOfficialRequest(routed, on: connection, route: route, models: false)
    }

    private func recordOfficialRoute(_ request: ParsedGatewayRequest) {
        guard let authorization = request.headers["authorization"],
              let account = self.snapshot().accounts.first(where: {
                  "Bearer " + $0.accessToken == authorization || $0.remoteAccountId == request.headers["chatgpt-account-id"]
              }) else { return }
        self.noteRoutedAccount(accountID: account.accountId, request: request)
    }

    private func noteRoutedAccount(accountID: String, request: ParsedGatewayRequest) {
        if let threadID = request.headers["session_id"] ?? request.headers["conversation_id"] {
            self.routeJournalStore.recordRoute(threadID: threadID, accountID: accountID, timestamp: Date())
        }
        self.stateQueue.sync { self.lastRoutedAccountID = accountID }
        NotificationCenter.default.post(name: .openAIAccountGatewayDidRouteAccount, object: self,
            userInfo: ["accountID": accountID])
    }

    private func streamRawResponse(
        result: (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>),
        to connection: NWConnection, timing: OpenAIAccountGatewayTimingContext
    ) async throws {
        Self.logTiming("upstream_headers", context: timing, statusCode: result.response.statusCode)
        try await self.send(Data(self.renderResponseHeaders(from: result.response).utf8), on: connection)
        var totalBytes = 0
        do {
            for try await chunk in result.bytes {
                try Task.checkCancellation()
                if totalBytes == 0 { Self.logTiming("first_chunk", context: timing) }
                totalBytes += chunk.count
                try await self.send(chunk, on: connection)
            }
            Self.logTiming("request_completed", context: timing, statusCode: result.response.statusCode, bytes: totalBytes)
            connection.cancel()
        } catch {
            Self.logTiming("stream_failed", context: timing, bytes: totalBytes,
                extra: "code=\((error as NSError).code)")
            connection.cancel()
            throw error
        }
    }

    private func requiresLocalAuthorization(_ routeTarget: OpenAIAccountGatewayRouteTarget) -> Bool {
        switch routeTarget {
        case .compatibleProvider, .openRouter:
            return true
        case .none, .openAIAccount:
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
        if token == OpenAIAccountGatewayConfiguration.apiKey {
            return true
        }
        switch snapshot.routeTarget {
        case .compatibleProvider(let target):
            if token == target.apiKey { return true }
        case .openRouter(let target):
            if token == target.apiKey { return true }
        case .none, .openAIAccount:
            break
        }
        if snapshot.accounts.contains(where: { $0.accessToken == token }) { return true }
        if let data = try? Data(contentsOf: CodexPaths.authURL),
           let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = auth["tokens"] as? [String: Any] {
            return tokens["access_token"] as? String == token
        }
        return false
    }

    private func handleModelsRequest(
        request: ParsedGatewayRequest,
        on connection: NWConnection,
        snapshot: OpenAIAccountGatewaySnapshot
    ) async {

        let clientVersion = Self.queryValue(named: "client_version", in: request.path)
            ?? OpenAIAccountGatewayConfiguration.defaultCodexCLIVersion
        for account in self.modelsRequestAccounts(snapshot: snapshot) {
            if let fetched = await self.fetchUpstreamModels(
                request: request,
                account: account,
                clientVersion: clientVersion
            ) {
                self.storeCachedModelsResponse(data: fetched.data, etag: fetched.etag)
                self.sendDataResponse(
                    on: connection,
                    statusCode: 200,
                    body: Self.modelsResponseData(fetched.data, routeTarget: snapshot.routeTarget),
                    contentType: "application/json",
                    headers: fetched.etag.map { ["ETag": $0] } ?? [:]
                )
                return
            }
        }

        if let cached = self.loadCachedModelsResponse() {
            self.sendDataResponse(
                on: connection,
                statusCode: 200,
                body: Self.modelsResponseData(cached.data, routeTarget: snapshot.routeTarget),
                contentType: "application/json",
                headers: cached.etag.map { ["ETag": $0] } ?? [:]
            )
            return
        }

        self.sendDataResponse(
            on: connection,
            statusCode: 200,
            body: Self.modelsResponseData(
                Self.fallbackModelsResponse(routeTarget: snapshot.routeTarget),
                routeTarget: snapshot.routeTarget
            ),
            contentType: "application/json"
        )
    }

    /// Provider routes are converted to stateless chat completions, so OpenAI-only
    /// capabilities in the upstream catalog (Code Mode, Responses Lite, multi-agent
    /// selectors) must not leak into Codex. Otherwise Codex exposes the freeform
    /// `exec` tool and third-party models produce incompatible tool payloads.
    private static func modelsResponseData(
        _ data: Data,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) -> Data {
        switch routeTarget {
        case .compatibleProvider, .openRouter:
            return self.providerCompatibleModelsResponseData(data)
        case .none, .openAIAccount:
            return data
        }
    }

    private static func providerCompatibleModelsResponseData(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return data
        }
        let normalizedModels = models.map { model -> [String: Any] in
            var model = model
            model["tool_mode"] = "direct"
            model["use_responses_lite"] = false
            model.removeValue(forKey: "multi_agent_version")
            model.removeValue(forKey: "multi_agent_reasoning_effort")
            model.removeValue(forKey: "guardian")
            return model
        }
        object["models"] = normalizedModels
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }

    private static func queryValue(named name: String, in path: String) -> String? {
        URLComponents(string: path)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func modelsRequestAccounts(snapshot: OpenAIAccountGatewaySnapshot) -> [TokenAccount] {
        if case .openAIAccount(let accountID) = snapshot.routeTarget {
            return snapshot.accounts.filter { $0.accountId == accountID }
        }
        return Array(snapshot.accounts.prefix(1))
    }

    private func fetchUpstreamModels(
        request: ParsedGatewayRequest,
        account: TokenAccount,
        clientVersion: String
    ) async -> (data: Data, etag: String?)? {
        var components = URLComponents(
            url: self.runtimeConfiguration.upstreamModelsURL,
            resolvingAgainstBaseURL: false
        )
        var queryItems = components?.queryItems ?? []
        for item in (URLComponents(string: request.path)?.queryItems ?? []) where item.name != "client_version" {
            queryItems.append(item)
        }
        if queryItems.contains(where: { $0.name == "client_version" }) == false {
            queryItems.append(URLQueryItem(name: "client_version", value: clientVersion))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = "GET"
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "accept")
        upstreamRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "authorization")
        upstreamRequest.setValue(account.remoteAccountId, forHTTPHeaderField: "chatgpt-account-id")
        upstreamRequest.setValue(OpenAIAccountGatewayConfiguration.originator, forHTTPHeaderField: "originator")
        upstreamRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        if let version = request.headers["version"], version.isEmpty == false {
            upstreamRequest.setValue(version, forHTTPHeaderField: "version")
        }

        do {
            let (data, response) = try await self.urlSession.data(for: upstreamRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.isEmpty == false else {
                return nil
            }
            return (data, httpResponse.value(forHTTPHeaderField: "ETag"))
        } catch {
            return nil
        }
    }

    private func loadCachedModelsResponse() -> (data: Data, etag: String?)? {
        if let cached = self.stateQueue.sync(execute: { self.cachedModelsResponse }) {
            return cached
        }
        guard let data = try? Data(contentsOf: CodexPaths.openAIGatewayModelsCacheURL),
              data.isEmpty == false,
              data.count <= Self.maxModelsResponseCacheBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["models"] is [Any] else {
            return nil
        }
        let cached = (data: data, etag: Optional<String>.none)
        self.stateQueue.sync {
            self.cachedModelsResponse = cached
        }
        return cached
    }

    private func storeCachedModelsResponse(data: Data, etag: String?) {
        guard data.count <= Self.maxModelsResponseCacheBytes else { return }
        let previous = self.stateQueue.sync { self.cachedModelsResponse }
        self.stateQueue.sync {
            self.cachedModelsResponse = (data: data, etag: etag)
        }
        guard previous?.data != data else { return }
        try? CodexPaths.writeSecureFile(data, to: CodexPaths.openAIGatewayModelsCacheURL)
    }

    private static let maxModelsResponseCacheBytes = 8 * 1024 * 1024

    private static func fallbackModelsResponse(
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) -> Data {
        let fallbackInstructions = """
        You are Codex, a coding agent. Work directly in the repository, read files before editing, \
        keep changes minimal and consistent with the surrounding code, run relevant tests, and \
        report what changed. Never print or expose secrets.
        """
        let reasoningLevels: [[String: Any]] = [
            ["effort": "low", "description": "Fast responses with lighter reasoning"],
            ["effort": "medium", "description": "Balances speed and reasoning depth for everyday tasks"],
            ["effort": "high", "description": "Greater reasoning depth for complex problems"],
            ["effort": "xhigh", "description": "Extra high reasoning depth for complex problems"],
        ]

        func entry(slug: String, displayName: String, description: String, priority: Int) -> [String: Any] {
            [
                "slug": slug,
                "display_name": displayName,
                "description": description,
                "default_reasoning_level": "medium",
                "supported_reasoning_levels": reasoningLevels,
                "shell_type": "shell_command",
                "visibility": "list",
                "supported_in_api": true,
                "priority": priority,
                "availability_nux": NSNull(),
                "upgrade": NSNull(),
                "base_instructions": fallbackInstructions,
                "supports_reasoning_summaries": true,
                "default_reasoning_summary": "none",
                "support_verbosity": true,
                "default_verbosity": "low",
                "apply_patch_tool_type": "freeform",
                "web_search_tool_type": "text_and_image",
                "truncation_policy": ["mode": "tokens", "limit": 10_000],
                "supports_parallel_tool_calls": true,
                "supports_image_detail_original": true,
                "context_window": 272_000,
                "auto_compact_token_limit": NSNull(),
                "effective_context_window_percent": 95,
                "experimental_supported_tools": [String](),
                "input_modalities": ["text", "image"],
                "supports_search_tool": true,
                "prefer_websockets": true,
                "include_apps_usage_instructions": true,
            ]
        }

        var models: [[String: Any]] = [
            entry(slug: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", description: "Latest Sol coding model.", priority: 1),
            entry(slug: "gpt-6-sol", displayName: "GPT-6-Sol", description: "GPT-6 Sol coding model.", priority: 3),
            entry(slug: "gpt-6-luna", displayName: "GPT-6-Luna", description: "GPT-6 Luna coding model.", priority: 4),
            entry(slug: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", description: "GPT-5.6 Sol coding model.", priority: 5),
            entry(slug: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", description: "GPT-5.6 Terra coding model.", priority: 8),
            entry(slug: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", description: "GPT-5.6 Luna coding model.", priority: 9),
            entry(slug: "gpt-5.5", displayName: "GPT-5.5", description: "Legacy coding model.", priority: 13),
        ]

        let routeModelID: String?
        switch routeTarget {
        case .compatibleProvider(let target):
            routeModelID = target.modelID
        case .openRouter(let target):
            routeModelID = target.modelID
        case .none, .openAIAccount:
            routeModelID = nil
        }
        if let routeModelID = routeModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           routeModelID.isEmpty == false,
           models.contains(where: { ($0["slug"] as? String) == routeModelID }) == false {
            models.append(
                entry(
                    slug: routeModelID,
                    displayName: routeModelID,
                    description: "Selected CodexBar provider model.",
                    priority: 100
                )
            )
        }

        let payload: [String: Any] = ["models": models]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"models":[]}"#.utf8)
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

        // Provider routes are converted to stateless chat completions (or forwarded to
        // provider-specific Responses endpoints). Codex's Responses WebSocket transport
        // relies on `previous_response_id` plus incremental input, which this gateway
        // cannot preserve, so force the well-supported HTTP Responses path instead of
        // bridging a one-shot socket and letting Codex retry/fall back mid-turn.
        self.sendJSONResponse(
            on: connection,
            statusCode: 426,
            body: #"{"error":{"message":"websocket upgrade is not supported for provider routes; use HTTP responses"}}"#
        )
    }

    private func snapshot() -> OpenAIAccountGatewaySnapshot {
        self.stateQueue.sync {
            OpenAIAccountGatewaySnapshot(
                accounts: self.accounts,
                accountUsageMode: self.accountUsageMode,
                modelRoutingEnabled: self.modelRoutingEnabled,
                modelRoutingOpenAIModelID: self.modelRoutingOpenAIModelID,
                routeTarget: self.routeTarget
            )
        }
    }

    private func reasoningRetryGuardConfigurationSnapshot() -> OpenAIAccountGatewayReasoningRetryGuardConfiguration {
        self.stateQueue.sync {
            self.reasoningRetryGuardConfiguration
        }
    }

    private func shouldInspectReasoningRetryGuard(
        route: OpenAIAccountGatewayResponsesRoute,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Bool {
        guard configuration.isEnabled else { return false }
        let endpoints = Set(configuration.endpoints)
        return endpoints.isDisjoint(with: route.retryGuardEndpointAliases) == false
    }

    private func reasoningRetryGuardSnapshotLocked() -> OpenAIAccountGatewayReasoningRetryGuardSnapshot {
        OpenAIAccountGatewayReasoningRetryGuardSnapshot(
            configuration: self.reasoningRetryGuardConfiguration,
            metrics: self.reasoningRetryGuardMetrics,
            logEntries: self.reasoningRetryGuardLogEntries
        )
    }

    private func recordReasoningRetryGuardProxyRequest() {
        self.stateQueue.sync {
            self.reasoningRetryGuardMetrics.totalProxyRequestCount += 1
            self.postReasoningRetryGuardSnapshotUpdateLocked()
        }
    }

    private func recordReasoningRetryGuardInspection(
        reasoningTokens: Int?,
        matchEvidence: [String],
        matched: Bool,
        blocked: Bool,
        route: OpenAIAccountGatewayResponsesRoute,
        isEventStream: Bool,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) {
        self.stateQueue.sync {
            self.reasoningRetryGuardMetrics.inspectedResponseCount += 1
            if let reasoningTokens {
                self.reasoningRetryGuardMetrics.observedReasoningCounts[reasoningTokens, default: 0] += 1
            }
            if matched {
                self.reasoningRetryGuardMetrics.matchedResponseCount += 1
                if isEventStream {
                    self.reasoningRetryGuardMetrics.matchedStreamingCount += 1
                } else {
                    self.reasoningRetryGuardMetrics.matchedNonStreamingCount += 1
                }
                if blocked {
                    self.reasoningRetryGuardMetrics.blockedResponseCount += 1
                    if isEventStream {
                        self.reasoningRetryGuardMetrics.blockedStreamingCount += 1
                    } else {
                        self.reasoningRetryGuardMetrics.blockedNonStreamingCount += 1
                    }
                }
                if configuration.logMatch {
                    let action = blocked ? "status_\(configuration.nonStreamStatusCode)" : "observe_only"
                    let evidence = matchEvidence.isEmpty ? "" : " evidence=\(matchEvidence.joined(separator: "+"))"
                    self.recordReasoningRetryGuardLogLocked(
                        kind: .interception,
                        message: "\(isEventStream ? "stream" : "non-stream") mode=\(configuration.matchMode.rawValue) path=\(route.diagnosticName) reasoning_tokens=\(reasoningTokens ?? -1) action=\(action)\(evidence)"
                    )
                }
            }
            self.postReasoningRetryGuardSnapshotUpdateLocked()
        }
    }

    private func recordReasoningRetryGuardLogLocked(
        kind: OpenAIAccountGatewayReasoningRetryGuardLogKind,
        message: String
    ) {
        let entry = OpenAIAccountGatewayReasoningRetryGuardLogEntry(
            id: self.nextReasoningRetryGuardLogID,
            recordedAt: Date(),
            kind: kind,
            batchID: nil,
            retryCount: 0,
            retryResult: nil,
            message: message
        )
        self.nextReasoningRetryGuardLogID += 1
        self.reasoningRetryGuardLogEntries.append(entry)
        self.trimReasoningRetryGuardLogsLocked()
        self.postReasoningRetryGuardSnapshotUpdateLocked()
    }

    private func recordGatewayRetryAttempt(
        batchID: String,
        path: String,
        target: String,
        statusCode: Int?,
        maximumRetryCount: Int,
        delay: TimeInterval,
        delaySource: String
    ) {
        self.stateQueue.sync {
            let existingIndex = self.reasoningRetryGuardLogEntries.firstIndex {
                $0.kind == .retry && $0.batchID == batchID
            }
            let existingEntry = existingIndex.map { self.reasoningRetryGuardLogEntries[$0] }
            let retryCount = (existingEntry?.retryCount ?? 0) + 1
            let entryID: Int
            if let existingEntry {
                entryID = existingEntry.id
            } else {
                entryID = self.nextReasoningRetryGuardLogID
                self.nextReasoningRetryGuardLogID += 1
            }
            if let existingIndex {
                self.reasoningRetryGuardLogEntries.remove(at: existingIndex)
            }

            let status = statusCode.map(String.init) ?? "transport_error"
            let delayMilliseconds = Int((delay * 1_000).rounded())
            self.reasoningRetryGuardLogEntries.append(
                OpenAIAccountGatewayReasoningRetryGuardLogEntry(
                    id: entryID,
                    recordedAt: Date(),
                    kind: .retry,
                    batchID: batchID,
                    retryCount: retryCount,
                    retryResult: .retrying,
                    message: "batch=\(batchID) path=\(path) target=\(target) status=\(status) attempts=\(retryCount)/\(maximumRetryCount) delay_ms=\(delayMilliseconds) source=\(delaySource)"
                )
            )
            self.trimReasoningRetryGuardLogsLocked()
            self.postReasoningRetryGuardSnapshotUpdateLocked()
        }
    }

    private func completeGatewayRetryLog(
        batchID: String,
        statusCode: Int?,
        succeeded: Bool
    ) {
        self.stateQueue.sync {
            guard let existingIndex = self.reasoningRetryGuardLogEntries.firstIndex(where: {
                $0.kind == .retry && $0.batchID == batchID && $0.retryResult == .retrying
            }) else { return }
            let existingEntry = self.reasoningRetryGuardLogEntries.remove(at: existingIndex)
            let finalStatus = statusCode.map(String.init) ?? "transport_error"
            self.reasoningRetryGuardLogEntries.append(
                OpenAIAccountGatewayReasoningRetryGuardLogEntry(
                    id: existingEntry.id,
                    recordedAt: Date(),
                    kind: existingEntry.kind,
                    batchID: existingEntry.batchID,
                    retryCount: existingEntry.retryCount,
                    retryResult: succeeded ? .succeeded : .failed,
                    message: "\(existingEntry.message) final_status=\(finalStatus)"
                )
            )
            self.postReasoningRetryGuardSnapshotUpdateLocked()
        }
    }

    private func trimReasoningRetryGuardLogsLocked() {
        if self.reasoningRetryGuardLogEntries.count > Self.maxReasoningRetryGuardLogEntries {
            self.reasoningRetryGuardLogEntries.removeFirst(
                self.reasoningRetryGuardLogEntries.count - Self.maxReasoningRetryGuardLogEntries
            )
        }
    }

    private func postReasoningRetryGuardSnapshotUpdateLocked() {
        let snapshot = self.reasoningRetryGuardSnapshotLocked()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .openAIAccountGatewayReasoningRetryGuardDidUpdate,
                object: snapshot
            )
        }
    }

    private func compactSessionSeed(from body: Data) -> String? {
        self.requestSessionSeed(from: body)
    }

    private func requestSessionSeed(from body: Data) -> String? {
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

    private func retryAt(from response: HTTPURLResponse?) -> Date? {
        guard let retryAfter = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return self.retryAt(fromRetryAfterValue: retryAfter)
    }

    private func retryAt(fromRetryAfterValue value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 {
            return Date().addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed)
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
        self.recordReasoningRetryGuardProxyRequest()

        let timing = Self.makeTimingContext(
            route: route.diagnosticName,
            target: routeTarget.diagnosticName
        )
        Self.logTiming("request_received", context: timing, extra: request.method.uppercased())

        switch routeTarget {
        case .openAIAccount(let accountID):
            await self.forwardOpenAIAccountResponsesRequest(
                request,
                on: connection,
                route: route,
                accountID: accountID,
                timing: timing
            )
            return
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
        case .none:
            break
        }

        self.sendJSONResponse(on: connection, statusCode: 503,
            body: #"{"error":{"message":"codexbar gateway unavailable: no routed target"}}"#)
    }

    private func forwardOpenAIAccountResponsesRequest(
        _ request: ParsedGatewayRequest,
        on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        accountID: String,
        timing: OpenAIAccountGatewayTimingContext
    ) async {
        guard let account = self.account(withID: accountID) else {
            self.sendJSONResponse(
                on: connection,
                statusCode: 503,
                body: #"{"error":{"message":"codexbar gateway unavailable: selected OpenAI account is not routable"}}"#
            )
            Self.logTiming("request_unavailable", context: timing, statusCode: 503)
            return
        }

        do {
            let guardConfiguration = self.reasoningRetryGuardConfigurationSnapshot()
            if self.shouldInspectReasoningRetryGuard(route: route, configuration: guardConfiguration) {
                try await self.forwardRouteTargetResponsesRequestWithRetry(
                    to: connection,
                    route: route,
                    targetName: "openAIAccount",
                    targetDiagnosticName: account.accountId,
                    upstreamURL: route.upstreamURL(using: self.runtimeConfiguration),
                    timing: timing,
                    request: {
                        try await self.proxyPOSTResponses(request, account: account, route: route)
                    }
                )
                return
            }

            let maxAttempts = max(1, guardConfiguration.routeTargetRetryAttempts + 1)
            var lastError: Error?
            for attempt in 1...maxAttempts {
                do {
                    let result = try await self.proxyPOSTResponses(request, account: account, route: route)
                    if (200...299).contains(result.response.statusCode) { self.noteRoutedAccount(accountID: account.accountId, request: request) }
                    if guardConfiguration.retryableStatusCodes.contains(result.response.statusCode),
                       attempt < maxAttempts {
                        _ = try? await self.readAllBytes(from: result.bytes)
                        Self.logTiming(
                            "request_retry_openai_account_status",
                            context: timing,
                            statusCode: result.response.statusCode,
                            extra: "attempt=\(attempt) max_attempts=\(maxAttempts)"
                        )
                        try await self.waitBeforeGatewayRetry(
                            response: result.response,
                            attempt: attempt,
                            maximumRetryCount: maxAttempts - 1,
                            timing: timing,
                            statusCode: result.response.statusCode,
                            target: account.accountId
                        )
                        continue
                    }
                    self.completeGatewayRetryLog(
                        batchID: timing.id,
                        statusCode: result.response.statusCode,
                        succeeded: (200...299).contains(result.response.statusCode)
                    )
                    _ = try await self.streamLiveOpenAIAccountResponse(
                        result: result,
                        account: account,
                        to: connection,
                        route: route,
                        timing: timing
                    )
                    return
                } catch {
                    let failure = self.resolvedPOSTFailure(from: error)
                    lastError = error
                    self.reportPOSTFailureDiagnostic(
                        route: route,
                        target: "openAIAccount",
                        upstreamURL: route.upstreamURL(using: self.runtimeConfiguration),
                        failure: failure
                    )
                    guard self.shouldRetryRouteTargetFailure(failure, configuration: guardConfiguration),
                          attempt < maxAttempts else {
                        self.completeGatewayRetryLog(
                            batchID: timing.id,
                            statusCode: failure.statusCode,
                            succeeded: false
                        )
                        throw error
                    }
                    Self.logTiming(
                        "request_retry_openai_account_failure",
                        context: timing,
                        statusCode: failure.statusCode,
                        extra: "attempt=\(attempt) max_attempts=\(maxAttempts) class=\(failure.failureClass.rawValue)"
                    )
                    try await self.waitBeforeGatewayRetry(
                        response: nil,
                        attempt: attempt,
                        maximumRetryCount: maxAttempts - 1,
                        timing: timing,
                        statusCode: failure.statusCode,
                        target: account.accountId
                    )
                }
            }
            if let lastError {
                throw lastError
            }
        } catch {
            let failure = self.resolvedPOSTFailure(from: error)
            self.completeGatewayRetryLog(
                batchID: timing.id,
                statusCode: failure.statusCode,
                succeeded: false
            )
            self.reportPOSTFailureDiagnostic(
                route: route,
                target: "openAIAccount",
                upstreamURL: route.upstreamURL(using: self.runtimeConfiguration),
                failure: failure
            )
            Self.logTiming("request_failed", context: timing, extra: (error as NSError).domain)
            self.sendJSONResponse(
                on: connection,
                statusCode: 502,
                body: #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
            )
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
            let body = self.applyGatewayPromptPatchIfNeeded(request.body)
            try await self.forwardRouteTargetResponsesRequestWithRetry(
                to: connection,
                route: route,
                targetName: "compatibleProvider",
                targetDiagnosticName: target.providerLabel,
                upstreamURL: try? self.providerResponsesURL(baseURL: target.baseURL, route: route),
                timing: timing,
                request: {
                    try await self.proxyProviderPOSTResponses(
                        body: body,
                        inboundHeaders: request.headers,
                        route: route,
                        target: target
                    )
                }
            )
        } catch {
            let upstreamURL = try? self.providerResponsesURL(baseURL: target.baseURL, route: route)
            let failure = self.resolvedPOSTFailure(from: error)
            self.reportPOSTFailureDiagnostic(
                route: route,
                target: "compatibleProvider",
                upstreamURL: upstreamURL,
                failure: failure
            )
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
            let body = self.applyGatewayPromptPatchIfNeeded(request.body)
            try await self.forwardRouteTargetResponsesRequestWithRetry(
                to: connection,
                route: route,
                targetName: "openRouter",
                targetDiagnosticName: "openRouter",
                upstreamURL: self.openRouterResponsesURL(route: route),
                timing: timing,
                request: {
                    try await self.proxyOpenRouterPOSTResponses(
                        body: body,
                        inboundHeaders: request.headers,
                        route: route,
                        target: target
                    )
                }
            )
        } catch {
            let upstreamURL = self.openRouterResponsesURL(route: route)
            let failure = self.resolvedPOSTFailure(from: error)
            self.reportPOSTFailureDiagnostic(
                route: route,
                target: "openRouter",
                upstreamURL: upstreamURL,
                failure: failure
            )
            Self.logTiming("request_failed", context: timing, extra: (error as NSError).domain)
            self.sendJSONResponse(
                on: connection,
                statusCode: 502,
                body: #"{"error":{"message":"codexbar gateway failed to reach OpenRouter upstream"}}"#
            )
        }
    }

    private func forwardRouteTargetResponsesRequestWithRetry(
        to connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        targetName: String,
        targetDiagnosticName: String,
        upstreamURL: URL?,
        timing: OpenAIAccountGatewayTimingContext,
        request: () async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>)
    ) async throws {
        let configuration = self.reasoningRetryGuardConfigurationSnapshot()
        let maxAttempts = max(1, configuration.routeTargetRetryAttempts + 1)
        var lastBufferedResponse: OpenAIAccountGatewayRouteTargetBufferedResponse?

        for attempt in 1...maxAttempts {
            do {
                let result = try await request()
                let buffered = try await self.bufferRouteTargetResponse(result, route: route, timing: timing)
                lastBufferedResponse = buffered

                guard self.shouldRetryRouteTargetResponse(buffered, configuration: configuration),
                      attempt < maxAttempts else {
                    let finalStatusCode = self.routeTargetRetryStatusCode(
                        for: buffered,
                        configuration: configuration
                    )
                    self.completeGatewayRetryLog(
                        batchID: timing.id,
                        statusCode: finalStatusCode,
                        succeeded: self.routeTargetResponseSucceeded(
                            buffered,
                            configuration: configuration
                        )
                    )
                    try await self.sendRouteTargetBufferedResponse(
                        buffered,
                        to: connection,
                        route: route,
                        timing: timing
                    )
                    return
                }

                Self.logTiming(
                    "request_retry_route_target",
                    context: timing,
                    statusCode: self.routeTargetRetryStatusCode(for: buffered, configuration: configuration),
                    isEventStream: buffered.isEventStream,
                    bytes: buffered.totalBytes,
                    extra: "attempt=\(attempt) max_attempts=\(maxAttempts) target=\(targetDiagnosticName)"
                )
                if buffered.shouldBlockGuardMatch {
                    self.recordGatewayRetryAttempt(
                        batchID: timing.id,
                        path: timing.route,
                        target: targetDiagnosticName,
                        statusCode: configuration.nonStreamStatusCode,
                        maximumRetryCount: maxAttempts - 1,
                        delay: 0,
                        delaySource: "reasoning_guard"
                    )
                } else {
                    try await self.waitBeforeGatewayRetry(
                        response: buffered.response,
                        attempt: attempt,
                        maximumRetryCount: maxAttempts - 1,
                        timing: timing,
                        statusCode: self.routeTargetRetryStatusCode(for: buffered, configuration: configuration),
                        target: targetDiagnosticName
                    )
                }
            } catch {
                let failure = self.resolvedPOSTFailure(from: error)
                self.reportPOSTFailureDiagnostic(
                    route: route,
                    target: targetName,
                    upstreamURL: upstreamURL,
                    failure: failure
                )
                guard self.shouldRetryRouteTargetFailure(failure, configuration: configuration),
                      attempt < maxAttempts else {
                    self.completeGatewayRetryLog(
                        batchID: timing.id,
                        statusCode: failure.statusCode,
                        succeeded: false
                    )
                    throw error
                }
                Self.logTiming(
                    "request_retry_route_target_failure",
                    context: timing,
                    statusCode: failure.statusCode,
                    extra: "attempt=\(attempt) max_attempts=\(maxAttempts) class=\(failure.failureClass.rawValue) target=\(targetDiagnosticName)"
                )
                try await self.waitBeforeGatewayRetry(
                    response: nil,
                    attempt: attempt,
                    maximumRetryCount: maxAttempts - 1,
                    timing: timing,
                    statusCode: failure.statusCode,
                    target: targetDiagnosticName
                )
            }
        }

        if let lastBufferedResponse {
            let finalStatusCode = self.routeTargetRetryStatusCode(
                for: lastBufferedResponse,
                configuration: configuration
            )
            self.completeGatewayRetryLog(
                batchID: timing.id,
                statusCode: finalStatusCode,
                succeeded: self.routeTargetResponseSucceeded(
                    lastBufferedResponse,
                    configuration: configuration
                )
            )
            try await self.sendRouteTargetBufferedResponse(
                lastBufferedResponse,
                to: connection,
                route: route,
                timing: timing
            )
        }
    }

    private func proxyRouteTargetPOSTResponses(
        body: Data,
        route: OpenAIAccountGatewayResponsesRoute,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        switch routeTarget {
        case .openAIAccount(let accountID):
            guard let account = self.account(withID: accountID) else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await self.proxyPOSTResponses(
                ParsedGatewayRequest(
                    method: "POST",
                    path: route.requestPath,
                    headers: [:],
                    body: body
                ),
                account: account,
                route: route
            )
        case .compatibleProvider(let target):
            let body = self.applyGatewayPromptPatchIfNeeded(body)
            return try await self.proxyProviderPOSTResponses(
                body: body,
                inboundHeaders: [:],
                route: route,
                target: target
            )
        case .openRouter(let target):
            let body = self.applyGatewayPromptPatchIfNeeded(body)
            return try await self.proxyOpenRouterPOSTResponses(
                body: body,
                inboundHeaders: [:],
                route: route,
                target: target
            )
        case .none:
            throw URLError(.userAuthenticationRequired)
        }
    }

    private func proxyPOSTResponses(
        _ request: ParsedGatewayRequest,
        account: TokenAccount,
        route: OpenAIAccountGatewayResponsesRoute
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let normalizedBody = await self.normalizeRequestBody(request.body, route: route)
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
            case "host",
                 "content-length",
                 "authorization",
                 "chatgpt-account-id",
                 "connection",
                 "originator":
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

        let stream = try await self.httpStreamingClient.stream(
            for: upstreamRequest,
            transportConfigurationOverride: nil
        )
        return (stream.response, stream.chunks)
    }

    private func proxyProviderPOSTResponses(
        _ request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let body = self.applyGatewayPromptPatchIfNeeded(request.body)
        return try await self.proxyProviderPOSTResponses(
            body: body,
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
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let body = try ToolHistoryCompatibility.normalize(body)
        if let thirdPartyProvider = target.thirdPartyModelProvider {
            if thirdPartyProvider == .openCode, route == .responses {
                if let compactionObject = self.thirdPartyCompactionRequestObject(from: body) {
                    return try await self.proxyThirdPartyCompaction(
                        requestObject: compactionObject,
                        inboundHeaders: inboundHeaders,
                        target: target,
                        thirdPartyProvider: thirdPartyProvider
                    )
                }
                return try await self.proxyOpenCodeResponsesNative(
                    body: body,
                    inboundHeaders: inboundHeaders,
                    target: target
                )
            }
            return try await self.proxyThirdPartyChatCompletions(
                body: body,
                inboundHeaders: inboundHeaders,
                route: route,
                target: target,
                thirdPartyProvider: thirdPartyProvider
            )
        }

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
        let stream = try await self.httpStreamingClient.stream(
            for: upstreamRequest,
            transportConfigurationOverride: self.routeTargetPOSTTransportConfigurationOverride(route: route)
        )
        return (stream.response, stream.chunks)
    }

    private func proxyThirdPartyChatCompletions(
        body: Data,
        inboundHeaders: [String: String],
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider,
        thirdPartyProvider: CodexBarThirdPartyModelProvider
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        if route == .responses,
           let compactionObject = self.thirdPartyCompactionRequestObject(from: body) {
            return try await self.proxyThirdPartyCompaction(
                requestObject: compactionObject,
                inboundHeaders: inboundHeaders,
                target: target,
                thirdPartyProvider: thirdPartyProvider
            )
        }

        let codexVisibleModelID = self.requestModelID(from: body) ?? target.modelID
        let normalizedBody = self.normalizeThirdPartyChatRequestBody(
            body,
            route: route,
            selectedModelID: target.modelID,
            thirdPartyProvider: thirdPartyProvider
        )
        var upstreamRequest = URLRequest(url: try self.thirdPartyChatCompletionsURL(baseURL: target.baseURL))
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
            case "host", "content-length", "authorization", "chatgpt-account-id", "connection", "originator", "api-key":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        switch thirdPartyProvider {
        case .deepSeek, .custom, .openCode:
            upstreamRequest.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "authorization")
        case .mimo:
            upstreamRequest.setValue(target.apiKey, forHTTPHeaderField: "api-key")
        }

        let stream = try await self.httpStreamingClient.stream(
            for: upstreamRequest,
            transportConfigurationOverride: self.routeTargetPOSTTransportConfigurationOverride(route: route)
        )
        guard (200...299).contains(stream.response.statusCode) else {
            return (stream.response, stream.chunks)
        }

        switch route {
        case .responses:
            let transformed = self.transformThirdPartyChatSSEToResponsesSSE(
                stream.chunks,
                modelID: codexVisibleModelID
            )
            return (
                self.makeSyntheticHTTPResponse(
                    statusCode: stream.response.statusCode,
                    contentType: "text/event-stream"
                ),
                transformed
            )
        case .compact:
            let data = try await self.readAllBytes(from: stream.chunks)
            if GatewayCapacityRetryPolicy.isCapacityBody(data, statusCode: stream.response.statusCode) {
                return (stream.response, self.singleChunkStream(data))
            }
            return (
                self.makeSyntheticHTTPResponse(
                    statusCode: stream.response.statusCode,
                    contentType: "application/json"
                ),
                self.singleChunkStream(
                    self.thirdPartyChatCompletionJSONToResponseJSON(
                        data,
                        modelID: codexVisibleModelID
                    )
                )
            )
        }
    }

    // MARK: - OpenCode native Responses

    private func proxyOpenCodeResponsesNative(
        body: Data,
        inboundHeaders: [String: String],
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let normalizedBody = self.normalizeOpenCodeResponsesBody(body, modelID: target.modelID)
        var upstreamRequest = URLRequest(url: try self.providerResponsesURL(baseURL: target.baseURL, route: .responses))
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
            case "host", "content-length", "authorization", "chatgpt-account-id",
                 "connection", "originator", "content-encoding", "transfer-encoding", "accept":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }

        upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        upstreamRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        upstreamRequest.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "authorization")
        if let sessionID = inboundHeaders["session_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           sessionID.isEmpty == false,
           upstreamRequest.value(forHTTPHeaderField: "x-opencode-session") == nil {
            upstreamRequest.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        }

        let stream = try await self.httpStreamingClient.stream(
            for: upstreamRequest,
            transportConfigurationOverride: self.routeTargetPOSTTransportConfigurationOverride(route: .responses)
        )
        guard stream.response.statusCode != 404, stream.response.statusCode != 405 else {
            return try await self.proxyThirdPartyChatCompletions(
                body: body,
                inboundHeaders: inboundHeaders,
                route: .responses,
                target: target,
                thirdPartyProvider: .openCode
            )
        }
        return (
            stream.response,
            stream.chunks
        )
    }



    private func normalizeOpenCodeResponsesBody(_ body: Data, modelID: String) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        object = self.unwrapResponseCreateEnvelopeIfNeeded(object)
        object["model"] = modelID
        object["stream"] = true
        object["store"] = false
        object.removeValue(forKey: "previous_response_id")
        object.removeValue(forKey: "access_programs")
        object.removeValue(forKey: "stream_options")
        object.removeValue(forKey: "prompt_cache_key")
        object.removeValue(forKey: "client_metadata")

        if var input = object["input"] as? [[String: Any]] {
            var summaries: [String] = []
            input = input.compactMap { item in
                guard let type = item["type"] as? String else { return item }
                if type == "compaction_trigger" {
                    return nil
                }
                if type == "compaction" || type == "compaction_summary" || type == "context_compaction" {
                    if let encoded = item["encrypted_content"] as? String {
                        let decoded = Data(base64Encoded: encoded)
                            .flatMap { String(data: $0, encoding: .utf8) } ?? encoded
                        if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            summaries.append("Earlier conversation summary:\n\(decoded)")
                        }
                    }
                    return nil
                }
                return item
            }
            if summaries.isEmpty == false {
                let existing = (object["instructions"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let summaryText = summaries.joined(separator: "\n\n")
                object["instructions"] = existing.isEmpty ? summaryText : "\(existing)\n\n\(summaryText)"
            }
            object["input"] = input
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return body
        }
        return data
    }

    // MARK: - Third-party remote compaction (Responses compaction v2)

    private static let thirdPartyCompactionPrompt = """
    You are compacting a coding session so another assistant can resume exactly where work stopped. Do not re-plan from scratch and do not restate system instructions. Output only a structured handoff with these sections:
    1. Original task and user constraints.
    2. Completed work: files, functions, paths, commands, and their concrete results.
    3. Current step / interruption point: the exact last action, tool call, error, or pending item.
    4. Immediate next action to take.
    5. Key facts to preserve: identifiers, paths, error messages, decisions, and anything partially changed.
    Preserve specific names and values instead of generic descriptions.
    """

    private func thirdPartyCompactionRequestObject(from body: Data) -> [String: Any]? {
        guard let raw = try? JSONSerialization.jsonObject(with: body) else { return nil }
        let object: [String: Any]
        if let dictionary = raw as? [String: Any] {
            object = self.unwrapResponseCreateEnvelopeIfNeeded(dictionary)
        } else if let array = raw as? [Any] {
            object = ["input": array]
        } else {
            return nil
        }
        guard let input = object["input"] as? [Any],
              input.contains(where: {
                  ($0 as? [String: Any])?["type"] as? String == "compaction_trigger"
              }) else {
            return nil
        }
        return object
    }

    private func proxyThirdPartyCompaction(
        requestObject: [String: Any],
        inboundHeaders: [String: String],
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider,
        thirdPartyProvider: CodexBarThirdPartyModelProvider
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let summary = try await self.thirdPartyCompactionSummary(
            requestObject: requestObject,
            inboundHeaders: inboundHeaders,
            target: target,
            thirdPartyProvider: thirdPartyProvider
        )
        let encodedSummary = Data(summary.utf8).base64EncodedString()
        let item: [String: Any] = [
            "id": "cmp_codexbar_\(UUID().uuidString)",
            "type": "compaction",
            "encrypted_content": encodedSummary,
        ]
        let responseID = "resp_codexbar_\(UUID().uuidString)"
        let createdAt = Int(Date().timeIntervalSince1970)
        var createdResponse: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": createdAt,
            "status": "in_progress",
            "model": target.modelID,
            "output": [],
            "output_text": "",
        ]
        var completedResponse = createdResponse
        completedResponse["status"] = "completed"
        completedResponse["output"] = [item]

        let events: [Data] = [
            self.responsesSSEEvent(["type": "response.created", "response": createdResponse]),
            self.responsesSSEEvent([
                "type": "response.output_item.added",
                "output_index": 0,
                "item": item,
            ]),
            self.responsesSSEEvent([
                "type": "response.output_item.done",
                "output_index": 0,
                "item": item,
            ]),
            self.responsesSSEEvent([
                "type": "response.completed",
                "response": completedResponse,
            ]),
        ]
        let payload = events.reduce(Data(), +) + Data("data: [DONE]\n\n".utf8)
        return (
            self.makeSyntheticHTTPResponse(statusCode: 200, contentType: "text/event-stream"),
            self.singleChunkStream(payload)
        )
    }

    private func thirdPartyCompactionSummary(
        requestObject: [String: Any],
        inboundHeaders: [String: String],
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider,
        thirdPartyProvider: CodexBarThirdPartyModelProvider
    ) async throws -> String {
        let fallback = self.thirdPartyFallbackCompactionSummary(from: requestObject)
        var messages = self.thirdPartyChatMessages(from: requestObject)
        let recentTranscript = self.thirdPartyCompactionTranscript(messages: messages)
        messages.append([
            "role": "user",
            "content": Self.thirdPartyCompactionPrompt,
        ])
        var chat: [String: Any] = [
            "model": target.modelID,
            "messages": messages,
            "stream": false,
            "temperature": 0,
        ]
        switch thirdPartyProvider {
        case .deepSeek, .custom, .openCode:
            chat["max_tokens"] = 6144
        case .mimo:
            chat["max_completion_tokens"] = 6144
        }
        guard let body = try? JSONSerialization.data(withJSONObject: chat),
              let data = try await self.sendThirdPartyCompactionRequestWithTimeout(
                  body: body,
                  inboundHeaders: inboundHeaders,
                  target: target,
                  thirdPartyProvider: thirdPartyProvider
              ),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let summary = message["content"] as? String,
              summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return fallback
        }
        guard recentTranscript.isEmpty == false else { return summary }
        return summary + "\n\n## Recent transcript (verbatim, most recent last)\n" + recentTranscript
    }

    private func thirdPartyCompactionTranscript(
        messages: [[String: Any]],
        limit: Int = 8_000
    ) -> String {
        let rendered = messages.compactMap { message -> String? in
            guard let role = message["role"] as? String, role != "system" else { return nil }
            var parts: [String] = []
            if let content = message["content"] as? String,
               content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               content.hasPrefix("<environment_context>") == false {
                parts.append(content)
            }
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                let calls = toolCalls.compactMap { call -> String? in
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else {
                        return nil
                    }
                    let arguments = (function["arguments"] as? String) ?? "{}"
                    return "\(name)(\(arguments))"
                }
                if calls.isEmpty == false {
                    parts.append("tool calls: " + calls.joined(separator: ", "))
                }
            }
            guard parts.isEmpty == false else { return nil }
            return "\(role): " + parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
        guard rendered.count > limit else { return rendered }
        return String(rendered.suffix(limit))
    }

    private func sendThirdPartyCompactionRequestWithTimeout(
        body: Data, inboundHeaders: [String: String], target: OpenAIAccountGatewayRouteTarget.CompatibleProvider,
        thirdPartyProvider: CodexBarThirdPartyModelProvider
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await self.sendThirdPartyCompactionRequest(body: body, inboundHeaders: inboundHeaders,
                    target: target, thirdPartyProvider: thirdPartyProvider)
            }
            group.addTask { try await Task.sleep(nanoseconds: 60_000_000_000); return nil }
            do {
                let result = try await group.next() ?? nil
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if error is GatewayCapacityRejection || error is GatewayCapacityRequestBudget.Exhausted || Task.isCancelled { throw error }
                return nil
            }
        }
    }

    private func sendThirdPartyCompactionRequest(
        body: Data,
        inboundHeaders: [String: String],
        target: OpenAIAccountGatewayRouteTarget.CompatibleProvider,
        thirdPartyProvider: CodexBarThirdPartyModelProvider
    ) async throws -> Data? {
        var upstreamRequest = URLRequest(url: try self.thirdPartyChatCompletionsURL(baseURL: target.baseURL))
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = body
        let mutableRequest = (upstreamRequest as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            body,
            forKey: Self.mockRequestBodyPropertyKey,
            in: mutableRequest
        )
        upstreamRequest = mutableRequest as URLRequest
        for (name, value) in inboundHeaders {
            switch name {
            case "host", "content-length", "authorization", "chatgpt-account-id",
                 "connection", "originator", "api-key", "accept",
                 "content-encoding", "transfer-encoding":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: name)
            }
        }
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "accept")
        switch thirdPartyProvider {
        case .deepSeek, .custom, .openCode:
            upstreamRequest.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "authorization")
        case .mimo:
            upstreamRequest.setValue(target.apiKey, forHTTPHeaderField: "api-key")
        }
        let stream = try await self.httpStreamingClient.stream(
            for: upstreamRequest,
            transportConfigurationOverride: self.routeTargetPOSTTransportConfigurationOverride(route: .responses)
        )
        let data = try await self.readAllBytes(from: stream.chunks)
        if GatewayCapacityRetryPolicy.isCapacityBody(data, statusCode: stream.response.statusCode) {
            throw GatewayCapacityRejection(response: stream.response, body: data)
        }
        guard (200...299).contains(stream.response.statusCode) else { return nil }
        return data
    }

    private func thirdPartyFallbackCompactionSummary(from requestObject: [String: Any]) -> String {
        let messages = self.thirdPartyChatMessages(from: requestObject)
        let transcript = self.thirdPartyCompactionTranscript(messages: messages, limit: 12_000)
        return """
        Earlier conversation summary (automatically truncated; use the transcript below to resume):
        \(transcript)
        """
    }

    private func proxyOpenRouterPOSTResponses(
        _ request: ParsedGatewayRequest,
        route: OpenAIAccountGatewayResponsesRoute,
        target: OpenAIAccountGatewayRouteTarget.OpenRouter
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let body = self.applyGatewayPromptPatchIfNeeded(request.body)
        return try await self.proxyOpenRouterPOSTResponses(
            body: body,
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
    ) async throws -> (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>) {
        let body = try ToolHistoryCompatibility.normalize(body)
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
        let stream = try await self.httpStreamingClient.stream(
            for: upstreamRequest,
            transportConfigurationOverride: self.routeTargetPOSTTransportConfigurationOverride(route: route)
        )
        return (stream.response, stream.chunks)
    }

    private func routeTargetPOSTTransportConfigurationOverride(
        route: OpenAIAccountGatewayResponsesRoute
    ) -> OpenAIAccountGatewayUpstreamTransportConfiguration? {
        switch route {
        case .responses:
            return .routeTargetResponses
        case .compact:
            return .routeTargetCompact
        }
    }

    private func bufferRouteTargetResponse(
        _ result: (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>),
        route: OpenAIAccountGatewayResponsesRoute,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws -> OpenAIAccountGatewayRouteTargetBufferedResponse {
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

        var buffer = Data()
        var eventAccumulator = SSEEventStreamAccumulator()
        var totalBytes = 0
        let guardConfiguration = self.reasoningRetryGuardConfigurationSnapshot()
        let shouldInspectReasoning = self.shouldInspectReasoningRetryGuard(
            route: route,
            configuration: guardConfiguration
        )
        var observedReasoningTokens: Int?
        var guardMatch: OpenAIAccountGatewayReasoningGuardMatch?

        for try await chunk in result.bytes {
            guard chunk.isEmpty == false else { continue }
            totalBytes += chunk.count
            if isEventStream {
                for eventChunk in eventAccumulator.append(contentsOf: chunk) {
                    if shouldInspectReasoning {
                        if guardConfiguration.matchMode == .strict,
                           let assessment = self.reasoningGuardAssessment(
                               inSSEEvent: eventChunk,
                               configuration: guardConfiguration
                           ) {
                            observedReasoningTokens = assessment.reasoningTokens
                            if assessment.shouldMatch {
                                guardMatch = guardMatch ?? assessment.match
                            }
                        } else if let reasoningTokens = self.reasoningTokens(inSSEEvent: eventChunk) {
                            observedReasoningTokens = reasoningTokens
                        }
                    }
                    buffer.append(eventChunk)
                }
            } else {
                buffer.append(chunk)
            }
        }

        if isEventStream {
            if let remaining = eventAccumulator.flush() {
                if shouldInspectReasoning,
                   guardConfiguration.matchMode == .strict,
                   let assessment = self.reasoningGuardAssessment(inSSEEvent: remaining, configuration: guardConfiguration) {
                    observedReasoningTokens = assessment.reasoningTokens
                    if assessment.shouldMatch {
                        guardMatch = guardMatch ?? assessment.match
                    }
                } else if shouldInspectReasoning,
                          let reasoningTokens = self.reasoningTokens(inSSEEvent: remaining) {
                    observedReasoningTokens = reasoningTokens
                }
                buffer.append(remaining)
            }
            if shouldInspectReasoning,
               guardConfiguration.matchMode == .cautious,
               let match = self.reasoningGuardMatch(
                   inBody: buffer,
                   isEventStream: true,
                   configuration: guardConfiguration
               ) {
                guardMatch = match
                observedReasoningTokens = match.reasoningTokens
            }
        } else {
            if shouldInspectReasoning,
               let assessment = self.reasoningGuardAssessment(inJSONData: buffer, configuration: guardConfiguration) {
                observedReasoningTokens = assessment.reasoningTokens
                if assessment.shouldMatch {
                    guardMatch = assessment.match
                }
            } else if shouldInspectReasoning,
                      let reasoningTokens = self.reasoningTokens(inJSONData: buffer) {
                observedReasoningTokens = reasoningTokens
            }
        }

        if shouldInspectReasoning {
            let guardBlocked = guardMatch != nil
                && (isEventStream ? guardConfiguration.interceptStreaming : guardConfiguration.interceptNonStreaming)
            self.recordReasoningRetryGuardInspection(
                reasoningTokens: guardMatch?.reasoningTokens ?? observedReasoningTokens,
                matchEvidence: guardMatch?.evidence ?? [],
                matched: guardMatch != nil,
                blocked: guardBlocked,
                route: route,
                isEventStream: isEventStream,
                configuration: guardConfiguration
            )
        }

        let shouldBlockGuardMatch = guardMatch != nil
            && (isEventStream ? guardConfiguration.interceptStreaming : guardConfiguration.interceptNonStreaming)

        return OpenAIAccountGatewayRouteTargetBufferedResponse(
            response: result.response,
            body: buffer,
            isEventStream: isEventStream,
            totalBytes: totalBytes,
            guardMatch: guardMatch,
            shouldBlockGuardMatch: shouldBlockGuardMatch
        )
    }

    private func shouldRetryRouteTargetResponse(
        _ buffered: OpenAIAccountGatewayRouteTargetBufferedResponse,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Bool {
        self.shouldRetryRouteTargetResponse(
            statusCode: buffered.response.statusCode,
            body: buffered.body,
            shouldBlockGuardMatch: buffered.shouldBlockGuardMatch,
            configuration: configuration
        )
    }

    private func shouldRetryRouteTargetResponse(
        statusCode: Int,
        body: Data,
        shouldBlockGuardMatch: Bool,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Bool {
        if shouldBlockGuardMatch {
            return true
        }
        if configuration.retryableStatusCodes.contains(statusCode) {
            return true
        }
        return configuration.retryUpstreamCapacityErrors
            && self.isUpstreamCapacityErrorResponse(statusCode: statusCode, body: body)
    }

    private func routeTargetRetryStatusCode(
        for buffered: OpenAIAccountGatewayRouteTargetBufferedResponse,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Int {
        if buffered.shouldBlockGuardMatch {
            return configuration.nonStreamStatusCode
        }
        if (200...299).contains(buffered.response.statusCode),
           self.isRetryableUpstreamCapacityResponse(buffered, configuration: configuration) {
            return 503
        }
        return buffered.response.statusCode
    }

    private func routeTargetResponseSucceeded(
        _ buffered: OpenAIAccountGatewayRouteTargetBufferedResponse,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Bool {
        buffered.shouldBlockGuardMatch == false
            && self.isRetryableUpstreamCapacityResponse(buffered, configuration: configuration) == false
            && (200...299).contains(buffered.response.statusCode)
    }

    private func isRetryableUpstreamCapacityResponse(
        _ buffered: OpenAIAccountGatewayRouteTargetBufferedResponse,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Bool {
        configuration.retryUpstreamCapacityErrors
            && self.isUpstreamCapacityErrorResponse(
                statusCode: buffered.response.statusCode,
                body: buffered.body
            )
    }

    private func isUpstreamCapacityErrorResponse(statusCode: Int, body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8)?.lowercased() else {
            return false
        }
        let containsCapacitySignal = text.contains("selected model is at capacity. please try a different model.")
            || (
                text.contains("selected model is at capacity")
                    && text.contains("try a different model")
            )
            || text.contains("server_overloaded")
        guard containsCapacitySignal else { return false }
        return statusCode >= 400 || self.containsInBandErrorEnvelope(in: body)
    }

    private func containsInBandErrorEnvelope(in body: Data) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: body),
           self.isErrorEnvelope(object) {
            return true
        }

        guard let text = String(data: body, encoding: .utf8) else { return false }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased() == "event: error" {
                return true
            }
            guard trimmed.lowercased().hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst("data:".count))
                .trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            if self.isErrorEnvelope(object) {
                return true
            }
        }
        return false
    }

    private func isErrorEnvelope(_ object: Any) -> Bool {
        guard let dictionary = object as? [String: Any] else { return false }
        if self.hasNonNullJSONValue(dictionary["error"]) {
            return true
        }
        let type = (dictionary["type"] as? String)?.lowercased()
        if type == "error" || type == "response.failed" {
            return true
        }
        guard let response = dictionary["response"] as? [String: Any] else { return false }
        return self.hasNonNullJSONValue(response["error"])
            || (response["status"] as? String)?.lowercased() == "failed"
    }

    private func hasNonNullJSONValue(_ value: Any?) -> Bool {
        guard let value else { return false }
        return (value is NSNull) == false
    }

    private func waitBeforeGatewayRetry(
        response: HTTPURLResponse?,
        attempt: Int,
        maximumRetryCount: Int,
        timing: OpenAIAccountGatewayTimingContext,
        statusCode: Int?,
        target: String
    ) async throws {
        let retryDelay = self.gatewayRetryDelay(response: response, attempt: attempt)
        self.recordGatewayRetryAttempt(
            batchID: timing.id,
            path: timing.route,
            target: target,
            statusCode: statusCode,
            maximumRetryCount: maximumRetryCount,
            delay: retryDelay.delay,
            delaySource: retryDelay.source
        )
        Self.logTiming(
            "request_retry_backoff",
            context: timing,
            statusCode: statusCode,
            extra: "attempt=\(attempt) delay_ms=\(Int((retryDelay.delay * 1_000).rounded())) source=\(retryDelay.source) target=\(target)"
        )
        try await self.retryDelaySleeper(retryDelay.delay)
    }

    private func gatewayRetryDelay(
        response: HTTPURLResponse?,
        attempt: Int
    ) -> (delay: TimeInterval, source: String) {
        if let retryAt = self.retryAt(from: response) {
            let delay = max(0, retryAt.timeIntervalSinceNow)
            if delay.isFinite {
                return (delay, "retry_after")
            }
        }

        let exponent = min(max(attempt - 1, 0), 6)
        let baseDelay = min(pow(2, Double(exponent)), 60)
        let jitterMultiplier = min(max(self.retryJitterMultiplier(), 0.8), 1.2)
        return (baseDelay * jitterMultiplier, "exponential_jitter")
    }

    private func shouldRetryRouteTargetFailure(
        _ failure: OpenAIAccountGatewayUpstreamFailure,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> Bool {
        switch failure {
        case .upstreamStatus(let statusCode):
            return configuration.retryableStatusCodes.contains(statusCode)
        case .accountStatus, .transport, .protocolViolation:
            return false
        }
    }

    private func sendRouteTargetBufferedResponse(
        _ buffered: OpenAIAccountGatewayRouteTargetBufferedResponse,
        to connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws {
        if let guardMatch = buffered.guardMatch,
           buffered.shouldBlockGuardMatch {
            let guardConfiguration = self.reasoningRetryGuardConfigurationSnapshot()
            self.sendReasoningGuardBlockedResponse(
                on: connection,
                route: route,
                reasoningTokens: guardMatch.reasoningTokens,
                statusCode: guardConfiguration.nonStreamStatusCode
            )
            Self.logTiming(
                "request_blocked_reasoning_guard",
                context: timing,
                statusCode: guardConfiguration.nonStreamStatusCode,
                isEventStream: buffered.isEventStream,
                bytes: buffered.totalBytes
            )
            return
        }

        let headers = self.renderResponseHeaders(from: buffered.response)
        try await self.send(Data(headers.utf8), on: connection)
        if buffered.body.isEmpty == false {
            try await self.send(buffered.body, on: connection)
            Self.logTiming(
                "first_downstream_body",
                context: timing,
                statusCode: buffered.response.statusCode,
                isEventStream: buffered.isEventStream,
                bytes: buffered.totalBytes
            )
        }
        Self.logTiming(
            "request_completed",
            context: timing,
            statusCode: buffered.response.statusCode,
            isEventStream: buffered.isEventStream,
            bytes: buffered.totalBytes
        )
        connection.cancel()
    }

    private func readAllBytes(from bytes: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var data = Data()
        for try await chunk in bytes {
            data.append(chunk)
        }
        return data
    }

    private func normalizeRequestBody(_ body: Data, route: OpenAIAccountGatewayResponsesRoute) async -> Data {
        let patchedBody = self.applyGatewayPromptPatchIfNeeded(body)
        switch route {
        case .responses:
            return self.normalizeResponsesRequestBody(patchedBody)
        case .compact:
            return self.normalizeCompactRequestBody(patchedBody)
        }
    }

    private func applyGatewayPromptPatchIfNeeded(_ body: Data) -> Data {
        let settings = self.stateQueue.sync {
            self.gatewayPromptPatchSettings
        }
        guard settings.isEnabled else { return body }
        let instructionsPatch = settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard instructionsPatch.isEmpty == false else { return body }

        guard var json = (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) as? [String: Any] else {
            return body
        }
        if var response = json["response"] as? [String: Any],
           (json["type"] as? String) == "response.create" {
            response = self.appendInstructionsPatch(instructionsPatch, to: response)
            json["response"] = response
        } else {
            json = self.appendInstructionsPatch(instructionsPatch, to: json)
        }

        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return data
    }

    private func appendInstructionsPatch(_ patch: String, to json: [String: Any]) -> [String: Any] {
        var patched = json
        let existing = (patched["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existing.contains(patch) {
            patched["instructions"] = existing
        } else if existing.isEmpty {
            patched["instructions"] = patch
        } else {
            patched["instructions"] = "\(existing)\n\n\(patch)"
        }
        return patched
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
            path += "/responses/compact"
        }
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func thirdPartyChatCompletionsURL(baseURL: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else {
            throw URLError(.badURL)
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/chat/completions"
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func makeSyntheticHTTPResponse(statusCode: Int, contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: OpenAIAccountGatewayConfiguration.baseURLString)!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    private func singleChunkStream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        }
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
        json = self.sanitizeNonOpenAIRequestObject(json)
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
            if json["instructions"] == nil || json["instructions"] is NSNull {
                json["instructions"] = ""
            }
        }
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return body
        }
        return data
    }

    private func requestModelID(from body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        let responseObject = self.unwrapResponseCreateEnvelopeIfNeeded(object)
        let trimmed = (responseObject["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeThirdPartyChatRequestBody(
        _ body: Data,
        route: OpenAIAccountGatewayResponsesRoute,
        selectedModelID: String,
        thirdPartyProvider: CodexBarThirdPartyModelProvider
    ) -> Data {
        let responseObject: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: body) {
            if let json = object as? [String: Any] {
                responseObject = self.unwrapResponseCreateEnvelopeIfNeeded(json)
            } else if let inputArray = object as? [Any] {
                responseObject = ["input": inputArray]
            } else {
                responseObject = ["input": String(data: body, encoding: .utf8) ?? ""]
            }
        } else {
            responseObject = ["input": String(data: body, encoding: .utf8) ?? ""]
        }

        var chat: [String: Any] = [
            "model": selectedModelID,
            "messages": self.thirdPartyChatMessages(from: responseObject),
            "stream": route == .responses,
        ]

        if route == .responses {
            chat["stream_options"] = ["include_usage": true]
        }
        if let tools = self.thirdPartyChatTools(from: responseObject["tools"]), tools.isEmpty == false {
            chat["tools"] = tools
            chat["tool_choice"] = self.thirdPartyChatToolChoice(
                responseObject["tool_choice"],
                hasTools: true
            )
        } else {
            chat["tool_choice"] = "none"
        }
        if let maxOutputTokens = responseObject["max_output_tokens"] {
            switch thirdPartyProvider {
            case .deepSeek, .custom, .openCode:
                chat["max_tokens"] = maxOutputTokens
            case .mimo:
                chat["max_completion_tokens"] = maxOutputTokens
            }
        }
        if let temperature = responseObject["temperature"] {
            chat["temperature"] = temperature
        }
        if let topP = responseObject["top_p"] {
            chat["top_p"] = topP
        }
        if let responseFormat = responseObject["response_format"] {
            chat["response_format"] = responseFormat
        }
        let reasoningEffort = self.thirdPartyReasoningEffort(from: responseObject["reasoning"])
        switch thirdPartyProvider {
        case .deepSeek:
            chat["thinking"] = ["type": "enabled"]
            chat["reasoning_effort"] = reasoningEffort
        case .mimo:
            chat["thinking"] = ["type": "enabled"]
        case .custom, .openCode:
            break
        }

        guard JSONSerialization.isValidJSONObject(chat),
              let data = try? JSONSerialization.data(withJSONObject: chat, options: [.sortedKeys]) else {
            return self.fallbackThirdPartyChatRequestBody(
                route: route,
                selectedModelID: selectedModelID,
                inputText: String(data: body, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private func fallbackThirdPartyChatRequestBody(
        route: OpenAIAccountGatewayResponsesRoute,
        selectedModelID: String,
        inputText: String
    ) -> Data {
        var chat: [String: Any] = [
            "model": selectedModelID,
            "messages": [
                ["role": "user", "content": inputText],
            ],
            "stream": route == .responses,
            "tool_choice": "none",
        ]
        if route == .responses {
            chat["stream_options"] = ["include_usage": true]
        }
        return (try? JSONSerialization.data(withJSONObject: chat)) ?? Data(#"{"messages":[{"role":"user","content":""}],"stream":false,"tool_choice":"none"}"#.utf8)
    }

    private func thirdPartyChatMessages(from responseObject: [String: Any]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let instructions = (responseObject["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           instructions.isEmpty == false {
            messages.append(["role": "system", "content": self.thirdPartyLanguageAwareInstructions(instructions, responseObject: responseObject)])
        } else {
            messages.append(["role": "system", "content": self.thirdPartyLanguageInstruction(for: responseObject)])
        }

        if let input = responseObject["input"] {
            messages.append(contentsOf: self.thirdPartyChatMessages(fromInput: input))
        }

        let hasCompactionSummary = messages.contains { message in
            message["role"] as? String == "system" &&
                (message["content"] as? String)?.hasPrefix("Earlier conversation summary") == true
        }
        if hasCompactionSummary {
            messages.append([
                "role": "system",
                "content": "Resume from the interruption point in the earlier summary unless the latest user message explicitly starts a different task. Do not repeat completed tool calls, re-run finished commands, or restart the task.",
            ])
        }

        if messages.isEmpty {
            messages.append(["role": "user", "content": ""])
        }
        return messages
    }

    private func thirdPartyChatMessages(fromInput input: Any) -> [[String: Any]] {
        if let text = input as? String {
            return [["role": "user", "content": text]]
        }
        guard let items = input as? [Any] else {
            return [["role": "user", "content": self.thirdPartyTextContent(from: input) ?? ""]]
        }

        var messages: [[String: Any]] = []
        var pendingToolCalls: [[String: Any]] = []
        func flushPendingToolCalls() {
            guard pendingToolCalls.isEmpty == false else { return }
            messages.append([
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": pendingToolCalls,
            ])
            pendingToolCalls.removeAll()
        }

        for item in items {
            guard let dictionary = item as? [String: Any] else {
                flushPendingToolCalls()
                if let content = self.thirdPartyTextContent(from: item), content.isEmpty == false {
                    messages.append(["role": "user", "content": content])
                }
                continue
            }

            let type = dictionary["type"] as? String
            if type == "compaction_trigger" {
                continue
            }
            if type == "compaction" || type == "compaction_summary" || type == "context_compaction" {
                flushPendingToolCalls()
                if let encoded = dictionary["encrypted_content"] as? String {
                    let decoded = Data(base64Encoded: encoded)
                        .flatMap { String(data: $0, encoding: .utf8) } ?? encoded
                    if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        messages.append([
                            "role": "system",
                            "content": "Earlier conversation summary (authoritative continuation state; resume from the interruption point and do not restart the task):\n\(decoded)",
                        ])
                    }
                }
                continue
            }
            if type == "reasoning" {
                continue
            }
            if type == "output_text" {
                flushPendingToolCalls()
                if let content = self.thirdPartyTextContent(from: dictionary["text"] ?? dictionary["content"] ?? ""),
                   content.isEmpty == false {
                    messages.append(["role": "assistant", "content": content])
                }
                continue
            }
            if type == "input_text" {
                flushPendingToolCalls()
                if let content = self.thirdPartyTextContent(from: dictionary["text"] ?? dictionary["content"] ?? ""),
                   content.isEmpty == false {
                    messages.append(["role": "user", "content": content])
                }
                continue
            }
            if type == "custom_tool_call" {
                let callID = ToolHistoryCompatibility.nonempty(dictionary["call_id"]) ?? ToolHistoryCompatibility.nonempty(dictionary["id"]) ?? "call_codexbar"
                let name = (dictionary["name"] as? String) ?? "custom_tool"
                let input = self.thirdPartyTextContent(from: dictionary["input"] ?? "") ?? ""
                pendingToolCalls.append([
                    "id": callID,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": self.compactJSONString(from: ["input": input]) ?? "{}",
                    ],
                ])
                continue
            }

            if type == "function_call" {
                let callID = ToolHistoryCompatibility.nonempty(dictionary["call_id"]) ?? ToolHistoryCompatibility.nonempty(dictionary["id"]) ?? "call_codexbar"
                let name = (dictionary["name"] as? String) ?? "tool"
                let arguments = (dictionary["arguments"] as? String) ?? "{}"
                pendingToolCalls.append([
                    "id": callID,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": arguments,
                    ],
                ])
                continue
            }

            if type == "function_call_output" || type == "custom_tool_call_output" {
                flushPendingToolCalls()
                let content = self.thirdPartyTextContent(from: dictionary["output"] ?? dictionary["content"] ?? "") ?? ""
                let explicitCallID = ToolHistoryCompatibility.nonempty(dictionary["call_id"])
                // Newer Codex injects context records as function_call_output items with a
                // name/namespace but no call_id. They have no tool call to answer here.
                if explicitCallID == nil,
                   let contextName = ToolHistoryCompatibility.nonempty(dictionary["name"])
                    ?? ToolHistoryCompatibility.nonempty(dictionary["namespace"]) {
                    if content.isEmpty == false {
                        messages.append(["role": "system", "content": "\(contextName): \(content)"])
                    }
                    continue
                }
                let callID = explicitCallID ?? ToolHistoryCompatibility.nonempty(dictionary["id"]) ?? "call_codexbar"
                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": content,
                ])
                continue
            }

            flushPendingToolCalls()
            let role = self.thirdPartyChatRole(from: dictionary["role"])
            let content = self.thirdPartyTextContent(from: dictionary["content"] ?? dictionary["text"] ?? "")
            if let content, content.isEmpty == false {
                messages.append(["role": role, "content": content])
            }
        }
        flushPendingToolCalls()
        return messages
    }

    private func thirdPartyChatRole(from value: Any?) -> String {
        switch (value as? String)?.lowercased() {
        case "system", "developer":
            return "system"
        case "assistant":
            return "assistant"
        case "tool", "function":
            return "tool"
        default:
            return "user"
        }
    }

    private func thirdPartyTextContent(from value: Any) -> String? {
        if value is NSNull { return nil }
        if let text = value as? String { return text }
        if let dictionary = value as? [String: Any] {
            if let text = dictionary["text"] as? String { return text }
            if let output = dictionary["output"] as? String { return output }
            if let content = dictionary["content"] { return self.thirdPartyTextContent(from: content) }
            return self.compactJSONString(from: dictionary)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                guard let dictionary = item as? [String: Any] else {
                    return self.thirdPartyTextContent(from: item)
                }
                let type = dictionary["type"] as? String
                if type == nil || type == "text" || type == "input_text" || type == "output_text" {
                    return self.thirdPartyTextContent(from: dictionary["text"] ?? dictionary["content"] ?? "")
                }
                return nil
            }
            return parts.joined(separator: "\n")
        }
        return self.compactJSONString(from: value)
    }

    private func thirdPartyLanguageAwareInstructions(_ instructions: String, responseObject: [String: Any]) -> String {
        instructions + "\n\n" + self.thirdPartyLanguageInstruction(for: responseObject)
    }

    private func thirdPartyLanguageInstruction(for responseObject: [String: Any]) -> String {
        if self.thirdPartyInputPrefersChinese(responseObject["input"]) || L.zh {
            return "请使用用户当前使用的语言回复；如果用户使用中文，请使用简体中文。不要仅因为系统提示、工具上下文或开发者指令是英文就改用英文。"
        }
        return "Reply in the same language the user uses. Do not switch languages just because system, tool, or developer context is in English."
    }

    private func thirdPartyInputPrefersChinese(_ input: Any?) -> Bool {
        guard let input else { return false }
        let content = self.thirdPartyChatMessages(fromInput: input)
            .compactMap { $0["content"] as? String }
            .joined(separator: "\n")
        return content.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
                || (0xF900...0xFAFF).contains(Int(scalar.value))
        }
    }

    private func thirdPartyChatTools(from tools: Any?) -> [[String: Any]]? {
        guard let items = tools as? [Any] else { return nil }
        let mapped: [[String: Any]] = items.compactMap { item in
            guard let tool = item as? [String: Any] else { return nil }
            let type = tool["type"] as? String
            if type == "function",
               let function = tool["function"] as? [String: Any] {
                return ["type": "function", "function": function]
            }
            let resolvedName = (tool["name"] as? String) ?? (type == "apply_patch" ? "apply_patch" : nil)
            guard let name = resolvedName, name.isEmpty == false else {
                return nil
            }
            var function: [String: Any] = ["name": name]
            if let description = tool["description"] as? String {
                function["description"] = description
            }
            if let parameters = tool["parameters"] {
                function["parameters"] = parameters
            } else if Self.thirdPartyCustomToolNames.contains(name) || type == "custom" || type == "apply_patch" {
                function["parameters"] = [
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": "Raw tool input. For apply_patch, this must be the full patch text.",
                        ],
                    ],
                    "required": ["input"],
                ]
            }
            return ["type": "function", "function": function]
        }
        return mapped
    }

    private func thirdPartyChatToolChoice(_ value: Any?, hasTools: Bool) -> Any {
        guard hasTools else { return "none" }
        guard let value, (value is NSNull) == false else { return "auto" }
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? [String: Any] {
            if (dictionary["type"] as? String) == "function",
               dictionary["function"] != nil {
                return dictionary
            }
            if let name = dictionary["name"] as? String {
                return ["type": "function", "function": ["name": name]]
            }
        }
        return "auto"
    }

    private func thirdPartyReasoningEffort(from reasoning: Any?) -> String {
        let raw: String?
        if let string = reasoning as? String {
            raw = string
        } else if let dictionary = reasoning as? [String: Any] {
            raw = dictionary["effort"] as? String
        } else {
            raw = nil
        }
        switch raw?.lowercased() {
        case "max", "xhigh":
            return "max"
        default:
            return "high"
        }
    }

    private struct ThirdPartyFunctionCallStreamState {
        var itemID: String
        var callID: String
        var name: String
        var arguments: String
        var outputIndex: Int
        var didEmitItem: Bool
    }

    private func thirdPartyCustomToolInput(name: String, arguments: String) -> String {
        guard Self.thirdPartyCustomToolNames.contains(name),
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = object["input"] as? String else {
            return arguments
        }
        return input
    }

    private func thirdPartyCustomToolInputDelta(from argumentsDelta: String) -> String? {
        if argumentsDelta.hasPrefix(#"{"input":""#) {
            return String(argumentsDelta.dropFirst(#"{"input":""#.count))
        }
        if argumentsDelta == #""}"# || argumentsDelta == #"" }"# {
            return nil
        }
        if argumentsDelta.hasSuffix(#""}"#) {
            return String(argumentsDelta.dropLast(2))
        }
        return argumentsDelta
    }

    private func thirdPartyToolCallItem(from state: ThirdPartyFunctionCallStreamState, status: String) -> [String: Any] {
        if Self.thirdPartyCustomToolNames.contains(state.name) {
            return [
                "id": state.itemID.hasPrefix("ctc_") ? state.itemID : "ctc_" + state.itemID,
                "type": "custom_tool_call",
                "status": status,
                "call_id": state.callID,
                "name": state.name,
                "input": self.thirdPartyCustomToolInput(name: state.name, arguments: state.arguments),
            ]
        }
        return [
            "id": state.itemID,
            "type": "function_call",
            "status": status,
            "call_id": state.callID,
            "name": state.name,
            "arguments": state.arguments,
        ]
    }

    private func transformThirdPartyChatSSEToResponsesSSE(
        _ chunks: AsyncThrowingStream<Data, Error>,
        modelID: String
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var accumulator = SSEEventStreamAccumulator()
                let responseID = "resp_codexbar_\(UUID().uuidString)"
                let messageID = "msg_codexbar_\(UUID().uuidString)"
                var messageOutputIndex: Int?
                var nextOutputIndex = 0
                var text = ""
                var contentPartAdded = false
                var functionCalls: [Int: ThirdPartyFunctionCallStreamState] = [:]
                var usage: [String: Any]?
                var didComplete = false

                func emit(_ payload: [String: Any]) {
                    continuation.yield(self.responsesSSEEvent(payload))
                }

                func ensureMessageItem() {
                    if messageOutputIndex == nil {
                        messageOutputIndex = nextOutputIndex
                        nextOutputIndex += 1
                        emit([
                            "type": "response.output_item.added",
                            "output_index": messageOutputIndex ?? 0,
                            "item": [
                                "id": messageID,
                                "type": "message",
                                "status": "in_progress",
                                "role": "assistant",
                                "content": [],
                            ],
                        ])
                    }
                    if contentPartAdded == false {
                        contentPartAdded = true
                        emit([
                            "type": "response.content_part.added",
                            "item_id": messageID,
                            "output_index": messageOutputIndex ?? 0,
                            "content_index": 0,
                            "part": ["type": "output_text", "text": ""],
                        ])
                    }
                }

                func finishMessageIfNeeded() {
                    guard let outputIndex = messageOutputIndex, contentPartAdded else { return }
                    emit([
                        "type": "response.content_part.done",
                        "item_id": messageID,
                        "output_index": outputIndex,
                        "content_index": 0,
                        "part": ["type": "output_text", "text": text],
                    ])
                    emit([
                        "type": "response.output_item.done",
                        "output_index": outputIndex,
                        "item": [
                            "id": messageID,
                            "type": "message",
                            "status": "completed",
                            "role": "assistant",
                            "content": [["type": "output_text", "text": text]],
                        ],
                    ])
                }

                func ensureFunctionCall(index: Int, delta: [String: Any]) -> ThirdPartyFunctionCallStreamState {
                    if let existing = functionCalls[index] {
                        return existing
                    }
                    let itemID = "fc_codexbar_\(UUID().uuidString)"
                    let callID = ToolHistoryCompatibility.nonempty(delta["id"]) ?? "call_codexbar_\(UUID().uuidString)"
                    let function = delta["function"] as? [String: Any]
                    let name = (function?["name"] as? String) ?? ""
                    let state = ThirdPartyFunctionCallStreamState(
                        itemID: itemID,
                        callID: callID,
                        name: name,
                        arguments: "",
                        outputIndex: nextOutputIndex,
                        didEmitItem: false
                    )
                    nextOutputIndex += 1
                    functionCalls[index] = state
                    return state
                }

                func emitFunctionCallItemIfNeeded(_ state: inout ThirdPartyFunctionCallStreamState) {
                    guard state.didEmitItem == false, !state.name.isEmpty else { return }
                    if Self.thirdPartyCustomToolNames.contains(state.name) { state.itemID = state.itemID.replacingOccurrences(of: "fc_", with: "ctc_", options: .anchored) }
                    emit([
                        "type": "response.output_item.added",
                        "output_index": state.outputIndex,
                        "item": self.thirdPartyToolCallItem(from: state, status: "in_progress"),
                    ])
                    state.didEmitItem = true
                }

                func finishFunctionCallsIfNeeded() {
                    for var state in functionCalls.values.sorted(by: { $0.outputIndex < $1.outputIndex }) {
                        emitFunctionCallItemIfNeeded(&state)
                        if Self.thirdPartyCustomToolNames.contains(state.name) {
                            emit([
                                "type": "response.custom_tool_call_input.done",
                                "item_id": state.itemID,
                                "output_index": state.outputIndex,
                                "input": self.thirdPartyCustomToolInput(name: state.name, arguments: state.arguments),
                            ])
                        } else {
                            emit([
                                "type": "response.function_call_arguments.done",
                                "item_id": state.itemID,
                                "output_index": state.outputIndex,
                                "arguments": state.arguments,
                            ])
                        }
                        emit([
                            "type": "response.output_item.done",
                            "output_index": state.outputIndex,
                            "item": self.thirdPartyToolCallItem(from: state, status: "completed"),
                        ])
                    }
                }

                func finishResponse() {
                    guard didComplete == false else { return }
                    finishMessageIfNeeded()
                    finishFunctionCallsIfNeeded()
                    emit([
                        "type": "response.completed",
                        "response": self.thirdPartyResponseObject(
                            id: responseID,
                            modelID: modelID,
                            status: "completed",
                            outputText: text,
                            functionCalls: functionCalls.values.sorted(by: { $0.outputIndex < $1.outputIndex }),
                            usage: usage
                        ),
                    ])
                    didComplete = true
                }

                emit([
                    "type": "response.created",
                    "response": self.thirdPartyResponseObject(
                        id: responseID,
                        modelID: modelID,
                        status: "in_progress",
                        outputText: "",
                        functionCalls: [],
                        usage: nil
                    ),
                ])

                do {
                    for try await chunk in chunks {
                        for event in accumulator.append(contentsOf: chunk) {
                            let payload = self.ssePayload(from: String(data: event, encoding: .utf8) ?? "")
                            if payload == "[DONE]" {
                                finishResponse()
                                continue
                            }
                            guard let object = self.jsonObject(from: payload) else { continue }
                            if GatewayCapacityRetryPolicy.isCapacityError(object) {
                                emit(["type": "response.failed", "response": ["id": responseID, "status": "failed", "error": object["error"] ?? object]])
                                continuation.finish()
                                return
                            }
                            if let rawUsage = object["usage"] as? [String: Any] {
                                usage = self.thirdPartyResponsesUsage(from: rawUsage)
                            }
                            guard let choices = object["choices"] as? [[String: Any]] else { continue }
                            for choice in choices {
                                guard let delta = choice["delta"] as? [String: Any] else { continue }
                                if let content = delta["content"] as? String,
                                   content.isEmpty == false {
                                    ensureMessageItem()
                                    text += content
                                    emit([
                                        "type": "response.output_text.delta",
                                        "item_id": messageID,
                                        "output_index": messageOutputIndex ?? 0,
                                        "content_index": 0,
                                        "delta": content,
                                    ])
                                }
                                if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
                                    for toolCallDelta in toolCallDeltas {
                                        let index = (toolCallDelta["index"] as? Int) ?? functionCalls.count
                                        var state = ensureFunctionCall(index: index, delta: toolCallDelta)
                                        if let function = toolCallDelta["function"] as? [String: Any] {
                                            if let name = function["name"] as? String, name.isEmpty == false {
                                                state.name = name
                                            }
                                            emitFunctionCallItemIfNeeded(&state)
                                            if let argumentsDelta = function["arguments"] as? String,
                                               argumentsDelta.isEmpty == false {
                                                state.arguments += argumentsDelta
                                                if Self.thirdPartyCustomToolNames.contains(state.name) == false {
                                                    emit([
                                                        "type": "response.function_call_arguments.delta",
                                                        "item_id": state.itemID,
                                                        "output_index": state.outputIndex,
                                                        "delta": argumentsDelta,
                                                    ])
                                                } else if let inputDelta = self.thirdPartyCustomToolInputDelta(from: argumentsDelta) {
                                                    emit([
                                                        "type": "response.custom_tool_call_input.delta",
                                                        "item_id": state.itemID,
                                                        "output_index": state.outputIndex,
                                                        "delta": inputDelta,
                                                    ])
                                                }
                                            }
                                        }
                                        functionCalls[index] = state
                                    }
                                }
                            }
                        }
                    }
                    if let remaining = accumulator.flush(),
                       let payload = String(data: remaining, encoding: .utf8),
                       self.ssePayload(from: payload) == "[DONE]" {
                    }
                    finishResponse()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func thirdPartyChatCompletionJSONToResponseJSON(_ data: Data, modelID: String) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return self.thirdPartyResponseJSON(
                id: "resp_codexbar_\(UUID().uuidString)",
                modelID: modelID,
                outputText: String(data: data, encoding: .utf8) ?? "",
                functionCalls: [],
                usage: nil
            )
        }
        let choices = object["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let outputText = (message?["content"] as? String) ?? ""
        let functionCalls: [ThirdPartyFunctionCallStreamState] = ((message?["tool_calls"] as? [[String: Any]]) ?? []).enumerated().map { offset, toolCall in
            let function = toolCall["function"] as? [String: Any]
            return ThirdPartyFunctionCallStreamState(
                itemID: "fc_codexbar_\(UUID().uuidString)",
                callID: ToolHistoryCompatibility.nonempty(toolCall["id"]) ?? "call_codexbar_\(UUID().uuidString)",
                name: (function?["name"] as? String) ?? "",
                arguments: (function?["arguments"] as? String) ?? "",
                outputIndex: outputText.isEmpty ? offset : offset + 1,
                didEmitItem: true
            )
        }
        let usage = (object["usage"] as? [String: Any]).map(self.thirdPartyResponsesUsage(from:))
        let responseID = (object["id"] as? String) ?? "resp_codexbar_\(UUID().uuidString)"
        return self.thirdPartyResponseJSON(
            id: responseID,
            modelID: modelID,
            outputText: outputText,
            functionCalls: functionCalls,
            usage: usage
        )
    }

    private func thirdPartyResponseJSON(
        id: String,
        modelID: String,
        outputText: String,
        functionCalls: [ThirdPartyFunctionCallStreamState],
        usage: [String: Any]?
    ) -> Data {
        let response = self.thirdPartyResponseObject(
            id: id,
            modelID: modelID,
            status: "completed",
            outputText: outputText,
            functionCalls: functionCalls,
            usage: usage
        )
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func thirdPartyResponseObject(
        id: String,
        modelID: String,
        status: String,
        outputText: String,
        functionCalls: [ThirdPartyFunctionCallStreamState],
        usage: [String: Any]?
    ) -> [String: Any] {
        var output: [[String: Any]] = []
        if outputText.isEmpty == false {
            output.append([
                "id": "msg_codexbar_\(UUID().uuidString)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": outputText]],
            ])
        }
        for functionCall in functionCalls {
            output.append(self.thirdPartyToolCallItem(from: functionCall, status: "completed"))
        }

        var response: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": status,
            "model": modelID,
            "output": output,
            "output_text": outputText,
        ]
        if let usage {
            response["usage"] = usage
        }
        return response
    }

    private func thirdPartyResponsesUsage(from usage: [String: Any]) -> [String: Any] {
        var mapped: [String: Any] = usage
        if let promptTokens = usage["prompt_tokens"] {
            mapped["input_tokens"] = promptTokens
        }
        if let completionTokens = usage["completion_tokens"] {
            mapped["output_tokens"] = completionTokens
        }
        return mapped
    }

    private func responsesSSEEvent(_ payload: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return Data()
        }
        return Data("data: \(json)\n\n".utf8)
    }

    private func compactJSONString(from value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
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
              let data = try? JSONSerialization.data(withJSONObject: normalizedObject, options: [.sortedKeys]) else {
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
        json = self.sanitizeNonOpenAIRequestObject(json)
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

    private func sanitizeNonOpenAIRequestObject(_ original: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in original {
            if key == "encrypted_content" {
                continue
            }
            if key == "include" {
                if let include = self.sanitizedNonOpenAIInclude(value) {
                    sanitized[key] = include
                }
                continue
            }
            if let sanitizedValue = self.sanitizedNonOpenAIValue(value) {
                sanitized[key] = sanitizedValue
            }
        }
        return sanitized
    }

    private func sanitizedNonOpenAIValue(_ value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if (dictionary["type"] as? String) == "reasoning" {
                return nil
            }
            return self.sanitizeNonOpenAIRequestObject(dictionary)
        }
        if let array = value as? [Any] {
            return array.compactMap { self.sanitizedNonOpenAIValue($0) }
        }
        return value
    }

    private func sanitizedNonOpenAIInclude(_ value: Any) -> [Any]? {
        guard let include = value as? [Any] else { return nil }
        let sanitized = include.filter {
            ($0 as? String) != OpenAIAccountGatewayConfiguration.reasoningIncludeMarker
        }
        return sanitized.isEmpty ? nil : sanitized
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

        if json["instructions"] == nil || json["instructions"] is NSNull {
            json["instructions"] = ""
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

    private func resolvedPOSTFailure(from error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        if let preByteFailure = error as? OpenAIAccountGatewayPreBytePOSTFailure {
            return preByteFailure.failure
        }
        return self.classifyPOSTFailure(error)
    }

    private func reportPOSTFailureDiagnostic(
        route: OpenAIAccountGatewayResponsesRoute,
        target: String,
        upstreamURL: URL?,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) {
        self.diagnosticsReporter(self.makePOSTFailureDiagnostic(
            route: route,
            target: target,
            upstreamURL: upstreamURL,
            failure: failure
        ))
    }

    private func makePOSTFailureDiagnostic(
        route: OpenAIAccountGatewayResponsesRoute,
        target: String,
        upstreamURL: URL?,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) -> OpenAIAccountGatewayUpstreamFailureDiagnostic {
        let underlyingError = failure.underlyingError as NSError?
        let transportPolicy = self.upstreamTransportConfiguration
            .resolvedTransportPolicy(for: upstreamURL)
        return OpenAIAccountGatewayUpstreamFailureDiagnostic(
            route: route.diagnosticName,
            target: target,
            upstreamHost: upstreamURL?.host,
            upstreamPath: upstreamURL?.path,
            failureClass: failure.failureClass,
            statusCode: failure.statusCode,
            errorDomain: underlyingError?.domain,
            errorCode: underlyingError?.code,
            loopbackProxySafeApplied: transportPolicy.loopbackProxySafeApplied,
            systemProxySummary: transportPolicy.systemProxySnapshot?.diagnosticSummary,
            effectiveProxySummary: transportPolicy.effectiveProxySnapshot?.diagnosticSummary
        )
    }

    private func streamLiveOpenAIAccountResponse(
        result: (response: HTTPURLResponse, bytes: AsyncThrowingStream<Data, Error>),
        account: TokenAccount,
        to connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws {
        try await self.streamRawResponse(result: result, to: connection, timing: timing)
    }

    private func reasoningGuardMatch(
        inSSEEvent event: Data,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> OpenAIAccountGatewayReasoningGuardMatch? {
        guard let assessment = self.reasoningGuardAssessment(inSSEEvent: event, configuration: configuration),
              assessment.shouldMatch else { return nil }
        return assessment.match
    }

    private func reasoningTokens(inSSEEvent event: Data) -> Int? {
        guard let eventText = String(data: event, encoding: .utf8) else { return nil }
        let payload = self.ssePayload(from: eventText)
        guard payload.isEmpty == false, payload != "[DONE]" else { return nil }
        guard let object = self.jsonObject(from: payload) else { return nil }
        return self.reasoningTokens(in: object)
    }

    private func reasoningGuardMatch(
        inJSONData data: Data,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> OpenAIAccountGatewayReasoningGuardMatch? {
        guard let assessment = self.reasoningGuardAssessment(inJSONData: data, configuration: configuration),
              assessment.shouldMatch else { return nil }
        return assessment.match
    }

    private func reasoningTokens(inJSONData data: Data) -> Int? {
        guard data.isEmpty == false,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return self.reasoningTokens(in: object)
    }

    private func reasoningGuardMatch(
        inBody data: Data,
        isEventStream: Bool,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> OpenAIAccountGatewayReasoningGuardMatch? {
        if isEventStream {
            if configuration.matchMode == .cautious {
                guard let assessment = self.reasoningGuardAssessment(
                    inSSEBody: data,
                    configuration: configuration
                ), assessment.shouldMatch else {
                    return nil
                }
                return assessment.match
            }

            var accumulator = SSEEventStreamAccumulator()
            for eventChunk in accumulator.append(contentsOf: data) {
                if let match = self.reasoningGuardMatch(inSSEEvent: eventChunk, configuration: configuration) {
                    return match
                }
            }
            if let remaining = accumulator.flush() {
                return self.reasoningGuardMatch(inSSEEvent: remaining, configuration: configuration)
            }
            return nil
        }

        return self.reasoningGuardMatch(inJSONData: data, configuration: configuration)
    }

    private func reasoningTokens(inBody data: Data, isEventStream: Bool) -> Int? {
        if isEventStream {
            var accumulator = SSEEventStreamAccumulator()
            for eventChunk in accumulator.append(contentsOf: data) {
                if let reasoningTokens = self.reasoningTokens(inSSEEvent: eventChunk) {
                    return reasoningTokens
                }
            }
            if let remaining = accumulator.flush() {
                return self.reasoningTokens(inSSEEvent: remaining)
            }
            return nil
        }

        return self.reasoningTokens(inJSONData: data)
    }

    private func reasoningGuardAssessment(
        inSSEEvent event: Data,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> OpenAIAccountGatewayReasoningGuardAssessment? {
        guard let eventText = String(data: event, encoding: .utf8) else { return nil }
        let payload = self.ssePayload(from: eventText)
        guard payload.isEmpty == false, payload != "[DONE]" else { return nil }
        guard let object = self.jsonObject(from: payload) else { return nil }
        return self.reasoningGuardAssessment(in: object, configuration: configuration, isEventStream: true)
    }

    private func reasoningGuardAssessment(
        inJSONData data: Data,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> OpenAIAccountGatewayReasoningGuardAssessment? {
        guard data.isEmpty == false,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return self.reasoningGuardAssessment(in: object, configuration: configuration, isEventStream: false)
    }

    private func reasoningGuardAssessment(
        inSSEBody data: Data,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration
    ) -> OpenAIAccountGatewayReasoningGuardAssessment? {
        var events: [Any] = []
        var reasoningTokens: Int?
        var accumulator = SSEEventStreamAccumulator()

        for eventChunk in accumulator.append(contentsOf: data) {
            guard let object = self.jsonObject(inSSEEvent: eventChunk) else { continue }
            events.append(object)
            if let value = self.reasoningTokens(in: object) {
                reasoningTokens = value
            }
        }
        if let remaining = accumulator.flush(),
           let object = self.jsonObject(inSSEEvent: remaining) {
            events.append(object)
            if let value = self.reasoningTokens(in: object) {
                reasoningTokens = value
            }
        }

        guard let reasoningTokens,
              configuration.reasoningEquals.contains(reasoningTokens) else {
            return nil
        }
        let evidence: [String]
        switch configuration.matchMode {
        case .strict:
            evidence = ["reasoning_equals"]
        case .cautious:
            evidence = self.cautiousReasoningGuardEvidence(in: events, isEventStream: true)
        }

        return OpenAIAccountGatewayReasoningGuardAssessment(
            reasoningTokens: reasoningTokens,
            evidence: evidence
        )
    }

    private func reasoningGuardAssessment(
        in payload: Any,
        configuration: OpenAIAccountGatewayReasoningRetryGuardConfiguration,
        isEventStream: Bool
    ) -> OpenAIAccountGatewayReasoningGuardAssessment? {
        guard let reasoningTokens = self.reasoningTokens(in: payload),
              configuration.reasoningEquals.contains(reasoningTokens) else {
            return nil
        }

        let evidence: [String]
        switch configuration.matchMode {
        case .strict:
            evidence = ["reasoning_equals"]
        case .cautious:
            evidence = self.cautiousReasoningGuardEvidence(in: payload, isEventStream: isEventStream)
        }

        return OpenAIAccountGatewayReasoningGuardAssessment(
            reasoningTokens: reasoningTokens,
            evidence: evidence
        )
    }

    private func jsonObject(inSSEEvent event: Data) -> Any? {
        guard let eventText = String(data: event, encoding: .utf8) else { return nil }
        let payload = self.ssePayload(from: eventText)
        guard payload.isEmpty == false, payload != "[DONE]" else { return nil }
        return self.jsonObject(from: payload)
    }

    private func cautiousReasoningGuardEvidence(in payload: Any, isEventStream: Bool) -> [String] {
        var evidence: [String] = []

        if let outputTokens = self.outputTokens(in: payload), outputTokens <= 64 {
            evidence.append("low_output_tokens")
        }

        let outputTextLength = self.outputTextCharacterCount(in: payload)
        if outputTextLength > 0,
           outputTextLength <= 240,
           self.hasToolCall(in: payload) == false {
            evidence.append("short_final_no_tool")
        }

        return evidence
    }

    private func outputTokens(in payload: Any) -> Int? {
        let pointerPaths = [
            ["usage", "output_tokens"],
            ["usage", "completion_tokens"],
            ["response", "usage", "output_tokens"],
            ["response", "usage", "completion_tokens"],
        ]

        for path in pointerPaths {
            if let value = self.value(in: payload, at: path),
               let integer = self.integerValue(value) {
                return integer
            }
        }
        return nil
    }

    private func outputTextCharacterCount(in payload: Any) -> Int {
        self.outputTextValues(in: payload).reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
    }

    private func outputTextValues(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var values: [String] = []
            let type = dictionary["type"] as? String
            if type == "output_text", let text = dictionary["text"] as? String {
                values.append(text)
            }
            if type == "message", let content = dictionary["content"] {
                values.append(contentsOf: self.outputTextValues(in: content))
            }
            if let outputText = dictionary["output_text"] as? String {
                values.append(outputText)
            }
            if let delta = dictionary["delta"] as? String,
               type == "response.output_text.delta" {
                values.append(delta)
            }
            for nestedKey in ["response", "output", "content"] {
                if let nested = dictionary[nestedKey] {
                    values.append(contentsOf: self.outputTextValues(in: nested))
                }
            }
            return values
        }

        if let array = value as? [Any] {
            return array.flatMap { self.outputTextValues(in: $0) }
        }

        return []
    }

    private func hasToolCall(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String,
               type.contains("tool_call") || type == "function_call" || type == "response.function_call_arguments.done" {
                return true
            }
            if dictionary["tool_calls"] != nil || dictionary["function_call"] != nil {
                return true
            }
            return dictionary.values.contains { self.hasToolCall(in: $0) }
        }

        if let array = value as? [Any] {
            return array.contains { self.hasToolCall(in: $0) }
        }

        return false
    }

    private func reasoningTokens(in payload: Any) -> Int? {
        let pointerPaths = [
            ["usage", "output_tokens_details", "reasoning_tokens"],
            ["usage", "completion_tokens_details", "reasoning_tokens"],
            ["response", "usage", "output_tokens_details", "reasoning_tokens"],
            ["response", "usage", "completion_tokens_details", "reasoning_tokens"],
        ]

        for path in pointerPaths {
            if let value = self.value(in: payload, at: path),
               let integer = self.integerValue(value) {
                return integer
            }
        }
        return nil
    }

    private func value(in payload: Any, at path: [String]) -> Any? {
        var current: Any? = payload
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    private func integerValue(_ value: Any) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.rounded() == double else { return nil }
            return number.intValue
        }
        if let string = value as? String,
           let integer = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return integer
        }
        return nil
    }

    private func sendReasoningGuardBlockedResponse(
        on connection: NWConnection,
        route: OpenAIAccountGatewayResponsesRoute,
        reasoningTokens: Int,
        statusCode: Int
    ) {
        self.sendJSONResponse(
            on: connection,
            statusCode: statusCode,
            body: self.reasoningGuardBlockedBody(
                route: route,
                reasoningTokens: reasoningTokens,
                statusCode: statusCode
            ),
            headers: ["X-CodexBar-Gateway-Reason": "reasoning-guard-triggered"]
        )
    }

    private func reasoningGuardBlockedBody(
        route: OpenAIAccountGatewayResponsesRoute,
        reasoningTokens: Int,
        statusCode: Int
    ) -> String {
        let payload: [String: Any] = [
            "error": [
                "message": "codexbar gateway blocked suspicious reasoning response on \(route.diagnosticName)",
                "type": "codexbar_gateway",
                "code": "reasoning_guard_triggered",
                "reasoning_tokens": reasoningTokens,
                "status_code": statusCode,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else {
            return #"{"error":{"message":"codexbar gateway blocked suspicious reasoning response","code":"reasoning_guard_triggered"}}"#
        }
        return body
    }

    private func ssePayload(from event: String) -> String {
        let normalizedEvent = event.replacingOccurrences(of: "\r\n", with: "\n")
        let dataLines = normalizedEvent
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

        return normalizedEvent.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let buffered = try await self.bufferRouteTargetWebSocketResponseWithRetry(
            text: text,
            routeTarget: routeTarget,
            timing: timing
        )
        let payloads = self.webSocketBridgePayloads(from: buffered)
        for payload in payloads {
            try await self.send(
                self.makeWebSocketFrame(opcode: 0x1, payload: Data(payload.utf8)),
                on: connection
            )
        }
        if payloads.isEmpty == false {
            Self.logTiming(
                "first_downstream_body",
                context: timing,
                statusCode: buffered.response.statusCode,
                isEventStream: buffered.isEventStream,
                bytes: buffered.totalBytes,
                events: payloads.count
            )
        }
        Self.logTiming(
            "request_completed",
            context: timing,
            statusCode: buffered.response.statusCode,
            isEventStream: buffered.isEventStream,
            bytes: buffered.totalBytes,
            events: payloads.count
        )
        return (200...299).contains(buffered.response.statusCode) ? 1000 : 1011
    }

    private func bufferRouteTargetWebSocketResponseWithRetry(
        text: String,
        routeTarget: OpenAIAccountGatewayRouteTarget,
        timing: OpenAIAccountGatewayTimingContext
    ) async throws -> OpenAIAccountGatewayRouteTargetBufferedResponse {
        let configuration = self.reasoningRetryGuardConfigurationSnapshot()
        let maxAttempts = max(1, configuration.routeTargetRetryAttempts + 1)

        for attempt in 1...maxAttempts {
            let result = try await self.proxyRouteTargetPOSTResponses(
                body: Data(text.utf8),
                route: .responses,
                routeTarget: routeTarget
            )
            let buffered = try await self.bufferRouteTargetResponse(
                result,
                route: .responses,
                timing: timing
            )
            let shouldRetry = self.shouldRetryRouteTargetResponse(
                buffered,
                configuration: configuration
            )
            guard shouldRetry, attempt < maxAttempts else {
                self.completeGatewayRetryLog(
                    batchID: timing.id,
                    statusCode: self.routeTargetRetryStatusCode(
                        for: buffered,
                        configuration: configuration
                    ),
                    succeeded: self.routeTargetResponseSucceeded(
                        buffered,
                        configuration: configuration
                    )
                )
                return buffered
            }

            let retryStatusCode = self.routeTargetRetryStatusCode(
                for: buffered,
                configuration: configuration
            )
            Self.logTiming(
                "request_retry_route_target_websocket_bridge",
                context: timing,
                statusCode: retryStatusCode,
                isEventStream: buffered.isEventStream,
                bytes: buffered.totalBytes,
                extra: "attempt=\(attempt) max_attempts=\(maxAttempts) target=\(routeTarget.diagnosticName)"
            )
            if buffered.shouldBlockGuardMatch {
                self.recordGatewayRetryAttempt(
                    batchID: timing.id,
                    path: timing.route,
                    target: routeTarget.diagnosticName,
                    statusCode: retryStatusCode,
                    maximumRetryCount: maxAttempts - 1,
                    delay: 0,
                    delaySource: "reasoning_guard"
                )
            } else {
                try await self.waitBeforeGatewayRetry(
                    response: buffered.response,
                    attempt: attempt,
                    maximumRetryCount: maxAttempts - 1,
                    timing: timing,
                    statusCode: retryStatusCode,
                    target: routeTarget.diagnosticName
                )
            }
        }

        throw URLError(.cannotParseResponse)
    }

    private func webSocketBridgePayloads(
        from buffered: OpenAIAccountGatewayRouteTargetBufferedResponse
    ) -> [String] {
        guard buffered.isEventStream else {
            return [String(data: buffered.body, encoding: .utf8) ?? "{}"]
        }

        var payloads: [String] = []
        let delimiter = Data("\n\n".utf8)
        var body = buffered.body
        while let range = body.range(of: delimiter) {
            let eventData = body.subdata(in: 0..<range.lowerBound)
            body.removeSubrange(0..<range.upperBound)
            guard let eventText = String(data: eventData, encoding: .utf8) else { continue }
            let payload = self.ssePayload(from: eventText)
            if payload.isEmpty == false, payload != "[DONE]" {
                payloads.append(payload)
            }
        }
        if body.isEmpty == false, let eventText = String(data: body, encoding: .utf8) {
            let payload = self.ssePayload(from: eventText)
            if payload.isEmpty == false, payload != "[DONE]" {
                payloads.append(payload)
            }
        }
        return payloads
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

    private func sendJSONResponse(
        on connection: NWConnection,
        statusCode: Int,
        body: String,
        headers additionalHeaders: [String: String] = [:]
    ) {
        self.sendDataResponse(
            on: connection,
            statusCode: statusCode,
            body: Data(body.utf8),
            contentType: "application/json",
            headers: additionalHeaders
        )
    }

    private func sendDataResponse(
        on connection: NWConnection,
        statusCode: Int,
        body: Data,
        contentType: String,
        headers additionalHeaders: [String: String] = [:]
    ) {
        var headerLines = [
            "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        for (name, value) in additionalHeaders.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(name): \(value)")
        }
        headerLines.append("")
        headerLines.append("")
        let head = headerLines.joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
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

    private func gatewayErrorBody(message: String) -> String {
        let payload: [String: Any] = ["error": ["message": message]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else {
            return #"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#
        }
        return body
    }
}

#if DEBUG
struct OpenAIAccountGatewayTestResponse {
    let statusCode: Int
    var headers: [String: String]
    var body: Data
}

struct OpenAIAccountGatewayWebSocketBridgeProbeResult {
    let events: [String]
    let closeCode: UInt16
}

extension OpenAIAccountGatewayService {
    func currentRoutedAccountIDForTesting() -> String? {
        self.currentRoutedAccountID()
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

    func routeTargetPOSTTransportConfigurationOverrideForTesting(
        routePath: String
    ) -> OpenAIAccountGatewayUpstreamTransportConfiguration? {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: routePath) else {
            return nil
        }
        return self.routeTargetPOSTTransportConfigurationOverride(route: route)
    }

    func classifyPOSTFailureForTesting(_ error: Error) -> OpenAIAccountGatewayUpstreamFailure {
        self.classifyPOSTFailure(error)
    }

    func upstreamFailureDiagnosticForTesting(
        routePath: String,
        target: String = "openai_account",
        upstreamURL: URL? = nil,
        failure: OpenAIAccountGatewayUpstreamFailure
    ) -> OpenAIAccountGatewayUpstreamFailureDiagnostic? {
        guard let route = OpenAIAccountGatewayResponsesRoute(requestPath: routePath) else {
            return nil
        }
        return self.makePOSTFailureDiagnostic(
            route: route,
            target: target,
            upstreamURL: upstreamURL,
            failure: failure
        )
    }

    func parseRequestForTesting(from data: Data) -> ParsedGatewayRequest? {
        self.parseRequest(from: data)
    }

    func routeTargetWebSocketUpgradeProbeForTesting(
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

        let routeTarget = self.snapshot().routeTarget
        let message: String
        switch routeTarget {
        case .compatibleProvider, .openRouter:
            message = "websocket upgrade is not supported for provider routes; use HTTP responses"
        case .none, .openAIAccount:
            message = "websocket upgrade is not supported for this gateway route"
        }

        return OpenAIAccountGatewayTestResponse(
            statusCode: 426,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":{"message":"\#(message)"}}"#.utf8)
        )
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
        case .openAIAccount(let accountID):
            guard let account = self.account(withID: accountID) else {
                return OpenAIAccountGatewayTestResponse(
                    statusCode: 503,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway unavailable: selected OpenAI account is not routable"}}"#.utf8)
                )
            }
            do {
                let configuration = self.reasoningRetryGuardConfigurationSnapshot()
                let maxAttempts = max(1, configuration.routeTargetRetryAttempts + 1)
                var lastResponse: OpenAIAccountGatewayTestResponse?
                for attempt in 1...maxAttempts {
                    let result = try await self.proxyPOSTResponses(request, account: account, route: route)
                    if (200...299).contains(result.response.statusCode) { self.noteRoutedAccount(accountID: account.accountId, request: request) }
                    let body = try await self.readAllBytesForTesting(from: result.bytes)
                    if let blocked = self.reasoningGuardBlockedTestResponse(
                        body: body,
                        response: result.response,
                        route: route
                    ) {
                        lastResponse = blocked
                        if attempt < maxAttempts {
                            continue
                        }
                        return blocked
                    }
                    let response = OpenAIAccountGatewayTestResponse(
                        statusCode: result.response.statusCode,
                        headers: self.responseHeadersForTesting(from: result.response),
                        body: body
                    )
                    lastResponse = response
                    if self.shouldRetryRouteTargetResponse(
                        statusCode: result.response.statusCode,
                        body: body,
                        shouldBlockGuardMatch: false,
                        configuration: configuration
                    ), attempt < maxAttempts {
                        let retryDelay = self.gatewayRetryDelay(response: result.response, attempt: attempt)
                        try await self.retryDelaySleeper(retryDelay.delay)
                        continue
                    }
                    return response
                }
                return lastResponse ?? OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
                )
            } catch {
                self.reportPOSTFailureDiagnostic(
                    route: route,
                    target: "openAIAccount",
                    upstreamURL: route.upstreamURL(using: self.runtimeConfiguration),
                    failure: self.resolvedPOSTFailure(from: error)
                )
                return OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenAI upstream"}}"#.utf8)
                )
            }
        case .compatibleProvider(let target):
            do {
                let configuration = self.reasoningRetryGuardConfigurationSnapshot()
                let maxAttempts = max(1, configuration.routeTargetRetryAttempts + 1)
                var lastResponse: OpenAIAccountGatewayTestResponse?
                for attempt in 1...maxAttempts {
                    let result = try await self.proxyProviderPOSTResponses(request, route: route, target: target)
                    let body = try await self.readAllBytesForTesting(from: result.bytes)
                    if let blocked = self.reasoningGuardBlockedTestResponse(
                        body: body,
                        response: result.response,
                        route: route
                    ) {
                        lastResponse = blocked
                        if attempt < maxAttempts {
                            continue
                        }
                        return blocked
                    }
                    let response = OpenAIAccountGatewayTestResponse(
                        statusCode: result.response.statusCode,
                        headers: self.responseHeadersForTesting(from: result.response),
                        body: body
                    )
                    lastResponse = response
                    if self.shouldRetryRouteTargetResponse(
                        statusCode: result.response.statusCode,
                        body: body,
                        shouldBlockGuardMatch: false,
                        configuration: configuration
                    ), attempt < maxAttempts {
                        let retryDelay = self.gatewayRetryDelay(response: result.response, attempt: attempt)
                        try await self.retryDelaySleeper(retryDelay.delay)
                        continue
                    }
                    return response
                }
                return lastResponse ?? OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach provider upstream"}}"#.utf8)
                )
            } catch {
                let upstreamURL = try? self.providerResponsesURL(baseURL: target.baseURL, route: route)
                self.reportPOSTFailureDiagnostic(
                    route: route,
                    target: "compatibleProvider",
                    upstreamURL: upstreamURL,
                    failure: self.resolvedPOSTFailure(from: error)
                )
                return OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach provider upstream"}}"#.utf8)
                )
            }
        case .openRouter(let target):
            do {
                let configuration = self.reasoningRetryGuardConfigurationSnapshot()
                let maxAttempts = max(1, configuration.routeTargetRetryAttempts + 1)
                var lastResponse: OpenAIAccountGatewayTestResponse?
                for attempt in 1...maxAttempts {
                    let result = try await self.proxyOpenRouterPOSTResponses(request, route: route, target: target)
                    let body = try await self.readAllBytesForTesting(from: result.bytes)
                    if let blocked = self.reasoningGuardBlockedTestResponse(
                        body: body,
                        response: result.response,
                        route: route
                    ) {
                        lastResponse = blocked
                        if attempt < maxAttempts {
                            continue
                        }
                        return blocked
                    }
                    let response = OpenAIAccountGatewayTestResponse(
                        statusCode: result.response.statusCode,
                        headers: self.responseHeadersForTesting(from: result.response),
                        body: body
                    )
                    lastResponse = response
                    if self.shouldRetryRouteTargetResponse(
                        statusCode: result.response.statusCode,
                        body: body,
                        shouldBlockGuardMatch: false,
                        configuration: configuration
                    ), attempt < maxAttempts {
                        let retryDelay = self.gatewayRetryDelay(response: result.response, attempt: attempt)
                        try await self.retryDelaySleeper(retryDelay.delay)
                        continue
                    }
                    return response
                }
                return lastResponse ?? OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenRouter upstream"}}"#.utf8)
                )
            } catch {
                self.reportPOSTFailureDiagnostic(
                    route: route,
                    target: "openRouter",
                    upstreamURL: self.openRouterResponsesURL(route: route),
                    failure: self.resolvedPOSTFailure(from: error)
                )
                return OpenAIAccountGatewayTestResponse(
                    statusCode: 502,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":{"message":"codexbar gateway failed to reach OpenRouter upstream"}}"#.utf8)
                )
            }
        case .none:
            return OpenAIAccountGatewayTestResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"codexbar gateway unavailable: no routed target"}}"#.utf8)
            )
        }
    }

    private func reasoningGuardBlockedTestResponse(
        body: Data,
        response: HTTPURLResponse,
        route: OpenAIAccountGatewayResponsesRoute
    ) -> OpenAIAccountGatewayTestResponse? {
        let configuration = self.reasoningRetryGuardConfigurationSnapshot()
        guard self.shouldInspectReasoningRetryGuard(route: route, configuration: configuration) else { return nil }
        let isEventStream = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true
        let match = self.reasoningGuardMatch(
            inBody: body,
            isEventStream: isEventStream,
            configuration: configuration
        )
        let shouldBlock = match != nil
            && (isEventStream ? configuration.interceptStreaming : configuration.interceptNonStreaming)
        self.recordReasoningRetryGuardInspection(
            reasoningTokens: match?.reasoningTokens ?? self.reasoningTokens(inBody: body, isEventStream: isEventStream),
            matchEvidence: match?.evidence ?? [],
            matched: match != nil,
            blocked: shouldBlock,
            route: route,
            isEventStream: isEventStream,
            configuration: configuration
        )
        guard let match, shouldBlock else {
            return nil
        }
        return OpenAIAccountGatewayTestResponse(
            statusCode: configuration.nonStreamStatusCode,
            headers: [
                "Content-Type": "application/json",
                "Connection": "close",
                "X-CodexBar-Gateway-Reason": "reasoning-guard-triggered",
            ],
            body: Data(
                self.reasoningGuardBlockedBody(
                    route: route,
                    reasoningTokens: match.reasoningTokens,
                    statusCode: configuration.nonStreamStatusCode
                ).utf8
            )
        )
    }

    private func collectRouteTargetWebSocketBridgeProbe(
        text: String,
        routeTarget: OpenAIAccountGatewayRouteTarget
    ) async throws -> OpenAIAccountGatewayWebSocketBridgeProbeResult {
        let timing = Self.makeTimingContext(
            route: "responses_ws_bridge",
            target: routeTarget.diagnosticName
        )
        let buffered = try await self.bufferRouteTargetWebSocketResponseWithRetry(
            text: text,
            routeTarget: routeTarget,
            timing: timing
        )
        return OpenAIAccountGatewayWebSocketBridgeProbeResult(
            events: self.webSocketBridgePayloads(from: buffered),
            closeCode: (200...299).contains(buffered.response.statusCode) ? 1000 : 1011
        )
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

    private func readAllBytesForTesting(from bytes: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var data = Data()
        var iterator = bytes.makeAsyncIterator()
        while true {
            let nextChunk: Data?
            do {
                nextChunk = try await iterator.next()
            } catch {
                if data.isEmpty {
                    throw OpenAIAccountGatewayPreBytePOSTFailure(
                        failure: self.classifyPOSTFailure(error)
                    )
                }
                throw error
            }

            guard let chunk = nextChunk else { break }
            data.append(chunk)
        }
        return data
    }
}
#endif
