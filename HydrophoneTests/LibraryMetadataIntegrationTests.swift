import Foundation
import Testing
@testable import Hydrophone

extension ConnectionModelNativeFeaturesTests {
    @Test func metadataSeedWaitsForVerifiedConnectionAndPrecedesLiveRows() async throws {
        let gate = MetadataIntegrationGate()
        let persistence = MetadataIntegrationStore()
        await persistence.setSeed(LibraryMetadataSnapshot(songs: [Song(id: "seed", title: "Warm")]))
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("search3.view") == true { await gate.wait() }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await gate.waitUntilEntered()
        #expect(connection.isConnected)
        #expect(library.songs.map(\.id) == ["seed"])
        await gate.release()
        await library.metadataRefreshTask?.value
        #expect(library.songs.map(\.id) == ["live"])
        #expect(await persistence.finishedSyncs == 1)
    }

    @Test func rejectedConnectionDoesNotReadOrExposeDiskSeed() async {
        let persistence = MetadataIntegrationStore()
        await persistence.setSeed(LibraryMetadataSnapshot(songs: [Song(id: "private", title: "Private")]))
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler { _ in
            Self.response(status: 401)
        }
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        #expect(!connection.isConnected)
        #expect(library.songs.isEmpty)
        #expect(await persistence.opens == 0)
    }

    @Test func missingStoreStillLoadsTheLiveLibrary() async {
        let persistence = MetadataIntegrationStore()
        await persistence.disableOpening()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        #expect(connection.isConnected)
        #expect(library.songs.map(\.id) == ["live"])
    }

    @Test func disconnectRetiresHeldLiveRefresh() async {
        let gate = MetadataIntegrationGate()
        let persistence = MetadataIntegrationStore()
        await persistence.setSeed(LibraryMetadataSnapshot(songs: [Song(id: "seed", title: "Warm")]))
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("search3.view") == true { await gate.wait() }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await gate.waitUntilEntered()
        let refresh = library.metadataRefreshTask
        await connection.disconnect()
        await gate.release()
        await refresh?.value
        #expect(library.songs.isEmpty)
        #expect(await persistence.finishedSyncs == 0)
    }

    func makeMetadataModels(_ persistence: any MetadataPersistence) -> (ConnectionModel, LibraryModel) {
        let credentials = ServerCredentials(baseURL: URL(string: "https://metadata.example")!,
                                            username: "listener", secret: "fixture", authMethod: .tokenSalt)
        let store = InMemoryCredentialStore(credentials)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionProbeMockProtocol.self]
        let session = URLSession(configuration: config)
        let client = SubsonicClient(credentials: store, session: session)
        let native = NavidromeClient(credentials: store, session: session)
        let connection = ConnectionModel(client: client, navidrome: native, credentials: store)
        let library = LibraryModel(client: client, navidrome: native, nativeFeaturesAvailable: {
            await connection.nativeFeaturesAvailable()
        }, metadata: persistence)
        _ = AppModel(credentials: store, client: client, playback: PlaybackService(client: client),
                     connection: connection, library: library, player: PlayerModel())
        return (connection, library)
    }

    nonisolated static func metadataResponse(_ request: URLRequest) -> ConnectionProbeMockProtocol.Response {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/auth/login") { return response(status: 401) }
        let payload: String
        if path.hasSuffix("search3.view") {
            payload = #""searchResult3":{"song":[{"id":"live","title":"Live"}]}"#
        } else if path.hasSuffix("getArtists.view") {
            payload = #""artists":{"index":[]}"#
        } else if path.hasSuffix("getAlbumList2.view") {
            payload = #""albumList2":{"album":[]}"#
        } else if path.hasSuffix("getGenres.view") {
            payload = #""genres":{"genre":[]}"#
        } else if path.hasSuffix("getPlaylists.view") {
            payload = #""playlists":{"playlist":[]}"#
        } else if path.hasSuffix("getStarred2.view") {
            payload = #""starred2":{"song":[],"album":[]}"#
        } else if path.hasSuffix("startScan.view") || path.hasSuffix("getScanStatus.view") {
            payload = #""scanStatus":{"scanning":false,"count":1}"#
        } else { payload = #""type":"navidrome""# }
        return response(status: 200,
                        body: Data(
                            "{\"subsonic-response\":{\"status\":\"ok\",\"version\":\"1.16.1\",\(payload)}}".utf8
                        ))
    }

    nonisolated static func response(status: Int, body: Data = Data()) -> ConnectionProbeMockProtocol.Response {
        .init(status: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

actor MetadataIntegrationGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func release() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

actor MetadataIntegrationStore: MetadataPersistence {
    private var snapshot: LibraryMetadataSnapshot?
    private var available = true
    private var session: MetadataSession?
    private(set) var opens = 0
    private(set) var finishedSyncs = 0
    func setSeed(_ snapshot: LibraryMetadataSnapshot) { self.snapshot = snapshot }
    func disableOpening() { available = false }
    func open(for credentials: ServerCredentials) -> MetadataSession? {
        opens += 1
        guard available else { return nil }
        let session = MetadataSession(scope: "test", generation: UUID())
        self.session = session
        return session
    }
    func close() { session = nil }
    func read(for session: MetadataSession) -> LibraryMetadataSnapshot? { snapshot }
    func write(_ change: MetadataWrite, for session: MetadataSession) {}
    func beginSync(for session: MetadataSession) -> MetadataSyncToken? {
        MetadataSyncToken(session: session, generation: UUID())
    }
    func finishSync(_ snapshot: LibraryMetadataSnapshot, token: MetadataSyncToken) -> Bool {
        guard token.session == session else { return false }
        self.snapshot = snapshot
        finishedSyncs += 1
        return true
    }
    func cancelSync(_ token: MetadataSyncToken) {}
}
