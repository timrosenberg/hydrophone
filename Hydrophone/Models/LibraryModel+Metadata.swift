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
                albums = snapshot.albums
                seededAlbums = !albums.isEmpty
            }
            artists = snapshot.artists
            seededArtists = !artists.isEmpty
            genres = snapshot.genres
            seededGenres = !genres.isEmpty
            playlists = snapshot.playlists
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
        guard metadataRefreshTask == nil, let credentials = await client.currentCredentials else { return }
        metadataRefreshTask = Task { [weak self] in
            await self?.runMetadataRefresh(using: credentials)
        }
    }

    private func runMetadataRefresh(using credentials: ServerCredentials) async {
        let generation = librarySessionGeneration
        let albumGeneration = albumLoadGeneration
        let session = metadataSession
        let token: MetadataSyncToken?
        if let metadata, let session { token = await metadata.beginSync(for: session) } else { token = nil }
        guard generation == librarySessionGeneration, !Task.isCancelled else { return }
        async let songs: Void = loadSongsIfNeeded()
        async let albums: Void = loadAlbumsIfNeeded()
        async let artists: Void = loadArtistsIfNeeded()
        async let genres: Void = loadGenresIfNeeded()
        async let playlists: Void = loadPlaylistsIfNeeded()
        async let favorites: Void = loadStarredIfNeeded()
        _ = await (songs, albums, artists, genres, playlists, favorites)
        guard let metadata, let session, let token else { return }
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
        if seededSongs { songs = snapshot.songs; seededSongs = false; songsState = .loaded(()) }
        if albumGeneration == albumLoadGeneration, albumSortType == "alphabeticalByName", albumFilter == .none {
            albumLoadGeneration += 1
            albums = snapshot.albums
            albumOffset = albums.count
            albumsExhausted = true
            albumsState = .loaded(())
            seededAlbums = false
            liveAlbumPages = []
        }
        if seededArtists { artists = snapshot.artists; seededArtists = false }
        if seededGenres { genres = snapshot.genres; seededGenres = false }
        if seededPlaylists { playlists = snapshot.playlists; seededPlaylists = false }
    }

    func refreshMetadataAfterScan(using credentials: ServerCredentials) async {
        await prepareMetadata(using: credentials)
        await startConnectedLoads()
        await metadataRefreshTask?.value
    }
}
