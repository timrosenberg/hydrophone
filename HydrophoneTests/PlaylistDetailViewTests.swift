import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Hydrophone

/// Rendered coverage for the playlist detail's two-phase load. The native
/// metadata response and playlist mutation are gated independently so the
/// test can exercise an optimistic edit while the original enrichment is
/// still in flight.
@MainActor
@Suite(.serialized)
struct PlaylistDetailViewTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func staleEnrichmentCannotUndoAnOptimisticRemoval() async throws {
        await PlaylistDetailMockProtocol.reset()
        let indexGate = PlaylistDetailGate()
        let mutationGate = PlaylistDetailGate()
        await PlaylistDetailMockProtocol.setHandler(Self.handler(indexGate: indexGate,
                                                                  mutationGate: mutationGate))
        let window = makeWindow()

        try await waitUntil("render the fast playlist fetch") {
            displayedSongs(in: window).map(\.id) == ["song-1", "song-2"]
        }
        try await waitUntil("start the native index walk") {
            await PlaylistDetailMockProtocol.count(pathSuffix: "/api/song") == 1
        }

        let coordinator = try #require(Self.trackCoordinator(in: window))
        let menu = try #require(coordinator.menuForSelection(IndexSet(integer: 1)))
        let removeItem = try #require(menu.items.first { $0.title == "Remove from Playlist" })
        let removeAction = try #require(removeItem.action)
        #expect(NSApp.sendAction(removeAction, to: removeItem.target, from: removeItem))
        try await waitUntil("apply the optimistic removal") {
            displayedSongs(in: window).map(\.id) == ["song-1"]
        }
        try await waitUntil("start the still-gated playlist mutation") {
            await PlaylistDetailMockProtocol.count(pathSuffix: "/rest/updatePlaylist.view") == 1
        }

        await indexGate.open()
        try await waitUntil("finish the original metadata response") {
            await PlaylistDetailMockProtocol.completedCount(pathSuffix: "/api/song") == 1
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(displayedSongs(in: window).map(\.id) == ["song-1"])

        await mutationGate.open()
        try await waitUntil("start the post-mutation reload") {
            await PlaylistDetailMockProtocol.count(pathSuffix: "/rest/getPlaylist.view") == 2
        }
        try await Task.sleep(for: .milliseconds(50))
        window.orderOut(nil)
        window.contentView = nil
    }

    private func makeWindow() -> NSWindow {
        let store = InMemoryCredentialStore(ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "test", secret: "test", authMethod: .tokenSalt
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistDetailMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        let library = LibraryModel(client: client, navidrome: navidrome,
                                   nativeFeaturesAvailable: { true })
        let connection = ConnectionModel(client: client, navidrome: navidrome, credentials: store)
        let player = PlayerModel()
        let app = AppModel(credentials: store, client: client, playback: PlaybackService(client: client),
                           connection: connection, library: library, player: player)
        let content = PlaylistDetailView(playlistID: "playlist-1")
            .environment(app).environment(connection).environment(library).environment(player)
            .environment(Navigator()).frame(width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return window
    }

    private static func handler(
        indexGate: PlaylistDetailGate,
        mutationGate: PlaylistDetailGate
    ) -> @Sendable (URLRequest) async -> PlaylistDetailMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/rest/getPlaylist.view") {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{
                "id":"playlist-1","name":"Test Playlist","entry":[
                {"id":"song-1","title":"First","duration":180},
                {"id":"song-2","title":"Second","duration":180}]}}}
                """
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            }
            if path.hasSuffix("/rest/updatePlaylist.view") {
                await mutationGate.wait()
                let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            }
            if path.hasSuffix("/auth/login") {
                let jwt = makeJWT(exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"test"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            }
            if path.hasSuffix("/api/song") {
                await indexGate.wait()
                let body = """
                [{"id":"song-1","title":"First","tags":{"work":["Work One"]}},
                 {"id":"song-2","title":"Second","tags":{"work":["Work Two"]}}]
                """
                return .init(status: 200,
                             headers: ["Content-Type": "application/json", "X-Total-Count": "2"],
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
        try #require(await condition(), "Playlist detail did not \(operation)")
    }

    private func displayedSongs(in window: NSWindow) -> [Song] {
        window.contentView?.layoutSubtreeIfNeeded()
        return Self.trackCoordinator(in: window)?.displayed ?? []
    }

    private static func trackCoordinator(in window: NSWindow) -> MusicTrackTable.Coordinator? {
        func find(in view: NSView?) -> MusicTrackTable.Coordinator? {
            if let table = view as? NSTableView,
               let coordinator = table.dataSource as? MusicTrackTable.Coordinator {
                return coordinator
            }
            for child in view?.subviews ?? [] {
                if let coordinator = find(in: child) { return coordinator }
            }
            return nil
        }
        return find(in: window.contentView)
    }
}

private actor PlaylistDetailGate {
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

final class PlaylistDetailMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor State {
        var handler: (@Sendable (URLRequest) async -> Response)?
        var requests: [URLRequest] = []
        var completedRequests: [URLRequest] = []

        func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) {
            self.handler = handler
        }

        func reset() {
            handler = nil
            requests = []
            completedRequests = []
        }

        func record(_ request: URLRequest) { requests.append(request) }
        func recordCompletion(_ request: URLRequest) { completedRequests.append(request) }
        func respond(to request: URLRequest) async -> Response? { await handler?(request) }
        func count(pathSuffix: String) -> Int {
            requests.count { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
        func completedCount(pathSuffix: String) -> Int {
            completedRequests.count { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) async {
        await state.setHandler(handler)
    }

    static func reset() async { await state.reset() }
    static func count(pathSuffix: String) async -> Int { await state.count(pathSuffix: pathSuffix) }
    static func completedCount(pathSuffix: String) async -> Int {
        await state.completedCount(pathSuffix: pathSuffix)
    }

    // Overriding URLProtocol's required class funcs, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Task {
            await Self.state.record(request)
            guard let response = await Self.state.respond(to: request), let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let http = HTTPURLResponse(url: url, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
            await Self.state.recordCompletion(request)
        }
    }

    override func stopLoading() {}
}
