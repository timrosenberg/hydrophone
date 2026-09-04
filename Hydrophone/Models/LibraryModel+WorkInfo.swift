import Foundation

/// Joins native (Navidrome-only) work/movement metadata, and bit depth
/// (#106), onto fetched songs. Split from LibraryModel for the type-body-length
/// lint, same reasoning as LibraryModel+Playlists.swift. See #45, epic #13.
extension LibraryModel {
    /// Joins `work`/`movementName`/`movementNumber`/`movementTotal`, and
    /// `bitDepth`, onto `songs` in place, from the cached Navidrome song
    /// index. A no-op — including on any native-side failure — when native
    /// features aren't available, so a plain Subsonic server never pays for
    /// or sees this.
    func joinWorkInfo(into songs: inout [Song]) async {
        guard !songs.isEmpty, await nativeFeaturesAvailable() else { return }
        let ids = songs.map(\.id)
        if let info = try? await navidrome.workInfo(forSongIds: ids), !info.isEmpty {
            for index in songs.indices {
                guard let work = info[songs[index].id] else { continue }
                songs[index].work = work.work
                songs[index].movementName = work.movementName
                songs[index].movementNumber = work.movementNumber
                songs[index].movementTotal = work.movementTotal
            }
        }
        if let bitDepths = try? await navidrome.bitDepths(forSongIds: ids), !bitDepths.isEmpty {
            for index in songs.indices {
                songs[index].bitDepth = bitDepths[songs[index].id]
            }
        }
    }
}
