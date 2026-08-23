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
    /// Full composer/song decoding isn't in scope here (#23/#24) — this only
    /// confirms paging + auth-header plumbing against `/api/artist`.
    @Test func paginatedGetRoundTripsAgainstRealArtistList() async throws {
        guard let env = liveEnv() else { return }
        struct MinimalArtist: Decodable, Sendable { let id: String }
        let artists = try await client(env).paginatedGet(
            path: "artist", sort: "name", pageSize: 50, as: MinimalArtist.self
        )
        #expect(!artists.isEmpty)
    }
}
