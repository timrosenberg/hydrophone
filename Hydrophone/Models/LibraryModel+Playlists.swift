import Foundation

/// Server playlists: listing, fetching, and full CRUD. Reorder is the
/// full-replace form of `createPlaylist` (`updatePlaylist` can only append).
/// Split from LibraryModel for the type-body-length lint.
extension LibraryModel {
    func loadPlaylistsIfNeeded() async {
        guard await metadataAllowsLoading() else { return }
        guard playlists.isEmpty || seededPlaylists else { return }
        let generation = librarySessionGeneration
        guard playlistsLoadingGeneration != generation else { return }
        playlistsLoadingGeneration = generation
        defer {
            if playlistsLoadingGeneration == generation { playlistsLoadingGeneration = nil }
        }
        await reloadPlaylists()
    }

    func reloadPlaylists() async {
        guard await metadataAllowsLoading() else { return }
        let generation = librarySessionGeneration
        playlistRevision += 1
        let revision = playlistRevision
        do {
            let fetched = try await client.list(.playlists, of: Playlist.self)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard generation == librarySessionGeneration, revision == playlistRevision else { return }
            playlists = fetched
            seededPlaylists = false
            persistMetadata(.playlists(fetched), generation: generation)
        } catch {
            // keep existing
        }
    }

    /// The playlist's own entries, unjoined — deliberately fast: no native
    /// work/movement/bit-depth lookup, so the caller can render tracks before
    /// paying for `joinWorkInfo(intoPlaylist:)`'s cold-cache cost. See #124.
    func playlist(id: String) async -> Playlist? {
        guard await metadataAllowsLoading() else { return nil }
        let generation = librarySessionGeneration
        let revision = playlistRevision
        guard let fetched = try? await client.object(.playlist(id: id), as: Playlist.self),
              generation == librarySessionGeneration, revision == playlistRevision else { return nil }
        persistMetadata(.playlist(fetched), generation: generation)
        return fetched
    }

    /// Non-blocking work/movement + bit-depth enrichment pass for an
    /// already-rendered playlist, applied after `playlist(id:)` so a cold
    /// native song-index cache (a full `/api/song` walk) never delays the
    /// playlist's own tracks from appearing. See #124.
    func joinWorkInfo(intoPlaylist playlist: Playlist) async -> Playlist {
        var updated = playlist
        var songs = updated.entry ?? []
        await joinWorkInfo(into: &songs)
        updated.entry = songs
        return updated
    }

    // MARK: - Playlist editing (M5)

    /// Create a playlist, optionally seeded with songs. Returns the created
    /// playlist (when the server echoes it) so callers can select it.
    @discardableResult
    func createPlaylist(name: String, songIds: [String] = []) async -> Playlist? {
        let generation = librarySessionGeneration
        guard let credentials = await client.currentCredentials else { return nil }
        let created = try? await client.object(.createPlaylist(name: name, songIds: songIds),
                                               using: credentials, as: Playlist.self)
        guard generation == librarySessionGeneration else { return nil }
        await reloadPlaylists()
        return created
    }

    func deletePlaylist(id: String) async {
        playlistRevision += 1
        await mutate(.deletePlaylist(id: id)) { await reloadPlaylists() }
    }

    func renamePlaylist(id: String, to name: String) async {
        playlistRevision += 1
        await mutate(.updatePlaylist(id: id, name: name)) { await reloadPlaylists() }
    }

    func addToPlaylist(id: String, songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        playlistRevision += 1
        await mutate(.updatePlaylist(id: id, songIdsToAdd: songIds)) { await reloadPlaylists() }
    }

    func removeFromPlaylist(id: String, indexes: [Int]) async {
        guard !indexes.isEmpty else { return }
        playlistRevision += 1
        await mutate(.updatePlaylist(id: id, songIndexesToRemove: indexes)) { await reloadPlaylists() }
    }

    /// Reorder by replacing the playlist's contents with `songIds` in the new
    /// order — `updatePlaylist` can only append, so the full-replace form of
    /// `createPlaylist` is the canonical reorder mechanism.
    func reorderPlaylist(id: String, name: String, songIds: [String]) async {
        playlistRevision += 1
        await mutate(.createPlaylist(name: name, playlistId: id, songIds: songIds)) {
            await reloadPlaylists()
        }
    }

}
