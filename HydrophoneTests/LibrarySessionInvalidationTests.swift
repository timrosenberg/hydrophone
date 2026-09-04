import Foundation
import Testing
@testable import Hydrophone

/// Cross-session regression coverage for the LibraryModel collections that
/// keep their own view/load state outside LibrarySongIndex. Network responses
/// are held at the URLProtocol boundary so reset() can run while the real
/// production loaders are suspended.
@MainActor
@Suite(.serialized)
struct LibrarySessionInvalidationTests {
    private func credentials(host: String) -> ServerCredentials {
        ServerCredentials(
            baseURL: URL(string: "https://\(host)")!,
            username: "tim", secret: "sesame", authMethod: .tokenSalt
        )
    }

    private func makeLibrary(
        store: InMemoryCredentialStore
    ) -> LibraryModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibrarySessionMockProtocol.self]
        let session = URLSession(configuration: configuration)
        return LibraryModel(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )
    }

    @Test func resetClearsThePreviousServersPlaylists() async {
        let store = InMemoryCredentialStore(credentials(host: "old.example.com"))
        let library = makeLibrary(store: store)
        library.playlists = [Playlist(id: "old-playlist", name: "Old Playlist")]

        await library.reset()

        #expect(library.playlists.isEmpty)
    }

    @Test func retiredPlaylistReloadCannotRepopulateTheNewSession() async throws {
        let oldHost = "old-playlists.example.com"
        await LibrarySessionMockProtocol.prepare(blocking: [oldHost])
        let store = InMemoryCredentialStore(credentials(host: oldHost))
        let library = makeLibrary(store: store)

        let oldReload = Task { await library.reloadPlaylists() }
        await waitForRequests(pathSuffix: "/rest/getPlaylists.view", host: oldHost, count: 1)
        try store.save(credentials(host: "new-playlists.example.com"))
        await library.reset()
        await LibrarySessionMockProtocol.unblock(oldHost)
        await oldReload.value

        #expect(library.playlists.isEmpty)
    }

    @Test func newSessionHomeLoadDoesNotWaitForRetiredLoad() async throws {
        let oldHost = "old-home.example.com"
        let newHost = "new-home.example.com"
        await LibrarySessionMockProtocol.prepare(blocking: [oldHost])
        let store = InMemoryCredentialStore(credentials(host: oldHost))
        let library = makeLibrary(store: store)

        let oldLoad = Task { await library.reloadHome() }
        await waitForRequests(pathSuffix: "/rest/getAlbumList2.view", host: oldHost, count: 4)
        try store.save(credentials(host: newHost))
        await library.reset()

        await library.reloadHome()

        #expect(await LibrarySessionMockProtocol.requestCount(
            pathSuffix: "/rest/getAlbumList2.view", host: newHost
        ) == 4)
        #expect(library.homeNewest.first?.id == "\(newHost)-newest")
        await LibrarySessionMockProtocol.unblock(oldHost)
        await oldLoad.value
        #expect(library.homeNewest.first?.id == "\(newHost)-newest")
    }

    @Test func newSessionGenresLoadDoesNotWaitForRetiredLoad() async throws {
        let oldHost = "old-genres.example.com"
        let newHost = "new-genres.example.com"
        await LibrarySessionMockProtocol.prepare(blocking: [oldHost])
        let store = InMemoryCredentialStore(credentials(host: oldHost))
        let library = makeLibrary(store: store)

        let oldLoad = Task { await library.loadGenresIfNeeded() }
        await waitForRequests(pathSuffix: "/rest/getGenres.view", host: oldHost, count: 1)
        try store.save(credentials(host: newHost))
        await library.reset()

        await library.loadGenresIfNeeded()

        #expect(library.genres.map(\.value) == [newHost])
        await LibrarySessionMockProtocol.unblock(oldHost)
        await oldLoad.value
        #expect(library.genres.map(\.value) == [newHost])
    }

    @Test func newSessionFavoritesLoadDoesNotWaitForRetiredLoad() async throws {
        let oldHost = "old-favorites.example.com"
        let newHost = "new-favorites.example.com"
        await LibrarySessionMockProtocol.prepare(blocking: [oldHost])
        let store = InMemoryCredentialStore(credentials(host: oldHost))
        let library = makeLibrary(store: store)

        let oldLoad = Task { await library.loadStarredIfNeeded() }
        await waitForRequests(pathSuffix: "/rest/getStarred2.view", host: oldHost, count: 1)
        try store.save(credentials(host: newHost))
        await library.reset()

        await library.loadStarredIfNeeded()

        #expect(library.starredAlbums.first?.id == "\(newHost)-favorite")
        await LibrarySessionMockProtocol.unblock(oldHost)
        await oldLoad.value
        #expect(library.starredAlbums.first?.id == "\(newHost)-favorite")
    }

    @Test func retiredRandomShelfRerollCannotRepopulateTheNewSession() async throws {
        let oldHost = "old-random.example.com"
        await LibrarySessionMockProtocol.prepare(blocking: [oldHost])
        let store = InMemoryCredentialStore(credentials(host: oldHost))
        let library = makeLibrary(store: store)

        let oldReroll = Task { await library.rerollRandomAlbums() }
        await waitForRequests(pathSuffix: "/rest/getAlbumList2.view", host: oldHost, count: 1)
        try store.save(credentials(host: "new-random.example.com"))
        await library.reset()
        await LibrarySessionMockProtocol.unblock(oldHost)
        await oldReroll.value

        #expect(library.homeRandom.isEmpty)
    }

    private func waitForRequests(pathSuffix: String, host: String, count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await LibrarySessionMockProtocol.requestCount(pathSuffix: pathSuffix, host: host) < count,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await LibrarySessionMockProtocol.requestCount(
            pathSuffix: pathSuffix, host: host
        ) == count)
    }
}

