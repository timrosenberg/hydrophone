import Testing
import Foundation
@testable import Hydrophone

/// Regression test for `ArtworkCache`. `clientBox` was declared `weak`, so the
/// inline `ClientBox(client)` AppModel assigned had no other owner and
/// deallocated immediately — leaving `clientBox` nil and artwork never loading.
@MainActor
@Suite(.serialized)
struct ArtworkCacheTests {
    @Test func clientBoxIsRetained() {
        let creds = ServerCredentials(baseURL: URL(string: "https://example.com")!,
                                      username: "u", secret: "s", authMethod: .tokenSalt)
        let client = SubsonicClient(credentials: InMemoryCredentialStore(creds))

        ArtworkCache.shared.clientBox = ClientBox(client)
        #expect(ArtworkCache.shared.clientBox != nil)
    }

    /// `prefetch` is the viewport-ahead warmer the albums grid drives from
    /// `onAppear` (issue #15/E7) — it must guard the same nil/empty inputs as
    /// `image(coverArt:cacheKey:size:)` rather than crash or spin up a
    /// pointless fetch task.
    @Test func prefetchIgnoresMissingCoverArt() async {
        let cache = ArtworkCache()
        cache.prefetch([.init(coverArt: nil, size: 320), .init(coverArt: "", size: 320)])
        // No task was scheduled, so there is nothing to await; a follow-up
        // cache lookup for a made-up key must still miss.
        #expect(cache.cachedVariant(key: "no-such-key") == nil)
    }

    /// Songs of one album must share a cache identity (servers hand each song
    /// its own coverArt id for the same image), and that identity must match
    /// the album's — so the album page, hero and queue all reuse one download.
    @Test func artworkKeyCollapsesSongsOntoTheirAlbum() {
        var song = Song(id: "s1", title: "One")
        song.albumId = "al9"
        song.coverArt = "mf-s1_cafe"
        var sibling = Song(id: "s2", title: "Two")
        sibling.albumId = "al9"
        sibling.coverArt = "mf-s2_beef"
        let album = Album(id: "al9", name: "The Album")

        #expect(song.artworkKey == sibling.artworkKey)
        #expect(song.artworkKey == album.artworkKey)

        // No album to key by → fall back to the song's own coverArt id.
        var single = Song(id: "s3", title: "Loose")
        single.coverArt = "mf-s3_f00d"
        #expect(single.artworkKey == "mf-s3_f00d")
    }

