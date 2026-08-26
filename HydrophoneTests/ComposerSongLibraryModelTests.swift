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

    @Test func dropsAnIndividualFailedSongFetch() async throws {
        await ComposerSongsMockProtocol.reset()
        await ComposerSongsMockProtocol.setHandler(Self.makeHandler(failedSongIDs: ["song-a"]))
        let library = makeLibrary()

        let songs = await library.songs(forComposer: "composer-1")

        #expect(songs.map(\.id) == ["song-b"])
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
        [{"id":"song-b","title":"Native B",
          "participants":{"composer":[{"id":"composer-1","name":"Brahms"}]},
          "tags":{"work":["Symphony No. 1"],"movementname":["Andante sostenuto"],
                  "movement":["2"],"movementtotal":["4"]}},
         {"id":"song-a","title":"Native A",
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
