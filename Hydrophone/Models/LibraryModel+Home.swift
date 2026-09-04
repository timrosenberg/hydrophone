import Foundation

/// Home-shelves load lifecycle. Split from LibraryModel for the
/// type-body-length/file-length lint, same reasoning as
/// LibraryModel+Playlists.swift.
extension LibraryModel {
    func loadHomeIfNeeded() async {
        guard !homeLoaded, !homeLoading else { return }
        await reloadHome()
    }

    /// The four shelves load concurrently; a shelf the server can't provide
    /// simply stays empty (the view hides it).
    func reloadHome() async {
        guard !homeLoading else { return }
        homeLoading = true
        defer { homeLoading = false }
        let generation = librarySessionGeneration
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
        homeRandom = await albumList(type: "random")
    }

    private func albumList(type: String) async -> [Album] {
        await fetchList(.albumList2(type: type, size: 20, offset: 0))
    }
}
