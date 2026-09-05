import Foundation

/// Thin forwarder onto `songIndex.join(into:)` — kept as a `LibraryModel`
/// method so the five call sites below (album, genre, search, favorites,
/// playlist) don't need to change. Split from LibraryModel for the
/// type-body-length lint, same reasoning as LibraryModel+Playlists.swift.
/// See #45, epic #13.
extension LibraryModel {
    /// Joins `work`/`movementName`/`movementNumber`/`movementTotal`, and
    /// `bitDepth`, onto `songs` in place, from the cached native song index.
    /// A no-op — including on any native-side failure — when native features
    /// aren't available, so a plain Subsonic server never pays for or sees
    /// this.
    func joinWorkInfo(into songs: inout [Song]) async {
        await songIndex.join(into: &songs)
    }
}
