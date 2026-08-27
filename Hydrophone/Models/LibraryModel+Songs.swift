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
        guard songs.isEmpty else { return }
        if case .loading = songsState { return }
        let generation = songsGeneration
        songsState = .loading
        do {
            var fetched = try await client.allSongs()
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
}
