import Foundation
import Observation
import os

/// Observable library-browsing state. Loads albums/artists/songs/genres from
/// the server with pagination. The SwiftData cache layer is layered in during
/// M2 (docs/05-data-and-caching.md); this model currently fetches directly via
/// the client and holds results in memory.
@MainActor
@Observable
final class LibraryModel {
    enum Load<T: Sendable>: Sendable {
        case idle
        case loading
        case loaded(T)
        case failed(String)
    }

    private(set) var albums: [Album] = []
    private(set) var albumsState: Load<Void> = .idle
    private var albumOffset = 0
    private var albumsExhausted = false
    var albumSortType = "alphabeticalByName"
    private(set) var albumFilter: AlbumFilter = .none

    /// Albums-grid filter. Genre and year are `getAlbumList2` list types, so
    /// an active filter replaces the sort order server-side (issue #9).
    enum AlbumFilter: Hashable {
        case none
        case genre(String)
        case years(from: Int, through: Int)
    }

    private(set) var artists: [Artist] = []
    private(set) var artistsState: Load<Void> = .idle

    private(set) var genres: [Genre] = []

    private(set) var songs: [Song] = []
    private(set) var songsState: Load<Void> = .idle

    private(set) var starredSongs: [Song] = []
    private(set) var starredAlbums: [Album] = []
    /// O(1) lookup mirror of `starredSongs`, rebuilt on every reload.
    private var starredSongIDs: Set<String> = []
    /// Optimistic star state (id → starred), shown until the write and the
    /// reconciling reload round-trip. All star surfaces read through
    /// `isStarred`, so a tap flips everywhere at once.
    private var starOverrides: [String: Bool] = [:]
    private var albumStarOverrides: [String: Bool] = [:]

    // Home shelves (getAlbumList2 list types).
    private(set) var homeNewest: [Album] = []
    private(set) var homeRecent: [Album] = []
    private(set) var homeFrequent: [Album] = []
    private(set) var homeRandom: [Album] = []
    private(set) var homeLoaded = false
    private var homeLoading = false

    // Internal setter (not private): playlist CRUD lives in
    // LibraryModel+Playlists.swift.
    var playlists: [Playlist] = []

    static let pageSize = 100

    // Internal (not private): LibraryModel+Playlists.swift sends through it.
    let client: SubsonicClient

    // Native Navidrome access; work/movement join lives in
    // LibraryModel+WorkInfo.swift (#45, epic #13).
    let navidrome: NavidromeClient
    let nativeFeaturesAvailable: () async -> Bool

    init(client: SubsonicClient, navidrome: NavidromeClient,
         nativeFeaturesAvailable: @escaping () async -> Bool) {
        self.client = client
        self.navidrome = navidrome
        self.nativeFeaturesAvailable = nativeFeaturesAvailable
    }

    func reset() {
        albums = []
        albumOffset = 0
        albumsExhausted = false
        albumFilter = .none
        albumsState = .idle
        artists = []
        artistsState = .idle
        genres = []
        starredSongs = []
        starredAlbums = []
        starredSongIDs = []
        starOverrides = [:]
        albumStarOverrides = [:]
        starredLoaded = false
        homeNewest = []
        homeRecent = []
        homeFrequent = []
        homeRandom = []
        homeLoaded = false
    }

    // MARK: - Albums (paginated)

    func loadAlbumsIfNeeded() async {
        // Retry when empty unless a request is already in flight, so a transient
        // failure (e.g. a network timeout) doesn't blank the grid until relaunch.
        guard albums.isEmpty else { return }
        if case .loading = albumsState { return }
        await loadMoreAlbums()
    }

    func loadMoreAlbums() async {
        guard !albumsExhausted else { return }
        if case .loading = albumsState { return }
        await load("album", into: \.albumsState) { () async throws(SubsonicError) in
            let page = try await client.list(albumPageEndpoint(), of: Album.self)
            albums.append(contentsOf: page)
            albumOffset += page.count
            albumsExhausted = page.count < Self.pageSize
        }
    }

    /// Owns the `.loading → .loaded/.failed` transition shared by the stateful
    /// loads; `label` names the load in the failure log. Loads whose failure
    /// semantics differ (genres keep `[]`, starred keeps stale data) stay out.
    private func load(_ label: String,
                      into state: ReferenceWritableKeyPath<LibraryModel, Load<Void>>,
                      _ work: () async throws(SubsonicError) -> Void) async {
        self[keyPath: state] = .loading
        do {
            try await work()
            self[keyPath: state] = .loaded(())
        } catch {
            self[keyPath: state] = .failed(error.userMessage)
            Self.log.error("\(label) load failed: \(error.userMessage)")
        }
    }

