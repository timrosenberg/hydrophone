import Foundation

/// Favorites load/reload and optimistic star toggling. Split from
/// LibraryModel for the type-body-length lint, same reasoning as
/// LibraryModel+Playlists.swift.
extension LibraryModel {
    func loadStarredIfNeeded() async {
        guard await metadataAllowsLoading() else { return }
        // `starredLoaded` (not emptiness): a user with zero favorites would
        // otherwise refetch on every appearance; the generation-owned
        // in-flight identity stops same-session callers from duplicating it.
        let generation = librarySessionGeneration
        guard !starredLoaded, starredLoadingGeneration != generation else { return }
        starredLoadingGeneration = generation
        defer {
            if starredLoadingGeneration == generation { starredLoadingGeneration = nil }
        }
        await reloadStarred()
    }

    @discardableResult
    func reloadStarred() async -> Bool {
        guard await metadataAllowsLoading() else { return false }
        let generation = librarySessionGeneration
        do {
            let starred = try await client.object(.starred2, as: StarredContent.self)
            var songs = starred.song ?? []
            await joinWorkInfo(into: &songs)
            guard generation == librarySessionGeneration else { return false }
            starredAlbums = starred.album ?? []
            starredSongs = songs
            starredSongIDs = Set(starredSongs.map(\.id))
            starredLoaded = true
            persistMetadata(.favorites(MetadataFavorites(songs: songs, albums: starredAlbums)), generation: generation)
            return true
        } catch {
            // leave existing values; surfaced via UI empty state
            return false
        }
    }

    // MARK: - Favorite toggling (optimistic)

    /// Star state for display: optimistic override > server truth once the
    /// starred list is loaded > the row's own (possibly stale) flag before it.
    func isStarred(_ song: Song) -> Bool {
        if let pending = starOverrides[song.id] { return pending }
        return starredLoaded ? starredSongIDs.contains(song.id) : song.isStarred
    }

    func isStarred(album: Album) -> Bool {
        if let pending = albumStarOverrides[album.id] { return pending }
        return starredLoaded ? starredAlbums.contains { $0.id == album.id } : album.isStarred
    }

    /// Changes whenever any star display state can change. Value-type views
    /// (the AppKit-backed track table) take it as plain data so a toggle
    /// re-renders them even though rows read stars through a closure.
    var starSignature: Int {
        var hasher = Hasher()
        hasher.combine(starredLoaded)
        hasher.combine(starredSongIDs)
        hasher.combine(starOverrides)
        return hasher.finalize()
    }

    /// Star/unstar songs optimistically: the star flips immediately, the
    /// writes go out, and one reload reconciles. A refused write rolls its
    /// override back; a failed reload keeps overrides for accepted writes.
    func setStarred(_ starred: Bool, songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        let generation = librarySessionGeneration
        guard let credentials = await client.currentCredentials else { return }
        for id in songIds { starOverrides[id] = starred }
        for id in songIds {
            let succeeded = (try? await client.sendStatus(
                .favorite(id: id, starred: starred), using: credentials
            )) != nil
            if !succeeded { starOverrides[id] = nil }
        }
        guard generation == librarySessionGeneration else { return }
        if await reloadStarred() {
            for id in songIds { starOverrides[id] = nil }
        }
    }

    func setAlbumStarred(_ starred: Bool, albumId: String) async {
        let generation = librarySessionGeneration
        guard let credentials = await client.currentCredentials else { return }
        albumStarOverrides[albumId] = starred
        let succeeded = (try? await client.sendStatus(
            .favorite(id: albumId, kind: .album, starred: starred), using: credentials
        )) != nil
        if !succeeded {
            albumStarOverrides[albumId] = nil
        }
        guard generation == librarySessionGeneration else { return }
        if await reloadStarred() { albumStarOverrides[albumId] = nil }
    }

    /// Toggle one song's star from anywhere (⌘L); loads favorites first so
    /// the flip is truthful.
    func toggleStarred(_ song: Song) async {
        await loadStarredIfNeeded()
        await setStarred(!isStarred(song), songIds: [song.id])
    }
}
