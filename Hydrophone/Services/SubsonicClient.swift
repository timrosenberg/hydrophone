import Foundation
import CryptoKit

/// Actor that performs all OpenSubsonic HTTP. Builds authenticated requests,
/// decodes the response envelope, and maps failures to `SubsonicError`.
/// See docs/01-architecture.md and docs/02-opensubsonic-api.md.
actor SubsonicClient { // swiftlint:disable:this type_body_length
    /// Protocol version we advertise. 1.16.1 is broadly supported.
    static let protocolVersion = "1.16.1"
    static let clientName = "Hydrophone"
    private static let allSongsPageLimiter = AsyncLimiter(limit: 6)

    private let credentials: CredentialStore
    private let session: URLSession
    private let decoder: JSONDecoder

    private var cachedAllSongs: [Song]?
    private var cachedAllSongsCredentials: ServerCredentials?
    private var inFlightAllSongs: Task<[Song], Error>?
    private var inFlightAllSongsCredentials: ServerCredentials?
    private var allSongsGeneration = 0

    /// Whether the current server supports the OpenSubsonic `formPost`
    /// extension, resolved lazily on the first flagged endpoint and cached
    /// per base URL (a reconnect to a different server re-resolves).
    private var formPostSupport: (baseURL: URL, supported: Bool)?

    init(credentials: CredentialStore, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        self.decoder = SubsonicClient.makeDecoder()
    }

    // MARK: - Public API

    var isConfigured: Bool { credentials.load() != nil }

    /// Performs an endpoint call and returns the decoded body.
    func send<Body: Decodable & Sendable>(_ endpoint: Endpoint, as _: Body.Type) async throws(SubsonicError) -> Body {
        let wrapper: SubsonicResponseWrapper<Body> = try await perform(endpoint)
        guard let body = wrapper.response.body else {
            throw SubsonicError.decoding("missing body for \(endpoint.method)")
        }
        return body
    }

    /// Performs a list endpoint (`{ "<method>": { "<listKey>": [Element] } }`)
    /// and returns the array; servers with no data yield `[]`.
    func list<Element: SubsonicListElement>(
        _ endpoint: Endpoint, of _: Element.Type
    ) async throws(SubsonicError) -> [Element] {
        try await send(endpoint, as: ListBody<Element>.self).items
    }

    /// Performs a single-payload endpoint (`{ "<method>": <Payload> }`).
    func object<Payload: Decodable & Sendable>(
        _ endpoint: Endpoint, as _: Payload.Type
    ) async throws(SubsonicError) -> Payload {
        try await send(endpoint, as: ObjectBody<Payload>.self).value
    }

    /// Performs an endpoint call that returns no payload (ping, star, etc.) and
    /// returns the server identity/capability info.
    @discardableResult
    func sendStatus(_ endpoint: Endpoint) async throws(SubsonicError) -> ServerInfo {
        let wrapper: SubsonicResponseWrapper<EmptyBody> = try await perform(endpoint)
        return wrapper.response.info
    }

    /// Connection test. Returns server identity (type/version/openSubsonic).
    func ping() async throws(SubsonicError) -> ServerInfo {
        try await sendStatus(.ping)
    }

    /// Returns every song exposed by the server's empty-query `search3`
    /// implementation, walking fixed-size pages to exhaustion. The completed
    /// result is cached for the exact credentials that produced it.
    func allSongs() async throws(SubsonicError) -> [Song] {
        guard let creds = credentials.load() else { throw .notConfigured }
        if cachedAllSongsCredentials == creds, let cachedAllSongs { return cachedAllSongs }
        if inFlightAllSongsCredentials == creds, let inFlightAllSongs {
            return try await allSongsResult(from: inFlightAllSongs)
        }

        allSongsGeneration += 1
        let generation = allSongsGeneration
        let task = Task<[Song], Error> { try await self.buildAllSongs(using: creds) }
        inFlightAllSongs = task
        inFlightAllSongsCredentials = creds

        do {
            let songs = try await task.value
            if allSongsGeneration == generation {
                cachedAllSongs = songs
                cachedAllSongsCredentials = creds
                inFlightAllSongs = nil
                inFlightAllSongsCredentials = nil
            }
            return songs
        } catch {
            if allSongsGeneration == generation {
                inFlightAllSongs = nil
                inFlightAllSongsCredentials = nil
            }
            throw error as? SubsonicError ?? .transport(error.localizedDescription)
        }
    }

    /// Retires both completed and in-flight snapshots. An already-awaiting
    /// caller may still receive its result, but that stale completion cannot
    /// repopulate the cache because its generation no longer matches.
    func invalidateAllSongs() {
        allSongsGeneration += 1
        cachedAllSongs = nil
        cachedAllSongsCredentials = nil
        inFlightAllSongs = nil
        inFlightAllSongsCredentials = nil
    }

    private func allSongsResult(from task: Task<[Song], Error>) async throws(SubsonicError) -> [Song] {
        do {
            return try await task.value
        } catch {
            throw error as? SubsonicError ?? .transport(error.localizedDescription)
        }
    }

    private func buildAllSongs(using creds: ServerCredentials) async throws(SubsonicError) -> [Song] {
        do {
            return try await walkAllSongs(using: creds)
        } catch {
            return try await list(.randomSongs(size: 500), using: creds, of: Song.self)
        }
    }

    // The walk keeps its probe, bounded fan-out, ordering, and progress guard
    // together so their pagination invariants stay visible in one place.
    // swiftlint:disable:next function_body_length
    private func walkAllSongs(using creds: ServerCredentials) async throws(SubsonicError) -> [Song] {
        let pageSize = 500
        let first = try await object(
            .allSongs(count: pageSize, offset: 0), using: creds,
            as: SearchContent.self
        ).song ?? []
        if first.isEmpty {
            return try await list(.randomSongs(size: pageSize), using: creds, of: Song.self)
        }
        guard first.count == pageSize else { return first }

        var songs = first
        var seenIDs = Set(first.map(\.id))
        guard seenIDs.count == first.count else {
            throw .decoding("search3 pagination returned duplicate song ids")
        }
        var nextOffset = pageSize
        while true {
            let offsets = (0..<6).map { nextOffset + ($0 * pageSize) }
            let pages = await withTaskGroup(
                of: (Int, Result<[Song], SubsonicError>).self
            ) { group in
                for offset in offsets {
                    group.addTask {
                        await Self.allSongsPageLimiter.run {
                            do {
                                let page = try await self.object(
                                    .allSongs(count: pageSize, offset: offset),
                                    using: creds,
                                    as: SearchContent.self
                                ).song ?? []
                                return (offset, .success(page))
                            } catch {
                                return (offset, .failure(
                                    error as? SubsonicError ?? .transport(error.localizedDescription)
                                ))
                            }
                        }
                    }
                }
                var results: [(Int, Result<[Song], SubsonicError>)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            for (_, result) in pages {
                let page = try result.get()
                let pageIDs = Set(page.map(\.id))
                guard pageIDs.count == page.count, seenIDs.isDisjoint(with: pageIDs) else {
                    throw .decoding("search3 pagination did not advance")
                }
                songs.append(contentsOf: page)
                seenIDs.formUnion(pageIDs)
                if page.count < pageSize { return songs }
            }
            nextOffset += pageSize * offsets.count
        }
    }

    /// Test a candidate set of credentials without persisting them. Used by the
    /// Settings "Test Connection" button.
    func testConnection(_ candidate: ServerCredentials) async throws(SubsonicError) -> ServerInfo {
        let request = try buildRequest(for: .ping, using: candidate)
        let wrapper: SubsonicResponseWrapper<EmptyBody> = try await execute(request, method: "ping")
        return wrapper.response.info
    }

    /// Builds an authenticated streaming URL for the given song id. Honors the
    /// transcoding settings (format/maxBitRate) when provided.
    func streamURL(songId: String, format: String? = nil, maxBitRate: Int? = nil,
                   timeOffset: Int? = nil) throws(SubsonicError) -> URL {
        var items: [URLQueryItem] = [.init(name: "id", value: songId)]
        if let format { items.append(.init(name: "format", value: format)) }
        if let maxBitRate { items.append(.init(name: "maxBitRate", value: String(maxBitRate))) }
        if let timeOffset { items.append(.init(name: "timeOffset", value: String(timeOffset))) }
        return try authedURL("stream", items)
    }

    /// Builds an authenticated cover-art URL for the given id at a target size.
    func coverArtURL(id: String, size: Int? = nil) throws(SubsonicError) -> URL {
        var items: [URLQueryItem] = [.init(name: "id", value: id)]
        if let size { items.append(.init(name: "size", value: String(size))) }
        return try authedURL("getCoverArt", items)
    }

    private func authedURL(_ method: String, _ items: [URLQueryItem]) throws(SubsonicError) -> URL {
        guard let creds = credentials.load() else { throw SubsonicError.notConfigured }
        return try url(for: Endpoint(method, items), using: creds)
    }

    // MARK: - Request execution

    private func perform<Body: Decodable & Sendable>(
        _ endpoint: Endpoint
    ) async throws(SubsonicError) -> SubsonicResponseWrapper<Body> {
        guard let creds = credentials.load() else { throw SubsonicError.notConfigured }
        return try await perform(endpoint, using: creds)
    }

    private func perform<Body: Decodable & Sendable>(
        _ endpoint: Endpoint, using creds: ServerCredentials
    ) async throws(SubsonicError) -> SubsonicResponseWrapper<Body> {
        if endpoint.usesFormPost, await supportsFormPost(using: creds) {
            return try await execute(try formPostRequest(for: endpoint, using: creds),
                                     method: endpoint.method)
        }
        return try await execute(try buildRequest(for: endpoint, using: creds), method: endpoint.method)
    }

    private func list<Element: SubsonicListElement>(
        _ endpoint: Endpoint, using creds: ServerCredentials, of _: Element.Type
    ) async throws(SubsonicError) -> [Element] {
        try await send(endpoint, using: creds, as: ListBody<Element>.self).items
    }

    private func object<Payload: Decodable & Sendable>(
        _ endpoint: Endpoint, using creds: ServerCredentials, as _: Payload.Type
    ) async throws(SubsonicError) -> Payload {
        try await send(endpoint, using: creds, as: ObjectBody<Payload>.self).value
    }

    private func send<Body: Decodable & Sendable>(
        _ endpoint: Endpoint, using creds: ServerCredentials, as _: Body.Type
    ) async throws(SubsonicError) -> Body {
        let wrapper: SubsonicResponseWrapper<Body> = try await perform(endpoint, using: creds)
        guard let body = wrapper.response.body else {
            throw SubsonicError.decoding("missing body for \(endpoint.method)")
        }
        return body
    }

    private func supportsFormPost(using creds: ServerCredentials) async -> Bool {
        if let cached = formPostSupport, cached.baseURL == creds.baseURL { return cached.supported }
        // `.openSubsonicExtensions` itself is a plain GET, so no recursion.
        // Errors (non-OpenSubsonic server, transient outage, missing payload)
        // resolve to false without caching, so one hiccup can't disable POST
        // for the session.
        guard let extensions = try? await object(.openSubsonicExtensions,
                                                 as: [OpenSubsonicExtension].self) else {
            return false
        }
        let supported = extensions.contains { $0.name == "formPost" }
        formPostSupport = (creds.baseURL, supported)
        return supported
    }

    private func execute<Body: Decodable & Sendable>(
        _ request: URLRequest, method: String
    ) async throws(SubsonicError) -> SubsonicResponseWrapper<Body> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubsonicError.transport(from: error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SubsonicError.http(status: http.statusCode)
        }
        let wrapper: SubsonicResponseWrapper<Body>
        do {
            wrapper = try decoder.decode(SubsonicResponseWrapper<Body>.self, from: data)
        } catch {
            throw SubsonicError.decoding(error.localizedDescription)
        }
        if wrapper.response.info.status != "ok" {
            let err = wrapper.response.error
            throw SubsonicError.api(code: err?.code ?? 0, message: err?.message ?? "Unknown error")
        }
        return wrapper
    }

    // MARK: - URL / auth construction

    private func buildRequest(for endpoint: Endpoint,
                              using creds: ServerCredentials) throws(SubsonicError) -> URLRequest {
        let finalURL = try url(for: endpoint, using: creds)
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return request
    }

    /// POST variant for endpoints flagged `usesFormPost`: identical parameter
    /// set (common + auth + endpoint), but carried in a form-encoded body so
    /// huge parameter lists stay out of the URL.
    func formPostRequest(for endpoint: Endpoint,
                         using creds: ServerCredentials) throws(SubsonicError) -> URLRequest {
        guard var components = URLComponents(url: creds.baseURL, resolvingAgainstBaseURL: false) else {
            throw SubsonicError.invalidURL
        }
        components.path = Self.restPath(basePath: components.path, method: endpoint.method)
        guard let url = components.url else { throw SubsonicError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(items: commonItems + authItems(for: creds) + endpoint.queryItems)
        return request
    }

    /// Percent-encode query items into a form body. `URLComponents` leaves `+`
    /// literal (legal in a URL query), but form decoding reads `+` as a space —
    /// escape it so a playlist named "A+B" survives the round trip.
    static func formBody(items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        let query = components.percentEncodedQuery ?? ""
        return Data(query.replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    private func url(for endpoint: Endpoint, using creds: ServerCredentials) throws(SubsonicError) -> URL {
        guard var components = URLComponents(url: creds.baseURL, resolvingAgainstBaseURL: false) else {
            throw SubsonicError.invalidURL
        }
        components.path = Self.restPath(basePath: components.path, method: endpoint.method)
        components.queryItems = commonItems + authItems(for: creds) + endpoint.queryItems
        guard let url = components.url else { throw SubsonicError.invalidURL }
        return url
    }

    private static func restPath(basePath: String, method: String) -> String {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return base + "/rest/" + method + ".view"
    }

    private let commonItems: [URLQueryItem] = [
        .init(name: "v", value: SubsonicClient.protocolVersion),
        .init(name: "c", value: SubsonicClient.clientName),
        .init(name: "f", value: "json")
    ]

    private func authItems(for creds: ServerCredentials) -> [URLQueryItem] {
        switch creds.authMethod {
        case .apiKey:
            // OpenSubsonic API-key auth extension.
            return [.init(name: "apiKey", value: creds.secret)]
        case .tokenSalt:
            let salt = Self.randomSalt()
            let token = Self.md5Hex(creds.secret + salt)
            return [
                .init(name: "u", value: creds.username),
                .init(name: "t", value: token),
                .init(name: "s", value: salt)
            ]
        }
    }

    // MARK: - Helpers

    static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomSalt(length: Int = 12) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Value-type format styles (Sendable), unlike ISO8601DateFormatter.
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = (try? withFraction.parse(string)) ?? (try? plain.parse(string)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(string)")
        }
        return decoder
    }
}
