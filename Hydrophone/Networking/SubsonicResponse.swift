import Foundation

/// The closed set of envelope-level status/capability keys. Shared by
/// `InnerResponse` (which decodes them) and the generic payload bodies (which
/// identify the payload as the one key that is *not* one of these).
private enum EnvelopeKey: String, CodingKey, CaseIterable {
    case status, version, type, serverVersion, openSubsonic, error
}

private let envelopeKeyNames = Set(EnvelopeKey.allCases.map(\.rawValue))

/// The Subsonic error object inside a failed response.
struct SubsonicAPIError: Decodable, Sendable {
    let code: Int
    let message: String?
}

/// Server identity / capability fields present on every response.
struct ServerInfo: Sendable, Equatable {
    var status: String
    var version: String?
    var type: String?
    var serverVersion: String?
    var openSubsonic: Bool?
}

/// Decodes the `subsonic-response` envelope: the common status/capability
/// fields, plus an optional endpoint-specific `Body` decoded from the same
/// level. On a failed status the body is skipped and `error` is populated.
/// See docs/02-opensubsonic-api.md.
struct InnerResponse<Body: Decodable & Sendable>: Decodable, Sendable {
    let info: ServerInfo
    let error: SubsonicAPIError?
    let body: Body?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EnvelopeKey.self)
        let status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        info = ServerInfo(
            status: status,
            version: try container.decodeIfPresent(String.self, forKey: .version),
            type: try container.decodeIfPresent(String.self, forKey: .type),
            serverVersion: try container.decodeIfPresent(String.self, forKey: .serverVersion),
            openSubsonic: try container.decodeIfPresent(Bool.self, forKey: .openSubsonic)
        )
        error = try container.decodeIfPresent(SubsonicAPIError.self, forKey: .error)
        body = status == "ok" ? try Body(from: decoder) : nil
    }
}

/// Outer wrapper: `{ "subsonic-response": { ... } }`.
struct SubsonicResponseWrapper<Body: Decodable & Sendable>: Decodable, Sendable {
    let response: InnerResponse<Body>
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

/// Payload for endpoints that return no data beyond status (e.g. ping, star).
struct EmptyBody: Decodable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
}

// MARK: - Generic payload bodies

/// Case-preserving key for the envelope's payload, whose name varies per
/// endpoint.
private struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer<DynamicKey> {
    /// The payload key: the single envelope key that isn't a status field.
    var payloadKey: DynamicKey? {
        allKeys.first { !envelopeKeyNames.contains($0.stringValue) }
    }

    func requirePayloadKey() throws -> DynamicKey {
        guard let key = payloadKey else {
            throw DecodingError.keyNotFound(DynamicKey("payload"), .init(
                codingPath: codingPath,
                debugDescription: "envelope has no payload key"))
        }
        return key
    }
}

/// A model that appears as a JSON array under a canonical key inside a list
/// container (`"song"`, `"album"`, …). The key must come from the type — it
/// can't be inferred from the container, which may carry sibling metadata
/// (`getArtists` sends `ignoredArticles` next to `index`).
protocol SubsonicListElement: Decodable, Sendable {
    static var listKey: String { get }
}

extension Song: SubsonicListElement { static var listKey: String { "song" } }
extension Album: SubsonicListElement { static var listKey: String { "album" } }
extension Artist: SubsonicListElement { static var listKey: String { "artist" } }
extension Genre: SubsonicListElement { static var listKey: String { "genre" } }
extension Playlist: SubsonicListElement { static var listKey: String { "playlist" } }
extension ArtistIndex: SubsonicListElement { static var listKey: String { "index" } }

/// `{ <status…>, "<method>": { "<listKey>": [Element], … } }` decoded straight
/// to the array. The method key repeats what the caller already knows, so it
/// is inferred rather than spelled out per endpoint; a missing list key or an
/// empty container (servers with no data send `{}`) decodes as `[]`.
struct ListBody<Element: SubsonicListElement>: Decodable, Sendable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: DynamicKey.self)
        let list = try outer.nestedContainer(keyedBy: DynamicKey.self,
                                             forKey: outer.requirePayloadKey())
        items = try list.decodeIfPresent([Element].self, forKey: DynamicKey(Element.listKey)) ?? []
    }
}

/// `{ <status…>, "<method>": <Payload> }` for single-payload endpoints.
/// A missing payload key throws (surfaced as `SubsonicError.decoding`).
struct ObjectBody<Payload: Decodable & Sendable>: Decodable, Sendable {
    let value: Payload

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: DynamicKey.self)
        value = try outer.decode(Payload.self, forKey: outer.requirePayloadKey())
    }
}

// MARK: - Payload shapes with structure of their own

/// One `getArtists` index bucket ("A", "B", …).
struct ArtistIndex: Decodable, Sendable {
    var name: String
    var artist: [Artist]?
}

/// `getStarred2` payload: both kinds of favorite in one response.
struct StarredContent: Decodable, Sendable {
    var album: [Album]?
    var song: [Song]?
}

/// `search3` payload: the three result lists.
struct SearchContent: Decodable, Sendable {
    var artist: [Artist]?
    var album: [Album]?
    var song: [Song]?
}

struct ScanStatus: Decodable, Sendable {
    var scanning: Bool
    var count: Int?
}

struct OpenSubsonicExtension: Decodable, Sendable {
    var name: String
    var versions: [Int]?
}

struct PlayQueue: Decodable, Sendable {
    var entry: [Song]?
    /// Id of the current song. Navidrome sends a string id; classic
    /// Subsonic servers send a number — accept both.
    var current: String?
    /// Playhead within the current song, in milliseconds.
    var position: Int?

    private enum CodingKeys: String, CodingKey { case entry, current, position }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entry = try container.decodeIfPresent([Song].self, forKey: .entry)
        position = try container.decodeIfPresent(Int.self, forKey: .position)
        if let text = try? container.decodeIfPresent(String.self, forKey: .current) {
            current = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .current) {
            current = String(number)
        }
    }
}
