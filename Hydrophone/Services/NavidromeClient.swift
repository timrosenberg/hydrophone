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

    /// The session token, credential-scoped: a token minted for one
    /// server/account is never replayed against a different one after
    /// Settings changes the connection (host swap, account swap, or a
    /// rotated password) — `CredentialScopedCache` enforces that by key.
    private let tokenCache = CredentialScopedCache<NavidromeToken>()

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

    /// The currently persisted credentials snapshot, if any — exposed so
    /// `LibrarySongIndex` can get a `ServerCredentials` to key its native
    /// song-index cache by without its own `CredentialStore` reference.
    var currentCredentials: ServerCredentials? { credentials.load() }

    /// Forces a fresh login (e.g. a feature-detection probe) and seeds the
    /// token cache with the result so the next `ensureValidToken()` call
    /// reuses it instead of logging in again. Ordinary requests should go
    /// through `ensureValidToken()` instead, which reuses an unexpired,
    /// still-current-credentials token rather than always hitting the network.
    @discardableResult
    func login() async throws(NavidromeError) -> NavidromeToken {
        guard let creds = credentials.load() else { throw NavidromeError.notConfigured }
        let token = try await performLogin(using: creds)
        await tokenCache.store(token, for: creds)
        return token
    }

    private func performLogin(using creds: ServerCredentials) async throws(NavidromeError) -> NavidromeToken {
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
        return NavidromeToken(raw: decoded.token, expiresAt: NavidromeToken.decodeExpiry(fromJWT: decoded.token))
    }

    /// Returns the cached token if it isn't (near) expired **and** the store's
    /// current credentials still match the ones it was minted for; otherwise
    /// logs in again against `creds`. `creds` is threaded in by the caller
    /// (rather than reloaded here) so one `fetchPage` call uses a single
    /// consistent credential snapshot for both auth and URL construction.
    private func ensureValidToken(using creds: ServerCredentials) async throws(NavidromeError) -> NavidromeToken {
        // `resolve`'s own cache-hit check only compares credentials, not
        // expiry — an expired-but-credential-matching cached token must be
        // explicitly invalidated first, or `resolve` would just hand it back
        // again without ever rebuilding.
        if let cached = await tokenCache.peek(matching: creds) {
            if !cached.isExpired() { return cached }
            await tokenCache.invalidate()
        }
        do {
            return try await tokenCache.resolve(using: creds) { try await self.performLogin(using: creds) }
        } catch {
            throw error as? NavidromeError ?? .transport("\(error)")
        }
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

    /// Pinned-credentials variant of the above, for a caller (`LibrarySongIndex`)
    /// that must pin an entire multi-page walk — and its 401 retry — to one
    /// exact snapshot rather than letting each page reload `credentials`
    /// independently, mirroring `SubsonicClient.perform(_:using:)`.
    func paginatedGet<T: Decodable & Sendable>(
        path: String,
        sort: String,
        order: String = "ASC",
        extraQuery: [URLQueryItem] = [],
        pageSize: Int = 500,
        using creds: ServerCredentials,
        as type: T.Type
    ) async throws(NavidromeError) -> [T] {
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
            await tokenCache.invalidate()
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
