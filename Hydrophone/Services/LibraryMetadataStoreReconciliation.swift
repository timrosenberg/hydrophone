import Foundation

extension LibraryMetadataStoreBatch {
    /// An authoritative root cannot leave nested records outside its inventory.
    /// Reject inconsistent input before touching disk rather than guess deletions.
    static func hasCompleteGraph(_ snapshot: LibraryMetadataSnapshot) -> Bool {
        let songIDs = Set(snapshot.songs.map(\.id))
        let albumIDs = Set(snapshot.albums.map(\.id))
        func validAlbum(_ album: Album) -> Bool {
            albumIDs.contains(album.id) && (album.song ?? []).allSatisfy { songIDs.contains($0.id) }
        }
        return snapshot.albums.allSatisfy(validAlbum)
            && snapshot.artists.allSatisfy { ($0.album ?? []).allSatisfy(validAlbum) }
            && snapshot.playlists.allSatisfy { ($0.entry ?? []).allSatisfy { songIDs.contains($0.id) } }
            && (snapshot.favorites?.songs ?? []).allSatisfy { songIDs.contains($0.id) }
            && (snapshot.favorites?.albums ?? []).allSatisfy(validAlbum)
    }

    func reconcile(_ snapshot: LibraryMetadataSnapshot) throws {
        for artist in snapshot.artists { try upsert(artist) }
        for album in snapshot.albums { try upsert(album) }
        for playlist in snapshot.playlists { try upsert(playlist) }
        // Complete root songs win over summary copies embedded in detail graphs,
        // and can clear native tags removed on the server since the last sync.
        for song in snapshot.songs { try upsert(song, authoritative: snapshot.includesNativeMetadata) }
        for genre in snapshot.genres { upsert(genre) }
        if let favorites = snapshot.favorites { try apply(.favorites(favorites)) }
        prune(to: snapshot)
    }

    private func prune(to snapshot: LibraryMetadataSnapshot) {
        let songIDs = Set(snapshot.songs.map(\.id))
        let albumIDs = Set(snapshot.albums.map(\.id))
        let artistIDs = Set(snapshot.artists.map(\.id))
        let genreIDs = Set(snapshot.genres.map(\.value))
        let playlistIDs = Set(snapshot.playlists.map(\.id))
        for record in albums.values {
            record.songIDs = record.songIDs?.filter { songIDs.contains($0) }
            record.songs = record.songs.filter { songIDs.contains($0.id) }
        }
        for record in artists.values {
            record.albumIDs = record.albumIDs?.filter { albumIDs.contains($0) }
            record.albums = record.albums.filter { albumIDs.contains($0.id) }
        }
        for record in playlists.values {
            record.entryIDs = record.entryIDs?.filter { songIDs.contains($0) }
            record.entries = record.entries.filter { songIDs.contains($0.id) }
        }
        playlists = playlists.filter { playlistIDs.contains($0.key) }
        artists = artists.filter { artistIDs.contains($0.key) }
        albums = albums.filter { albumIDs.contains($0.key) }
        songs = songs.filter { songIDs.contains($0.key) }
        genres = genres.filter { genreIDs.contains($0.key) }
    }

    /// Delay physical deletion until replay has had a chance to restore an ID.
    /// Reuse its original model rather than delete/insert the same unique key
    /// within one SwiftData transaction.
    func finalizeDeletions() {
        for (id, record) in knownPlaylists where playlists[id] == nil { context.delete(record) }
        for (id, record) in knownArtists where artists[id] == nil { context.delete(record) }
        for (id, record) in knownAlbums where albums[id] == nil { context.delete(record) }
        for (id, record) in knownSongs where songs[id] == nil { context.delete(record) }
        for (id, record) in knownGenres where genres[id] == nil { context.delete(record) }
    }
}
