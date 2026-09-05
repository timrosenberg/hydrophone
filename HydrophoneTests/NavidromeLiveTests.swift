import Testing
import Foundation
@testable import Hydrophone

/// Opt-in integration tests for `NavidromeClient` against a real Navidrome
/// server. **Skipped** unless `HYDROPHONE_HOST`, `HYDROPHONE_USER`, and
/// `HYDROPHONE_PASS` are set in the environment, so no credentials are
/// committed — same gating as `LiveDecodeTests.swift`. See docs/08-testing.md,
/// #22.
struct NavidromeLiveTests {
    private struct Env {
        let host: URL, user: String, pass: String
    }

    private func liveEnv() -> Env? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["HYDROPHONE_HOST"], let url = URL(string: host),
              let user = env["HYDROPHONE_USER"], let pass = env["HYDROPHONE_PASS"] else { return nil }
        return Env(host: url, user: user, pass: pass)
    }

    private func client(_ env: Env) -> NavidromeClient {
        let creds = ServerCredentials(baseURL: env.host, username: env.user,
                                      secret: env.pass, authMethod: .tokenSalt)
        return NavidromeClient(credentials: InMemoryCredentialStore(creds))
    }

    @Test func loginReturnsANonEmptyToken() async throws {
        guard let env = liveEnv() else { return }
        let token = try await client(env).login()
        #expect(!token.raw.isEmpty)
    }

    /// A cached login should be reused (no observable behavior difference to
    /// assert on directly since the token is opaque) — this just proves a
    /// second call doesn't throw, i.e. the cache path is exercised without error.
    @Test func loginTwiceInARowSucceeds() async throws {
        guard let env = liveEnv() else { return }
        let sharedClient = client(env)
        _ = try await sharedClient.login()
        let second = try await sharedClient.login()
        #expect(!second.raw.isEmpty)
    }

    /// Proof the pagination helper round-trips against a real list endpoint.
    /// The minimal row type deliberately isolates paging + auth-header
    /// plumbing; composer and song-domain coverage live in the tests below.
    @Test func paginatedGetRoundTripsAgainstRealArtistList() async throws {
        guard let env = liveEnv() else { return }
        struct MinimalArtist: Decodable, Sendable { let id: String }
        let artists = try await client(env).paginatedGet(
            path: "artist", sort: "name", pageSize: 50, as: MinimalArtist.self
        )
        #expect(!artists.isEmpty)
    }

    /// Non-missing library pull via `songIndex()` — proves the concurrent walk,
    /// tolerant decode of `participants`/`tags`, and in-session cache all
    /// work end to end against a real library. Elapsed time is printed, not
    /// asserted on (server-dependent; ~5-15s measured against a real
    /// 14,794-track library — see #24).
    @Test func songIndexReturnsFullLibraryAndCachesOnSecondCall() async throws {
        guard let env = liveEnv() else { return }
        let sharedClient = client(env)

        let token = try await sharedClient.login()
        let credentials = ServerCredentials(
            baseURL: env.host, username: env.user, secret: env.pass, authMethod: .tokenSalt
        )
        let countRequest = try await sharedClient.apiRequest(
            path: "song", query: [
                URLQueryItem(name: "_start", value: "0"),
                URLQueryItem(name: "_end", value: "1"),
                URLQueryItem(name: "missing", value: "false")
            ], token: token, using: credentials
        )
        let (_, response) = try await URLSession.shared.data(for: countRequest)
        let http = try #require(response as? HTTPURLResponse)
        try #require(http.statusCode == 200)
        let filteredTotal = try #require(http.value(forHTTPHeaderField: "X-Total-Count").flatMap(Int.init))

        let sharedIndex = LibrarySongIndex(
            client: SubsonicClient(credentials: InMemoryCredentialStore()),
            navidrome: sharedClient,
            nativeFeaturesAvailable: { true }
        )

        let start = Date()
        let index = try await sharedIndex.songIndex()
        let elapsed = Date().timeIntervalSince(start)
        print("songIndex(): \(index.count) songs in \(String(format: "%.1f", elapsed))s")
        #expect(!index.isEmpty)
        #expect(index.count == filteredTotal)

        let cachedStart = Date()
        let cached = try await sharedIndex.songIndex()
        let cachedElapsed = Date().timeIntervalSince(cachedStart)
        print("songIndex() cached: \(cached.count) songs in \(String(format: "%.3f", cachedElapsed))s")
        #expect(cached.count == index.count)
    }

    /// `composers()` (#23): a non-empty, name-sorted roster against a real
    /// server.
    @Test func composersReturnsNonEmptyNameSortedRoster() async throws {
        guard let env = liveEnv() else { return }
        let composers = try await client(env).composers()
        #expect(!composers.isEmpty)
        let names = composers.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
