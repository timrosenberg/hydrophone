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
    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockProtocol.self]
        return URLSession(configuration: config)
    }

    func creds(host: String = "https://music.example.com", secret: String = "sesame") -> ServerCredentials {
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

    // MARK: - songIndex()

    @Test func songIndexCachesAndDoesNotRefetchOnRepeatCalls() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        let first = try await client.songIndex()
        let second = try await client.songIndex()

        #expect(first.map(\.id) == second.map(\.id))
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 1) // second call served from cache, no refetch
    }

    @Test func invalidateSongIndexForcesRefetchOnNextCall() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        _ = try await client.songIndex()
        await client.invalidateSongIndex()
        _ = try await client.songIndex()

        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 2)
    }

    /// PR #31 review, P1: a cache built for one server/account must not be
    /// served to a different one after Settings changes the connection.
    @Test func songIndexIsInvalidatedByCredentialChange() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let store = InMemoryCredentialStore(creds(host: "https://old-server.example.com"))
        let client = NavidromeClient(credentials: store, session: makeSession())

        _ = try await client.songIndex()
        try store.save(creds(host: "https://new-server.example.com", secret: "different-password"))
        _ = try await client.songIndex()

        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 2) // the credential swap must force a refetch, not reuse old-server's cache

        let hosts = await NavidromeMockProtocol.requestedHosts(pathSuffix: "/api/song")
        #expect(hosts == ["old-server.example.com", "new-server.example.com"])
    }

    /// PR #31 re-review, P1: replacing an in-flight build after a credential
    /// change must retire the old build. If the new-server build completes
    /// first, the old-server build's later completion must not overwrite the
    /// new cache or clear the new build's state.
    @Test func credentialChangeDuringBuildCannotLetOldCompletionOverwriteNewCache() async throws {
        await NavidromeMockProtocol.reset()
        let oldGate = Gate()
        let newGate = Gate()
        await NavidromeMockProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            let host = request.url?.host ?? ""
            if host == "old-server.example.com" { await oldGate.wait() }
            if host == "new-server.example.com" { await newGate.wait() }
            let headers = ["Content-Type": "application/json", "X-Total-Count": "1"]
            let songID = host == "old-server.example.com" ? "old-song" : "new-song"
            return .init(status: 200, headers: headers, body: Data("[{\"id\":\"\(songID)\"}]".utf8))
        }
        let store = InMemoryCredentialStore(creds(host: "https://old-server.example.com"))
        let client = NavidromeClient(credentials: store, session: makeSession())

        async let oldBuild = client.songIndex()
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song", host: "old-server.example.com")

        try store.save(creds(host: "https://new-server.example.com", secret: "different-password"))
        async let newBuild = client.songIndex()
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song", host: "new-server.example.com")

        await newGate.open()
        #expect(try await newBuild.map(\.id) == ["new-song"])
        await oldGate.open()
        #expect(try await oldBuild.map(\.id) == ["old-song"])

        let cached = try await client.songIndex()
        #expect(cached.map(\.id) == ["new-song"])
        let hosts = await NavidromeMockProtocol.requestedHosts(pathSuffix: "/api/song")
        #expect(hosts == ["old-server.example.com", "new-server.example.com"])
    }

    /// PR #31 review, P2: overlapping callers arriving while a build is in
    /// flight must coalesce onto it rather than each starting their own
    /// full paginated walk.
    @Test func concurrentSongIndexCallsCoalesceIntoOneWalk() async throws {
        await NavidromeMockProtocol.reset()
        let gate = Gate()
        await NavidromeMockProtocol.setHandler(Self.gatedSongHandler(gate))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        async let first = client.songIndex()
        async let second = client.songIndex()
        // Let both callers reach the actor and observe the same in-flight
        // build before the gated response is allowed to resolve.
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song")
        await gate.open()

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult.map(\.id) == secondResult.map(\.id))
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 1) // both callers shared one walk, not two
    }

    /// PR #31 review, P2: actor reentrancy means `invalidateSongIndex()` can
    /// run while a build is awaiting its network response. That build's
    /// eventual completion must not resurrect the cache it was told to
    /// drop, and a caller arriving after invalidation must see a genuine
    /// refetch rather than the stale in-flight result.
    @Test func invalidationDuringInFlightBuildIsNotClobberedByItsCompletion() async throws {
        await NavidromeMockProtocol.reset()
        let gate = Gate()
        await NavidromeMockProtocol.setHandler(Self.gatedSongHandler(gate))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        async let firstBuild = client.songIndex()
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song")
        await client.invalidateSongIndex() // runs while firstBuild is still awaiting the gated response
        await gate.open()
        _ = try await firstBuild

        _ = try await client.songIndex() // must see a cache miss and refetch, not the retired build's result
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 2)
    }

    /// Polls the mock's request log until a request matching `pathSuffix` is
    /// recorded. Recording happens as soon as `URLProtocol.startLoading`
    /// fires, before the (possibly gated) handler runs, so this reliably
    /// observes "the request has started" without a fixed sleep.
    private static func waitUntilRequestSeen(pathSuffix: String) async {
        while await NavidromeMockProtocol.count(pathSuffix: pathSuffix) == 0 {
            await Task.yield()
        }
    }

    private static func waitUntilRequestSeen(pathSuffix: String, host: String) async {
        while !(await NavidromeMockProtocol.requestedHosts(pathSuffix: pathSuffix).contains(host)) {
            await Task.yield()
        }
    }

    /// A `/api/song` handler that blocks on `gate` before responding with a
    /// single-song page, so a test can deterministically act while the
    /// request is "in flight" without a real slow network call.
    private static func gatedSongHandler(
        _ gate: Gate
    ) -> @Sendable (URLRequest) async -> NavidromeMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            await gate.wait()
            let headers = ["Content-Type": "application/json", "X-Total-Count": "1"]
            return .init(status: 200, headers: headers, body: Data(#"[{"id":"s1"}]"#.utf8))
        }
    }

    // MARK: - Handler

    /// Builds a request handler serving `/auth/login` and any `/api/<resource>`
    /// page request with one artist per page (so pagination logic isn't
    /// exercised here — that's a separate concern from cache/retry behavior).
    static func makeHandler(
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

/// Lets a test hold a mock handler's response open until it explicitly
/// releases it — used to make an "in flight" moment deterministic instead of
/// racing real (if fast) async work. `open()` before anyone calls `wait()`
/// is a no-op-safe no-wait, matching a real gate's "already open" case.
private actor Gate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

final class NavidromeMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor State {
        var handler: (@Sendable (URLRequest) async -> Response)?
        var requests: [URLRequest] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) { self.handler = handler }
        func reset() { handler = nil; requests = [] }
        func record(_ request: URLRequest) { requests.append(request) }
        func respond(to request: URLRequest) async -> Response? { await handler?(request) }
        func matchingRequests(pathSuffix: String) -> [URLRequest] {
            requests.filter { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) async {
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
