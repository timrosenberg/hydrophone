import Foundation
import SwiftData
import Testing
@testable import Hydrophone

@MainActor
struct MetadataStoreSchemaTests {
    @Test func songRoundTripPreservesEveryFieldIncludingNativeEnrichment() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.song, in: context)
        try context.save()
        let reader = ModelContext(container)
        let restored = try #require(reader.fetch(FetchDescriptor<CachedSong>()).first)
        #expect(try restored.value() == MetadataStoreFixtures.song)
    }

    @Test func sparseSongDoesNotInventMetadata() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let input = Song(id: "sparse", title: "")
        try MetadataRecords.upsert(input, in: context)
        try context.save()
        let restored = try #require(ModelContext(container).fetch(FetchDescriptor<CachedSong>()).first)
        #expect(try restored.value() == input)
    }

    @Test func artistAlbumGraphRoundTripsWithoutDroppingDetail() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.artist, in: context)
        try context.save()
        let restored = try #require(ModelContext(container).fetch(FetchDescriptor<CachedArtist>()).first)
        #expect(try restored.value() == MetadataStoreFixtures.artist)
    }

    @Test func playlistPreservesOrderAndDuplicateSongs() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        try context.save()
        let reader = ModelContext(container)
        let restored = try #require(reader.fetch(FetchDescriptor<CachedPlaylist>()).first)
        #expect(try restored.value() == MetadataStoreFixtures.playlist)
        #expect(try reader.fetchCount(FetchDescriptor<CachedSong>()) == 2)
    }

    @Test func unfetchedAndEmptyRelationshipsRemainDistinct() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        for loaded in [false, true] {
            let id = loaded ? "empty" : "unfetched"
            try MetadataRecords.upsert(Album(id: id, name: id, song: loaded ? [] : nil), in: context)
            try MetadataRecords.upsert(Artist(id: id, name: id, album: loaded ? [] : nil), in: context)
            try MetadataRecords.upsert(Playlist(id: id, name: id, entry: loaded ? [] : nil), in: context)
        }
        try context.save()
        let reader = ModelContext(container)
        for album in try reader.fetch(FetchDescriptor<CachedAlbum>()) {
            #expect(try album.value().song == (album.id == "empty" ? [] : nil))
        }
        for artist in try reader.fetch(FetchDescriptor<CachedArtist>()) {
            #expect(try artist.value().album == (artist.id == "empty" ? [] : nil))
        }
        for playlist in try reader.fetch(FetchDescriptor<CachedPlaylist>()) {
            #expect(try playlist.value().entry == (playlist.id == "empty" ? [] : nil))
        }
    }

    @Test func serverIDUpsertReplacesInsteadOfDuplicating() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.song, in: context)
        try context.save()
        try MetadataRecords.upsert(Song(id: "song-1", title: "Renamed"), in: context)
        try context.save()
        let songs = try ModelContext(container).fetch(FetchDescriptor<CachedSong>())
        #expect(songs.count == 1)
        #expect(try songs.first?.value() == Song(id: "song-1", title: "Renamed"))
    }

    @Test func removingCollectionsDoesNotDeleteSharedSongs() throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        let playlist = try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        try context.save()
        context.delete(playlist)
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<CachedSong>()) == 2)
    }

    @Test func v1DiskStoreReopensWithMigrationPlanAndAllEntityTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("metadata.store")
        try writeDiskFixture(at: url)
        let container = try MetadataStoreFixtures.container(at: url)
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<CachedArtist>()).first?.value() == MetadataStoreFixtures.artist)
        #expect(try reader.fetch(FetchDescriptor<CachedPlaylist>()).first?.value() == MetadataStoreFixtures.playlist)
        #expect(try reader.fetch(FetchDescriptor<CachedGenre>()).first?.value()
                == Genre(value: "Chamber", songCount: 7, albumCount: 2))
        let sync = try #require(reader.fetch(FetchDescriptor<LibrarySyncState>()).first)
        #expect(sync.value() == LibrarySyncSnapshot(collection: "songs", offset: 42, generation: 3,
                                                   lastSyncedAt: MetadataStoreFixtures.date))
    }

    private func writeDiskFixture(at url: URL) throws {
        let container = try MetadataStoreFixtures.container(at: url)
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.artist, in: context)
        try context.save()
        try MetadataRecords.upsert(MetadataStoreFixtures.playlist, in: context)
        try MetadataRecords.upsert(Genre(value: "Chamber", songCount: 7, albumCount: 2), in: context)
        try MetadataRecords.upsert(LibrarySyncSnapshot(collection: "songs", offset: 42, generation: 3,
                                                      lastSyncedAt: MetadataStoreFixtures.date), in: context)
        try context.save()
    }

    @Test func actorBoundaryReturnsSendableSongValues() async throws {
        let container = try MetadataStoreFixtures.container()
        let context = ModelContext(container)
        try MetadataRecords.upsert(MetadataStoreFixtures.song, in: context)
        try context.save()
        let reader = MetadataStoreReader(modelContainer: container)
        let songs = try await reader.songs()
        #expect(songs == [MetadataStoreFixtures.song])
    }
}
