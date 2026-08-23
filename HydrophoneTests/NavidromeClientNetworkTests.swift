import Testing
import Foundation
@testable import Hydrophone

/// Hermetic network-level tests for `NavidromeClient` via a stubbed
/// `URLProtocol` — no live server, so these run in CI and locally alike
/// (unlike `NavidromeLiveTests`). Covers what request-building alone can't:
/// token cache reuse, expiry-triggered refresh, credential-change
/// invalidation (PR #27 review, P1), one-retry-only 401 handling, and the
/// `X-Total-Count` failure path (PR #27 review, P2). See docs/08-testing.md.
///
/// `.serialized`: every test shares `NavidromeMockProtocol`'s single static
/// state (handler + request log) by design — it stands in for one real
/// server across a session, matching how `NavidromeClient` itself is used.
/// Running the suite's tests concurrently would race each other's handler/
/// log resets, so they're forced to run one at a time.
@Suite(.serialized)
struct NavidromeClientNetworkTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockProtocol.self]
        return URLSession(configuration: config)
    }

    private func creds(host: String = "https://music.example.com", secret: String = "sesame") -> ServerCredentials {
        ServerCredentials(baseURL: URL(string: host)!, username: "tim", secret: secret, authMethod: .tokenSalt)
    }

    private struct MinimalArtist: Decodable, Sendable { let id: String }

    @Test func cachedTokenIsReusedAcrossMultipleOperations() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)
        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)

        let loginCount = await NavidromeMockProtocol.count(pathSuffix: "/auth/login")
        #expect(loginCount == 1)
    }

    @Test func expiredTokenTriggersFreshLoginOnNextOperation() async throws {
        await NavidromeMockProtocol.reset()
        // Every login hands back an already-expired token, so the cache is
        // never usable and each call must re-authenticate.
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: -3600))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)
        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)

        let loginCount = await NavidromeMockProtocol.count(pathSuffix: "/auth/login")
        #expect(loginCount == 2)
    }

    @Test func credentialChangeInvalidatesCachedTokenAndTargetsNewHost() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let store = InMemoryCredentialStore(creds(host: "https://old-server.example.com"))
        let client = NavidromeClient(credentials: store, session: makeSession())

        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)
        try store.save(creds(host: "https://new-server.example.com", secret: "different-password"))
        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)

        let loginCount = await NavidromeMockProtocol.count(pathSuffix: "/auth/login")
        #expect(loginCount == 2) // the credential swap must force a fresh login, not reuse old-server's token

        let hosts = await NavidromeMockProtocol.requestedHosts(pathSuffix: "/api/artist")
        #expect(hosts == ["old-server.example.com", "new-server.example.com"]) // never cross-contaminated
    }

    /// The single-page test above can't catch this: a multi-page walk must
    /// use *one* credentials snapshot for every page, even if Settings saves
    /// a different server/account while the walk is in flight (between page
    /// zero completing and the remaining pages firing). Otherwise the
    /// combined result could silently mix page zero from server A with later
    /// pages from server B. See PR #27 re-review.
    @Test func credentialChangeMidMultiPageWalkDoesNotMixServers() async throws {
        await NavidromeMockProtocol.reset()
        let store = InMemoryCredentialStore(creds(host: "https://old-server.example.com"))
        let sawFirstArtistPage = FlagBox()

        await NavidromeMockProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            // Simulate Settings saving a new server while page zero's
            // request is in flight — only the *first* /api/artist call
            // triggers it, so it lands strictly between page zero and the
            // concurrent remaining-page fetches paginatedGet spawns after it.
            if sawFirstArtistPage.setTrueIfFirst() {
                try? store.save(self.creds(host: "https://new-server.example.com"))
            }
            // 1000 total / pageSize 500 → page zero + one more page.
            let headers = ["Content-Type": "application/json", "X-Total-Count": "1000"]
            return .init(status: 200, headers: headers, body: Data(#"[{"id":"a1"}]"#.utf8))
        }

        let client = NavidromeClient(credentials: store, session: makeSession())
        _ = try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)

        let hosts = await NavidromeMockProtocol.requestedHosts(pathSuffix: "/api/artist")
        #expect(hosts.count == 2)
        // Every page pinned to the snapshot from before the walk started.
        #expect(Set(hosts) == ["old-server.example.com"])
    }

    @Test func unauthorizedResponseRetriesExactlyOnceThenFails() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600, alwaysUnauthorized: true))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        await #expect(throws: NavidromeError.authenticationFailed) {
            try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)
        }

        let apiCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/artist")
        #expect(apiCallCount == 2) // original + exactly one retry after re-login
        let loginCount = await NavidromeMockProtocol.count(pathSuffix: "/auth/login")
        #expect(loginCount == 2) // initial + the re-login the 401 triggers
    }

    @Test func missingTotalCountHeaderFailsRatherThanSilentlyTruncating() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600, omitTotalCount: true))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        await #expect(throws: NavidromeError.self) {
            try await client.paginatedGet(path: "artist", sort: "name", pageSize: 500, as: MinimalArtist.self)
        }
    }

    /// Navidrome's database collation can put an accented spelling before
    /// its otherwise-identical unaccented spelling. `composers()` promises
    /// the macOS-localized order consumed by the UI, independent of that
    /// server-side collation.
    @Test func composersSortsServerRosterWithLocalizedStandardOrder() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            let body = #"[{"id":"accented","name":"André Caplet"},{"id":"plain","name":"Andre Caplet"}]"#
            let headers = ["Content-Type": "application/json", "X-Total-Count": "2"]
            return .init(status: 200, headers: headers, body: Data(body.utf8))
        }
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        let names = try await client.composers().map(\.name)

        #expect(names == ["Andre Caplet", "André Caplet"])
    }

    // MARK: - Handler

    /// Builds a request handler serving `/auth/login` and any `/api/<resource>`
    /// page request with one artist per page (so pagination logic isn't
    /// exercised here — that's a separate concern from cache/retry behavior).
    private static func makeHandler(
        jwtExpiresIn: TimeInterval, alwaysUnauthorized: Bool = false, omitTotalCount: Bool = false
    ) -> @Sendable (URLRequest) -> NavidromeMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(jwtExpiresIn).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if alwaysUnauthorized {
                return .init(status: 401, headers: [:], body: Data())
            }
            var headers = ["Content-Type": "application/json"]
            if !omitTotalCount { headers["X-Total-Count"] = "1" }
            return .init(status: 200, headers: headers, body: Data(#"[{"id":"a1"}]"#.utf8))
        }
    }

    /// A minimal but well-formed JWT (`header.payload.signature`, matching
    /// `NavidromeToken.decodeExpiry`'s url-safe-base64 parsing) carrying only
    /// an `exp` claim.
    private static func makeJWT(exp: TimeInterval) -> String {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = segment(#"{"exp":\#(Int(exp))}"#)
        return "\(header).\(payload).signature"
    }
}

