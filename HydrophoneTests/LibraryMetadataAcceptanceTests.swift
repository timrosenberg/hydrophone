import Foundation
import Testing
@testable import Hydrophone

extension ConnectionModelNativeFeaturesTests {
    @Test(.timeLimit(.minutes(1))) func completedSyncPreservesAlphabeticalAlbumsAndNewerFavorites() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledMetadataStore(root: root)
        let favorites = MetadataResponseCounter()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("getAlbumList2.view") == true {
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{
                    "album":[{"id":"z","name":"Alpha"},{"id":"a","name":"Zulu"}]}}}
                    """#.utf8
                ))
            }
            if request.url?.path.hasSuffix("getStarred2.view") == true, await favorites.next() == 1 {
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{
                    "song":[{"id":"live","title":"Live","starred":"2026-09-05T00:00:00Z"}],"album":[]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        #expect(library.albums.map(\.name) == ["Alpha", "Zulu"])
        #expect(await persistence.snapshot()?.favorites?.songs.isEmpty == true)
        #expect(library.starredSongs.isEmpty)
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func slowMetadataWritesDoNotHoldLiveRows() async throws {
        let gate = MetadataIntegrationGate()
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledMetadataStore(root: root, writeGate: gate)
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await gate.waitUntilEntered()
        await library.loadSongsIfNeeded()
        while library.songs.isEmpty { await Task.yield() }
        #expect(connection.isConnected)
        #expect(library.songs.map(\.id) == ["live"])
        #expect(await persistence.successfulWrites == 0)
        await gate.release()
        await library.metadataRefreshTask?.value
        #expect(await persistence.snapshot()?.songs.map(\.id) == ["live"])
        #expect(await persistence.successfulWrites > 0)
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func failedMetadataWritesDoNotFailTheLiveLibrary() async {
        let persistence = ControlledMetadataStore(root: LibraryMetadataStoreTests.root(), failWrites: true)
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        #expect(connection.isConnected)
        #expect(library.songs.map(\.id) == ["live"])
        #expect(await persistence.attemptedWrites > 0)
        #expect(await persistence.successfulWrites == 0)
        #expect(await persistence.snapshot()?.songs.isEmpty == true)
        await connection.disconnect()
        await persistence.removeFiles()
    }

    @Test(.timeLimit(.minutes(1))) func manualScanWaitsForServerThenCommitsFreshMetadata() async throws {
        let gate = MetadataIntegrationGate()
        let persistence = MetadataIntegrationStore()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        #expect(await persistence.finishedSyncs == 1)
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("startScan.view") == true {
                return Self.response(status: 200, body: Data(
                    #"{"subsonic-response":{"status":"ok","version":"1.16.1","scanStatus":{"scanning":true}}}"#.utf8
                ))
            }
            if request.url?.path.hasSuffix("getScanStatus.view") == true { await gate.wait() }
            if request.url?.path.hasSuffix("search3.view") == true {
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
                    "song":[{"id":"after-scan","title":"New"}]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let scan = Task { await connection.startLibraryScan() }
        await gate.waitUntilEntered()
        #expect(await persistence.finishedSyncs == 1)
        #expect(library.songs.map(\.id) == ["live"])
        await gate.release()
        await scan.value
        #expect(await persistence.finishedSyncs == 2)
        #expect(library.songs.map(\.id) == ["after-scan"])
        #expect(connection.scanMessage == "Scan finished — 1 items")
        await connection.disconnect()
    }
}

actor MetadataResponseCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

/// A held or failed cache backend exercises the production write-behind path.
/// Successful operations use the real disk store, including full reconciliation.
actor ControlledMetadataStore: MetadataPersistence {
    let root: URL
    let store: LibraryMetadataStore
    let writeGate: MetadataIntegrationGate?
    let failWrites: Bool
    private var session: MetadataSession?
    private(set) var attemptedWrites = 0
    private(set) var successfulWrites = 0

    init(root: URL, writeGate: MetadataIntegrationGate? = nil, failWrites: Bool = false) {
        self.root = root
        store = LibraryMetadataStore(rootDirectory: root)
        self.writeGate = writeGate
        self.failWrites = failWrites
    }
    func open(for credentials: ServerCredentials) async -> MetadataSession? {
        session = await store.open(for: credentials)
        return session
    }
    func close() async { session = nil; await store.close() }
    func read(for session: MetadataSession) async -> LibraryMetadataSnapshot? { await store.read(for: session) }
    func snapshot() async -> LibraryMetadataSnapshot? {
        guard let session else { return nil }
        return await store.read(for: session)
    }
    func write(_ change: MetadataWrite, for session: MetadataSession) async {
        attemptedWrites += 1
        await writeGate?.wait()
        guard !failWrites else { return }
        await store.write(change, for: session)
        successfulWrites += 1
    }
    func beginSync(for session: MetadataSession) async -> MetadataSyncToken? { await store.beginSync(for: session) }
    func finishSync(_ snapshot: LibraryMetadataSnapshot, token: MetadataSyncToken) async -> Bool {
        if failWrites { await store.cancelSync(token); return false }
        return await store.finishSync(snapshot, token: token)
    }
    func cancelSync(_ token: MetadataSyncToken) async { await store.cancelSync(token) }
    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
