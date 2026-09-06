import Foundation

/// Immutable song values identify one content revision. A model retains the
/// snapshot across view recreation; publishing different values replaces it.
/// Render-time cache validation is reference identity, never a song-array hash.
@MainActor
final class SongPresentation {
    let songs: [Song]
    private var sorts: [Sort: [Song]] = [:]
    private var sortOrder: [Sort] = []
    private(set) var sortBuildCount = 0

    private struct Sort: Hashable {
        let key: String
        let ascending: Bool
    }

    init(_ songs: [Song]) { self.songs = songs }

    func sorted(key: String, ascending: Bool, compute: () -> [Song]) -> [Song] {
        let sort = Sort(key: key, ascending: ascending)
        if let value = sorts[sort] { return value }
        let value = compute()
        sortBuildCount += 1
        // Bound retained permutations. Another table owns a different snapshot
        // and cannot evict this collection's most recent sort.
        if sortOrder.count == 4 { sorts.removeValue(forKey: sortOrder.removeFirst()) }
        sorts[sort] = value
        sortOrder.append(sort)
        return value
    }
}

/// The browser's four dependent projections live with the library session,
/// independently of the lifetime of the SwiftUI pane and table views.
@MainActor
final class SongBrowserPresentation {
    private var base: SongPresentation?
    private var artist: String?
    private var album: String?
    private var composer: String?
    private var artistSongs: [Song] = []
    private var albumSongs: [Song] = []
    private var result = Result(artists: [], albums: [], composers: [], tracks: SongPresentation([]))

    struct Result {
        var artists: [String]
        var albums: [String]
        var composers: [String]
        var tracks: SongPresentation
    }

    func resolve(base: SongPresentation, artist: String?, album: String?, composer: String?) -> Result {
        let baseChanged = self.base !== base
        let artistChanged = baseChanged || self.artist != artist
        let albumChanged = artistChanged || self.album != album
        let composerChanged = albumChanged || self.composer != composer
        if baseChanged { result.artists = uniqueSorted(base.songs.compactMap(\.artist)) }
        if artistChanged {
            artistSongs = artist.map { selected in base.songs.filter { $0.artist == selected } } ?? base.songs
            result.albums = uniqueSorted(artistSongs.compactMap(\.album))
        }
        if albumChanged {
            albumSongs = album.map { selected in artistSongs.filter { $0.album == selected } } ?? artistSongs
            result.composers = uniqueSorted(albumSongs.compactMap(\.nonEmptyDisplayComposer))
        }
        if composerChanged {
            let tracks = composer.map { selected in
                albumSongs.filter { $0.nonEmptyDisplayComposer == selected }
            } ?? albumSongs
            result.tracks = artist == nil && album == nil && composer == nil ? base : SongPresentation(tracks)
        }
        self.base = base
        self.artist = artist
        self.album = album
        self.composer = composer
        return result
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
