import Foundation
import SwiftData

/// Context-confined value-to-record mapping. Reuse canonical records before
/// linking graphs: implicit uniqueness merges of separately constructed graphs
/// can fail on disk when an album and a playlist reference the same song.
/// These helpers never save, open a container, schedule work, or call the server.
/// The future writer owns its context, transaction, error handling, and timing.
enum MetadataRecords {
    @discardableResult
    static func upsert(_ value: Song, in context: ModelContext) throws -> CachedSong {
        let id = value.id
        let record = try find(in: context, matching: #Predicate<CachedSong> { $0.id == id }) {
            CachedSong(id: id, title: value.title)
        }
        try record.update(value)
        return record
    }

    @discardableResult
    static func upsert(_ value: Album, in context: ModelContext) throws -> CachedAlbum {
        let id = value.id
        let songs = try MetadataMapping.unique(value.song ?? []).map { try upsert($0, in: context) }
        let record = try find(in: context, matching: #Predicate<CachedAlbum> { $0.id == id }) {
            CachedAlbum(id: id, name: value.name)
        }
        try record.update(value, songs: songs)
        return record
    }

    @discardableResult
    static func upsert(_ value: Artist, in context: ModelContext) throws -> CachedArtist {
        let id = value.id
        let albums = try MetadataMapping.unique(value.album ?? []).map { try upsert($0, in: context) }
        let record = try find(in: context, matching: #Predicate<CachedArtist> { $0.id == id }) {
            CachedArtist(id: id, name: value.name)
        }
        try record.update(value, albums: albums)
        return record
    }

    @discardableResult
    static func upsert(_ value: Playlist, in context: ModelContext) throws -> CachedPlaylist {
        let id = value.id
        let entries = try MetadataMapping.unique(value.entry ?? []).map { try upsert($0, in: context) }
        let record = try find(in: context, matching: #Predicate<CachedPlaylist> { $0.id == id }) {
            CachedPlaylist(id: id, name: value.name)
        }
        try record.update(value, entries: entries)
        return record
    }

    @discardableResult
    static func upsert(_ value: Genre, in context: ModelContext) throws -> CachedGenre {
        let name = value.value
        let record = try find(in: context, matching: #Predicate<CachedGenre> { $0.name == name }) {
            CachedGenre(value)
        }
        record.songCount = value.songCount
        record.albumCount = value.albumCount
        return record
    }

    @discardableResult
    static func upsert(_ value: LibrarySyncSnapshot, in context: ModelContext) throws -> LibrarySyncState {
        let collection = value.collection
        let record = try find(in: context, matching: #Predicate<LibrarySyncState> { $0.collection == collection }) {
            LibrarySyncState(value)
        }
        record.offset = value.offset
        record.generation = value.generation
        record.lastSyncedAt = value.lastSyncedAt
        return record
    }

    private static func find<Record: PersistentModel>(
        in context: ModelContext, matching predicate: Predicate<Record>, create: () -> Record
    ) throws -> Record {
        var descriptor = FetchDescriptor<Record>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let record = create()
        context.insert(record)
        return record
    }
}