    @Test func retryDelayParsesAndClampsRetryAfter() {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429,
                            httpVersion: nil, headerFields: headers)!
        }
        #expect(ArtworkCache.retryDelay(from: response(["Retry-After": "5"])) == 5)
        #expect(ArtworkCache.retryDelay(from: response(["Retry-After": "900"])) == 30)  // clamp
        #expect(ArtworkCache.retryDelay(from: response([:])) == 2)                      // default
        #expect(ArtworkCache.retryDelay(from: response(["Retry-After": "soon"])) == 2)  // junk
    }

    /// The albums grid's prefetch driver (issue #15/E7) sizes its warm-up
    /// fetch with this same helper `ArtworkView` uses for its own on-appear
    /// fetch, so a prefetched size actually lands on the cache entry the view
    /// goes on to request instead of warming a variant nobody asks for.
    @Test func fetchPixelsQuantizesToA160PxGrid() {
        #expect(ArtworkView.fetchPixels(forSize: 0) == 160)     // clamped to the floor
        #expect(ArtworkView.fetchPixels(forSize: 80) == 160)    // 80*2 = 160: exact 1st quantum
        #expect(ArtworkView.fetchPixels(forSize: 81) == 320)    // 81*2 = 162: just over → 2nd quantum
        #expect(ArtworkView.fetchPixels(forSize: 160) == 320)   // 160*2 = 320: exact 2nd quantum
        #expect(ArtworkView.fetchPixels(forSize: 161) == 480)   // 161*2 = 322: just over → 3rd quantum
    }

    @Test func visibleArtworkBypassesPendingPrefetches() async throws {
        try await withFixture { fixture in
            fixture.cache.prefetch((0..<24).map { request("held-\($0)") })
            try await waitUntil { ArtworkMockProtocol.state.ids.contains("held-0") }
            let visible = Task { await fixture.cache.image(coverArt: "visible", size: 480) }
            try await waitUntil { ArtworkMockProtocol.state.ids.contains("visible") }
            #expect(await visible.value != nil)
            #expect(ArtworkMockProtocol.state.ids == ["held-0", "visible"])
        }
    }

    @Test func replacingWindowDropsObsoletePendingArtwork() async throws {
        try await withFixture { fixture in
            fixture.cache.prefetch((0..<24).map { request("held-\($0)") })
            try await waitUntil { ArtworkMockProtocol.state.ids.contains("held-0") }
            fixture.cache.prefetch([request("replacement")])
            ArtworkMockProtocol.state.completeHeld()
            try await waitUntil { fixture.cache.cachedVariant(key: "replacement") != nil }
            #expect(ArtworkMockProtocol.state.ids == ["held-0", "replacement"])
        }
    }

    @Test func clearingWindowStopsPendingArtworkWithoutCancellingVisibleJoin() async throws {
        try await withFixture { fixture in
            fixture.cache.prefetch([request("held-0"), request("obsolete")])
            try await waitUntil { ArtworkMockProtocol.state.ids.contains("held-0") }
            let visible = Task { await fixture.cache.image(coverArt: "held-0", size: 480) }
            fixture.cache.prefetch([])
            ArtworkMockProtocol.state.completeHeld()
            #expect(await visible.value != nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(ArtworkMockProtocol.state.ids == ["held-0"])
        }
    }

    @Test func serverChangeDiscardsPendingPrefetches() async throws {
        try await withFixture { fixture in
            fixture.cache.prefetch([request("held-0"), request("obsolete")])
            try await waitUntil { ArtworkMockProtocol.state.ids.contains("held-0") }
            fixture.cache.setServer(baseURL: URL(string: "https://other.example.com")!)
            ArtworkMockProtocol.state.completeHeld()
            try await Task.sleep(for: .milliseconds(100))
            #expect(ArtworkMockProtocol.state.ids == ["held-0"])
        }
    }

    @Test func oversizedWindowFetchesOnlyTheBoundedPrefix() async throws {
        try await withFixture { fixture in
            fixture.cache.prefetch((0..<50).map { request("album-\($0)") })
            try await waitUntil { fixture.cache.cachedVariant(key: "album-23") != nil }
            try await Task.sleep(for: .milliseconds(50))
            #expect(ArtworkMockProtocol.state.ids == (0..<24).map { "album-\($0)" })
            // A repeated window reuses the warmed entries rather than downloading again.
            fixture.cache.prefetch((0..<24).map { request("album-\($0)") })
            try await Task.sleep(for: .milliseconds(50))
            #expect(ArtworkMockProtocol.state.ids.count == 24)
        }
    }

    private func withFixture(_ body: (ArtworkFixture) async throws -> Void) async throws {
        let fixture = ArtworkFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.finish()
            throw error
        }
        await fixture.finish()
    }

    @Test func albumPrefetchWindowWaitsForGeometryAndTracksVisibleIDs() {
        let albums = (0..<100).map { Album(id: "\($0)", name: "Album", coverArt: "art-\($0)") }
        #expect(AlbumsView.artworkToPrefetch(albums: albums, visibleIDs: ["0"], tileWidth: 0).isEmpty)
        #expect(AlbumsView.artworkToPrefetch(albums: albums, visibleIDs: [], tileWidth: 214).isEmpty)
        let initial = AlbumsView.artworkToPrefetch(albums: albums, visibleIDs: ["0", "8"], tileWidth: 214)
        #expect(initial.map(\.coverArt) == (9...32).map { "art-\($0)" })
        #expect(initial.allSatisfy { $0.size == 480 })
        let resized = AlbumsView.artworkToPrefetch(albums: albums, visibleIDs: ["97"], tileWidth: 260)
        #expect(resized.map(\.cacheKey) == ["album:98", "album:99"])
        #expect(resized.allSatisfy { $0.size == 640 })
        #expect(AlbumsView.artworkToPrefetch(albums: [], visibleIDs: ["97"], tileWidth: 260).isEmpty)
    }

    private func request(_ id: String) -> ArtworkCache.PrefetchRequest {
        .init(coverArt: id, size: 480)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for artwork")
    }

    @Test func limiterCapsConcurrencyAndRunsEveryBody() async {
        let limiter = AsyncLimiter(limit: 3)
        let gauge = ConcurrencyGauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.run {
                        await gauge.enter()
                        await Task.yield()
                        await gauge.exit()
                    }
                }
            }
        }
        let (peak, total) = await (gauge.peak, gauge.completed)
        #expect(peak <= 3)
        #expect(total == 20)
    }
}

private actor ConcurrencyGauge {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var completed = 0
    func enter() { active += 1; peak = max(peak, active) }
    func exit() { active -= 1; completed += 1 }
}

@MainActor
private final class ArtworkFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session: URLSession
    private var ownedCache: ArtworkCache?
    var cache: ArtworkCache { ownedCache! }

    init() {
        ArtworkMockProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkMockProtocol.self]
        session = URLSession(configuration: config)
        ownedCache = ArtworkCache(session: session, directory: directory)
        let creds = ServerCredentials(baseURL: URL(string: "https://artwork.example.com")!,
                                      username: "u", secret: "s", authMethod: .tokenSalt)
        cache.clientBox = ClientBox(SubsonicClient(credentials: InMemoryCredentialStore(creds)))
    }

    func finish() async {
        cache.prefetch([])
        // A queued request can reach the protocol after teardown begins.
        // Complete those too, then let the cache's worker and image calls
        // release it before invalidating the session or removing its files.
        ArtworkMockProtocol.state.completeHeld(stopHolding: true)
        weak var drainingCache = ownedCache
        ownedCache = nil
        for _ in 0..<500 {
            if drainingCache == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(drainingCache == nil, "Artwork work must drain before its session is invalidated")
        guard drainingCache == nil else { return }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ArtworkMockProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [String] = []
        private var held: [ArtworkMockProtocol] = []
        private var isFinishing = false

        var ids: [String] { lock.withLock { started } }
        func reset() { lock.withLock { started = []; held = []; isFinishing = false } }
        func record(_ request: ArtworkMockProtocol, id: String) -> Bool {
            lock.withLock {
                started.append(id)
                guard id.hasPrefix("held-"), !isFinishing else { return false }
                held.append(request)
                return true
            }
        }
        func completeHeld(stopHolding: Bool = false) {
            let requests = lock.withLock {
                if stopHolding { isFinishing = true }
                let requests = held
                held = []
                return requests
            }
            requests.forEach { $0.complete() }
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value ?? "missing"
        if !Self.state.record(self, id: id) { complete() }
    }
    override func stopLoading() {}
    func complete() {
        let data = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "image/png",
                                                         expectedContentLength: data.count,
                                                         textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
