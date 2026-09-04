import Foundation
import Testing
@testable import Hydrophone

// Shares the suite's serialized trait and mock protocol without growing its main file.
extension NavidromeClientNetworkTests {
    /// The native song-index cache lives on `LibrarySongIndex` now (#140/#141),
    /// not `NavidromeClient` directly. The `SubsonicClient` half is never
    /// called by this test, so a plain unconfigured one is enough.
    private func songIndex(navidrome: NavidromeClient) -> LibrarySongIndex {
        LibrarySongIndex(
            client: SubsonicClient(credentials: InMemoryCredentialStore()),
            navidrome: navidrome,
            nativeFeaturesAvailable: { true }
        )
    }

    @Test func songIndexCachesAndDoesNotRefetchOnRepeatCalls() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())
        let index = songIndex(navidrome: client)

        let first = try await index.songIndex()
        let second = try await index.songIndex()

        #expect(first.map(\.id) == second.map(\.id))
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 1) // second call served from cache, no refetch
    }

    @Test func invalidateSongIndexForcesRefetchOnNextCall() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeHandler(jwtExpiresIn: 3600))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())
        let index = songIndex(navidrome: client)

        _ = try await index.songIndex()
        await index.invalidate()
        _ = try await index.songIndex()

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
        let index = songIndex(navidrome: client)

        _ = try await index.songIndex()
        try store.save(creds(host: "https://new-server.example.com", secret: "different-password"))
        _ = try await index.songIndex()

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
        let index = songIndex(navidrome: client)

        async let oldBuild = index.songIndex()
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song", host: "old-server.example.com")

        try store.save(creds(host: "https://new-server.example.com", secret: "different-password"))
        async let newBuild = index.songIndex()
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song", host: "new-server.example.com")

        await newGate.open()
        #expect(try await newBuild.map(\.id) == ["new-song"])
        await oldGate.open()
        #expect(try await oldBuild.map(\.id) == ["old-song"])

        let cached = try await index.songIndex()
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
        let index = songIndex(navidrome: client)

        async let first = index.songIndex()
        async let second = index.songIndex()
        // Let both callers reach the actor and observe the same in-flight
        // build before the gated response is allowed to resolve.
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song")
        await gate.open()

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult.map(\.id) == secondResult.map(\.id))
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 1) // both callers shared one walk, not two
    }

    /// PR #31 review, P2: actor reentrancy means invalidation can run while a
    /// build is awaiting its network response. That build's eventual
    /// completion must not resurrect the cache it was told to drop, and a
    /// caller arriving after invalidation must see a genuine refetch rather
    /// than the stale in-flight result.
    @Test func invalidationDuringInFlightBuildIsNotClobberedByItsCompletion() async throws {
        await NavidromeMockProtocol.reset()
        let gate = Gate()
        await NavidromeMockProtocol.setHandler(Self.gatedSongHandler(gate))
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())
        let index = songIndex(navidrome: client)

        async let firstBuild = index.songIndex()
        await Self.waitUntilRequestSeen(pathSuffix: "/api/song")
        await index.invalidate() // runs while firstBuild is still awaiting the gated response
        await gate.open()
        _ = try await firstBuild

        _ = try await index.songIndex() // must see a cache miss and refetch, not the retired build's result
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 2)
    }

    @Test func songIndexExcludesMissingFilesOnEveryPageAndRetry() async throws {
        await NavidromeMockProtocol.reset()
        let requests = SongIndexRequests()
        await NavidromeMockProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/auth/login") == true {
                return Self.makeHandler(jwtExpiresIn: 3600)(request)
            }
            let attempt = await requests.record(request)
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let start = query.first { $0.name == "_start" }.flatMap { $0.value }.flatMap(Int.init) ?? 0
            if start == 500, attempt == 1 {
                return .init(status: 401, headers: [:], body: Data())
            }
            let rows = (start..<min(start + 500, 1001)).map { #"{"id":"s\#($0)"}"# }
            return .init(
                status: 200, headers: ["Content-Type": "application/json", "X-Total-Count": "1001"],
                body: Data("[\(rows.joined(separator: ","))]".utf8)
            )
        }
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        let index = try await songIndex(navidrome: client).songIndex()

        #expect(index.count == 1001)
        #expect(index.first?.id == "s0")
        #expect(index.last?.id == "s1000")
        let urls = await requests.urls
        #expect(urls.count == 4)
        for url in urls {
            #expect(url.path == "/api/song")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.filter { $0.name == "missing" } == [URLQueryItem(name: "missing", value: "false")])
        }
        let ranges = urls.map { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = query.first { $0.name == "_start" }?.value ?? ""
            let end = query.first { $0.name == "_end" }?.value ?? ""
            return "\(start):\(end)"
        }
        #expect(ranges.sorted() == ["0:500", "1000:1500", "500:1000", "500:1000"])
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

private actor SongIndexRequests {
    var urls: [URL] = []

    func record(_ request: URLRequest) -> Int {
        guard let url = request.url else { return 0 }
        urls.append(url)
        return urls.filter { $0 == url }.count
    }
}
