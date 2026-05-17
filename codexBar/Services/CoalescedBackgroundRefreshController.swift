import Foundation

private final class AnyCoalescedRefreshRequest {
    let now: Date
    let load: @Sendable (Date) -> Any
    let apply: @MainActor (Any) -> Void

    init(
        now: Date,
        load: @escaping @Sendable (Date) -> Any,
        apply: @escaping @MainActor (Any) -> Void
    ) {
        self.now = now
        self.load = load
        self.apply = apply
    }
}

@MainActor
final class CoalescedBackgroundRefreshController {
    typealias Loader<Result> = @Sendable (Date) -> Result
    typealias Deliver<Result> = @MainActor (Result) -> Void

    private let queue: DispatchQueue
    private var generation = 0
    private var isRefreshing = false
    private var pendingRequest: AnyCoalescedRefreshRequest?

    init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    func requestRefresh<Result>(
        now: Date = Date(),
        load: @escaping Loader<Result>,
        apply: @escaping Deliver<Result>
    ) {
        let request = AnyCoalescedRefreshRequest(
            now: now,
            load: { load($0) },
            apply: { value in
                guard let result = value as? Result else { return }
                apply(result)
            }
        )
        if self.isRefreshing {
            self.pendingRequest = request
            return
        }

        self.start(request)
    }

    private func start(_ request: AnyCoalescedRefreshRequest) {
        self.isRefreshing = true
        let generation = self.generation
        self.queue.async {
            let result = request.load(request.now)

            Task { @MainActor [weak self] in
                guard let self else { return }

                if generation == self.generation {
                    request.apply(result)
                }

                self.isRefreshing = false
                if let pendingRequest = self.pendingRequest {
                    self.pendingRequest = nil
                    self.start(pendingRequest)
                }
            }
        }
    }

    func reset() {
        self.generation += 1
        self.pendingRequest = nil
    }
}