    /// Best-effort list fetch: failures resolve to `[]` (views show their
    /// empty states instead of an error).
    private func fetchList<Element: SubsonicListElement>(_ endpoint: Endpoint) async -> [Element] {
        (try? await client.list(endpoint, of: Element.self)) ?? []
    }

    /// The next page for the current sort/filter combination. Filters are
    /// list *types* in the API, so an active filter takes over from the sort.
    private func albumPageEndpoint() -> Endpoint {
        switch albumFilter {
        case .none:
            return .albumList2(type: albumSortType, size: Self.pageSize, offset: albumOffset)
        case let .genre(name):
            return .albumList2(type: "byGenre", size: Self.pageSize, offset: albumOffset,
                               genre: name)
        case let .years(from, through):
            return .albumList2(type: "byYear", size: Self.pageSize, offset: albumOffset,
                               fromYear: from, toYear: through)
        }
    }

    private static let log = Logger(subsystem: "app.hydrophone", category: "library")

    func changeAlbumSort(to type: String) async {
        albumSortType = type
        await reloadAlbums()
    }

    func changeAlbumFilter(to filter: AlbumFilter) async {
        guard filter != albumFilter else { return }
        albumFilter = filter
        await reloadAlbums()
    }

    private func reloadAlbums() async {
        albums = []
        albumOffset = 0
        albumsExhausted = false
        albumsState = .idle
        await loadMoreAlbums()
    }

    // MARK: - Artists

    func loadArtistsIfNeeded() async {
        guard artists.isEmpty else { return }
        if case .loading = artistsState { return }
        await load("artist", into: \.artistsState) { () async throws(SubsonicError) in
            artists = try await client.list(.artists, of: ArtistIndex.self)
                .flatMap { $0.artist ?? [] }
        }
    }

    // MARK: - Songs (random sample — see endpoint note)

    func loadSongsIfNeeded() async {
        guard songs.isEmpty else { return }
        if case .loading = songsState { return }
        await load("song", into: \.songsState) { () async throws(SubsonicError) in
            var fetched = try await client.list(.randomSongs(size: 500), of: Song.self)
            await joinWorkInfo(into: &fetched)
            songs = fetched
        }
    }

    /// A fresh random batch for whole-library shuffle (Shuffle All). Distinct
    /// from the Songs sample above so the visible list isn't disturbed.
    /// Best-effort: an empty result simply leaves playback untouched.
    func randomBatch(size: Int = 500) async -> [Song] {
        await fetchList(.randomSongs(size: size))
    }

    // MARK: - Genres

    private var genresLoading = false

    func loadGenresIfNeeded() async {
        // Albums and the column browser can both request genres at once.
        guard genres.isEmpty, !genresLoading else { return }
        genresLoading = true
        defer { genresLoading = false }
        do {
            genres = try await client.list(.genres, of: Genre.self)
                .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        } catch {
            genres = []
        }
    }

    // MARK: - Favorites

    private var starredLoaded = false
    private var starredLoading = false

    func loadStarredIfNeeded() async {
        // `starredLoaded` (not emptiness): a user with zero favorites would
        // otherwise refetch on every appearance; the in-flight flag stops
        // Favorites + an album detail from firing duplicate fetches.
        guard !starredLoaded, !starredLoading else { return }
        starredLoading = true
        await reloadStarred()
        starredLoading = false
    }

    @discardableResult
    func reloadStarred() async -> Bool {
        do {
            let starred = try await client.object(.starred2, as: StarredContent.self)
            starredAlbums = starred.album ?? []
            var songs = starred.song ?? []
            await joinWorkInfo(into: &songs)
            starredSongs = songs
            starredSongIDs = Set(starredSongs.map(\.id))
            starredLoaded = true
            return true
        } catch {
            // leave existing values; surfaced via UI empty state
            return false
        }
    }

    // MARK: - Favorite toggling (optimistic)

    /// Star state for display: optimistic override > server truth once the
    /// starred list is loaded > the row's own (possibly stale) flag before it.
    func isStarred(_ song: Song) -> Bool {
        if let pending = starOverrides[song.id] { return pending }
        return starredLoaded ? starredSongIDs.contains(song.id) : song.isStarred
    }

    func isStarred(album: Album) -> Bool {
        if let pending = albumStarOverrides[album.id] { return pending }
        return starredLoaded ? starredAlbums.contains { $0.id == album.id } : album.isStarred
    }