/// Intercepts every request on sessions that register it and answers from a
/// caller-supplied handler. All mutable state is actor-protected so it's safe
/// to touch from `URLProtocol`'s arbitrary-thread callbacks and from test
/// assertions alike.
/// A one-shot, thread-safe latch: `setTrueIfFirst()` returns `true` exactly
/// once (for whichever call reaches it first), `false` for every call after.
/// Used to trigger a side effect (a mid-walk credential change) on exactly
/// the first matching request in a mock handler, regardless of which thread
/// the `URLProtocol` machinery runs it on.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setTrueIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}

final class NavidromeMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor State {
        var handler: (@Sendable (URLRequest) -> Response)?
        var requests: [URLRequest] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) { self.handler = handler }
        func reset() { handler = nil; requests = [] }
        func record(_ request: URLRequest) { requests.append(request) }
        func respond(to request: URLRequest) -> Response? { handler?(request) }
        func matchingRequests(pathSuffix: String) -> [URLRequest] {
            requests.filter { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) async {
        await state.setHandler(handler)
    }

    static func reset() async { await state.reset() }

    static func count(pathSuffix: String) async -> Int {
        await state.matchingRequests(pathSuffix: pathSuffix).count
    }

    static func requestedHosts(pathSuffix: String) async -> [String] {
        await state.matchingRequests(pathSuffix: pathSuffix).compactMap { $0.url?.host }
    }

    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        Task {
            await Self.state.record(req)
            guard let response = await Self.state.respond(to: req), let url = req.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let httpResponse = HTTPURLResponse(
                url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
