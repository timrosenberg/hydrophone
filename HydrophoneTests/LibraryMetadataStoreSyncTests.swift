import Foundation
import Testing
@testable import Hydrophone

struct LibraryMetadataStoreSyncTests {
    @Test func syncPrunesDeletedRecordsAndPreservedDetailReferences() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        await store.write(.artists([MetadataStoreFixtures.artist]), for: session)
        await store.write(.playlist(MetadataStoreFixtures.playlist), for: session)
        await store.write(.genres([Genre(value: "Old")]), for: session)
        let token = try #require(await store.beginSync(for: session))
        let remaining = Song(id: "song-2", title: "Remaining")
        let snapshot = LibraryMetadataSnapshot(
            artists: [Artist(id: "artist-1", name: "Artist")], albums: [], songs: [remaining],
            genres: [Genre(value: "New")], playlists: [Playlist(id: "playlist-1", name: "Favorites")])
        #expect(await store.finishSync(snapshot, token: token))
        let result = try #require(await store.read(for: session))
        #expect(result.songs == [remaining])
        #expect(result.albums.isEmpty)
        #expect(result.artists.first?.album == [])
        #expect(result.playlists.first?.entry?.map(\.id) == ["song-2"])
        #expect(result.genres.map(\.value) == ["New"])
        #expect(result.lastSyncedAt != nil)
        await store.close()
    }

    @Test func syncReplaysNewerFavoriteAndPlaylistMutations() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let token = try #require(await store.beginSync(for: session))
        let song = Song(id: "song", title: "Song")
        let old = Playlist(id: "old", name: "Deleted", entry: [song])
        let new = Playlist(id: "new", name: "Created", entry: [song, song])
        await store.write(.favorites(MetadataFavorites(songs: [], albums: [])), for: session)
        await store.write(.playlists([new]), for: session)
        var starred = song
        starred.starred = MetadataStoreFixtures.date
        let snapshot = LibraryMetadataSnapshot(songs: [starred], playlists: [old],
                                               favorites: MetadataFavorites(songs: [starred], albums: []))
        #expect(await store.finishSync(snapshot, token: token))
        let result = try #require(await store.read(for: session))
        #expect(result.favorites?.songs == [])
        #expect(result.songs.first?.starred == nil)
        #expect(result.playlists.map(\.id) == ["new"])
        #expect(result.playlists.first?.entry?.map(\.id) == ["song", "song"])
        await store.close()
    }

    @Test func canceledStaleAndInvalidGraphSyncCannotPrune() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        await store.write(.songs([MetadataStoreFixtures.song]), for: session)
        let canceled = try #require(await store.beginSync(for: session))
        await store.cancelSync(canceled)
        #expect(await store.finishSync(LibraryMetadataSnapshot(), token: canceled) == false)
        let token = try #require(await store.beginSync(for: session))
        #expect(await store.beginSync(for: session) == nil)
        let invalid = LibraryMetadataSnapshot(albums: [MetadataStoreFixtures.album], songs: [])
        #expect(await store.finishSync(invalid, token: token) == false)
        #expect(await store.read(for: session)?.songs == [MetadataStoreFixtures.song])
        #expect(await store.read(for: session)?.lastSyncedAt == nil)
        await store.close()
        let next = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        #expect(await store.finishSync(LibraryMetadataSnapshot(), token: token) == false)
        #expect(await store.read(for: next)?.songs == [MetadataStoreFixtures.song])
        await store.close()
    }

    @Test func fullSyncRoundTripsNestedValuesAndClearsRemovedNativeTags() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let token = try #require(await store.beginSync(for: session))
        let snapshot = LibraryMetadataSnapshot(
            artists: [MetadataStoreFixtures.artist], albums: [MetadataStoreFixtures.album],
            songs: [MetadataStoreFixtures.song, Song(id: "song-2", title: "Other")],
            genres: [Genre(value: "Classical", songCount: 1, albumCount: 1)],
            playlists: [MetadataStoreFixtures.playlist],
            favorites: MetadataFavorites(songs: [MetadataStoreFixtures.song], albums: [MetadataStoreFixtures.album]))
        #expect(await store.finishSync(snapshot, token: token))
        await store.close()
        let next = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let result = try #require(await store.read(for: next))
        #expect(result.artists == snapshot.artists)
        #expect(result.albums == snapshot.albums)
        #expect(result.songs == snapshot.songs)
        #expect(result.playlists == snapshot.playlists)
        let nextToken = try #require(await store.beginSync(for: next))
        #expect(await store.finishSync(LibraryMetadataSnapshot(songs: [Song(id: "song-1", title: "Raw")],
                                                                     includesNativeMetadata: true),
                                      token: nextToken))
        #expect(await store.read(for: next)?.songs.first?.work == nil)
        #expect(await store.read(for: next)?.songs.first?.bitDepth == nil)
        await store.close()
    }

    @Test func fourteenThousandSongBatchPersistsAndPrunes() async throws {
        let root = LibraryMetadataStoreTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: LibraryMetadataStoreTests.credentials()))
        let songs = (0..<14_000).map { Song(id: String(format: "%05d", $0), title: "Song \($0)", work: "Suite") }
        let token = try #require(await store.beginSync(for: session))
        #expect(await store.finishSync(LibraryMetadataSnapshot(songs: songs), token: token))
        #expect(await store.read(for: session)?.songs.count == 14_000)
        let next = try #require(await store.beginSync(for: session))
        #expect(await store.finishSync(LibraryMetadataSnapshot(songs: Array(songs.prefix(7_000))), token: next))
        #expect(await store.read(for: session)?.songs.count == 7_000)
        await store.close()
    }
}