    /// Changes whenever any star display state can change. Value-type views
    /// (the AppKit-backed track table) take it as plain data so a toggle
    /// re-renders them even though rows read stars through a closure.
    var starSignature: Int {
        var hasher = Hasher()
        hasher.combine(starredLoaded)
        hasher.combine(starredSongIDs)
        hasher.combine(starOverrides)
        return hasher.finalize()
    }

    /// Star/unstar songs optimistically: the star flips immediately, the
    /// writes go out, and one reload reconciles. A refused write rolls its
    /// override back; a failed reload keeps overrides for accepted writes.
    func setStarred(_ starred: Bool, songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        for id in songIds { starOverrides[id] = starred }
        for id in songIds where (try? await client.sendStatus(.favorite(id: id, starred: starred))) == nil {
            starOverrides[id] = nil
        }
        if await reloadStarred() {
            for id in songIds { starOverrides[id] = nil }
        }
    }

    func setAlbumStarred(_ starred: Bool, albumId: String) async {
        albumStarOverrides[albumId] = starred
        if (try? await client.sendStatus(.favorite(id: albumId, kind: .album, starred: starred))) == nil {
            albumStarOverrides[albumId] = nil
        }
        if await reloadStarred() { albumStarOverrides[albumId] = nil }
    }

    /// Toggle one song's star from anywhere (⌘L); loads favorites first so
    /// the flip is truthful.
    func toggleStarred(_ song: Song) async {
        await loadStarredIfNeeded()
        await setStarred(!isStarred(song), songIds: [song.id])
    }

    /// Fire a best-effort mutation, then refresh the affected collection —
    /// the shared shape of the playlist CRUD writes. Internal so
    /// LibraryModel+Playlists can send through it.
    func mutate(_ endpoint: Endpoint, thenReload reload: () async -> Void) async {
        _ = try? await client.sendStatus(endpoint)
        await reload()
    }
}

// MARK: - Album detail

extension LibraryModel {
    func songs(forAlbum id: String) async -> [Song] {
        var songs = (try? await client.object(.album(id: id), as: Album.self))?.song ?? []
        await joinWorkInfo(into: &songs)
        return songs
    }

    /// The full album record for an id — used by "Go to Album" from a track,
    /// where only the song's `albumId` is at hand.
    func album(id: String) async -> Album? {
        try? await client.object(.album(id: id), as: Album.self)
    }

    func albums(forArtist id: String) async -> [Album] {
        (try? await client.object(.artist(id: id), as: Artist.self))?.album ?? []
    }

    func songs(forGenre genre: String) async -> [Song] {
        var songs: [Song] = await fetchList(.songsByGenre(genre, count: Self.pageSize, offset: 0))
        await joinWorkInfo(into: &songs)
        return songs
    }
}

// MARK: - Discovery (artist info, radio mixes, album shuffle)

extension LibraryModel {
    /// Bio + similar artists for the artist page. Best-effort: nil simply
    /// hides the extras (servers without a metadata agent return little).
    func artistInfo(id: String) async -> ArtistInfo? {
        try? await client.object(.artistInfo2(id: id, count: 12), as: ArtistInfo.self)
    }

    /// Similar-song mix seeding Start Radio. `id` may be a song or artist id.
    func similarSongs(id: String, count: Int = 50) async -> [Song] {
        await fetchList(.similarSongs2(id: id, count: count))
    }

    /// Radio fallback for servers with no similarity data for an artist.
    func topSongs(artist name: String, count: Int = 50) async -> [Song] {
        await fetchList(.topSongs(artist: name, count: count))
    }

    /// Random whole albums for Shuffle Albums, honoring the active grid
    /// filter. Without one the server randomizes; genre/year are list types
    /// with no random order, so sample a large filtered page client-side.
    func randomAlbums(count: Int = 12) async -> [Album] {
        let endpoint: Endpoint
        switch albumFilter {
        case .none:
            endpoint = .albumList2(type: "random", size: count, offset: 0)
        case let .genre(name):
            endpoint = .albumList2(type: "byGenre", size: 200, offset: 0, genre: name)
        case let .years(from, through):
            endpoint = .albumList2(type: "byYear", size: 200, offset: 0,
                                   fromYear: from, toYear: through)
        }
        let albums: [Album] = await fetchList(endpoint)
        if case .none = albumFilter { return albums }
        return Array(albums.shuffled().prefix(count))
    }
}

// MARK: - Home shelves

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
        async let newest = albumList(type: "newest")
        async let recent = albumList(type: "recent")
        async let frequent = albumList(type: "frequent")
        async let random = albumList(type: "random")
        (homeNewest, homeRecent, homeFrequent, homeRandom)
            = await (newest, recent, frequent, random)
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
