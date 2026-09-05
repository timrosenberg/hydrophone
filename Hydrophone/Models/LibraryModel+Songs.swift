import Foundation

/// Songs-tab load/invalidate lifecycle over the client's complete-library
/// walk. Split from LibraryModel for the type-body-length lint (see
/// PlayerModel's extension split).
extension LibraryModel {
    /// A fresh random batch for whole-library shuffle (Shuffle All). Distinct
    /// from the Songs sample above so the visible list isn't disturbed.
    /// Best-effort: an empty result simply leaves playback untouched.
    func randomBatch(size: Int = 500) async -> [Song] {
        await fetchList(.randomSongs(size: size))
    }

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
        guard await metadataAllowsLoading() else { return }
        if case .loading = songsState { return }
        if case .failed = songsState {
            // Partial rows remain usable, but must not prevent a fresh attempt.
        } else if !songs.isEmpty, !seededSongs {
            return
        }
        let generation = songsGeneration
        let sessionGeneration = librarySessionGeneration
        songsState = .loading
        do {
            // The native work/movement/bitDepth join now happens inside
            // `allSongs()` itself (once, after the walk completes) — see
            // `LibrarySongIndex`.
            let fetched: [Song]
            if seededSongs, let credentials = await client.currentCredentials {
                fetched = try await songIndex.completeSongs(using: credentials)
            } else {
                fetched = try await songIndex.allSongs { [weak self] partial in
                    await self?.publishPartialSongs(partial, generation: generation)
                }
            }
            guard generation == songsGeneration else { return }
            songs = fetched
            seededSongs = false
            persistMetadata(.songs(fetched), generation: sessionGeneration)
            songsState = .loaded(())
        } catch {
            guard generation == songsGeneration else { return }
            let message = (error as? SubsonicError)?.userMessage ?? error.localizedDescription
            songsState = .failed(message)
            Self.log.error("song load failed: \(message)")
        }
    }

    /// Publishes raw Subsonic pages while the complete walk is still in
    /// flight. Work/movement enrichment remains a single final pass so the
    /// native metadata join is never repeated for every partial snapshot.
    private func publishPartialSongs(_ partial: [Song], generation: Int) {
        guard generation == songsGeneration, !seededSongs else { return }
        songs = partial
    }
}
