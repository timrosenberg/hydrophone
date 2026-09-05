import Foundation

/// Tokens retire pending work without putting credentials in persisted metadata.
struct MetadataSession: Sendable, Equatable {
    let scope: String
    let generation: UUID
}

struct MetadataSyncToken: Sendable, Equatable {
    let session: MetadataSession
    let generation: UUID
}

struct MetadataFavorites: Sendable {
    var songs: [Song]
    var albums: [Album]
}

struct LibraryMetadataSnapshot: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
    var genres: [Genre] = []
    var playlists: [Playlist] = []
    var favorites: MetadataFavorites?
    var lastSyncedAt: Date?
    var includesNativeMetadata = false
}

enum MetadataWrite: Sendable {
    case artists([Artist])
    case albums([Album])
    case songs([Song])
    case genres([Genre])
    /// A complete server playlist listing, including successful CRUD reconciliation.
    case playlists([Playlist])
    case playlist(Playlist)
    case favorites(MetadataFavorites)
}

/// Best-effort disk storage: its failures never fail a live library operation.
/// Each implementation owns its contexts; callers send values and session tokens.
protocol MetadataPersistence: Sendable {
    func open(for credentials: ServerCredentials) async -> MetadataSession?
    func close() async
    func read(for session: MetadataSession) async -> LibraryMetadataSnapshot?
    func write(_ change: MetadataWrite, for session: MetadataSession) async
    func beginSync(for session: MetadataSession) async -> MetadataSyncToken?
    func finishSync(_ snapshot: LibraryMetadataSnapshot, token: MetadataSyncToken) async -> Bool
    func cancelSync(_ token: MetadataSyncToken) async
}
