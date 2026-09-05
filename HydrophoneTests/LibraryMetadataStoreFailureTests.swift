import Foundation
import Testing
@testable import Hydrophone

struct LibraryMetadataStoreFailureTests {
    @Test func ordinaryWritesCannotUndoAuthoritativeFavorites() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let staleSong = Song(id: "song", title: "Song", starred: MetadataStoreFixtures.date)
        let staleAlbum = Album(id: "album", name: "Album", starred: MetadataStoreFixtures.date)
        await store.write(.favorites(MetadataFavorites(songs: [staleSong], albums: [staleAlbum])), for: session)
        let token = try #require(await store.beginSync(for: session))
        await store.write(.favorites(MetadataFavorites(songs: [], albums: [])), for: session)
        await store.write(.songs([staleSong]), for: session)
        await store.write(.albums([staleAlbum]), for: session)
        await store.write(.playlist(Playlist(id: "list", name: "List", entry: [staleSong])), for: session)
        #expect(await store.read(for: session)?.favorites?.songs.isEmpty == true)
        #expect(await store.read(for: session)?.favorites?.albums.isEmpty == true)
        let snapshot = LibraryMetadataSnapshot(albums: [staleAlbum], songs: [staleSong],
            favorites: MetadataFavorites(songs: [staleSong], albums: [staleAlbum]))
        #expect(await store.finishSync(snapshot, token: token))
        #expect(await store.read(for: session)?.favorites?.songs.isEmpty == true)
        #expect(await store.read(for: session)?.favorites?.albums.isEmpty == true)
        await store.close()
    }

    @Test func corruptDatabaseIsBestEffortAndCannotRetireTheWrongSession() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = LibraryMetadataStoreTests.credentials()
        let first = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await first.open(for: credentials))
        await first.close()
        let directory = root.appendingPathComponent(session.scope)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        try Data("invalid SQLite database".utf8).write(to: directory.appendingPathComponent("metadata.store"))
        let reopened = LibraryMetadataStore(rootDirectory: root)
        #expect(await reopened.open(for: credentials) == nil)
        #expect(await reopened.read(for: session) == nil)
        #expect(await reopened.beginSync(for: session) == nil)
        let other = try #require(await reopened.open(for: LibraryMetadataStoreTests.credentials("https://other.test")))
        #expect(await reopened.read(for: other)?.songs.isEmpty == true)
        await reopened.close()
    }

    @Test func changedPlaylistSummaryInvalidatesDetailAndCompleteListDeletesOnlyPlaylists() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        await store.write(.playlist(MetadataStoreFixtures.playlist), for: session)
        let changed = Playlist(id: "playlist-1", name: "Updated", songCount: 3,
                               changed: MetadataStoreFixtures.date.addingTimeInterval(1))
        await store.write(.playlists([changed]), for: session)
        #expect(await store.read(for: session)?.playlists.first?.entry == nil)
        await store.write(.playlists([]), for: session)
        #expect(await store.read(for: session)?.playlists.isEmpty == true)
        #expect(await store.read(for: session)?.songs.count == 2)
        await store.close()
    }

    @Test func syncWithoutNativeCapabilityPreservesNativeFields() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        await store.write(.songs([MetadataStoreFixtures.song]), for: session)
        let token = try #require(await store.beginSync(for: session))
        let snapshot = LibraryMetadataSnapshot(songs: [Song(id: "song-1", title: "New title")])
        #expect(await store.finishSync(snapshot, token: token))
        let song = try #require(await store.read(for: session)?.songs.first)
        #expect(song.title == "New title")
        #expect(song.work == MetadataStoreFixtures.song.work)
        #expect(song.bitDepth == MetadataStoreFixtures.song.bitDepth)
        await store.close()
    }

    @Test func failedMappingRollsBackEarlierMutationsAndSyncBookkeeping() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let initial = try #require(await store.beginSync(for: session))
        #expect(await store.finishSync(LibraryMetadataSnapshot(songs: [MetadataStoreFixtures.song]), token: initial))
        let before = try #require(await store.read(for: session))
        let token = try #require(await store.beginSync(for: session))
        let invalid = Song(id: "invalid", title: "Cannot encode", replayGain: ReplayGainInfo(trackGain: .nan))
        let snapshot = LibraryMetadataSnapshot(songs: [Song(id: "song-1", title: "Overwritten"), invalid])
        #expect(await store.finishSync(snapshot, token: token) == false)
        let after = try #require(await store.read(for: session))
        #expect(after.songs == before.songs)
        #expect(after.lastSyncedAt == before.lastSyncedAt)
        await store.close()
        let reopened = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        #expect(await store.read(for: reopened)?.songs == before.songs)
        await store.close()
    }

    @Test func canceledSyncDoesNotUndoAcceptedWritesOrCancelAnotherSync() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let old = try #require(await store.beginSync(for: session))
        await store.write(.songs([MetadataStoreFixtures.song]), for: session)
        await store.cancelSync(old)
        #expect(await store.read(for: session)?.songs == [MetadataStoreFixtures.song])
        let next = try #require(await store.beginSync(for: session))
        await store.cancelSync(old)
        #expect(await store.finishSync(LibraryMetadataSnapshot(), token: next))
        #expect(await store.read(for: session)?.songs.isEmpty == true)
        await store.close()
    }
}
