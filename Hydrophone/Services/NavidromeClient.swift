import Foundation

/// Actor that talks to Navidrome's native react-admin API (`/api/...`,
/// separate from Subsonic's `/rest/`). Metadata-only: composer enumeration,
/// a full song index, and work/movement tags — never streaming or playback,
/// which stay on `SubsonicClient`. The API is internal/undocumented, so every
/// decode here is tolerant and every failure degrades to Subsonic-only
/// upstream rather than crashing. See docs/02-opensubsonic-api.md, the E3
/// spike (#8), and epic #11.
actor NavidromeClient {
    private let credentials: CredentialStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    private var cachedToken: NavidromeToken?
    /// The credentials `cachedToken` was actually derived from. A token is
    /// only reused when the store's *current* credentials still match this
    /// snapshot — otherwise a token minted for one server/account could be
    /// replayed against a different one after Settings changes the
    /// connection (host swap, account swap, or a rotated password).
    private var cachedTokenCredentials: ServerCredentials?

    /// Bounds concurrent page fetches during `paginatedGet`. Same limit as
    /// `ArtworkCache`'s fetch limiter (`Services/AsyncLimiter.swift`) — 6-way
    /// concurrency is what was measured against a real 14,794-track library
    /// (14.2s sequential vs 5.3s at 6-way; see #8/#22).
    private static let pageLimiter = AsyncLimiter(limit: 6)

    init(credentials: CredentialStore, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - Auth

    /// Logs in and caches the resulting token against the credentials used.
    /// Call directly to force a fresh login (e.g. a feature-detection probe);
    /// ordinary requests should go through `ensureValidToken()` instead so an
    /// unexpired, still-current-credentials token is reused.
    @discardableResult
    func login() async throws(NavidromeError) -> NavidromeToken {
        guard let creds = credentials.load() else { throw NavidromeError.notConfigured }
        return try await login(using: creds)
    }

    private func login(using creds: ServerCredentials) async throws(NavidromeError) -> NavidromeToken {
        guard creds.authMethod == .tokenSalt else { throw NavidromeError.apiKeyAuthUnsupported }
        let request = try loginRequest(using: creds)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NavidromeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NavidromeError.transport("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw (http.statusCode == 401 || http.statusCode == 403)
                ? NavidromeError.authenticationFailed
                : NavidromeError.http(status: http.statusCode)
        }
        let decoded: NavidromeLoginResponse
        do {
            decoded = try decoder.decode(NavidromeLoginResponse.self, from: data)
        } catch {
            throw NavidromeError.decoding(error.localizedDescription)
        }
        let token = NavidromeToken(raw: decoded.token, expiresAt: NavidromeToken.decodeExpiry(fromJWT: decoded.token))
        cachedToken = token
        cachedTokenCredentials = creds
        return token
    }

    /// Returns the cached token if it isn't (near) expired **and** the store's
    /// current credentials still match the ones it was minted for; otherwise
    /// logs in again against `creds`. `creds` is threaded in by the caller
    /// (rather than reloaded here) so one `fetchPage` call uses a single
    /// consistent credential snapshot for both auth and URL construction.
    private func ensureValidToken(using creds: ServerCredentials) async throws(NavidromeError) -> NavidromeToken {
        if let cachedToken, cachedTokenCredentials == creds, !cachedToken.isExpired() {
            return cachedToken
        }
        return try await login(using: creds)
    }

    // MARK: - Pagination

    /// The parts of a `paginatedGet` call that stay constant across every
    /// page — including the credentials snapshot, so a Settings change
    /// mid-walk can't mix pages from two different servers/accounts into one
    /// result (a 401 retry reuses the same snapshot too). Bundled to keep
    /// `fetchPage`'s parameter count reasonable.
    private struct PageQuery: Sendable {
        let path: String
        let sort: String
        let order: String
        let extraQuery: [URLQueryItem]
        let credentials: ServerCredentials
    }

    /// Walks a react-admin list resource (`_start`/`_end`/`_sort`/`_order`,
    /// total via the `X-Total-Count` response header) fully, fetching pages
    /// concurrently after the first. `path` is the resource name under
    /// `/api/`, e.g. `"artist"` or `"song"`. Credentials are loaded once here
    /// and reused for every page of this walk, deliberately — see `PageQuery`.
    func paginatedGet<T: Decodable & Sendable>(
        path: String,
        sort: String,
        order: String = "ASC",
        extraQuery: [URLQueryItem] = [],
        pageSize: Int = 500,
        as type: T.Type
    ) async throws(NavidromeError) -> [T] {
        guard let creds = credentials.load() else { throw NavidromeError.notConfigured }
        let query = PageQuery(
            path: path, sort: sort, order: order,
            extraQuery: extraQuery, credentials: creds
        )
        return try await paginatedGet(query, pageSize: pageSize, as: type)
    }

    private func paginatedGet<T: Decodable & Sendable>(
        _ query: PageQuery, pageSize: Int, as type: T.Type
    ) async throws(NavidromeError) -> [T] {
        let first = try await fetchPage(query, start: 0, end: pageSize, as: type)
        guard first.totalCount > pageSize else { return first.items }

        let remainingStarts = Array(stride(from: pageSize, to: first.totalCount, by: pageSize))
        let pageResults = await withTaskGroup(of: (Int, Result<[T], NavidromeError>).self) { group in
            for start in remainingStarts {
                group.addTask {
                    await Self.pageLimiter.run {
                        do {
                            let page = try await self.fetchPage(query, start: start, end: start + pageSize, as: type)
                            return (start, .success(page.items))
                        } catch {
                            // `fetchPage` is `throws(NavidromeError)`; the cast always
                            // succeeds, but AsyncLimiter.run needs a non-throwing
                            // closure, so this stays a plain `catch` with a safe fallback.
                            return (start, .failure(error as? NavidromeError ?? .transport("\(error)")))
                        }
                    }
                }
            }
            var collected: [(Int, Result<[T], NavidromeError>)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var combined = first.items
        for (_, result) in pageResults.sorted(by: { $0.0 < $1.0 }) {
            combined.append(contentsOf: try result.get())
        }
        return combined
    }

    private struct Page<T: Sendable>: Sendable {
        let items: [T]
        let totalCount: Int
    }

    private func fetchPage<T: Decodable & Sendable>(
        _ query: PageQuery, start: Int, end: Int, as type: T.Type, isRetry: Bool = false
    ) async throws(NavidromeError) -> Page<T> {
        // Deliberately `query.credentials`, not a fresh `credentials.load()`:
        // every page (and the 401 retry below) must use the one snapshot
        // `paginatedGet` loaded at the start of this walk.
        let creds = query.credentials
        let token = try await ensureValidToken(using: creds)
        var items = [
            URLQueryItem(name: "_start", value: String(start)),
            URLQueryItem(name: "_end", value: String(end)),
            URLQueryItem(name: "_sort", value: query.sort),
            URLQueryItem(name: "_order", value: query.order)
        ]
        items.append(contentsOf: query.extraQuery)
        let request = try apiRequest(path: query.path, query: items, token: token, using: creds)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NavidromeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NavidromeError.transport("no HTTP response")
        }
        if http.statusCode == 401, !isRetry {
            invalidateCachedToken()
            return try await fetchPage(query, start: start, end: end, as: type, isRetry: true)
        }
        guard (200...299).contains(http.statusCode) else {
            throw http.statusCode == 401
                ? NavidromeError.authenticationFailed
                : NavidromeError.http(status: http.statusCode)
        }
        let decoded: [T]
        do {
            decoded = try decoder.decode([T].self, from: data)
        } catch {
            throw NavidromeError.decoding(error.localizedDescription)
        }
        // `paginatedGet` promises to walk the resource *fully*; a missing or
        // unparseable total silently downgraded to `start + decoded.count`
        // would make a short/malformed first page look like the whole
        // library. Fail loudly instead — see PR #27 review.
        guard let total = Self.totalCount(from: http) else {
            throw NavidromeError.decoding("missing or invalid X-Total-Count header")
        }
        return Page(items: decoded, totalCount: total)
    }

    private static func totalCount(from response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "X-Total-Count").flatMap(Int.init)
    }

    // MARK: - Song index

    /// In-memory cache of `songIndex()`'s result, kept for the app session
    /// only — no disk persistence (M2 dropped the SwiftData cache; see
    /// docs/PROGRESS.md). Cleared by `invalidateSongIndex()`.
    private var cachedSongIndex: NativeSongIndexSnapshot?
    /// The credentials `cachedSongIndex` was built against — same reasoning
    /// as `cachedTokenCredentials`: a cache built for one server/account
    /// must not be served to a different one after Settings changes the
    /// connection. See PR #31 review.
    private var cachedSongIndexCredentials: ServerCredentials?
    /// Bumped whenever a build starts and by `invalidateSongIndex()`. Actor
    /// isolation is reentrant across an `await`, so this identity lets a
    /// superseded build recognize it's stale and skip repopulating the cache
    /// or clearing a newer build's in-flight state. See PR #31 re-review.
    private var songIndexGeneration = 0
    /// The in-flight full-library build, if any, plus the credentials it
    /// was started under — coalesces overlapping `songIndex()` callers onto
    /// one paginated walk instead of each starting their own, but only when
    /// the caller's current credentials match (otherwise a caller under new
    /// credentials could be handed a build's result fetched under the old
    /// ones). See PR #31 review.
    private var inFlightSongIndexBuild: Task<NativeSongIndexSnapshot, Error>?
    private var inFlightSongIndexCredentials: ServerCredentials?

    /// Every non-missing song in the library, with per-role `participants` credits and
    /// raw `tags` — the data a later sub-issue needs to answer "songs by
    /// composer X" and "work/movement for song Y" without further network
    /// calls. Paginates `/api/song` concurrently via `paginatedGet` and
    /// caches the result; repeat calls within the same session return the
    /// cached copy without refetching, unless credentials changed or
    /// `invalidateSongIndex()` was called. See #24, epic #11.
    func songIndex() async throws(NavidromeError) -> [NativeSongRecord] {
        try await songIndexSnapshot().records
    }

    private func songIndexSnapshot() async throws(NavidromeError) -> NativeSongIndexSnapshot {
        guard let creds = credentials.load() else { throw NavidromeError.notConfigured }
        if let cachedSongIndex, cachedSongIndexCredentials == creds {
            return cachedSongIndex
        }
        if let inFlightSongIndexBuild, inFlightSongIndexCredentials == creds {
            do {
                return try await inFlightSongIndexBuild.value
            } catch {
                throw error as? NavidromeError ?? .transport("\(error)")
            }
        }

        songIndexGeneration += 1
        let generation = songIndexGeneration
        let build = Task<NativeSongIndexSnapshot, Error> {
            let query = PageQuery(
                path: "song", sort: "id", order: "ASC",
                extraQuery: [URLQueryItem(name: "missing", value: "false")], credentials: creds
            )
            let records = try await self.paginatedGet(query, pageSize: 500, as: NativeSongRecord.self)
            return NativeSongIndexSnapshot(records: records)
        }
        inFlightSongIndexBuild = build
        inFlightSongIndexCredentials = creds
        do {
            let snapshot = try await build.value
            // Only the still-current build may finish the job: invalidation
            // or a credential-scoped replacement may have retired this task,
            // and its stale result must not overwrite the newer cache/state.
            if generation == songIndexGeneration {
                cachedSongIndex = snapshot
                cachedSongIndexCredentials = creds
                inFlightSongIndexBuild = nil
                inFlightSongIndexCredentials = nil
            }
            return snapshot
        } catch {
            if generation == songIndexGeneration {
                inFlightSongIndexBuild = nil
                inFlightSongIndexCredentials = nil
            }
            throw error as? NavidromeError ?? .transport("\(error)")
        }
    }

    /// Clears the cached song index and retires any in-flight build (so it
    /// can't repopulate the cache once it completes), so the next
    /// `songIndex()` call rebuilds from scratch (e.g. after a library scan —
    /// the rebuild trigger itself is a later sub-issue's concern, not this
    /// one's).
    func invalidateSongIndex() {
        cachedSongIndex = nil
        cachedSongIndexCredentials = nil
        songIndexGeneration += 1
        inFlightSongIndexBuild = nil
        inFlightSongIndexCredentials = nil
    }

    // MARK: - URL / request construction

    /// Exposed (not `private`) so request-building can be unit-tested without
    /// a network call, the same way `SubsonicClient`'s equivalents are.
    func loginRequest(using creds: ServerCredentials) throws(NavidromeError) -> URLRequest {
        guard var components = URLComponents(url: creds.baseURL, resolvingAgainstBaseURL: false) else {
            throw NavidromeError.invalidURL
        }
        components.path = Self.authPath(basePath: components.path)
        guard let url = components.url else { throw NavidromeError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let body = NavidromeLoginRequest(username: creds.username, password: creds.secret)
            request.httpBody = try encoder.encode(body)
        } catch {
            throw NavidromeError.decoding("failed to encode login body: \(error.localizedDescription)")
        }
        return request
    }

    func apiRequest(
        path: String, query: [URLQueryItem], token: NavidromeToken, using creds: ServerCredentials
    ) throws(NavidromeError) -> URLRequest {
        guard var components = URLComponents(url: creds.baseURL, resolvingAgainstBaseURL: false) else {
            throw NavidromeError.invalidURL
        }
        components.path = Self.apiPath(basePath: components.path, resource: path)
        components.queryItems = query
        guard let url = components.url else { throw NavidromeError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token.raw)", forHTTPHeaderField: "X-Nd-Authorization")
        return request
    }

    static func authPath(basePath: String) -> String {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return base + "/auth/login"
    }

    static func apiPath(basePath: String, resource: String) -> String {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return base + "/api/" + resource
    }
}

extension NavidromeClient {
    private func invalidateCachedToken() {
        cachedToken = nil
        cachedTokenCredentials = nil
    }

    /// The full composer roster (`/api/artist?role=composer`), sorted by
    /// localized standard name order. The server-side sort keeps page boundaries
    /// stable; the final sort normalizes differences in database collation.
    /// Includes Navidrome's synthetic joint-credit rows as-is — see `Composer`'s
    /// doc comment. See #23, epic #11.
    func composers() async throws(NavidromeError) -> [Composer] {
        let composers = try await paginatedGet(
            path: "artist",
            sort: "name",
            order: "ASC",
            extraQuery: [URLQueryItem(name: "role", value: "composer")],
            as: Composer.self
        )
        return composers.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Every song crediting `composerId` as a composer (including joint
    /// credits, where one song lists several composer ids). Derived entirely
    /// from `songIndex()`'s cache — no network call beyond whatever building
    /// or reusing that cache already costs; there is no server-side "songs
    /// by composer" filter to call instead (see #24's doc comment). See #25,
    /// epic #11.
    func songs(byComposerId composerId: String) async throws(NavidromeError) -> [NativeSongRecord] {
        try await songIndexSnapshot().records.filter {
            $0.participants?.composer?.contains { $0.id == composerId } ?? false
        }
    }

    /// The work/movement metadata for one song, read from `songIndex()`'s
    /// cached `tags` — no per-song network round trip. `nil` when the song
    /// id isn't in the index, or is but carries none of the four fields.
    /// See #25, epic #11.
    func workMetadata(songId: String) async throws(NavidromeError) -> WorkInfo? {
        guard let song = try await songIndexSnapshot().record(id: songId) else { return nil }
        return Self.workInfo(from: song)
    }

    /// Batch variant of `workMetadata(songId:)`: joins work/movement metadata
    /// for many songs at once against a single dictionary built from the
    /// cached `songIndex()`, so an album's dozen tracks don't each pay
    /// `workMetadata`'s O(n) scan of the whole library. Ids with no match, or
    /// with none of the four fields, are simply absent from the result — same
    /// "nothing to show" contract as the single-song version. See #45, epic
    /// #13.
    func workInfo(forSongIds ids: [String]) async throws(NavidromeError) -> [String: WorkInfo] {
        guard !ids.isEmpty else { return [:] }
        let snapshot = try await songIndexSnapshot()
        var result: [String: WorkInfo] = [:]
        for id in ids {
            guard let song = snapshot.record(id: id), let info = Self.workInfo(from: song) else { continue }
            result[id] = info
        }
        return result
    }

    /// `nil` when `record` carries none of the four tags — the shared "is
    /// there anything to show" rule both `workMetadata(songId:)` and
    /// `workInfo(forSongIds:)` apply.
    private static func workInfo(from record: NativeSongRecord) -> WorkInfo? {
        let tags = record.tags ?? [:]
        let info = WorkInfo(
            work: tags["work"]?.first,
            movementName: tags["movementname"]?.first,
            movementNumber: tags["movement"]?.first.flatMap(Int.init),
            movementTotal: tags["movementtotal"]?.first.flatMap(Int.init)
        )
        let isEmpty = info.work == nil && info.movementName == nil
            && info.movementNumber == nil && info.movementTotal == nil
        return isEmpty ? nil : info
    }
}
