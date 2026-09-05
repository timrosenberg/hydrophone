import Foundation

/// Per-item album/artist detail fetches. Split from LibraryModel for the
/// file-length lint, same reasoning as LibraryModel+Favorites.swift.
/// `album(id:)` and `albums(forArtist:)` cache their result in
/// `albumDetailCache`/`artistAlbumsCache` (#114) so a revisit within a
/// session is instant; `reset()` and a completed background reconciliation
/// clear those caches, mirroring how the rest of the library index already
/// invalidates.
extension LibraryModel {
    func songs(forAlbum id: String) async -> [Song] {
        guard await metadataAllowsLoading() else { return [] }
        let generation = librarySessionGeneration
        var songs = (try? await client.object(.album(id: id), as: Album.self))?.song ?? []
        await joinWorkInfo(into: &songs)
        guard generation == librarySessionGeneration else { return [] }
        persistMetadata(.songs(songs), generation: generation)
        return songs
    }

    /// The full album record for an id — used by "Go to Album" from a track,
    /// where only the song's `albumId` is at hand. Cached per session (#114):
    /// a repeat visit to the same album returns the prior result instantly.
    func album(id: String) async -> Album? {
        if let cached = albumDetailCache[id] { return cached }
        guard await metadataAllowsLoading() else { return nil }
        let generation = librarySessionGeneration
        guard var album = try? await client.object(.album(id: id), as: Album.self) else { return nil }
        var songs = album.song ?? []
        await joinWorkInfo(into: &songs)
        guard generation == librarySessionGeneration else { return nil }
        album.song = songs
        albumDetailCache[id] = album
        persistMetadata(.albums([album]), generation: generation)
        return album
    }

    /// Cached per session (#114): re-selecting an already-viewed artist
    /// returns its album list instantly instead of re-fetching. Only a
    /// successful fetch is cached — a network failure resolves to `[]` for
    /// this call (matching prior behavior) but is deliberately not cached,
    /// so the next visit retries instead of a hiccup permanently locking in
    /// an empty result for the rest of the session.
    func albums(forArtist id: String) async -> [Album] {
        if let cached = artistAlbumsCache[id] { return cached }
        guard await metadataAllowsLoading() else { return [] }
        let generation = librarySessionGeneration
        guard let artist = try? await client.object(.artist(id: id), as: Artist.self) else { return [] }
        let albums = artist.album ?? []
        guard generation == librarySessionGeneration else { return [] }
        artistAlbumsCache[id] = albums
        persistMetadata(.albums(albums), generation: generation)
        return albums
    }
}
