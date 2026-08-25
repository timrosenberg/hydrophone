import Foundation

/// Sidebar selection, grouped iTunes-style into Library and Playlists.
/// See docs/04-ui-ux.md.
enum SidebarSelection: Hashable {
    case home
    case albums
    case artists
    case songs
    case favorites
    case composers
    case playlist(id: String)
}

/// String coding so the selection can be persisted with `@SceneStorage` for
/// window state restoration.
extension SidebarSelection: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "albums": self = .albums
        case "artists": self = .artists
        case "songs": self = .songs
        case "favorites": self = .favorites
        case "composers": self = .composers
        default:
            guard rawValue.hasPrefix("playlist:") else { return nil }
            self = .playlist(id: String(rawValue.dropFirst("playlist:".count)))
        }
    }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .albums: "albums"
        case .artists: "artists"
        case .songs: "songs"
        case .favorites: "favorites"
        case .composers: "composers"
        case .playlist(let id): "playlist:\(id)"
        }
    }
}
