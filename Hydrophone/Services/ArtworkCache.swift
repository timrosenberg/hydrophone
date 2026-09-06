import SwiftUI
import AppKit

/// Two-tier artwork cache: an in-memory `NSCache` over a persistent on-disk
/// store. Cover art is immutable, so a disk hit is authoritative and kept
/// indefinitely — artwork loads instantly across launches and survives network
/// blips. Keyed by a caller-supplied cache identity + target pixel size (list
/// thumbnails and the now-playing hero are separate, right-sized entries).
///
/// The cache identity (`cacheKey`) is decoupled from the `coverArt` id used to
/// build the fetch URL: servers hand every *song* its own coverArt id even
/// though all tracks of an album resolve to the same image, so song surfaces
/// key by album (`Song.artworkKey`) and a whole queue costs one download.
///
/// Everything is **scoped to the current server** (a hash of its base URL): a
/// different Navidrome server can reuse the same coverArt id for a different
/// album, so without scoping the disk cache would serve the wrong image. See
/// docs/05.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [Request: Task<NSImage?, Never>] = [:]
    /// Pixel sizes cached per coverArt id (current server), so a different-size
    /// request can show an already-loaded variant instantly.
    private var sizesByID: [String: [Int]] = [:]
    private let diskRoot: URL
    private let session: URLSession
    private let failureRetryDelay: Duration
    private var pendingPrefetches: [PrefetchRequest] = []
    private var prefetchTask: Task<Void, Never>?
    private var requestObservers: [Request: [UUID: (RequestEvent) -> Void]] = [:]
    private var generationByCacheKey: [String: Int] = [:]
    private var invalidatedDiskCacheKeys: Set<String> = []
    private var refreshedDiskSizes: [String: Set<Int>] = [:]
    private var sessionGeneration = 0

    static let prefetchLimit = 24

    struct PrefetchRequest: Equatable {
        var coverArt: String?
        var cacheKey: String?
        var size: Int
    }

    struct Request: Hashable {
        let sessionGeneration: Int
        let cacheGeneration: Int
        let serverID: String
        let cacheKey: String
        let coverArt: String
        let size: Int

        fileprivate var storageKey: String { "\(serverID)|\(cacheKey)@\(size)" }
    }

    enum RequestEvent {
        case ready(NSImage)
        case invalidated
    }

    @MainActor
    final class Interest {
        private weak var cache: ArtworkCache?
        private let request: Request
        private let id: UUID
        private var isActive = true

        fileprivate init(cache: ArtworkCache, request: Request, id: UUID) {
            self.cache = cache
            self.request = request
            self.id = id
        }

        func cancel() {
            guard isActive else { return }
            isActive = false
            cache?.removeObserver(id: id, for: request)
        }
    }
    /// Filesystem-safe token identifying the current server; namespaces both
    /// tiers so artwork never mixes across servers.
    private var serverID = "default"

    /// Set by AppModel so the cache can build authenticated cover-art URLs.
    /// Held strongly: the cache is a process-lifetime singleton and `ClientBox`
    /// only retains the `SubsonicClient` (no cycle). A `weak` ref here would let
    /// the inline `ClientBox(client)` deallocate immediately → no artwork.
    var clientBox: ClientBox?

    /// Byte budget for the in-memory tier, sized in decoded-pixel bytes (see
    /// `cost(of:)`) rather than entry count alone: a handful of now-playing
    /// heroes at full size shouldn't crowd out hundreds of grid thumbnails.
    /// ~200 MB comfortably holds a large album grid's visible + prefetched
    /// range without pinning excessive memory. See issue #15 (E7).
    private static let memoryBudgetBytes = 200 * 1_024 * 1_024

    init(session: URLSession = .shared, directory: URL? = nil,
         failureRetryDelay: Duration = .seconds(1.5)) {
        self.session = session
        self.failureRetryDelay = failureRetryDelay
        // Count limit is a loose backstop; totalCostLimit (byte-based) does
        // the real bounding so raising the visible+prefetch window doesn't
        // silently blow the memory budget.
        cache.countLimit = 1_000
        cache.totalCostLimit = Self.memoryBudgetBytes
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskRoot = directory ?? base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Hydrophone", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    /// Point the cache at a server (nil when disconnected). Switching servers
    /// drops the in-memory tier; the disk tier is namespaced per server, so each
    /// server keeps its own images and switching back reuses them.
    func setServer(baseURL: URL?) {
        let id = baseURL.map(ArtworkCacheIO.scope(for:)) ?? "default"
        sessionGeneration &+= 1
        let observers = requestObservers.values.flatMap(\.values)
        requestObservers.removeAll()
        pendingPrefetches.removeAll()
        inFlight.removeAll()
        generationByCacheKey.removeAll()
        guard id != serverID else {
            observers.forEach { $0(.invalidated) }
            return
        }
        serverID = id
        cache.removeAllObjects()
        sizesByID.removeAll()
        invalidatedDiskCacheKeys.removeAll()
        refreshedDiskSizes.removeAll()
        observers.forEach { $0(.invalidated) }
    }

    /// Replace the speculative window, never append to an unbounded backlog.
    /// One worker submits at most one speculative load to the six-slot network
    /// limiter, leaving the other slots for visible artwork. An active load is
    /// allowed to finish because a visible view may have joined its in-flight
    /// task; clearing/replacing the window discards all obsolete pending work.
    func prefetch(_ requests: [PrefetchRequest]) {
        pendingPrefetches = Array(requests.lazy.filter {
            !($0.coverArt?.isEmpty ?? true)
        }.prefix(Self.prefetchLimit))
        guard prefetchTask == nil, !pendingPrefetches.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            while !pendingPrefetches.isEmpty {
                let request = pendingPrefetches.removeFirst()
                _ = await image(coverArt: request.coverArt, cacheKey: request.cacheKey, size: request.size)
            }
            prefetchTask = nil
        }
    }

    /// Any in-memory variant for the cache identity (largest available), used
    /// as an instant placeholder while the exact size loads — so showing the
    /// same art at a different size doesn't flash the empty placeholder.
    func cachedVariant(key identity: String?) -> NSImage? {
        guard let identity, let sizes = sizesByID[identity] else { return nil }
        for size in sizes.sorted(by: >) {
            if let image = cache.object(forKey: "\(serverID)|\(identity)@\(size)" as NSString) {
                return image
            }
        }
        return nil
    }

    func cachedVariant(for request: Request) -> NSImage? {
        guard isCurrent(request) else { return nil }
        return cachedVariant(key: request.cacheKey)
    }

    /// Drop the in-memory tier (disk store persists — artwork is immutable).
    func purge() {
        cache.removeAllObjects()
        sizesByID.removeAll()
    }

    /// The original-size artwork, staged as a nicely-named image file for
    /// Quick Look (the panel titles itself with the filename). The original
    /// bytes are disk-cached like any other size (keyed size 0).
    func originalImageFileURL(coverArt id: String?, cacheKey: String? = nil,
                              displayName: String) async -> URL? {
        guard let id, !id.isEmpty, let clientBox else { return nil }
        let cacheURL = serverDir().appendingPathComponent(
            ArtworkCacheIO.filename(identity: cacheKey ?? id, size: 0)
        )
        return await Self.stageOriginal(id: id, displayName: displayName,
                                        client: clientBox.client, cacheURL: cacheURL, session: session)
    }

    private nonisolated static func stageOriginal(id: String, displayName: String,
                                                  client: SubsonicClient, cacheURL: URL,
                                                  session: URLSession) async -> URL? {
        var data = try? Data(contentsOf: cacheURL)
        if data == nil {
            // Same governed path as every other fetch: the concurrency cap
            // and the one-retry ladder apply to originals too.
            guard let url = try? await client.coverArtURL(id: id),
                  let (fetched, _) = await ArtworkCacheIO.fetchWithRetry(
                    url, session: session, failureRetryDelay: .seconds(1.5)
                  ) else { return nil }
            try? fetched.write(to: cacheURL, options: .atomic)
            data = fetched
        }
        guard let data, NSImage(data: data) != nil else { return nil }

        let safeName = displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let previews = cacheURL.deletingLastPathComponent().appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let staged = previews.appendingPathComponent(safeName)
            .appendingPathExtension(imageExtension(for: data))
        try? data.write(to: staged, options: .atomic)
        return staged
    }

    /// Quick Look picks the handler from the extension, so name the staged
    /// file for what the bytes actually are.
    private nonisolated static func imageExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50]) { return "png" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "jpg"
    }

    // MARK: - Disk + network (off the main actor)

    private func serverDir() -> URL {
        let dir = diskRoot.appendingPathComponent(serverID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seconds to wait per the 429's Retry-After header (delta-seconds form),
    /// clamped to something sane; 2s when absent or unparseable.
    nonisolated static func retryDelay(from response: HTTPURLResponse) -> TimeInterval {
        ArtworkCacheIO.retryDelay(from: response)
    }
}

extension ArtworkCache {
    func request(coverArt id: String?, cacheKey: String? = nil, size: Int,
                 refreshingCacheIdentity: Bool = false) -> Request? {
        guard let id, !id.isEmpty, clientBox != nil else { return nil }
        let identity = cacheKey ?? id
        if refreshingCacheIdentity {
            refreshCacheIdentity(identity, requestedSize: size)
        }
        return Request(sessionGeneration: sessionGeneration,
                       cacheGeneration: generationByCacheKey[identity, default: 0],
                       serverID: serverID, cacheKey: identity, coverArt: id, size: size)
    }
    /// `cacheKey` is the cache identity (defaults to the coverArt id); `id`
    /// only feeds the fetch URL. Passing the same key for different coverArt
    /// ids (all songs of one album) makes them share entries and downloads.
    func image(coverArt id: String?, cacheKey: String? = nil, size: Int) async -> NSImage? {
        guard let request = request(coverArt: id, cacheKey: cacheKey, size: size) else { return nil }
        return await image(for: request)
    }
    func image(for request: Request) async -> NSImage? {
        guard isCurrent(request), let clientBox else { return nil }
        if let cached = cache.object(forKey: request.storageKey as NSString) { return cached }
        if let existing = inFlight[request] { return await existing.value }
        let client = clientBox.client
        let fileURL = serverDir().appendingPathComponent(
            ArtworkCacheIO.filename(identity: request.cacheKey, size: request.size)
        )
        let session = session
        let failureRetryDelay = failureRetryDelay
        let useDisk = !invalidatedDiskCacheKeys.contains(request.cacheKey)
            || refreshedDiskSizes[request.cacheKey]?.contains(request.size) == true
        let input = ArtworkLoadInput(coverArt: request.coverArt, size: request.size, fileURL: fileURL,
                                     useDisk: useDisk, failureRetryDelay: failureRetryDelay)
        let task = Task<NSImage?, Never> { [weak self] in
            let result = await ArtworkCacheIO.load(input, client: client, session: session)
            guard let self else {
                ArtworkCacheIO.discard(result?.stagedFileURL)
                return nil
            }
            defer { self.inFlight[request] = nil }
            guard let result else { return nil }
            guard self.isCurrent(request) else {
                ArtworkCacheIO.discard(result.stagedFileURL)
                return nil
            }
            ArtworkCacheIO.publish(result.stagedFileURL, to: fileURL)
            let image = result.image
            self.cache.setObject(
                image, forKey: request.storageKey as NSString, cost: ArtworkCacheIO.cost(of: image)
            )
            if !(self.sizesByID[request.cacheKey]?.contains(request.size) ?? false) {
                self.sizesByID[request.cacheKey, default: []].append(request.size)
            }
            if !useDisk {
                self.refreshedDiskSizes[request.cacheKey, default: []].insert(request.size)
            }
            for observer in self.requestObservers[request]?.values ?? [:].values {
                observer(.ready(image))
            }
            return image
        }
        inFlight[request] = task
        return await task.value
    }

    func observe(_ request: Request, receive: @escaping (RequestEvent) -> Void) -> Interest? {
        guard isCurrent(request) else { return nil }
        let id = UUID()
        requestObservers[request, default: [:]][id] = receive
        let interest = Interest(cache: self, request: request, id: id)
        if let cached = cache.object(forKey: request.storageKey as NSString) {
            receive(.ready(cached))
        }
        return interest
    }
    func isCurrent(_ request: Request) -> Bool {
        request.sessionGeneration == sessionGeneration
            && request.cacheGeneration == generationByCacheKey[request.cacheKey, default: 0]
            && request.serverID == serverID
    }
    fileprivate func removeObserver(id: UUID, for request: Request) {
        requestObservers[request]?[id] = nil
        if requestObservers[request]?.isEmpty == true {
            requestObservers[request] = nil
        }
    }
    private func refreshCacheIdentity(_ identity: String, requestedSize: Int) {
        generationByCacheKey[identity, default: 0] &+= 1
        let retired = requestObservers.filter { $0.key.cacheKey == identity }
        for request in retired.keys {
            requestObservers[request] = nil
        }
        invalidateVariants(cacheKey: identity, requestedSize: requestedSize)
        retired.values.flatMap(\.values).forEach { $0(.invalidated) }
    }
    private func invalidateVariants(cacheKey identity: String, requestedSize: Int) {
        let knownSizes = Set((sizesByID[identity] ?? []) + [requestedSize, 0])
        for size in knownSizes {
            cache.removeObject(forKey: "\(serverID)|\(identity)@\(size)" as NSString)
            let fileURL = serverDir().appendingPathComponent(
                ArtworkCacheIO.filename(identity: identity, size: size)
            )
            try? FileManager.default.removeItem(at: fileURL)
        }
        sizesByID[identity] = nil
        invalidatedDiskCacheKeys.insert(identity)
        refreshedDiskSizes[identity] = []
    }
}
/// Lets the @MainActor cache hold a reference to the actor-isolated client
/// without retaining AppModel directly.
final class ClientBox {
    let client: SubsonicClient
    init(_ client: SubsonicClient) { self.client = client }
}
