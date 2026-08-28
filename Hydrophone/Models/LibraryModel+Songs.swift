import Foundation

/// Songs-tab load/invalidate lifecycle over the client's complete-library
/// walk. Split from LibraryModel for the type-body-length lint (see
/// PlayerModel's extension split).
extension LibraryModel {
    /// Drops the rendered song snapshot so the next Songs-view load rebuilds
    /// it from the client's credential-bound full-library cache.
    func invalidateSongs() {
        songsGeneration += 1
        songs = []
        songsState = .idle
    }

    func loadSongsIfNeeded() async {
        if case .loading = songsState { return }
        if case .failed = songsState {
            // Partial rows remain usable, but must not prevent a fresh attempt.
        } else if !songs.isEmpty {
            return
        }
        let generation = songsGeneration
        songsState = .loading
        do {
            var fetched = try await client.allSongs { [weak self] partial in
                await self?.publishPartialSongs(partial, generation: generation)
            }
            await joinWorkInfo(into: &fetched)
            guard generation == songsGeneration else { return }
            songs = fetched
            songsState = .loaded(())
        } catch {
            guard generation == songsGeneration else { return }
            songsState = .failed(error.userMessage)
            Self.log.error("song load failed: \(error.userMessage)")
        }
    }

    /// Publishes raw Subsonic pages while the complete walk is still in
    /// flight. Work/movement enrichment remains a single final pass so the
    /// native metadata join is never repeated for every partial snapshot.
    private func publishPartialSongs(_ partial: [Song], generation: Int) {
        guard generation == songsGeneration else { return }
        songs = partial
    }
}
