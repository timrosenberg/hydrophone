import AppKit
import Observation

/// Observable presentation lifecycle for one visible artwork consumer.
/// `ArtworkCache` still owns bytes and shared work; this object owns demand,
/// recovery and protection against completions for a retired view request.
@MainActor
@Observable
final class ArtworkLoader {
    struct Input: Hashable {
        var coverArt: String?
        var cacheKey: String?
        var size: Int
    }

    enum State {
        case idle
        case loading(NSImage?)
        case ready(NSImage)
        case failed(NSImage?, recoverable: Bool)

        var image: NSImage? {
            switch self {
            case .idle:
                nil
            case let .loading(image), let .failed(image, _):
                image
            case let .ready(image):
                image
            }
        }
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let cache: ArtworkCache
    @ObservationIgnored private let recoveryDelay: Duration
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var request: ArtworkCache.Request?
    @ObservationIgnored private var interest: ArtworkCache.Interest?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(cache: ArtworkCache = .shared, recoveryDelay: Duration = .seconds(2)) {
        self.cache = cache
        self.recoveryDelay = recoveryDelay
    }

    var hasStarted: Bool { input != nil }

    func image(for input: Input) -> NSImage? {
        let image = state.image
        guard self.input == input else { return nil }
        return image
    }

    func start(_ input: Input) {
        start(input, replacingCurrentRequest: false)
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        interest?.cancel()
        interest = nil
        input = nil
        request = nil
        state = .idle
    }

    private func start(_ input: Input, replacingCurrentRequest: Bool) {
        if !replacingCurrentRequest, self.input == input,
           let request, cache.isCurrent(request) {
            return
        }

        let previousInput = self.input
        loadTask?.cancel()
        interest?.cancel()
        self.input = input
        let previousIdentity = previousInput?.cacheKey ?? previousInput?.coverArt
        let identity = input.cacheKey ?? input.coverArt
        let refreshesIdentity = !replacingCurrentRequest
            && previousInput != nil
            && previousIdentity == identity
            && previousInput?.coverArt != input.coverArt
        guard let request = cache.request(coverArt: input.coverArt,
                                          cacheKey: input.cacheKey,
                                          size: input.size,
                                          refreshingCacheIdentity: refreshesIdentity) else {
            self.request = nil
            interest = nil
            loadTask = nil
            state = .idle
            return
        }

        self.request = request
        let fallback = cache.cachedVariant(for: request)
        state = .loading(fallback)
        interest = cache.observe(request) { [weak self] event in
            self?.receive(event, for: request, input: input)
        }
        loadTask = Task { [weak self] in
            await self?.loadWithRecovery(request, input: input, fallback: fallback)
        }
    }

    private func receive(_ event: ArtworkCache.RequestEvent,
                         for request: ArtworkCache.Request,
                         input: Input) {
        guard self.request == request, self.input == input else { return }
        switch event {
        case let .ready(image):
            state = .ready(image)
        case .invalidated:
            start(input, replacingCurrentRequest: true)
        }
    }

    private func loadWithRecovery(_ request: ArtworkCache.Request,
                                  input: Input,
                                  fallback: NSImage?) async {
        for attempt in 0..<2 {
            let image = await cache.image(for: request)
            guard self.request == request, self.input == input, !Task.isCancelled else { return }
            if let image {
                state = .ready(image)
                return
            }

            let canRecover = attempt == 0
            state = .failed(fallback, recoverable: canRecover)
            guard canRecover else { return }
            do {
                try await Task.sleep(for: recoveryDelay)
            } catch {
                return
            }
            guard self.request == request, self.input == input else { return }
            if case .ready = state { return }
            state = .loading(fallback)
        }
    }
}