private actor LibrarySessionMockState {
    private var blockedHosts: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requests: [(path: String, host: String)] = []

    func prepare(blocking hosts: Set<String>) {
        for continuations in waiters.values {
            continuations.forEach { $0.resume() }
        }
        blockedHosts = hosts
        waiters = [:]
        requests = []
    }

    func record(path: String, host: String) {
        requests.append((path, host))
    }

    func waitIfBlocked(_ host: String) async {
        guard blockedHosts.contains(host) else { return }
        await withCheckedContinuation { waiters[host, default: []].append($0) }
    }

    func unblock(_ host: String) {
        blockedHosts.remove(host)
        waiters.removeValue(forKey: host)?.forEach { $0.resume() }
    }

    func requestCount(pathSuffix: String, host: String) -> Int {
        requests.count { $0.path.hasSuffix(pathSuffix) && $0.host == host }
    }
}

private final class LibrarySessionMockProtocol: URLProtocol, @unchecked Sendable {
    private static let state = LibrarySessionMockState()

    static func prepare(blocking hosts: Set<String>) async {
        await state.prepare(blocking: hosts)
    }

    static func unblock(_ host: String) async {
        await state.unblock(host)
    }

    static func requestCount(pathSuffix: String, host: String) async -> Int {
        await state.requestCount(pathSuffix: pathSuffix, host: host)
    }

    // Overriding URLProtocol's required class funcs, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Task { @Sendable [self] in
            await Self.state.record(path: url.path, host: host)
            await Self.state.waitIfBlocked(host)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody(for: url, host: host))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func responseBody(for url: URL, host: String) -> Data {
        let method = url.lastPathComponent
        let payload: String
        switch method {
        case "getPlaylists.view":
            payload = #""playlists":{"playlist":[{"id":"\#(host)-playlist","name":"\#(host)"}]}"#
        case "getGenres.view":
            payload = #""genres":{"genre":[{"value":"\#(host)","songCount":1,"albumCount":1}]}"#
        case "getStarred2.view":
            payload = #""starred2":{"album":[{"id":"\#(host)-favorite","name":"\#(host)"}]}"#
        default:
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let type = query.first { $0.name == "type" }?.value ?? "random"
            payload = #""albumList2":{"album":[{"id":"\#(host)-\#(type)","name":"\#(host)"}]}"#
        }
        return Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(payload)}}"#.utf8)
    }
}
