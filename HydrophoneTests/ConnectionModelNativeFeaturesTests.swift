import Testing
import Foundation
@testable import Hydrophone

/// Hermetic coverage for `ConnectionModel`'s native-feature-detection probe
/// (#26): after a successful Subsonic connect, a real `NavidromeClient.login()`
/// call decides `nativeFeaturesState`, and a library scan fires the library
/// invalidation handler (#24, #140/#141 — the underlying cache invalidation
/// itself is covered by `LibrarySongIndex`'s own tests). Stubs both
/// `SubsonicClient`'s `/rest/...` calls and `NavidromeClient`'s
/// `/auth/login`/`/api/...` calls behind one shared `URLProtocol`, so no live
/// server is needed. Live behavior (real server, real demo/bad-password
/// probe) is covered separately by hand — see docs/PROGRESS.md. See
/// docs/02-opensubsonic-api.md, docs/08-testing.md.
///
/// `.serialized`: shares `ConnectionProbeMockProtocol`'s single static state
/// across this suite's tests, same reasoning as
/// `NavidromeClientNetworkTests`'s `NavidromeMockProtocol`.
@MainActor
@Suite(.serialized)
struct ConnectionModelNativeFeaturesTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionProbeMockProtocol.self]
        return URLSession(configuration: config)
    }

    private func creds(authMethod: ServerCredentials.AuthMethod = .tokenSalt) -> ServerCredentials {
        ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                          username: "tim", secret: "sesame", authMethod: authMethod)
    }

    private func makeModel(
        _ creds: ServerCredentials?
    ) -> (model: ConnectionModel, navidrome: NavidromeClient) {
        let store = InMemoryCredentialStore(creds)
        let session = makeSession()
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        let model = ConnectionModel(client: client, navidrome: navidrome, credentials: store)
        return (model, navidrome)
    }

    private func makeApp(
        _ creds: ServerCredentials?
    ) -> (app: AppModel, connection: ConnectionModel) {
        let store = InMemoryCredentialStore(creds)
        let session = makeSession()
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        let connection = ConnectionModel(client: client, navidrome: navidrome, credentials: store)
        let library = LibraryModel(client: client, navidrome: navidrome,
                                   nativeFeaturesAvailable: { await connection.nativeFeaturesAvailable() })
        let app = AppModel(credentials: store, client: client, playback: PlaybackService(client: client),
                           connection: connection, library: library, player: PlayerModel())
        return (app, connection)
    }

    // MARK: - Probe outcomes

    @Test func refreshMarksNativeFeaturesAvailableAfterSuccessfulLogin() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds())

        await model.refresh()

        #expect(model.isConnected)
        #expect(model.nativeFeaturesState == .available)
    }

    @Test func launchRefreshStartsTheEagerSongsWalk() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (app, connection) = makeApp(creds())

        await connection.refresh()

        #expect(app.library.songs.map(\.id) == ["s1"])
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/rest/search3.view") == 1)
    }

    @Test func nativeFeaturesAvailableStartsAndAwaitsDetectionWhenUnknown() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds())

        let available = await model.nativeFeaturesAvailable()

        #expect(available)
        #expect(model.nativeFeaturesState == .available)
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/rest/ping.view") == 1)
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/auth/login") == 1)
    }

    @Test func nativeFeaturesAvailableWaitsForAnInFlightProbe() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler(loginDelay: .milliseconds(100)))
        let (model, _) = makeModel(creds())

        let refresh = Task { await model.refresh() }
        while model.nativeFeaturesState != .checking { await Task.yield() }
        let available = await model.nativeFeaturesAvailable()
        await refresh.value

        #expect(available)
        #expect(model.nativeFeaturesState == .available)
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/auth/login") == 1)
    }

    @Test func nativeFeaturesAvailableWaitsForLaunchRefreshBeforeProbeStarts() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler(pingDelay: .milliseconds(100)))
        let (model, _) = makeModel(creds())

        let refresh = Task { await model.refresh() }
        while model.state != .connecting { await Task.yield() }
        let available = await model.nativeFeaturesAvailable()
        await refresh.value

        #expect(available)
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/rest/ping.view") == 1)
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/auth/login") == 1)
    }

    @Test func refreshMarksNativeFeaturesUnavailableWhenLoginFails() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler(loginStatus: 401))
        let (model, _) = makeModel(creds())

        await model.refresh()

        #expect(model.isConnected) // the Subsonic ping still succeeded
        #expect(model.nativeFeaturesState == .unavailable)
    }

    @Test func refreshMarksNativeFeaturesUnavailableForAPIKeyAuthWithoutANetworkCall() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds(authMethod: .apiKey))

        await model.refresh()

        #expect(model.nativeFeaturesState == .unavailable)
        let loginCount = await ConnectionProbeMockProtocol.count(pathSuffix: "/auth/login")
        #expect(loginCount == 0) // apiKeyAuthUnsupported is a local guard — never reaches the network
    }

    @Test func testConnectionNeverProbesNativeFeatures() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds())

        await model.testConnection()

        #expect(model.nativeFeaturesState == .unknown)
        let loginCount = await ConnectionProbeMockProtocol.count(pathSuffix: "/auth/login")
        #expect(loginCount == 0) // verifies unsaved form creds; probing here would check the wrong server
    }

    @Test func saveAndConnectMarksNativeFeaturesAvailableAfterSuccessfulLogin() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(nil)
        model.serverAddress = "https://music.example.com"
        model.username = "tim"
        model.secret = "sesame"
        model.authMethod = .tokenSalt

        await model.saveAndConnect()

        #expect(model.isConnected)
        #expect(model.nativeFeaturesState == .available)
    }

    @Test func firstSaveAndConnectStartsTheEagerSongsWalk() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (app, connection) = makeApp(nil)
        connection.serverAddress = "https://music.example.com"
        connection.username = "tim"
        connection.secret = "sesame"
        connection.authMethod = .tokenSalt

        await connection.saveAndConnect()

        #expect(app.library.songs.map(\.id) == ["s1"])
        #expect(await ConnectionProbeMockProtocol.count(pathSuffix: "/rest/search3.view") == 1)
    }

    @Test func changedSavedCredentialsInvalidateSongsSnapshot() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds())
        var invalidations = 0
        model.setLibraryInvalidationHandler { invalidations += 1 }
        model.serverAddress = "https://second.example.com"
        model.username = "other"
        model.secret = "different"
        model.authMethod = .apiKey

        await model.saveAndConnect()

        #expect(invalidations == 1)
    }

    @Test func disconnectResetsNativeFeaturesStateToUnknown() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds())
        var invalidations = 0
        model.setLibraryInvalidationHandler { invalidations += 1 }
        await model.refresh()
        #expect(model.nativeFeaturesState == .available)

        await model.disconnect()

        #expect(model.nativeFeaturesState == .unknown)
        #expect(invalidations == 1)
    }

    // MARK: - Scan → library invalidation (#24, #140/#141)

    /// `ConnectionModel` no longer touches a song-index cache directly (that
    /// state moved to `LibrarySongIndex` — see docs/05's "Design decision
    /// (#140)"); this just proves a successful scan fires the library
    /// invalidation handler exactly once. `LibrarySongIndex`'s own tests
    /// cover that `invalidate()` actually clears its caches.
    @Test func startLibraryScanFiresLibraryInvalidationHandlerOnce() async {
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.makeHandler())
        let (model, _) = makeModel(creds())
        var invalidations = 0
        model.setLibraryInvalidationHandler { invalidations += 1 }

        await model.startLibraryScan()

        #expect(invalidations == 1)
    }

    // MARK: - Mock handler

    private static func makeHandler(
        loginStatus: Int = 200,
        loginDelay: Duration = .zero,
        pingDelay: Duration = .zero
    ) -> @Sendable (URLRequest) -> ConnectionProbeMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                guard loginStatus == 200 else {
                    return .init(status: loginStatus, headers: [:], body: Data())
                }
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8), delay: loginDelay)
            }
            if path.hasSuffix("/rest/ping.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",\
                "serverVersion":"0.52.0","openSubsonic":true}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8), delay: pingDelay)
            }
            if path.hasSuffix("/rest/startScan.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1",\
                "scanStatus":{"scanning":false,"count":1}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/search3.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
                "song":[{"id":"s1","title":"Track 1"}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/api/song") {
                return .init(status: 200,
                             headers: ["Content-Type": "application/json", "X-Total-Count": "1"],
                             body: Data(#"[{"id":"s1"}]"#.utf8))
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    /// A minimal but well-formed JWT (`header.payload.signature`, matching
    /// `NavidromeToken.decodeExpiry`'s url-safe-base64 parsing) carrying only
    /// an `exp` claim.
    private nonisolated static func makeJWT(exp: TimeInterval) -> String {
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

/// Handler-based `URLProtocol` stub shared by this suite's tests — routes
/// both `SubsonicClient`'s `/rest/...` calls and `NavidromeClient`'s
/// `/auth/login`/`/api/...` calls to one caller-supplied handler, since a
/// `ConnectionModel` test exercises both clients together. Modeled on
/// `NavidromeMockProtocol` (`NavidromeClientNetworkTests.swift`) but kept
/// separate so the two suites' shared static state can't race each other.
final class ConnectionProbeMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        var delay: Duration = .zero
    }

    private actor State {
        var handler: (@Sendable (URLRequest) -> Response)?
        var asyncHandler: (@Sendable (URLRequest) async -> Response)?
        var requests: [URLRequest] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) { self.handler = handler }
        func setAsyncHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) {
            asyncHandler = handler
        }
        func reset() { handler = nil; asyncHandler = nil; requests = [] }
        func record(_ request: URLRequest) { requests.append(request) }
        func respond(to request: URLRequest) -> Response? { handler?(request) }
        func respondAsync(to request: URLRequest) async -> Response? {
            if let asyncHandler { return await asyncHandler(request) }
            return handler?(request)
        }
        func matchingRequests(pathSuffix: String) -> [URLRequest] {
            requests.filter { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) async {
        await state.setHandler(handler)
    }

    static func setAsyncHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) async {
        await state.setAsyncHandler(handler)
    }

    static func reset() async { await state.reset() }

    static func count(pathSuffix: String) async -> Int {
        await state.matchingRequests(pathSuffix: pathSuffix).count
    }

    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        Task { @Sendable [self] in
            await Self.state.record(req)
            guard let response = await Self.state.respondAsync(to: req), let url = req.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            try? await Task.sleep(for: response.delay)
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
