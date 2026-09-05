import Foundation

/// Songs-tab load/invalidate lifecycle over the client's complete-library
/// walk. Split from LibraryModel for the type-body-length lint (see
/// PlayerModel's extension split).
extension LibraryModel {
    /// Drops the rendered song snapshot so the next Songs-view load rebuilds
    /// it from `songIndex`'s credential-bound full-library cache, and retires
    /// that underlying cache (both the Subsonic and native side) too — a
    /// stale in-flight build from before this call can't repopulate it. Async
    /// (awaits the actor call directly) so a caller can be sure the cache is
    /// actually cleared before proceeding, rather than racing a fire-and-forget
    /// invalidation against a subsequent read.
    func invalidateSongs() async {
        songsGeneration += 1
        songs = []
        songsState = .idle
        await songIndex.invalidate()
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
            // The native work/movement/bitDepth join now happens inside
            // `allSongs()` itself (once, after the walk completes) — see
            // `LibrarySongIndex`.
            let fetched = try await songIndex.allSongs { [weak self] partial in
                await self?.publishPartialSongs(partial, generation: generation)
            }
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
