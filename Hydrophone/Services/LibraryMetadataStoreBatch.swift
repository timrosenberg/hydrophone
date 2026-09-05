import Foundation
import SwiftData

/// One operation's canonical identity maps. Fetch each table once, then link
/// shared records in memory instead of issuing a query for each of 14k songs.
final class LibraryMetadataStoreBatch {
    let context: ModelContext
    var songs: [String: CachedSong]
    var albums: [String: CachedAlbum]
    var artists: [String: CachedArtist]
    var genres: [String: CachedGenre]
    var playlists: [String: CachedPlaylist]

    var knownSongs: [String: CachedSong]
    var knownAlbums: [String: CachedAlbum]
    var knownArtists: [String: CachedArtist]
    var knownGenres: [String: CachedGenre]
    var knownPlaylists: [String: CachedPlaylist]

    init(context: ModelContext) throws {
        self.context = context
        songs = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CachedSong>()).map { ($0.id, $0) })
        albums = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CachedAlbum>()).map { ($0.id, $0) })
        artists = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<CachedArtist>()).map { ($0.id, $0) })
        genres = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<CachedGenre>()).map { ($0.name, $0) })
        playlists = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<CachedPlaylist>()).map { ($0.id, $0) })
        knownSongs = songs
        knownAlbums = albums
        knownArtists = artists
        knownGenres = genres
        knownPlaylists = playlists
    }

    func apply(_ change: MetadataWrite) throws {
        switch change {
        case .songs(let values):
            try values.forEach { try upsert($0) }
        case .albums(let values):
            try values.forEach { try upsert($0) }
        case .artists(let values):
            try values.forEach { try upsert($0) }
        case .genres(let values):
            values.forEach { upsert($0) }
        case .playlists(let values):
            try replacePlaylists(values)
        case .playlist(let value):
            try upsert(value)
        case .favorites(let favorites):
            try applyFavorites(favorites)
        }
    }

    private func replacePlaylists(_ values: [Playlist]) throws {
        for value in values { try upsert(value) }
        let ids = Set(values.map(\.id))
        playlists = playlists.filter { ids.contains($0.key) }
    }

    @discardableResult
    func upsert(_ incoming: Song, authoritative: Bool = false, richMerge: Bool = false) throws -> CachedSong {
        let record: CachedSong
        if let existing = knownSongs[incoming.id] {
            record = existing
        } else {
            record = CachedSong(id: incoming.id, title: incoming.title)
            context.insert(record)
            knownSongs[incoming.id] = record
        }
        songs[incoming.id] = record
        var value = incoming
        if !authoritative {
            value.work = value.work ?? record.work
            value.movementName = value.movementName ?? record.movementName
            value.movementNumber = value.movementNumber ?? record.movementNumber
            value.movementTotal = value.movementTotal ?? record.movementTotal
            value.bitDepth = value.bitDepth ?? record.bitDepth
        }
        if richMerge { value = try Self.preservingRichFields(value, existing: record.value()) }
        try record.update(value)
        return record
    }

    @discardableResult
    func upsert(_ incoming: Album, richMerge: Bool = false) throws -> CachedAlbum {
        let record: CachedAlbum
        if let existing = knownAlbums[incoming.id] {
            record = existing
        } else {
            record = CachedAlbum(id: incoming.id, name: incoming.name)
            context.insert(record)
            knownAlbums[incoming.id] = record
        }
        albums[incoming.id] = record
        var value = incoming
        let preserve = value.song == nil && (value.songCount == nil || record.songIDs == nil
            || value.songCount == record.songIDs?.count)
        let ids = preserve ? record.songIDs : value.song?.map(\.id)
        let linked = value.song == nil ? (preserve ? record.songs : [])
            : try MetadataMapping.unique(value.song ?? []).map { try upsert($0, richMerge: richMerge) }
        value.discTitles = try value.discTitles ?? MetadataMapping.decode(record.discTitlesData, as: [DiscTitle].self)
        if richMerge { value = try Self.preservingRichFields(value, existing: record.value()) }
        try record.update(value, songs: linked)
        record.songIDs = ids
        return record
    }

    @discardableResult
    func upsert(_ value: Artist) throws -> CachedArtist {
        let record: CachedArtist
        if let existing = knownArtists[value.id] {
            record = existing
        } else {
            record = CachedArtist(id: value.id, name: value.name)
            context.insert(record)
            knownArtists[value.id] = record
        }
        artists[value.id] = record
        let preserve = value.album == nil && (value.albumCount == nil || record.albumIDs == nil
            || value.albumCount == record.albumIDs?.count)
        let ids = preserve ? record.albumIDs : value.album?.map(\.id)
        let linked = value.album == nil ? (preserve ? record.albums : [])
            : try MetadataMapping.unique(value.album ?? []).map { try upsert($0) }
        try record.update(value, albums: linked)
        record.albumIDs = ids
        return record
    }

    @discardableResult
    func upsert(_ value: Playlist) throws -> CachedPlaylist {
        let record: CachedPlaylist
        if let existing = knownPlaylists[value.id] {
            record = existing
        } else {
            record = CachedPlaylist(id: value.id, name: value.name)
            context.insert(record)
            knownPlaylists[value.id] = record
        }
        playlists[value.id] = record
        let sameRevision = value.changed == nil || value.changed == record.changed
        let sameCount = value.songCount == nil || record.entryIDs == nil || value.songCount == record.entryIDs?.count
        let preserve = value.entry == nil && sameRevision && sameCount
        let ids = preserve ? record.entryIDs : value.entry?.map(\.id)
        let linked = value.entry == nil ? (preserve ? record.entries : [])
            : try MetadataMapping.unique(value.entry ?? []).map { try upsert($0) }
        try record.update(value, entries: linked)
        record.entryIDs = ids
        return record
    }

    func upsert(_ value: Genre) {
        let record: CachedGenre
        if let existing = knownGenres[value.value] {
            record = existing
        } else {
            record = CachedGenre(value)
            context.insert(record)
            knownGenres[value.value] = record
        }
        genres[value.value] = record
        record.songCount = value.songCount
        record.albumCount = value.albumCount
    }

    private func applyFavorites(_ favorites: MetadataFavorites) throws {
        for song in favorites.songs { try upsert(song, richMerge: true) }
        for album in favorites.albums { try upsert(album, richMerge: true) }
        let songDates = Dictionary(favorites.songs.map { ($0.id, $0.starred ?? Date()) },
                                   uniquingKeysWith: { first, _ in first })
        let albumDates = Dictionary(favorites.albums.map { ($0.id, $0.starred ?? Date()) },
                                    uniquingKeysWith: { first, _ in first })
        for record in songs.values { record.starred = songDates[record.id] }
        for record in albums.values { record.starred = albumDates[record.id] }
        try MetadataRecords.upsert(LibrarySyncSnapshot(collection: "favorites"), in: context)
    }
}
