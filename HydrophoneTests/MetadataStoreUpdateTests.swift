import Foundation
import SwiftData
import Testing
@testable import Hydrophone

@MainActor
struct MetadataStoreUpdateTests {
    @Test(arguments: [false, true])
    func overlappingGraphsReusePendingRecordsBeforeSave(onDisk: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = onDisk ? directory.appendingPathComponent("metadata.store") : nil
        let container = try MetadataStoreFixtures.container(at: url)
        let context = ModelContext(container)
        let artist = try MetadataRecords.upsert(MetadataStoreFixtures.artist, in: context)
        let playlist = try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CachedSong>()) == 2)
        let albumSong = try #require(artist.albums.first?.songs.first)
        let playlistSong = try #require(playlist.entries.first { $0.id == "song-1" })
        #expect(albumSong === playlistSong)
        #expect(try artist.value() == MetadataStoreFixtures.artist)
    }

    @Test func updatedCollectionsReplaceRelationshipsAndRetainSharedRows() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let artist = try MetadataRecords.upsert(MetadataStoreFixtures.artist, in: context)
        let playlist = try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        try context.save()
        var changed = MetadataStoreFixtures.playlist
        changed.name = "Changed"
        changed.entry = [Song(id: "song-2", title: "Changed too")]
        try MetadataRecords.upsert(changed, in: context)
        try MetadataRecords.upsert(Artist(id: "artist-1", name: "Artist", album: []), in: context)
        try context.save()
        #expect(try playlist.value() == changed)
        #expect(try artist.value().album == [])
        #expect(try context.fetchCount(FetchDescriptor<CachedPlaylist>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CachedArtist>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CachedAlbum>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CachedSong>()) == 2)
    }

    @Test func albumAndArtistOrderSurvivesRelationshipReordering() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let songs = [Song(id: "z", title: "First"), Song(id: "a", title: "Second")]
        let albums = [Album(id: "z", name: "First", song: songs), Album(id: "a", name: "Second")]
        let input = Artist(id: "artist", name: "Artist", album: albums)
        let artist = try MetadataRecords.upsert(input, in: context)
        let album = try #require(artist.albums.first)
        artist.albums.reverse()
        album.songs.reverse()
        try context.save()
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<CachedArtist>()).first?.value() == input)
    }

    @Test func albumGenreAndSyncUpdatesUseStableKeys() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.album, in: context)
        try MetadataRecords.upsert(Genre(value: "Chamber", songCount: 7, albumCount: 2), in: context)
        try MetadataRecords.upsert(LibrarySyncSnapshot(collection: "songs", offset: 10), in: context)
        try context.save()
        let album = Album(id: "album-1", name: "Renamed", song: [])
        let genre = Genre(value: "Chamber", songCount: 0, albumCount: 0)
        let sync = LibrarySyncSnapshot(collection: "songs", offset: 0, generation: 1,
                                       lastSyncedAt: MetadataStoreFixtures.date)
        try MetadataRecords.upsert(album, in: context)
        try MetadataRecords.upsert(genre, in: context)
        try MetadataRecords.upsert(sync, in: context)
        try context.save()
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<CachedAlbum>()).map { try $0.value() } == [album])
        #expect(try reader.fetch(FetchDescriptor<CachedGenre>()).map { $0.value() } == [genre])
        #expect(try reader.fetch(FetchDescriptor<LibrarySyncState>()).map { $0.value() } == [sync])
    }

    @Test func deletingAlbumKeepsPlaylistSongsUsable() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let album = try MetadataRecords.upsert(MetadataStoreFixtures.album, in: context)
        try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        try context.save()
        context.delete(album)
        try context.save()
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<CachedPlaylist>()).first?.value() == MetadataStoreFixtures.playlist)
    }

    @Test func incompleteRelationshipRejectsSeedInsteadOfSilentlyLosingRows() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let playlist = try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        playlist.entries = []
        #expect(throws: MetadataMapping.MappingError.self) { try playlist.value() }
    }

    @Test func corruptNestedMetadataRejectsSeedInsteadOfErasingCredits() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let song = try MetadataRecords.upsert(MetadataStoreFixtures.song, in: context)
        song.contributorsData = Data("invalid JSON".utf8)
        #expect(throws: DecodingError.self) { try song.value() }
    }
}
