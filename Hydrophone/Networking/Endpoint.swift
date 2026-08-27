import Foundation

/// Assembles an endpoint's query-item list declaratively: each expression is
/// either a single `query(_:_:)` item (nil values drop out) or a repeated-key
/// `queries(_:_:)` group. Order is preserved — it is part of the wire format
/// (`SubsonicClient.formBody` serializes in order; see EndpointGoldenTests).
@resultBuilder
enum QueryList {
    static func buildBlock(_ parts: [URLQueryItem]...) -> [URLQueryItem] { parts.flatMap(\.self) }
    static func buildExpression(_ item: URLQueryItem?) -> [URLQueryItem] { item.map { [$0] } ?? [] }
    static func buildExpression(_ items: [URLQueryItem]) -> [URLQueryItem] { items }
    static func buildOptional(_ items: [URLQueryItem]?) -> [URLQueryItem] { items ?? [] }
}

/// One query item; a nil value means "omit the parameter".
private func query(_ name: String, _ value: String?) -> URLQueryItem? {
    value.map { URLQueryItem(name: name, value: $0) }
}

private func query(_ name: String, _ value: Int?) -> URLQueryItem? {
    value.map { URLQueryItem(name: name, value: String($0)) }
}

private func query(_ name: String, _ value: Bool?) -> URLQueryItem? {
    value.map { URLQueryItem(name: name, value: $0 ? "true" : "false") }
}

/// A repeated-key group (`id=a&id=b`), as Subsonic spells list parameters.
private func queries(_ name: String, _ values: [String]) -> [URLQueryItem] {
    values.map { URLQueryItem(name: name, value: $0) }
}

private func queries(_ name: String, _ values: [Int]) -> [URLQueryItem] {
    values.map { URLQueryItem(name: name, value: String($0)) }
}

/// Describes a single Subsonic REST call: the method name and its
/// endpoint-specific query items (auth + common params are added by the
/// client). See docs/02-opensubsonic-api.md.
struct Endpoint: Sendable {
    let method: String
    let queryItems: [URLQueryItem]
    /// Mutations whose parameter lists grow with content (playlist song ids)
    /// blow past typical URL limits around ~1,500 tracks. When the server
    /// advertises the OpenSubsonic `formPost` extension, flagged endpoints are
    /// sent as a form-encoded POST body instead (see `SubsonicClient`).
    let usesFormPost: Bool

    init(_ method: String, _ queryItems: [URLQueryItem] = [], usesFormPost: Bool = false) {
        self.method = method
        self.queryItems = queryItems
        self.usesFormPost = usesFormPost
    }

    init(_ method: String, usesFormPost: Bool = false,
         @QueryList _ items: () -> [URLQueryItem]) {
        self.init(method, items(), usesFormPost: usesFormPost)
    }

    // MARK: Connection
    static let ping = Endpoint("ping")

    /// OpenSubsonic capability discovery; used to decide GET vs form POST.
    static let openSubsonicExtensions = Endpoint("getOpenSubsonicExtensions")

    /// Ask the server to rescan its music folders (Settings → Connection,
    /// File → Update Server Library).
    static let startScan = Endpoint("startScan")

    // MARK: Library
    /// `genre` requires `type == "byGenre"`; `fromYear`/`toYear` require
    /// `type == "byYear"` (filters are list types in the Subsonic API).
    static func albumList2(type: String, size: Int, offset: Int,
                           genre: String? = nil,
                           fromYear: Int? = nil, toYear: Int? = nil) -> Endpoint {
        Endpoint("getAlbumList2") {
            query("type", type)
            query("size", size)
            query("offset", offset)
            query("genre", genre)
            query("fromYear", fromYear)
            query("toYear", toYear)
        }
    }

    static let artists = Endpoint("getArtists")

    static func randomSongs(size: Int) -> Endpoint {
        Endpoint("getRandomSongs") { query("size", size) }
    }

    /// Empty-query `search3` is the ecosystem's de-facto all-songs primitive.
    /// Artist and album results are disabled because this walk consumes only
    /// complete Song rows.
    static func allSongs(count: Int, offset: Int) -> Endpoint {
        Endpoint("search3") {
            query("query", "")
            query("songCount", count)
            query("songOffset", offset)
            query("albumCount", 0)
            query("artistCount", 0)
        }
    }

    static func artist(id: String) -> Endpoint {
        Endpoint("getArtist", [.init(name: "id", value: id)])
    }

    static func album(id: String) -> Endpoint {
        Endpoint("getAlbum", [.init(name: "id", value: id)])
    }

