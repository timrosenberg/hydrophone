import Foundation
import Observation
import os

/// Observable library-browsing state. Loads albums/artists/songs/genres from
/// the server with pagination, seeding from the optional metadata store only
/// after connection verification. Live values remain authoritative.
@MainActor
@Observable
final class LibraryModel {
    enum Load<T: Sendable>: Sendable {
        case idle
        case loading
        case loaded(T)
        case failed(String)
    }

    var albums: [Album] = []
    var albumsState: Load<Void> = .idle
    var albumOffset = 0
    var albumsExhausted = false
    var albumSortType = "alphabeticalByName"
    private(set) var albumFilter: AlbumFilter = .none

    /// Albums-grid filter. Genre and year are `getAlbumList2` list types, so
    /// an active filter replaces the sort order server-side (issue #9).
    enum AlbumFilter: Hashable {
        case none
        case genre(String)
        case years(from: Int, through: Int)
    }

    var artists: [Artist] = []
    var artistsState: Load<Void> = .idle

    private(set) var composers: [Composer] = []
    private(set) var composersState: Load<Void> = .idle

    var genres: [Genre] = []

    // Internal setter (not private): load/invalidate logic lives in
    // LibraryModel+Songs.swift.
    var songs: [Song] = []
    var songsState: Load<Void> = .idle
    var songsGeneration = 0

    /// Whether the complete-library walk is actively in flight — app-wide
    /// (not tied to any particular view's lifecycle), so callers like the
    /// toolbar status can reflect it regardless of which page is on screen.
    var songsAreLoading: Bool {
        if case .loading = songsState { return true }
        return false
    }

    // Internal setters (not private): load/toggle lifecycle lives in
    // LibraryModel+Favorites.swift.
    var starredSongs: [Song] = []
    var starredAlbums: [Album] = []
    /// O(1) lookup mirror of `starredSongs`, rebuilt on every reload.
    var starredSongIDs: Set<String> = []
    /// Optimistic star state (id → starred), shown until the write and the
    /// reconciling reload round-trip. All star surfaces read through
    /// `isStarred`, so a tap flips everywhere at once.
    var starOverrides: [String: Bool] = [:]
    var albumStarOverrides: [String: Bool] = [:]

    // Home shelves (getAlbumList2 list types). Internal setters (not
    // private): load lifecycle lives in LibraryModel+Home.swift.
    var homeNewest: [Album] = []
    var homeRecent: [Album] = []
    var homeFrequent: [Album] = []
    var homeRandom: [Album] = []
    var homeLoaded = false
    var homeLoadingGeneration: Int?

    // Internal setter (not private): playlist CRUD lives in
    // LibraryModel+Playlists.swift.
    var playlists: [Playlist] = []
    var playlistsLoadingGeneration: Int?

    static let pageSize = 100

    // Internal (not private): LibraryModel+Playlists.swift sends through it.
    let client: SubsonicClient

    // Native Navidrome access; work/movement join lives in
    // LibraryModel+WorkInfo.swift (#45, epic #13).
    let navidrome: NavidromeClient
    let nativeFeaturesAvailable: @Sendable () async -> Bool

    // Internal (not private): LibraryModel+Songs.swift, +WorkInfo.swift, and
    // +Composers.swift call through it — the single owner of both
    // full-library walks (Subsonic + native), consolidating what used to be
    // split across SubsonicClient.cachedAllSongs and
    // NavidromeClient.cachedSongIndex. See docs/05-data-and-caching.md's
    // "Design decision (#140)".
    let songIndex: LibrarySongIndex

    /// Bumped by `reset()` (disconnect, credential change, or a successful
    /// library scan). Loads for albums/artists/composers/genres/starred/home/
    /// playlists capture this before their async fetch and check it's unchanged
    /// before writing the result back, so a fetch already in flight when
    /// `reset()` fires can't repopulate a collection with stale (wrong-server)
    /// data — the same generation-guard shape `songsGeneration` already uses
    /// for Songs specifically. Internal (not private): the Favorites, Home,
    /// and Playlists extensions read it for their own generation guards.
    var librarySessionGeneration = 0
    let metadata: (any MetadataPersistence)?
    @ObservationIgnored var metadataSession: MetadataSession?
    @ObservationIgnored var metadataRefreshTask: Task<Void, Never>?
    @ObservationIgnored var metadataWriteTask: Task<Void, Never>?
    @ObservationIgnored var metadataWaiters: [CheckedContinuation<Bool, Never>] = []
    enum MetadataReadiness { case waiting, ready, disconnected }
    var metadataReadiness: MetadataReadiness
    var seededSongs = false
    var seededAlbums = false
    var seededArtists = false
    var seededGenres = false
    var seededPlaylists = false
    var liveAlbumPages: [Album] = []
    var albumLoadGeneration = 0
    var metadataWriteRevision = 0

