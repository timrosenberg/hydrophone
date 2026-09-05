import Foundation
import Testing
@testable import Hydrophone

extension ConnectionModelNativeFeaturesTests {
    @Test func failedFormTestRetainsTheVerifiedLibraryAndStore() async {
        let persistence = MetadataIntegrationStore()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setHandler(Self.metadataResponse)
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        let session = library.metadataSession
        let generation = library.librarySessionGeneration
        await ConnectionProbeMockProtocol.setHandler { request in
            if request.url?.host == "invalid.example" { return Self.response(status: 401) }
            return Self.metadataResponse(request)
        }
        connection.serverAddress = "https://invalid.example"
        await connection.testConnection()
        #expect(library.songs.map(\.id) == ["live"])
        #expect(library.librarySessionGeneration == generation)
        #expect(library.metadataSession == session)
        #expect(await library.metadataAllowsLoading())
        await library.reloadPlaylists()
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func unrelatedPlaylistMutationDoesNotRetireSelectedDetail() async {
        let gate = MetadataIntegrationGate()
        let persistence = MetadataIntegrationStore()
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
                    {"subsonic-response":{"status":"ok","version":"1.16.1",
                    "playlist":{"id":"selected","name":"Selected","entry":[]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let detail = Task { await library.playlist(id: "selected") }
        await gate.waitUntilEntered()
        await library.renamePlaylist(id: "unrelated", to: "Renamed")
        await gate.release()
        #expect(await detail.value?.id == "selected")
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func nativeWaiterRemainsPendingWhenAProbeIsReplaced() async {
        let firstGate = MetadataIntegrationGate()
        let secondGate = MetadataIntegrationGate()
        let logins = MetadataResponseCounter()
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("/auth/login") == true {
                if await logins.next() == 1 { await firstGate.wait() } else { await secondGate.wait() }
                return Self.response(status: 200, body: Data(
                    #"{"token":"eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.signature"}"#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(MetadataIntegrationStore())
        let first = Task { await connection.refresh() }
        await firstGate.waitUntilEntered()
        var started = false
        var result: Bool?
        let waiter = Task { started = true; result = await connection.nativeFeaturesAvailable() }
        while !started { await Task.yield() }
        let second = Task { await connection.refresh() }
        await secondGate.waitUntilEntered()
        #expect(result == nil)
        await secondGate.release()
        await second.value
        await waiter.value
        #expect(result == true)
        await firstGate.release()
        await first.value
        await library.metadataRefreshTask?.value
        await connection.disconnect()
    }
}
