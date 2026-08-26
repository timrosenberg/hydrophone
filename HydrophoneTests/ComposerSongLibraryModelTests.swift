import Foundation
import Testing
@testable import Hydrophone

/// Hermetic coverage for resolving Navidrome composer-song ids into the full
/// Subsonic `Song` values the playback and track-table paths consume. This
/// suite owns its `URLProtocol` state so it cannot race other network suites.
@MainActor
@Suite(.serialized)
struct LibraryModelComposerSongsTests {
    private func makeLibrary() -> LibraryModel {
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim",
            secret: "sesame",
            authMethod: .tokenSalt
        )
        let store = InMemoryCredentialStore(credentials)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComposerSongsMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        return LibraryModel(client: client, navidrome: navidrome,
                            nativeFeaturesAvailable: { true })
    }

    @Test func returnsPlayableSongsInComposerOrderAndJoinsWorkInfo() async throws {
        await ComposerSongsMockProtocol.reset()
        await ComposerSongsMockProtocol.setHandler(Self.makeHandler())
        let library = makeLibrary()

        let songs = await library.songs(forComposer: "composer-1")

        #expect(songs.map(\.id) == ["song-b", "song-a"])
        #expect(songs.map(\.title) == ["Second Movement", "First Movement"])
        #expect(songs.map(\.duration) == [301, 245])
        #expect(songs.map(\.bitRate) == [1411, 320])
        #expect(songs.map(\.suffix) == ["flac", "mp3"])
        #expect(songs[0].work == "Symphony No. 1")
        #expect(songs[0].movementName == "Andante sostenuto")
        #expect(songs[0].movementNumber == 2)
        #expect(songs[0].movementTotal == 4)
        #expect(songs[1].work == nil)
    }

    @Test func nativeSongsDoNotDependOnIndividualSongEndpoint() async throws {
        await ComposerSongsMockProtocol.reset()
        await ComposerSongsMockProtocol.setHandler(Self.makeHandler(failedSongIDs: ["song-a"]))
        let library = makeLibrary()

        let songs = await library.songs(forComposer: "composer-1")

        #expect(songs.map(\.id) == ["song-b", "song-a"])
        #expect(await ComposerSongsMockProtocol.count(pathSuffix: "/rest/getSong.view") == 0)
    }

    @Test func largeComposerUsesOnlyCachedNativePages() async throws {
        await ComposerSongsMockProtocol.reset()
        let handler = Self.makeHandler()
        await ComposerSongsMockProtocol.setHandler { request in
            guard request.url?.path.hasSuffix("/api/song") == true else { return handler(request) }
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "_start" }?.value.flatMap(Int.init) ?? 0
            let rows = (start..<min(start + 500, 600)).map { index in
                """
                {"id":"large-\(index)","title":"Track \(index)","duration":123.9,
                 "participants":{"composer":[{"id":"large-composer","name":"Composer"}]}}
                """
            }
            return .init(status: 200, headers: ["X-Total-Count": "600"],
                         body: Data("[\(rows.joined(separator: ","))]".utf8))
        }
        let library = makeLibrary()

        let first = await library.songs(forComposer: "large-composer")
        let cached = await library.songs(forComposer: "large-composer")

        #expect(first.count == 600)
        #expect(first.first?.id == "large-0")
        #expect(first.last?.id == "large-599")
        #expect(first.first?.duration == 123)
        #expect(cached == first)
        #expect(await ComposerSongsMockProtocol.count(pathSuffix: "/api/song") == 2)
        #expect(await ComposerSongsMockProtocol.count(pathSuffix: "/rest/getSong.view") == 0)
    }

    @Test func preservesMetadataForInfoArtworkAndPlayback() async throws {
        await ComposerSongsMockProtocol.reset()
        await ComposerSongsMockProtocol.setHandler(Self.makeHandler())
        let songs = await makeLibrary().songs(forComposer: "composer-1")
        let song = try #require(songs.first)

        #expect(song.artist == "Orchestra B")
        #expect(song.artistId == "artist-b")
        #expect(song.album == "Symphony No. 1")
        #expect(song.albumId == "album-1")
        #expect(song.coverArt == "song-b")
        #expect(song.artworkKey == "album:album-1")
        #expect(song.qualityLabel == "FLAC")
        #expect(song.contentType == "audio/flac")
        #expect(song.track == 2)
        #expect(song.discNumber == 1)
        #expect(song.year == 1999)
        #expect(song.size == 42_000_000)
        #expect(song.displayGenre == "Classical")
        #expect(song.genres?.map(\.name) == ["Classical", "Orchestral"])
        #expect(song.displayComposer == "Brahms • Clara Schumann")
        #expect(song.displayAlbumArtist == "Orchestra B • Conductor")
        #expect(song.comment == "Recorded live")
        #expect(song.groupings == ["Romantic", "Symphonies"])
        #expect(song.samplingRate == 96_000)
        #expect(song.sortName == "Symphony movement")
        #expect(song.playCount == 7)
        #expect(song.created == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(song.played == Date(timeIntervalSince1970: 1_735_776_000))
        #expect(song.starred == Date(timeIntervalSince1970: 1_735_862_400))
        #expect(song.replayGain == ReplayGainInfo(trackGain: -3.5, albumGain: -5,
                                                 trackPeak: 0.95, albumPeak: 0.99))
    }

    @Test func currentFavoritesOverrideCachedNativeAnnotations() async throws {
        await ComposerSongsMockProtocol.reset()
        let handler = Self.makeHandler()
        await ComposerSongsMockProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/rest/getStarred2.view") == true {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{
                  "song":[{"id":"song-a","title":"First Movement","starred":"2025-01-04T00:00:00Z"}]}}}
                """
                return .init(status: 200, headers: [:], body: Data(body.utf8))
            }
            return handler(request)
        }
        let library = makeLibrary()
        _ = await library.songs(forComposer: "composer-1")
        await library.loadStarredIfNeeded()
        let songs = await library.songs(forComposer: "composer-1")

        #expect(songs.map(\.isStarred) == [false, true])
        #expect(songs.map { library.isStarred($0) } == [false, true])
        #expect(songs.last?.starred == Date(timeIntervalSince1970: 1_735_948_800))
        #expect(await ComposerSongsMockProtocol.count(pathSuffix: "/api/song") == 1)
        #expect(await ComposerSongsMockProtocol.count(pathSuffix: "/rest/getSong.view") == 0)
    }

    @Test func nativeLookupFailureReturnsEmptyWithoutSubsonicSongCalls() async throws {
        await ComposerSongsMockProtocol.reset()
        await ComposerSongsMockProtocol.setHandler(Self.makeHandler(nativeSongStatus: 503))
        let library = makeLibrary()

        let songs = await library.songs(forComposer: "composer-1")

        #expect(songs.isEmpty)
        #expect(await ComposerSongsMockProtocol.count(pathSuffix: "/rest/getSong.view") == 0)
    }

    // MARK: - Mock handler

    private static func makeHandler(
        nativeSongStatus: Int = 200,
        failedSongIDs: Set<String> = []
    ) -> @Sendable (URLRequest) -> ComposerSongsMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeJWT(exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            }
            if path.hasSuffix("/api/song") {
                return Self.nativeSongResponse(status: nativeSongStatus)
            }
            if path.hasSuffix("/rest/getSong.view") {
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "id" }?.value
                return Self.subsonicSongResponse(id: id, failedSongIDs: failedSongIDs)
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    private nonisolated static func nativeSongResponse(
        status: Int
    ) -> ComposerSongsMockProtocol.Response {
        guard status == 200 else { return .init(status: status, headers: [:], body: Data()) }
        let body = """
        [{"id":"song-b","title":"Second Movement","artist":"Orchestra B","artistId":"artist-b",
          "album":"Symphony No. 1","albumId":"album-1","albumArtist":"Orchestra B • Conductor",
          "duration":301.75,"bitRate":1411,"suffix":"flac","sampleRate":96000,
          "trackNumber":2,"discNumber":1,"year":1999,"size":42000000,"genre":"Classical",
          "genres":[{"id":"genre-1","name":"Classical"},{"id":"genre-2","name":"Orchestral"}],
          "comment":"Recorded live","orderTitle":"second movement","sortTitle":"Symphony movement",
          "playCount":7,"createdAt":"2025-01-01T00:00:00Z","playDate":"2025-01-02T00:00:00.000Z",
          "starred":true,"starredAt":"2025-01-03T00:00:00Z",
          "rgTrackGain":-3.5,"rgAlbumGain":-5,"rgTrackPeak":0.95,"rgAlbumPeak":0.99,
          "participants":{"composer":[{"id":"composer-1","name":"Brahms"},
                                       {"id":"composer-2","name":"Clara Schumann"}]},
          "tags":{"work":["Symphony No. 1"],"movementname":["Andante sostenuto"],
                  "movement":["2"],"movementtotal":["4"],"grouping":["Romantic","Symphonies"]}},
         {"id":"song-a","title":"First Movement","duration":245,"bitRate":320,"suffix":"mp3",
          "participants":{"composer":[{"id":"composer-1","name":"Brahms"}]}}]
        """
        return .init(status: 200,
                     headers: ["Content-Type": "application/json", "X-Total-Count": "2"],
                     body: Data(body.utf8))
    }

    private nonisolated static func subsonicSongResponse(
        id: String?, failedSongIDs: Set<String>
    ) -> ComposerSongsMockProtocol.Response {
        guard let id, !failedSongIDs.contains(id) else {
            return .init(status: 404, headers: [:], body: Data())
        }
        let payload: String
        switch id {
        case "song-b":
            payload = """
            {"id":"song-b","title":"Second Movement","artist":"Orchestra B",
             "album":"Symphony No. 1","duration":301,"bitRate":1411,
             "suffix":"flac","contentType":"audio/flac"}
            """
        case "song-a":
            payload = """
            {"id":"song-a","title":"First Movement","artist":"Orchestra A",
             "album":"Symphony No. 1","duration":245,"bitRate":320,
             "suffix":"mp3","contentType":"audio/mpeg"}
            """
        default:
            return .init(status: 404, headers: [:], body: Data())
        }
        let body = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","song":\(payload)}}
        """
        return .init(status: 200, headers: ["Content-Type": "application/json"],
                     body: Data(body.utf8))
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

final class ComposerSongsMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor State {
        var handler: (@Sendable (URLRequest) -> Response)?
        var requests: [URLRequest] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) {
            self.handler = handler
        }

        func reset() {
            handler = nil
            requests = []
        }

        func record(_ request: URLRequest) { requests.append(request) }
        func respond(to request: URLRequest) -> Response? { handler?(request) }
        func count(pathSuffix: String) -> Int {
            requests.count { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) async {
        await state.setHandler(handler)
    }

    static func reset() async { await state.reset() }

    static func count(pathSuffix: String) async -> Int {
        await state.count(pathSuffix: pathSuffix)
    }

    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Task { @Sendable [self] in
            await Self.state.record(request)
            guard let response = await Self.state.respond(to: request), let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
