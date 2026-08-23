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
/// `participants` credits and raw `tags` (work/movement among others) that
/// Subsonic's `Song` model has no room for. Deliberately separate from
/// `Song` (`Networking/SubsonicModels.swift`), which is the playback
/// pipeline's model — see #24, epic #11. Every field beyond `id` is decoded
/// tolerantly: a missing key here is normal, not an error.
struct NativeSongRecord: Identifiable, Sendable, Decodable {
    let id: String
    var title: String?
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
    }
}
