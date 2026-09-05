import Foundation
import Testing
@testable import Hydrophone

enum MetadataPlaylistFailure: Sendable, CaseIterable {
    case transient, deleted, persistent
}

extension ConnectionModelNativeFeaturesTests {
    @Test(arguments: MetadataPlaylistFailure.allCases)
    func playlistFailureRetriesACompleteInventory(_ failure: MetadataPlaylistFailure) async {
        let listings = MetadataResponseCounter()
        let details = MetadataResponseCounter()
        let persistence = MetadataIntegrationStore()
        await persistence.setSeed(LibraryMetadataSnapshot(songs: [Song(id: "old", title: "Retained")]))
        await ConnectionProbeMockProtocol.reset()
        await ConnectionProbeMockProtocol.setAsyncHandler { request in
            if request.url?.path.hasSuffix("getPlaylists.view") == true {
                let count = await listings.next()
                // Initial UI load has no playlists; the complete walk discovers one.
                if count == 1 || (failure == .deleted && count > 2) { return Self.metadataResponse(request) }
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1",
                    "playlists":{"playlist":[{"id":"list","name":"List"}]}}}
                    """#.utf8
                ))
            }
            if request.url?.path.hasSuffix("getPlaylist.view") == true {
                let count = await details.next()
                if count == 1 || failure == .persistent { return Self.response(status: 404) }
                return Self.response(status: 200, body: Data(
                    #"""
                    {"subsonic-response":{"status":"ok","version":"1.16.1",
                    "playlist":{"id":"list","name":"List","entry":[{"id":"live","title":"Live"}]}}}
                    """#.utf8
                ))
            }
            return Self.metadataResponse(request)
        }
        let (connection, library) = makeMetadataModels(persistence)
        await connection.refresh()
        await library.metadataRefreshTask?.value
        #expect(await listings.next() == 4)
        if failure == .persistent {
            #expect(await persistence.finishedSyncs == 0)
            if let session = library.metadataSession {
                #expect(await persistence.read(for: session)?.songs.map(\.id) == ["old"])
            }
        } else {
            #expect(await persistence.finishedSyncs == 1)
            #expect(library.playlists.map(\.id) == (failure == .deleted ? [] : ["list"]))
        }
        await connection.disconnect()
    }
}
