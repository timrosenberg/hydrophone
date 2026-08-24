import Foundation

/// Server playlists: listing, fetching, and full CRUD. Reorder is the
/// full-replace form of `createPlaylist` (`updatePlaylist` can only append).
/// Split from LibraryModel for the type-body-length lint.
extension LibraryModel {
    func loadPlaylistsIfNeeded() async {
        guard playlists.isEmpty else { return }
        await reloadPlaylists()
    }

    func reloadPlaylists() async {
        do {
            playlists = try await client.list(.playlists, of: Playlist.self)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // keep existing
        }
    }

    func playlist(id: String) async -> Playlist? {
        guard var playlist = try? await client.object(.playlist(id: id), as: Playlist.self) else { return nil }
        var songs = playlist.entry ?? []
        await joinWorkInfo(into: &songs)
        playlist.entry = songs
        return playlist
    }

    // MARK: - Playlist editing (M5)

    /// Create a playlist, optionally seeded with songs. Returns the created
    /// playlist (when the server echoes it) so callers can select it.
    @discardableResult
    func createPlaylist(name: String, songIds: [String] = []) async -> Playlist? {
        let created = try? await client.object(.createPlaylist(name: name, songIds: songIds),
                                               as: Playlist.self)
        await reloadPlaylists()
        return created
    }

    func deletePlaylist(id: String) async {
        await mutate(.deletePlaylist(id: id)) { await reloadPlaylists() }
    }

    func renamePlaylist(id: String, to name: String) async {
        await mutate(.updatePlaylist(id: id, name: name)) { await reloadPlaylists() }
    }

    func addToPlaylist(id: String, songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        await mutate(.updatePlaylist(id: id, songIdsToAdd: songIds)) { await reloadPlaylists() }
    }

    func removeFromPlaylist(id: String, indexes: [Int]) async {
        guard !indexes.isEmpty else { return }
        await mutate(.updatePlaylist(id: id, songIndexesToRemove: indexes)) { await reloadPlaylists() }
    }

    /// Reorder by replacing the playlist's contents with `songIds` in the new
    /// order — `updatePlaylist` can only append, so the full-replace form of
    /// `createPlaylist` is the canonical reorder mechanism.
    func reorderPlaylist(id: String, name: String, songIds: [String]) async {
        await mutate(.createPlaylist(name: name, playlistId: id, songIds: songIds)) {
            await reloadPlaylists()
        }
    }

}
