import Foundation

/// Fetches a complete value snapshot. Disk reconciliation happens only after
/// this succeeds, so a failed page never grants permission to prune old rows.
struct LibraryMetadataSync: Sendable {
    let client: SubsonicClient
    let songIndex: LibrarySongIndex
    let nativeFeaturesAvailable: @Sendable () async -> Bool

    func fetch(using credentials: ServerCredentials) async throws -> LibraryMetadataSnapshot {
        async let songs = songIndex.completeSongs(using: credentials)
        async let albums = allAlbums(using: credentials)
        async let artists = client.list(.artists, using: credentials, of: ArtistIndex.self)
        async let genres = client.list(.genres, using: credentials, of: Genre.self)
        async let playlists = allPlaylists(using: credentials)
        async let favorites = client.object(.starred2, using: credentials, as: StarredContent.self)
        let (fetchedSongs, fetchedAlbums, artistGroups, fetchedGenres, fetchedPlaylists, starred)
            = try await (songs, albums, artists, genres, playlists, favorites)
        try Task.checkCancellation()
        guard await client.currentCredentials == credentials else { throw CancellationError() }

        let songsByID = Dictionary(uniqueKeysWithValues: fetchedSongs.map { ($0.id, $0) })
        let albumSongs = Dictionary(grouping: fetchedSongs, by: { $0.albumId ?? "" })
        let completeAlbums = fetchedAlbums.map { value in
            var album = value
            album.song = (albumSongs[value.id] ?? []).sorted {
                ($0.discNumber ?? 0, $0.track ?? 0, $0.id) < ($1.discNumber ?? 0, $1.track ?? 0, $1.id)
            }
            return album
        }
        let artistAlbums = Dictionary(grouping: completeAlbums, by: { $0.artistId ?? "" })
        let completeArtists = artistGroups.flatMap { $0.artist ?? [] }.map { value in
            var artist = value
            artist.album = artistAlbums[value.id] ?? []
            return artist
        }
        let completePlaylists = fetchedPlaylists.map { value in
            var playlist = value
            playlist.entry = value.entry?.compactMap { songsByID[$0.id] }
            return playlist
        }
        let albumIDs = Set(completeAlbums.map(\.id))
        return LibraryMetadataSnapshot(
            artists: completeArtists, albums: completeAlbums, songs: fetchedSongs, genres: fetchedGenres,
            playlists: completePlaylists,
            favorites: MetadataFavorites(songs: (starred.song ?? []).compactMap { song in
                guard var full = songsByID[song.id] else { return nil }
                full.starred = song.starred
                return full
            }, albums: (starred.album ?? []).filter { albumIDs.contains($0.id) }),
            includesNativeMetadata: await nativeFeaturesAvailable()
        )
    }

    private func allAlbums(using credentials: ServerCredentials) async throws -> [Album] {
        var albums: [Album] = []
        var seen: Set<String> = []
        let pageSize = 500
        while true {
            try Task.checkCancellation()
            let page = try await client.list(
                .albumList2(type: "alphabeticalByName", size: pageSize, offset: albums.count),
                using: credentials, of: Album.self)
            let ids = Set(page.map(\.id))
            guard ids.count == page.count, seen.isDisjoint(with: ids), page.count <= pageSize else {
                throw SubsonicError.decoding("Album pagination did not advance")
            }
            albums += page
            seen.formUnion(ids)
            if page.count < pageSize { return albums }
        }
    }

    private func allPlaylists(using credentials: ServerCredentials) async throws -> [Playlist] {
        do {
            return try await playlistInventory(using: credentials)
        } catch {
            try Task.checkCancellation()
            guard await client.currentCredentials == credentials else { throw CancellationError() }
            // Retry the listing too: a detail 404 may mean the playlist was
            // deleted mid-walk. Never turn a failed detail into pruning authority.
            return try await playlistInventory(using: credentials)
        }
    }

    private func playlistInventory(using credentials: ServerCredentials) async throws -> [Playlist] {
        let listing = try await client.list(.playlists, using: credentials, of: Playlist.self)
        let limiter = AsyncLimiter(limit: 4)
        return try await withThrowingTaskGroup(of: Playlist.self) { group in
            for playlist in listing {
                group.addTask {
                    let result: Result<Playlist, SubsonicError> = await limiter.run {
                        do {
                            return .success(try await client.object(.playlist(id: playlist.id),
                                using: credentials, as: Playlist.self))
                        } catch {
                            return .failure(error as? SubsonicError
                                            ?? .transport(error.localizedDescription))
                        }
                    }
                    return try result.get()
                }
            }
            var result: [Playlist] = []
            for try await playlist in group { result.append(playlist) }
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