    static func song(id: String) -> Endpoint {
        Endpoint("getSong", [.init(name: "id", value: id)])
    }

    static let genres = Endpoint("getGenres")

    static func songsByGenre(_ genre: String, count: Int, offset: Int) -> Endpoint {
        Endpoint("getSongsByGenre") {
            query("genre", genre)
            query("count", count)
            query("offset", offset)
        }
    }

    // MARK: Discovery
    /// Artist biography and similar artists (served from the server's
    /// metadata agent, e.g. Navidrome's Last.fm bridge). Only artists present
    /// in the library are returned (`includeNotPresent` defaults to false).
    static func artistInfo2(id: String, count: Int) -> Endpoint {
        Endpoint("getArtistInfo2") {
            query("id", id)
            query("count", count)
        }
    }

    /// Similar-song mix for Start Radio. `id` may be a song, album, or
    /// artist id — the server mixes accordingly.
    static func similarSongs2(id: String, count: Int) -> Endpoint {
        Endpoint("getSimilarSongs2") {
            query("id", id)
            query("count", count)
        }
    }

    /// Top songs key off the artist *name*, not id (Subsonic API quirk).
    static func topSongs(artist: String, count: Int) -> Endpoint {
        Endpoint("getTopSongs") {
            query("artist", artist)
            query("count", count)
        }
    }

    // MARK: Play queue
    /// Persist playback state server-side: the queue, the current song, and
    /// the playhead (ms). Survives relaunch and enables cross-device resume.
    /// The id list grows with the queue → formPost when available.
    static func savePlayQueue(ids: [String], current: String?, positionMs: Int) -> Endpoint {
        Endpoint("savePlayQueue", usesFormPost: true) {
            queries("id", ids)
            if let current {
                query("current", current)
                query("position", positionMs)
            }
        }
    }

    static let playQueue = Endpoint("getPlayQueue")

    // MARK: Scrobbling
    /// `submission: false` reports "now playing"; `true` records the play
    /// (Navidrome play counts / external scrobblers).
    static func scrobble(id: String, submission: Bool) -> Endpoint {
        Endpoint("scrobble") {
            query("id", id)
            query("submission", submission)
        }
    }

    // MARK: Favorites
    static let starred2 = Endpoint("getStarred2")

    /// What a star applies to; the raw value is the API's parameter key.
    enum FavoriteKind: String, Sendable {
        case song = "id"
        case album = "albumId"
        case artist = "artistId"
    }

    static func favorite(id: String, kind: FavoriteKind = .song, starred: Bool) -> Endpoint {
        Endpoint(starred ? "star" : "unstar") { query(kind.rawValue, id) }
    }

    // MARK: Search
    static func search3(query text: String, songCount: Int, songOffset: Int,
                        albumCount: Int, artistCount: Int) -> Endpoint {
        Endpoint("search3") {
            query("query", text)
            query("songCount", songCount)
            query("songOffset", songOffset)
            query("albumCount", albumCount)
            query("artistCount", artistCount)
        }
    }

    // MARK: Playlists
    static let playlists = Endpoint("getPlaylists")

    static func playlist(id: String) -> Endpoint {
        Endpoint("getPlaylist", [.init(name: "id", value: id)])
    }

    /// Create a playlist, or — when `playlistId` is supplied — replace an
    /// existing playlist's contents with `songIds` in the given order. The
    /// replace form is the canonical way to **reorder** a playlist, since
    /// `updatePlaylist` can only append (see `updatePlaylist`).
    static func createPlaylist(name: String? = nil, playlistId: String? = nil,
                               songIds: [String] = []) -> Endpoint {
        Endpoint("createPlaylist", usesFormPost: true) {
            query("playlistId", playlistId)
            query("name", name)
            queries("songId", songIds)
        }
    }

    static func deletePlaylist(id: String) -> Endpoint {
        Endpoint("deletePlaylist", [.init(name: "id", value: id)])
    }

    /// Update a playlist. Supports rename, comment, public flag, adding songs,
    /// and removing songs by their index within the playlist.
    static func updatePlaylist(id: String, name: String? = nil, comment: String? = nil,
                               isPublic: Bool? = nil, songIdsToAdd: [String] = [],
                               songIndexesToRemove: [Int] = []) -> Endpoint {
        Endpoint("updatePlaylist", usesFormPost: true) {
            query("playlistId", id)
            query("name", name)
            query("comment", comment)
            query("public", isPublic)
            queries("songIdToAdd", songIdsToAdd)
            queries("songIndexToRemove", songIndexesToRemove)
        }
    }
}
