import Foundation

/// Typed errors surfaced by `NavidromeClient`. Mirrors `SubsonicError`'s shape.
/// See docs/02-opensubsonic-api.md, issue #22, epic #11.
enum NavidromeError: Error, Sendable, Equatable {
    case notConfigured
    /// The stored credentials use OpenSubsonic API-key auth, which has no raw
    /// password to log into Navidrome's native `/auth/login` with.
    case apiKeyAuthUnsupported
    case invalidURL
    case transport(String)
    case http(status: Int)
    case decoding(String)
    /// Login rejected, or a request still 401s after one re-login retry.
    case authenticationFailed

    var userMessage: String {
        switch self {
        case .notConfigured: return "No server is configured."
        case .apiKeyAuthUnsupported: return "Native Navidrome features need password auth, not an API key."
        case .invalidURL: return "The server address is not a valid URL."
        case let .transport(message): return "Could not reach the server: \(message)"
        case let .http(status): return "The server returned HTTP \(status)."
        case let .decoding(message): return "Unexpected response from the server: \(message)"
        case .authenticationFailed: return "Could not sign in to the server's native API."
        }
    }
}

/// A cached native-API session token: the raw JWT plus its decoded expiry
/// (read from the JWT's own `exp` claim, not a guessed TTL).
struct NavidromeToken: Sendable, Equatable {
    let raw: String
    /// `nil` when the JWT carries no `exp` claim (or isn't well-formed) —
    /// treated as expired so the client always re-derives a fresh token
    /// rather than trusting one it can't validate.
    let expiresAt: Date?

    /// Expired (or unknown) `leeway` seconds before the real deadline, so a
    /// request built just before expiry doesn't land as a 401 mid-flight.
    func isExpired(asOf now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return true }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    /// Decodes the Unix `exp` claim out of a JWT's payload segment without
    /// verifying the signature (client-side expiry-checking only; the server
    /// is the actual authority on validity).
    static func decodeExpiry(fromJWT token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expNumber = payload["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expNumber.doubleValue)
    }
}

/// `POST /auth/login` request body.
struct NavidromeLoginRequest: Codable, Sendable {
    let username: String
    let password: String
}

/// `POST /auth/login` response. Also carries `subsonicSalt`/`subsonicToken`
/// (unused here — this issue only needs the native `token`; see #11).
struct NavidromeLoginResponse: Decodable, Sendable {
    let token: String
}

/// One `/api/song` entry: the native, undocumented shape carrying per-role
/// `participants` credits, raw `tags`, and metadata used to map composer
/// results directly to playable `Song` values. Deliberately separate from
/// `Song` (`Networking/SubsonicModels.swift`), which is the playback
/// pipeline's model — see #24, epic #11. Every field beyond `id` is decoded
/// tolerantly: a missing key here is normal, not an error.
struct NativeSongRecord: Identifiable, Sendable, Decodable {
    let id: String
    var title: String?
    var artist: String?
    var artistId: String?
    var album: String?
    var albumId: String?
    var albumArtist: String?
    var duration: Double?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var genres: [GenreRef]?
    var bitRate: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var suffix: String?
    var size: Int?
    var comment: String?
    var sortTitle: String?
    var orderTitle: String?
    var playCount: Int?
    // Keep native timestamps as strings so an absent/invalid optional date
    // cannot prevent the entire cached index from decoding.
    var createdAt: String?
    var playDate: String?
    var starred: Bool?
    var starredAt: String?
    var rgTrackGain: Double?
    var rgAlbumGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumPeak: Double?
    var participants: Participants?
    var tags: [String: [String]]?

    struct Participants: Sendable, Decodable {
        var composer: [Credit]?
        var artist: [Credit]?
        var albumartist: [Credit]?
    }

    struct Credit: Sendable, Decodable {
        let id: String
        let name: String
        var subRole: String?
    }
}

/// One full native song-index result plus its reusable id lookup. Constructed
/// once when an index build completes so every metadata join is O(requested
/// ids) rather than rebuilding an O(library size) dictionary per table load.
struct NativeSongIndexSnapshot: Sendable {
    let records: [NativeSongRecord]
    private let recordsByID: [String: NativeSongRecord]

    init(records: [NativeSongRecord]) {
        self.records = records
        self.recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func record(id: String) -> NativeSongRecord? {
        recordsByID[id]
    }
}

/// A song's work/movement metadata, read from `NativeSongRecord.tags`.
/// `movementNumber`/`movementTotal` are Navidrome's separate plain-number
/// tag strings (e.g. `"13"`/`"14"`), not a combined "n/total" string — each
/// parses independently, and each of the four fields is optional on its own
/// (a single-movement work can carry `work`/`movementName` with no numbered
/// movement at all). See #25, epic #11.
struct WorkInfo: Sendable, Equatable {
    var work: String?
    var movementName: String?
    var movementNumber: Int?
    var movementTotal: Int?
}

/// Mirrors the `stats` object on an `/api/artist` row, of which only
/// `composer` is read here (siblings `artist`/`albumartist`/`maincredit`
/// exist but aren't needed for the roster).
private struct ComposerRosterStats: Decodable {
    var composer: ComposerCounts?
}

private struct ComposerCounts: Decodable {
    var songCount: Int?
    var albumCount: Int?
}

/// One row from `/api/artist?role=composer` — the composer roster.
/// Some rows are synthetic joint-credit entities (e.g. a track crediting
/// three composers jointly produces one row named "A, B, and C" with its own
/// id, distinct from A/B/C's individual rows). That's Navidrome's own
/// behavior, not deduplicated here — surfaced as the server presents it, the
/// same convention `displayComposer` already follows. See #23, epic #11.
struct Composer: Identifiable, Sendable, Decodable {
    let id: String
    let name: String
    var songCount: Int?
    var albumCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, stats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let stats = try container.decodeIfPresent(ComposerRosterStats.self, forKey: .stats)
        songCount = stats?.composer?.songCount
        albumCount = stats?.composer?.albumCount
    }
}