    init(client: SubsonicClient, navidrome: NavidromeClient,
         nativeFeaturesAvailable: @escaping @Sendable () async -> Bool,
         metadata: (any MetadataPersistence)? = nil) {
        self.metadata = metadata
        self.metadataReadiness = metadata == nil ? .ready : .waiting
        self.client = client
        self.navidrome = navidrome
        self.nativeFeaturesAvailable = nativeFeaturesAvailable
        self.songIndex = LibrarySongIndex(client: client, navidrome: navidrome,
                                          nativeFeaturesAvailable: nativeFeaturesAvailable)
    }

    /// Async so callers (`ConnectionModel`'s invalidation hook) can be sure
    /// the underlying `songIndex` actor cache is actually cleared before
    /// they proceed — a fire-and-forget invalidation could let a subsequent
    /// read race the actor call and observe stale (pre-reset) state.
    func reset() async {
        librarySessionGeneration += 1
        retireMetadataSession()
        albumLoadGeneration += 1
        liveAlbumPages = []
        albums = []
        albumOffset = 0
        albumsExhausted = false
        albumFilter = .none
        albumsState = .idle
        artists = []
        artistsState = .idle
        composers = []
        composersState = .idle
        genres = []
        playlists = []
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
        await invalidateSongs()
        await metadata?.close()
    }

    // MARK: - Albums (paginated)

    func loadAlbumsIfNeeded() async {
        // Retry when empty unless a request is already in flight, so a transient
        // failure (e.g. a network timeout) doesn't blank the grid until relaunch.
        guard await metadataAllowsLoading() else { return }
        guard albums.isEmpty || seededAlbums else { return }
        if case .loading = albumsState { return }
        await loadMoreAlbums()
    }

    func loadMoreAlbums() async {
        guard await metadataAllowsLoading() else { return }
        guard !albumsExhausted else { return }
        if case .loading = albumsState { return }
        let generation = librarySessionGeneration
        let albumGeneration = albumLoadGeneration
        await load("album", into: \.albumsState, generation: generation) { () async throws(SubsonicError) in
            let page = try await client.list(albumPageEndpoint(), of: Album.self)
            guard generation == librarySessionGeneration, albumGeneration == albumLoadGeneration else { return }
            if seededAlbums {
                liveAlbumPages.append(contentsOf: page)
                let fetchedIDs = Set(liveAlbumPages.map(\.id))
                albums = liveAlbumPages + albums.filter { !fetchedIDs.contains($0.id) }
            } else {
                albums.append(contentsOf: page)
            }
            albumOffset += page.count
            albumsExhausted = page.count < Self.pageSize
            if seededAlbums, albumsExhausted {
                albums = liveAlbumPages
                seededAlbums = false
                liveAlbumPages = []
            }
            persistMetadata(.albums(page), generation: generation)
        }
    }

    /// Owns the `.loading → .loaded/.failed` transition shared by the stateful
    /// loads; `label` names the load in the failure log. Loads whose failure
    /// semantics differ (genres keep `[]`, starred keeps stale data) stay out.
    /// `generation` guards the state transition itself the same way callers
    /// already guard their own data write inside `work` — see
    /// `librarySessionGeneration`.
    private func load(_ label: String,
                      into state: ReferenceWritableKeyPath<LibraryModel, Load<Void>>,
                      generation: Int,
                      _ work: () async throws(SubsonicError) -> Void) async {
        self[keyPath: state] = .loading
        do {
            try await work()
            guard generation == librarySessionGeneration else { return }
            self[keyPath: state] = .loaded(())
        } catch {
            guard generation == librarySessionGeneration else { return }
            self[keyPath: state] = .failed(error.userMessage)
            Self.log.error("\(label) load failed: \(error.userMessage)")
        }
    }

    /// Best-effort list fetch: failures resolve to `[]` (views show their
    /// empty states instead of an error). Internal (not private): also used
    /// by LibraryModel+Home.swift.
    func fetchList<Element: SubsonicListElement>(_ endpoint: Endpoint) async -> [Element] {
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

    // Internal (not private): also used by LibraryModel+Songs.swift.
    static let log = Logger(subsystem: "app.hydrophone", category: "library")

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
        albumLoadGeneration += 1
        seededAlbums = false
        liveAlbumPages = []
        albums = []
        albumOffset = 0
        albumsExhausted = false
        albumsState = .idle
        await loadMoreAlbums()
    }

