import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Hydrophone

/// Rendered regression coverage for #112: `ArtistDetailView` must load and
/// show an artist's albums driven only by `getArtist`, with no dependency on
/// a bio/similar-artists lookup (removed by product decision — Hydrophone
/// does not fetch or display third-party artist metadata). Hosts the actual
/// view so its `.task(id:)` runs under real SwiftUI lifecycle, unlike
/// `LibraryModelDetailCacheTests` which exercises `LibraryModel` directly.
@MainActor
@Suite(.serialized)
struct ArtistDetailViewTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func uncachedArtistLoadsAlbumsAndNeverRequestsArtistInfo() async throws {
        await ArtistDetailMockProtocol.reset()
        await ArtistDetailMockProtocol.setHandler(Self.handler())
        let (window, library) = makeWindow()

        try await waitUntil("request the artist's albums") {
            await ArtistDetailMockProtocol.count(pathSuffix: "/rest/getArtist.view") == 1
        }
        try await waitUntil("populate the album grid's data from the resolved fetch") {
            library.artistAlbumsCache["artist-1"]?.map(\.id) == ["album-1"]
        }
        // Give a would-be bio/similar-artists request time to have fired
        // alongside the album fetch before asserting its absence.
        try await Task.sleep(for: .milliseconds(100))

        #expect(await ArtistDetailMockProtocol.count(pathSuffix: "/rest/getArtist.view") == 1)
        #expect(await ArtistDetailMockProtocol.count(pathSuffix: "/rest/getArtistInfo2.view") == 0)

        window.orderOut(nil)
        window.contentView = nil
    }

    private func makeWindow() -> (NSWindow, LibraryModel) {
        let store = InMemoryCredentialStore(ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "test", secret: "test", authMethod: .tokenSalt
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistDetailMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        let library = LibraryModel(client: client, navidrome: navidrome,
                                   nativeFeaturesAvailable: { true })
        let connection = ConnectionModel(client: client, navidrome: navidrome, credentials: store)
        let player = PlayerModel()
        let app = AppModel(credentials: store, client: client, playback: PlaybackService(client: client),
                           connection: connection, library: library, player: player)
        let artist = Artist(id: "artist-1", name: "Miles Davis")
        let content = ArtistDetailView(artist: artist)
            .environment(app).environment(connection).environment(library).environment(player)
            .environment(Navigator()).frame(width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return (window, library)
    }

    private static func handler() -> @Sendable (URLRequest) async -> ArtistDetailMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/rest/getArtist.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","artist":{"id":"artist-1",
                "name":"Miles Davis","album":[{"id":"album-1","name":"Kind of Blue"}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/getArtistInfo2.view") {
                let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","artistInfo2":{}}}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            }
            if path.hasSuffix("/auth/login") {
                let jwt = makeJWT(exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"test"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
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
        return "\(segment(#"{"alg":"HS256","typ":"JWT"}"#)).\(segment(#"{"exp":\#(Int(exp))}"#)).signature"
    }

    private func waitUntil(_ operation: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await condition(), "Artist detail did not \(operation)")
    }
}

final class ArtistDetailMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor State {
        var handler: (@Sendable (URLRequest) async -> Response)?
        var requests: [URLRequest] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) {
            self.handler = handler
        }

        func reset() {
            handler = nil
            requests = []
        }

        func record(_ request: URLRequest) { requests.append(request) }
        func respond(to request: URLRequest) async -> Response? { await handler?(request) }
        func count(pathSuffix: String) -> Int {
            requests.count { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) async {
        await state.setHandler(handler)
    }

    static func reset() async { await state.reset() }
    static func count(pathSuffix: String) async -> Int { await state.count(pathSuffix: pathSuffix) }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Task {
            await Self.state.record(request)
            guard let response = await Self.state.respond(to: request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            guard let url = request.url,
                  let httpResponse = HTTPURLResponse(url: url, statusCode: response.status,
                                                     httpVersion: "HTTP/1.1", headerFields: response.headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
