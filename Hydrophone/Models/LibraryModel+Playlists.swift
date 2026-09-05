import Foundation

/// Server playlists: listing, fetching, and full CRUD. Reorder is the
/// full-replace form of `createPlaylist` (`updatePlaylist` can only append).
/// Split from LibraryModel for the type-body-length lint.
extension LibraryModel {
    /// Fire a best-effort mutation, then refresh the affected collection —
    /// the shared shape of the playlist CRUD writes below.
    func mutate(_ endpoint: Endpoint, thenReload reload: () async -> Void) async {
        let generation = librarySessionGeneration
        guard let credentials = await client.currentCredentials else { return }
        _ = try? await client.sendStatus(endpoint, using: credentials)
        guard generation == librarySessionGeneration else { return }
        await reload()
    }

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
        playlistListingGeneration += 1
        let requestGeneration = playlistListingGeneration
        let revision = playlistRevision
        do {
            let fetched = try await client.list(.playlists, of: Playlist.self)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard generation == librarySessionGeneration, revision == playlistRevision,
                  requestGeneration == playlistListingGeneration else { return }
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
        let revision = playlistDetailRevisions[id, default: 0]
        guard let fetched = try? await client.object(.playlist(id: id), as: Playlist.self),
              generation == librarySessionGeneration,
              revision == playlistDetailRevisions[id, default: 0] else { return nil }
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
        await mutatePlaylist(id: id, endpoint: .deletePlaylist(id: id))
    }

    func renamePlaylist(id: String, to name: String) async {
        await mutatePlaylist(id: id, endpoint: .updatePlaylist(id: id, name: name))
    }

    func addToPlaylist(id: String, songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        await mutatePlaylist(id: id, endpoint: .updatePlaylist(id: id, songIdsToAdd: songIds))
    }

    func removeFromPlaylist(id: String, indexes: [Int]) async {
        guard !indexes.isEmpty else { return }
        await mutatePlaylist(id: id, endpoint: .updatePlaylist(id: id, songIndexesToRemove: indexes))
    }

    /// Reorder by replacing the playlist's contents with `songIds` in the new
    /// order — `updatePlaylist` can only append, so the full-replace form of
    /// `createPlaylist` is the canonical reorder mechanism.
    func reorderPlaylist(id: String, name: String, songIds: [String]) async {
        await mutatePlaylist(id: id, endpoint: .createPlaylist(name: name, playlistId: id, songIds: songIds))
    }

    private func mutatePlaylist(id: String, endpoint: Endpoint) async {
        let generation = librarySessionGeneration
        playlistRevision += 1
        playlistDetailRevisions[id, default: 0] += 1
        await mutate(endpoint) { await reloadPlaylists() }
        guard generation == librarySessionGeneration else { return }
        // Retire details fetched during the mutation and reload the selected
        // playlist after its server round-trip, including a rejected edit.
        playlistDetailRevisions[id, default: 0] += 1
        playlistReloadRevisions[id, default: 0] += 1
    }
}