    // MARK: - Artists

    func loadArtistsIfNeeded() async {
        guard await metadataAllowsLoading() else { return }
        guard artists.isEmpty || seededArtists else { return }
        if case .loading = artistsState { return }
        let generation = librarySessionGeneration
        await load("artist", into: \.artistsState, generation: generation) { () async throws(SubsonicError) in
            let fetched = try await client.list(.artists, of: ArtistIndex.self)
                .flatMap { $0.artist ?? [] }
            guard generation == librarySessionGeneration else { return }
            artists = fetched
            seededArtists = false
            persistMetadata(.artists(fetched), generation: generation)
        }
    }

    // MARK: - Composers

    func loadComposersIfNeeded() async {
        guard await metadataAllowsLoading() else { return }
        guard composers.isEmpty else { return }
        if case .loading = composersState { return }
        guard await nativeFeaturesAvailable() else { return }
        let generation = librarySessionGeneration
        composersState = .loading
        do {
            let fetched = try await navidrome.composers()
            guard generation == librarySessionGeneration else { return }
            composers = fetched
            composersState = .loaded(())
        } catch {
            guard generation == librarySessionGeneration else { return }
            composersState = .failed(error.userMessage)
            Self.log.error("composer load failed: \(error.userMessage)")
        }
    }

    // MARK: - Genres

    private var genresLoadingGeneration: Int?

    func loadGenresIfNeeded() async {
        // Albums and the column browser can both request genres at once.
        guard await metadataAllowsLoading() else { return }
        let generation = librarySessionGeneration
        guard genres.isEmpty || seededGenres, genresLoadingGeneration != generation else { return }
        genresLoadingGeneration = generation
        defer {
            if genresLoadingGeneration == generation { genresLoadingGeneration = nil }
        }
        do {
            let fetched = try await client.list(.genres, of: Genre.self)
                .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            guard generation == librarySessionGeneration else { return }
            genres = fetched
            seededGenres = false
            persistMetadata(.genres(fetched), generation: generation)
        } catch {
            guard generation == librarySessionGeneration else { return }
            if !seededGenres { genres = [] }
        }
    }

    // MARK: - Favorites (load/toggle lifecycle in LibraryModel+Favorites.swift)

    // Internal (not private): LibraryModel+Favorites.swift's load/toggle
    // methods manage these directly.
    var starredLoaded = false
    var starredLoadingGeneration: Int?

    /// Fire a best-effort mutation, then refresh the affected collection —
    /// the shared shape of the playlist CRUD writes. Internal so
    /// LibraryModel+Playlists can send through it.
    func mutate(_ endpoint: Endpoint, thenReload reload: () async -> Void) async {
        let generation = librarySessionGeneration
        guard let credentials = await client.currentCredentials else { return }
        _ = try? await client.sendStatus(endpoint, using: credentials)
        guard generation == librarySessionGeneration else { return }
        await reload()
    }
}

// MARK: - Album detail

extension LibraryModel {
    func songs(forAlbum id: String) async -> [Song] {
        guard await metadataAllowsLoading() else { return [] }
        let generation = librarySessionGeneration
        var songs = (try? await client.object(.album(id: id), as: Album.self))?.song ?? []
        await joinWorkInfo(into: &songs)
        guard generation == librarySessionGeneration else { return [] }
        persistMetadata(.songs(songs), generation: generation)
        return songs
    }

    /// The full album record for an id — used by "Go to Album" from a track,
    /// where only the song's `albumId` is at hand.
    func album(id: String) async -> Album? {
        guard await metadataAllowsLoading() else { return nil }
        let generation = librarySessionGeneration
        guard var album = try? await client.object(.album(id: id), as: Album.self) else { return nil }
        var songs = album.song ?? []
        await joinWorkInfo(into: &songs)
        guard generation == librarySessionGeneration else { return nil }
        album.song = songs
        persistMetadata(.albums([album]), generation: generation)
        return album
    }

    func albums(forArtist id: String) async -> [Album] {
        guard await metadataAllowsLoading() else { return [] }
        let generation = librarySessionGeneration
        let albums = (try? await client.object(.artist(id: id), as: Artist.self))?.album ?? []
        guard generation == librarySessionGeneration else { return [] }
        persistMetadata(.albums(albums), generation: generation)
        return albums
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
