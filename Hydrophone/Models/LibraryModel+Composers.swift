import Foundation

/// Maps cached native Navidrome composer records into the `Song` values
/// consumed by track tables and playback, without per-track requests. Split from
/// LibraryModel for the type-body-length lint.
extension LibraryModel {
    func songs(forComposer id: String) async -> [Song] {
        guard let records = try? await navidrome.songs(byComposerId: id),
              !records.isEmpty else { return [] }
        let starredDates = Dictionary(starredSongs.compactMap { song in
            song.starred.map { (song.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var songs = records.map { record in
            var song = record.asSong()
            // Native annotations are a snapshot. Honor loaded favorites and
            // optimistic overrides, including Get Info's direct row flag.
            song.starred = isStarred(song) ? starredDates[song.id] ?? song.starred ?? .distantPast : nil
            return song
        }
        await joinWorkInfo(into: &songs)
        return songs
    }
}
