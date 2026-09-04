import Foundation

/// Home-shelves load lifecycle. Split from LibraryModel for the
/// type-body-length/file-length lint, same reasoning as
/// LibraryModel+Playlists.swift.
extension LibraryModel {
    func loadHomeIfNeeded() async {
        guard !homeLoaded else { return }
        await reloadHome()
    }

    /// The four shelves load concurrently; a shelf the server can't provide
    /// simply stays empty (the view hides it).
    func reloadHome() async {
        let generation = librarySessionGeneration
        guard homeLoadingGeneration != generation else { return }
        homeLoadingGeneration = generation
        defer {
            if homeLoadingGeneration == generation { homeLoadingGeneration = nil }
        }
        async let newest = albumList(type: "newest")
        async let recent = albumList(type: "recent")
        async let frequent = albumList(type: "frequent")
        async let random = albumList(type: "random")
        let (fetchedNewest, fetchedRecent, fetchedFrequent, fetchedRandom)
            = await (newest, recent, frequent, random)
        guard generation == librarySessionGeneration else { return }
        (homeNewest, homeRecent, homeFrequent, homeRandom)
            = (fetchedNewest, fetchedRecent, fetchedFrequent, fetchedRandom)
        // All-empty almost always means the fetches failed (offline at
        // launch) — stay "unloaded" so the next appearance retries instead
        // of showing an empty Home until relaunch.
        homeLoaded = !(homeNewest.isEmpty && homeRecent.isEmpty
                       && homeFrequent.isEmpty && homeRandom.isEmpty)
    }

    /// Re-roll just the Random shelf (the Home view's refresh button).
    func rerollRandomAlbums() async {
        let generation = librarySessionGeneration
        let fetched = await albumList(type: "random")
        guard generation == librarySessionGeneration else { return }
        homeRandom = fetched
    }

    private func albumList(type: String) async -> [Album] {
        await fetchList(.albumList2(type: type, size: 20, offset: 0))
    }
}
