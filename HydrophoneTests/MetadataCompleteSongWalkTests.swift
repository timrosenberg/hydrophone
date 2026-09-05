import Foundation
import Testing
@testable import Hydrophone

extension SubsonicAllSongsTests {
    @Test func metadataSyncReusesCompletedLiveWalk() async throws {
        await AllSongsMockProtocol.reset(songCount: 1_003)
        let (index, store) = makeIndex()
        let credentials = try #require(store.load())
        let live = try await index.allSongs()
        let requests = await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view")
        let synced = try await index.completeSongs(using: credentials)
        #expect(synced == live)
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == requests)
    }

    @Test func metadataSyncRejectsRandomFallbackAsDeletionAuthority() async throws {
        await AllSongsMockProtocol.reset(songCount: 12_000, searchBehavior: .empty, randomSongCount: 2)
        let (index, store) = makeIndex()
        let credentials = try #require(store.load())
        #expect(try await index.allSongs().count == 2)
        await #expect(throws: SubsonicError.self) { try await index.completeSongs(using: credentials) }
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 2)
    }

    @Test func metadataSyncRejectsPartialWalkFailure() async throws {
        await AllSongsMockProtocol.reset(songCount: 1_003, rejectAtOffset: 500, randomSongCount: 2)
        let (index, store) = makeIndex()
        let credentials = try #require(store.load())
        await #expect(throws: SubsonicError.self) { try await index.completeSongs(using: credentials) }
    }

    @Test func metadataSyncAcceptsVerifiedEmptyLibrary() async throws {
        await AllSongsMockProtocol.reset(songCount: 0)
        let (index, store) = makeIndex()
        let credentials = try #require(store.load())
        #expect(try await index.completeSongs(using: credentials).isEmpty)
    }
}
