import Testing
import Foundation
@testable import Hydrophone

/// Regression test for `ArtworkCache`. `clientBox` was declared `weak`, so the
/// inline `ClientBox(client)` AppModel assigned had no other owner and
/// deallocated immediately — leaving `clientBox` nil and artwork never loading.
@MainActor
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
        let cache = ArtworkCache.shared
        cache.clientBox = nil
        cache.prefetch(coverArt: nil, size: 320)
        cache.prefetch(coverArt: "", size: 320)
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
        #expect(ArtworkView.fetchPixels(forSize: 0) == 160)     // floor
        #expect(ArtworkView.fetchPixels(forSize: 80) == 160)    // 80*2 = 160, exact
        #expect(ArtworkView.fetchPixels(forSize: 160) == 320)   // 160*2 = 320, exact
        #expect(ArtworkView.fetchPixels(forSize: 161) == 480)   // rounds up a quantum
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
