import Foundation

extension LibraryModel {
    func metadataAllowsLoading() async -> Bool {
        switch metadataReadiness {
        case .ready: return true
        case .disconnected: return false
        case .waiting: return await withCheckedContinuation { metadataWaiters.append($0) }
        }
    }

    func retireMetadataSession() {
        playlistDetailRevisions = [:]
        playlistReloadRevisions = [:]
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
        metadataWriteTask?.cancel()
        metadataWriteTask = nil
        metadataSession = nil
        metadataReadiness = metadata == nil ? .ready : .disconnected
        seededSongs = false
        seededAlbums = false
        seededArtists = false
        seededGenres = false
        seededPlaylists = false
        resumeMetadataWaiters(false)
    }

    private func resumeMetadataWaiters(_ ready: Bool) {
        let waiters = metadataWaiters
        metadataWaiters = []
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    func prepareMetadata(using credentials: ServerCredentials) async {
        guard let metadata else { return }
        let generation = librarySessionGeneration
        metadataReadiness = .waiting
        let session = await metadata.open(for: credentials)
        guard generation == librarySessionGeneration else { return }
        metadataSession = session
        if let session, let snapshot = await metadata.read(for: session) {
            guard generation == librarySessionGeneration else { return }
            songs = snapshot.songs
            seededSongs = !songs.isEmpty
            if albumSortType == "alphabeticalByName", albumFilter == .none {
                albums = snapshot.albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                seededAlbums = !albums.isEmpty
            }
            artists = snapshot.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            seededArtists = !artists.isEmpty
            genres = snapshot.genres
            seededGenres = !genres.isEmpty
            playlists = snapshot.playlists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            seededPlaylists = !playlists.isEmpty
            if let favorites = snapshot.favorites {
                starredSongs = favorites.songs
                starredAlbums = favorites.albums
                starredSongIDs = Set(favorites.songs.map(\.id))
            }
        }
        guard generation == librarySessionGeneration else { return }
        metadataReadiness = .ready
        resumeMetadataWaiters(true)
    }

    func persistMetadata(_ change: MetadataWrite, generation: Int) {
        guard generation == librarySessionGeneration, let metadata, let session = metadataSession else { return }
        metadataWriteRevision += 1
        let previous = metadataWriteTask
        metadataWriteTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await metadata.write(change, for: session)
        }
    }

    func startConnectedLoads() async {
        guard metadata != nil else {
            await loadSongsIfNeeded()
            return
        }
        let generation = librarySessionGeneration
        guard let credentials = await client.currentCredentials, generation == librarySessionGeneration,
              metadataRefreshTask == nil else { return }
        metadataRefreshTask = Task { [weak self] in
            await self?.runMetadataRefresh(using: credentials)
        }
    }

    private func runMetadataRefresh(using credentials: ServerCredentials) async {
        let generation = librarySessionGeneration
        let albumGeneration = albumLoadGeneration
        let session = metadataSession
        guard generation == librarySessionGeneration, !Task.isCancelled else { return }
        async let songs: Void = loadSongsIfNeeded()
        async let albums: Void = loadAlbumsIfNeeded()
        async let artists: Void = loadArtistsIfNeeded()
        async let genres: Void = loadGenresIfNeeded()
        async let playlists: Void = loadPlaylistsIfNeeded()
        async let favorites: Void = loadStarredIfNeeded()
        _ = await (songs, albums, artists, genres, playlists, favorites)
        // Initial loads precede the authoritative walk. Their older responses
        // must not be replayed over the later snapshot as concurrent edits.
        await metadataWriteTask?.value
        guard generation == librarySessionGeneration, !Task.isCancelled,
              let metadata, let session, let token = await metadata.beginSync(for: session) else { return }
        do {
            try Task.checkCancellation()
            guard generation == librarySessionGeneration else { throw CancellationError() }
            let snapshot = try await LibraryMetadataSync(client: client, songIndex: songIndex,
                nativeFeaturesAvailable: nativeFeaturesAvailable).fetch(using: credentials)
            await metadataWriteTask?.value
            try Task.checkCancellation()
            guard generation == librarySessionGeneration else { throw CancellationError() }
            guard await metadata.finishSync(snapshot, token: token) else { return }
            let revision = metadataWriteRevision
            guard let reconciled = await metadata.read(for: session),
                  generation == librarySessionGeneration, revision == metadataWriteRevision else { return }
            publishReconciledMetadata(reconciled, albumGeneration: albumGeneration)
        } catch {
            await metadata.cancelSync(token)
        }
    }

    private func publishReconciledMetadata(_ snapshot: LibraryMetadataSnapshot, albumGeneration: Int) {
        songs = snapshot.songs
        seededSongs = false
        songsState = .loaded(())
        if albumGeneration == albumLoadGeneration, albumSortType == "alphabeticalByName", albumFilter == .none {
            albumLoadGeneration += 1
            albums = snapshot.albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            albumOffset = albums.count
            albumsExhausted = true
            albumsState = .loaded(())
            seededAlbums = false
            liveAlbumPages = []
        }
        artists = snapshot.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artistsState = .loaded(())
        seededArtists = false
        genres = snapshot.genres
        seededGenres = false
        playlists = snapshot.playlists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        seededPlaylists = false
        if let favorites = snapshot.favorites {
            starredSongs = favorites.songs
            starredAlbums = favorites.albums
            starredSongIDs = Set(favorites.songs.map(\.id))
            starredLoaded = true
        }
    }

    func refreshMetadataAfterScan(using credentials: ServerCredentials) async {
        await prepareMetadata(using: credentials)
        await startConnectedLoads()
        await metadataRefreshTask?.value
    }
}
