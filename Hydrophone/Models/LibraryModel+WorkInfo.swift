import Foundation

/// Joins native (Navidrome-only) work/movement metadata onto fetched songs.
/// Split from LibraryModel for the type-body-length lint, same reasoning as
/// LibraryModel+Playlists.swift. See #45, epic #13.
extension LibraryModel {
    /// Joins `work`/`movementName`/`movementNumber`/`movementTotal` onto
    /// `songs` in place, from the cached Navidrome song index. A no-op —
    /// including on any native-side failure — when native features aren't
    /// available, so a plain Subsonic server never pays for or sees this.
    func joinWorkInfo(into songs: inout [Song]) async {
        guard nativeFeaturesAvailable(), !songs.isEmpty else { return }
        guard let info = try? await navidrome.workInfo(forSongIds: songs.map(\.id)), !info.isEmpty else { return }
        for index in songs.indices {
            guard let work = info[songs[index].id] else { continue }
            songs[index].work = work.work
            songs[index].movementName = work.movementName
            songs[index].movementNumber = work.movementNumber
            songs[index].movementTotal = work.movementTotal
        }
    }
}
