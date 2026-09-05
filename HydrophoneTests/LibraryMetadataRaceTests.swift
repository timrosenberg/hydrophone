import Foundation
import Testing
@testable import Hydrophone

extension ConnectionModelNativeFeaturesTests {
    @Test(.timeLimit(.minutes(1))) func ordinaryPlaylistListingDoesNotRetireASelectedDetail() async throws {
        let persistence = MetadataIntegrationStore()
        let gate = MetadataIntegrationGate()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("getPlaylist.view") == true {
                await gate.wait()
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{
                    "id":"selected","name":"Selected","entry":[]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let detail = Task { await library.playlist(id: "selected") }
        await gate.waitUntilEntered()
        await library.reloadPlaylists()
        await gate.release()
        #expect(await detail.value?.id == "selected")
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func fullSyncRecoversAnInitialCollectionFailure() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledMetadataStore(root: root)
        let requests = MetadataResponseCounter()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("getArtists.view") == true {
                if await requests.next() == 1 { return Self.response(status: 503) }
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1","artists":{
                    "index":[{"name":"A","artist":[{"id":"recovered","name":"Artist"}]}]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        #expect(library.artists.map(\.id) == ["recovered"])
        #expect(await persistence.snapshot()?.artists.map(\.id) == ["recovered"])
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func formTestCannotAbandonHeldNativeProbeAndMetadataLoads() async {
        let gate = MetadataIntegrationGate()
        let persistence = MetadataIntegrationStore()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("/auth/login") == true { await gate.wait() }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(persistence)
        let refresh = Task { await connection.refresh() }
        await gate.waitUntilEntered()
        let native = Task { await connection.nativeFeaturesAvailable() }
        await connection.testConnection()
        await gate.release()
        await refresh.value
        #expect(await native.value == false)
        await library.metadataRefreshTask?.value
        #expect(connection.nativeFeaturesState == .unavailable)
        #expect(library.songs.map(\.id) == ["live"])
        #expect(await persistence.finishedSyncs == 1)
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func deletedPlaylistCannotReturnThroughHeldDetailFetch() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledMetadataStore(root: root)
        let gate = MetadataIntegrationGate()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("getPlaylist.view") == true {
                await gate.wait()
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{
                    "id":"deleted","name":"Old","entry":[{"id":"live","title":"Live"}]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let detail = Task { await library.playlist(id: "deleted") }
        await gate.waitUntilEntered()
        await library.deletePlaylist(id: "deleted")
        await gate.release()
        #expect(await detail.value == nil)
        await library.metadataWriteTask?.value
        #expect(await persistence.snapshot()?.playlists.isEmpty == true)
        await connection.disconnect()
    }
}
