import Testing
import Foundation
@testable import Hydrophone

/// Hermetic coverage for #114: `LibraryModel.album(id:)` and
/// `albums(forArtist:)` cache their result per session so revisiting an
/// already-fetched album or artist doesn't re-hit the network, and that
/// cache is cleared on `reset()` (disconnect/credential-change/manual scan)
/// so a stale entry can't survive the same event that already invalidates
/// the rest of the library index. Stubs `SubsonicClient`'s `/rest/...` calls
/// behind a dedicated `URLProtocol`, mirroring `WorkInfoJoinMockProtocol`
/// (`LibraryModelWorkInfoJoinTests.swift`) but kept separate so the two
/// suites' shared static state can't race.
@MainActor
@Suite(.serialized)
struct LibraryModelDetailCacheTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DetailCacheMockProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeLibrary() -> LibraryModel {
        let creds = ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                                      username: "tim", secret: "sesame", authMethod: .tokenSalt)
        let store = InMemoryCredentialStore(creds)
        let session = makeSession()
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        return LibraryModel(client: client, navidrome: navidrome,
                            nativeFeaturesAvailable: { false })
    }

    @Test func albumDetailIsCachedWithinASession() async throws {
        await DetailCacheMockProtocol.reset()
        await DetailCacheMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary()

        let first = try #require(await library.album(id: "album-1"))
        let second = try #require(await library.album(id: "album-1"))

        #expect(first.name == "Schwanengesang")
        #expect(second.name == "Schwanengesang")
        #expect(await DetailCacheMockProtocol.count(pathSuffix: "/rest/getAlbum.view") == 1)
    }

    @Test func albumsForArtistAreCachedWithinASession() async throws {
        await DetailCacheMockProtocol.reset()
        await DetailCacheMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary()

        let first = await library.albums(forArtist: "artist-1")
        let second = await library.albums(forArtist: "artist-1")

        #expect(first.map(\.id) == ["album-1"])
        #expect(second.map(\.id) == ["album-1"])
        #expect(await DetailCacheMockProtocol.count(pathSuffix: "/rest/getArtist.view") == 1)
    }

    @Test func distinctIdsAreCachedSeparately() async throws {
        await DetailCacheMockProtocol.reset()
        await DetailCacheMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary()

        _ = await library.album(id: "album-1")
        _ = await library.album(id: "album-2")

        #expect(await DetailCacheMockProtocol.count(pathSuffix: "/rest/getAlbum.view") == 2)
    }

    @Test func resetClearsTheDetailCacheSoTheNextVisitRefetches() async throws {
        await DetailCacheMockProtocol.reset()
        await DetailCacheMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary()

        _ = await library.album(id: "album-1")
        _ = await library.albums(forArtist: "artist-1")
        await library.reset()
        _ = await library.album(id: "album-1")
        _ = await library.albums(forArtist: "artist-1")

        #expect(await DetailCacheMockProtocol.count(pathSuffix: "/rest/getAlbum.view") == 2)
        #expect(await DetailCacheMockProtocol.count(pathSuffix: "/rest/getArtist.view") == 2)
    }

    @Test func aFailedArtistFetchIsNotCachedSoTheNextVisitRetries() async throws {
        await DetailCacheMockProtocol.reset()
        await DetailCacheMockProtocol.setHandler(Self.makeFailingArtistHandler())
        let library = makeLibrary()

        let first = await library.albums(forArtist: "artist-1")
        let second = await library.albums(forArtist: "artist-1")

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(await DetailCacheMockProtocol.count(pathSuffix: "/rest/getArtist.view") == 2)
    }

    // MARK: - Mock handler

    private static func makeHandler() -> @Sendable (URLRequest) -> DetailCacheMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/rest/getAlbum.view") {
                let albumId = request.url?.queryItem("id") ?? "album-1"
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"\(albumId)",
                "name":"Schwanengesang","song":[]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/getArtist.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","artist":{"id":"artist-1",
                "name":"Schubert","album":[{"id":"album-1","name":"Schwanengesang"}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    private static func makeFailingArtistHandler() -> @Sendable (URLRequest) -> DetailCacheMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/rest/getArtist.view") {
                return .init(status: 500, headers: [:], body: Data())
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }
}

private extension URL {
    func queryItem(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

/// Handler-based `URLProtocol` stub for this suite only — see the type doc
/// comment above for why it isn't shared with `WorkInfoJoinMockProtocol`.
final class DetailCacheMockProtocol: URLProtocol, @unchecked Sendable {
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

    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        Task { @Sendable [self] in
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
