import Testing
import Foundation
@testable import Hydrophone

/// Hermetic coverage for `LibraryModel`'s work/movement join (#45, epic #13):
/// Album, Favorites, search, and playlist sources should carry `Song.work`
/// etc. onto their results when native features are available, and leave songs
/// untouched — with no native network call at all — when they aren't. Stubs
/// both `SubsonicClient`'s `/rest/...` calls and `NavidromeClient`'s
/// `/api/...` calls behind one shared `URLProtocol`, reusing the pattern
/// `ConnectionModelNativeFeaturesTests` already established for a test that
/// needs both clients together.
@MainActor
@Suite(.serialized)
struct LibraryModelWorkInfoJoinTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkInfoJoinMockProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeLibrary(nativeFeaturesAvailable: @escaping () async -> Bool) -> LibraryModel {
        let creds = ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                                      username: "tim", secret: "sesame", authMethod: .tokenSalt)
        let store = InMemoryCredentialStore(creds)
        let session = makeSession()
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        return LibraryModel(client: client, navidrome: navidrome,
                            nativeFeaturesAvailable: nativeFeaturesAvailable)
    }

    @Test func songsForAlbumJoinsWorkInfoWhenNativeFeaturesAreAvailable() async throws {
        await WorkInfoJoinMockProtocol.reset()
        await WorkInfoJoinMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary(nativeFeaturesAvailable: { true })

        let songs = await library.songs(forAlbum: "album-1").sorted { $0.id < $1.id }
        #expect(songs.count == 2)

        #expect(songs.map(\.id) == ["schubert-song", "untagged-song"])
        #expect(songs[0].work == "Schwanengesang, D. 957")
        #expect(songs[0].movementName == "Der Doppelgänger")
        #expect(songs[0].movementNumber == 13)
        #expect(songs[0].movementTotal == 14)
        #expect(songs[1].work == nil) // no work tags on this one — untouched
    }

    @Test func albumDetailJoinsWorkInfoOntoReturnedSongs() async throws {
        await WorkInfoJoinMockProtocol.reset()
        await WorkInfoJoinMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary(nativeFeaturesAvailable: { true })

        let album = try #require(await library.album(id: "album-1"))
        let songs = (album.song ?? []).sorted { $0.id < $1.id }

        #expect(songs.map(\.id) == ["schubert-song", "untagged-song"])
        #expect(songs[0].work == "Schwanengesang, D. 957")
        #expect(songs[0].movementName == "Der Doppelgänger")
        #expect(songs[0].movementNumber == 13)
        #expect(songs[0].movementTotal == 14)
        #expect(songs[1].work == nil)
    }

    @Test func songsForAlbumLeavesWorkFieldsNilWhenNativeFeaturesAreUnavailable() async throws {
        await WorkInfoJoinMockProtocol.reset()
        await WorkInfoJoinMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary(nativeFeaturesAvailable: { false })

        let songs = await library.songs(forAlbum: "album-1")

        #expect(!songs.isEmpty)
        #expect(songs.allSatisfy { $0.work == nil })
        // Gated before the native call is ever made — not just discarded after.
        #expect(await WorkInfoJoinMockProtocol.count(pathSuffix: "/api/song") == 0)
    }

    @Test func reloadStarredJoinsWorkInfoOntoStarredSongs() async throws {
        await WorkInfoJoinMockProtocol.reset()
        await WorkInfoJoinMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary(nativeFeaturesAvailable: { true })

        let reloaded = await library.reloadStarred()

        #expect(reloaded)
        let song = try #require(library.starredSongs.first)
        #expect(song.work == "Schwanengesang, D. 957")
    }

    @Test func searchJoinsWorkInfoOntoSongResults() async throws {
        await WorkInfoJoinMockProtocol.reset()
        await WorkInfoJoinMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary(nativeFeaturesAvailable: { true })

        let results = await library.search("Doppelgänger")

        let song = try #require(results.songs.first)
        #expect(song.work == "Schwanengesang, D. 957")
        #expect(song.movementName == "Der Doppelgänger")
    }

    @Test func playlistJoinsWorkInfoOntoEntries() async throws {
        await WorkInfoJoinMockProtocol.reset()
        await WorkInfoJoinMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary(nativeFeaturesAvailable: { true })

        let playlist = try #require(await library.playlist(id: "playlist-1"))

        let song = try #require(playlist.entry?.first)
        #expect(song.work == "Schwanengesang, D. 957")
        #expect(song.movementName == "Der Doppelgänger")
    }

    // MARK: - Mock handler

    private static func makeHandler() -> @Sendable (URLRequest) -> WorkInfoJoinMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/getAlbum.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"album-1",
                "name":"Schwanengesang","song":[
                {"id":"schubert-song","title":"Der Doppelgänger","duration":240},
                {"id":"untagged-song","title":"Some Other Track","duration":180}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/getStarred2.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{"song":[
                {"id":"schubert-song","title":"Der Doppelgänger","duration":240}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/search3.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[
                {"id":"schubert-song","title":"Der Doppelgänger","duration":240}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/getPlaylist.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{
                "id":"playlist-1","name":"Classical","entry":[
                {"id":"schubert-song","title":"Der Doppelgänger","duration":240}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            if path.hasSuffix("/api/song") {
                let json = """
                [{"id": "schubert-song", "title": "Der Doppelgänger",
                  "tags": {"work": ["Schwanengesang, D. 957"], "movementname": ["Der Doppelgänger"],
                           "movement": ["13"], "movementtotal": ["14"]}},
                 {"id": "untagged-song", "title": "Some Other Track"}]
                """
                let headers = ["Content-Type": "application/json", "X-Total-Count": "2"]
                return .init(status: 200, headers: headers, body: Data(json.utf8))
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

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
/// `/auth/login`/`/api/...` calls to one caller-supplied handler. Modeled on
/// `ConnectionProbeMockProtocol` (`ConnectionModelNativeFeaturesTests.swift`)
/// but kept separate so the two suites' shared static state can't race.
final class WorkInfoJoinMockProtocol: URLProtocol, @unchecked Sendable {
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
