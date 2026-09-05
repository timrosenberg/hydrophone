import Foundation
import Observation

/// Observable server-connection + authentication state. Backs the Settings
/// window and gates library loading. See docs/02-opensubsonic-api.md.
@MainActor
@Observable
final class ConnectionModel {
    enum State: Equatable {
        case unconfigured
        case connecting
        case connected(ServerInfo)
        case failed(String)
    }

    private(set) var state: State = .unconfigured

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Whether Navidrome's native react-admin API (`NavidromeClient`) is
    /// reachable on the current server — the on/off switch E4/E5's classical-
    /// metadata UI checks before using it. Detected automatically, never a
    /// user-facing toggle: `.unknown` until the first successful Subsonic
    /// connect this session probes it via a real `login()` call; any failure
    /// (network, 401, non-Navidrome server, API-key auth with no password to
    /// log in with) settles on `.unavailable` and the rest of the app is
    /// unaffected. See #26, docs/02-opensubsonic-api.md.
    enum NativeFeaturesState: Equatable {
        case unknown
        case checking
        case available
        case unavailable
    }

    private(set) var nativeFeaturesState: NativeFeaturesState = .unknown
    private var nativeFeatureWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Resolves native availability for consumers that may start loading at
    /// the same time as the launch-time connection refresh. An early caller
    /// starts that refresh itself rather than treating `.unknown` as a final
    /// "unavailable" answer.
    func nativeFeaturesAvailable() async -> Bool {
        switch nativeFeaturesState {
        case .available:
            return true
        case .unavailable:
            return false
        case .checking:
            return await withCheckedContinuation { nativeFeatureWaiters.append($0) }
        case .unknown:
            guard isConfigured else { return false }
            if case .connecting = state {
                while case .connecting = state { await Task.yield() }
                return await nativeFeaturesAvailable()
            }
            await refresh()
            return nativeFeaturesState == .available
        }
    }

    // Editable form fields (bound by the Settings UI).
    var serverAddress: String = ""
    var username: String = ""
    var secret: String = ""
    var authMethod: ServerCredentials.AuthMethod = .tokenSalt

    /// Transcoding preferences (persisted in UserDefaults, applied at stream time).
    var transcodeEnabled: Bool
    var transcodeFormat: String
    var transcodeMaxBitRate: Int

    private let client: SubsonicClient
    private let navidrome: NavidromeClient
    private let credentials: CredentialStore
    @ObservationIgnored private var libraryInvalidationHandler: @MainActor () async -> Void = {}
    private var connectionGeneration = 0
    @ObservationIgnored private var libraryConnectionHandler: @MainActor (ServerCredentials) async -> Void = { _ in }
    @ObservationIgnored private var libraryRescanHandler: (@MainActor (ServerCredentials) async -> Void)?
    @ObservationIgnored private var songsLoadHandler: @MainActor () async -> Void = {}

    init(client: SubsonicClient, navidrome: NavidromeClient, credentials: CredentialStore) {
        self.client = client
        self.navidrome = navidrome
        self.credentials = credentials

        let defaults = UserDefaults.standard
        self.transcodeEnabled = defaults.bool(forKey: "transcodeEnabled")
        self.transcodeFormat = defaults.string(forKey: "transcodeFormat") ?? "mp3"
        self.transcodeMaxBitRate = defaults.integer(forKey: "transcodeMaxBitRate") == 0
            ? 320 : defaults.integer(forKey: "transcodeMaxBitRate")

        if let existing = credentials.load() {
            serverAddress = existing.baseURL.absoluteString
            username = existing.username
            secret = existing.secret
            authMethod = existing.authMethod
            state = .unconfigured // verified lazily via refresh()
        }
    }

    var isConfigured: Bool { credentials.load() != nil }

    /// Composition-root hook that clears every credential-scoped library
    /// collection (Songs, Albums, Artists, Composers, Genres, Favorites, Home,
    /// Playlists)
    /// whenever the credentials, server, or library contents behind them
    /// change — wired to `LibraryModel.reset()`.
    func setLibraryInvalidationHandler(_ handler: @escaping @MainActor () async -> Void) {
        libraryInvalidationHandler = handler
    }

    /// Composition-root hook that starts the complete Songs walk after a
    /// persisted server connection succeeds, including first-time setup and
    /// reconnects that happen after RootView's launch task has already run.
    func setSongsLoadHandler(_ handler: @escaping @MainActor () async -> Void) {
        songsLoadHandler = handler
    }

    func setLibraryConnectionHandler(_ handler: @escaping @MainActor (ServerCredentials) async -> Void) {
        libraryConnectionHandler = handler
    }

    func setLibraryRescanHandler(_ handler: @escaping @MainActor (ServerCredentials) async -> Void) {
        libraryRescanHandler = handler
    }

    private func invalidateLibrary() async {
        await libraryInvalidationHandler()
    }

    /// Build credentials from the current form, or nil if the form is invalid.
    private func formCredentials() -> ServerCredentials? {
        guard let url = Self.normalizedBaseURL(from: serverAddress) else { return nil }
        return ServerCredentials(baseURL: url, username: username, secret: secret, authMethod: authMethod)
    }

    /// Normalize a user-entered server address into a clean API base URL:
    /// assume `https://` when no scheme is given, and drop query/fragment, any
    /// trailing slash, and Navidrome's `/app` web-UI suffix (a common
    /// copy-from-browser mistake that would make requests 404). A legitimate
    /// reverse-proxy subpath (e.g. `/navidrome`) is preserved.
    static func normalizedBaseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var comps = URLComponents(string: text), comps.scheme != nil, comps.host != nil else {
            return nil
        }
        comps.query = nil
        comps.fragment = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/app") { path.removeLast("/app".count) }
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        return comps.url
    }

    /// Verify the current form against the server without persisting.
    func testConnection() async {
        // A form test must not abandon a persisted connection's native probe
        // or the metadata loads waiting on it.
        guard state != .connecting, nativeFeaturesState != .checking else { return }
        let generation = connectionGeneration
        if let (_, info) = await verifyForm(generation: generation), generation == connectionGeneration {
            state = .connected(info)
        }
    }

    /// Verify, persist, then seed before allowing the session's live loads.
    func saveAndConnect() async {
        connectionGeneration += 1
        let generation = connectionGeneration
        settleNativeFeatures(.checking)
        guard let (candidate, info) = await verifyForm(generation: generation),
              generation == connectionGeneration else {
            guard generation == connectionGeneration else { return }
            await invalidateLibrary()
            guard generation == connectionGeneration else { return }
            settleNativeFeatures(.unavailable)
            return
        }
        do {
            try credentials.save(candidate)
            persistTranscodePrefs()
            await completeConnection(candidate, info: info, generation: generation)
        } catch {
            guard generation == connectionGeneration else { return }
            await invalidateLibrary()
            guard generation == connectionGeneration else { return }
            settleNativeFeatures(.unavailable)
            state = .failed(error.localizedDescription)
        }
    }

    private func completeConnection(_ candidate: ServerCredentials, info: ServerInfo, generation: Int) async {
        await invalidateLibrary()
        guard generation == connectionGeneration, credentials.load() == candidate else { return }
        await libraryConnectionHandler(candidate)
        guard generation == connectionGeneration, credentials.load() == candidate else { return }
        ArtworkCache.shared.setServer(baseURL: candidate.baseURL)
        state = .connected(info)
        await probeNativeFeatures(generation: generation)
        guard generation == connectionGeneration else { return }
        await songsLoadHandler()
    }

    /// Shared preamble of the two calls above: validate the form fields and
    /// verify them against the server, reporting failures via `state`.
    private func verifyForm(generation: Int) async -> (ServerCredentials, ServerInfo)? {
        guard let candidate = formCredentials() else {
            state = .failed("Enter a valid server address (including http:// or https://).")
            return nil
        }
        state = .connecting
        do {
            let info = try await client.testConnection(candidate)
            guard generation == connectionGeneration else { return nil }
            return (candidate, info)
        } catch {
            guard generation == connectionGeneration else { return nil }
            state = .failed(error.userMessage)
            return nil
        }
    }

    /// Re-verify already-saved credentials (e.g. at launch).
    func refresh() async {
        connectionGeneration += 1
        let generation = connectionGeneration
        settleNativeFeatures(.checking)
        guard let candidate = credentials.load() else {
            await invalidateLibrary()
            guard generation == connectionGeneration else { return }
            settleNativeFeatures(.unavailable)
            state = .unconfigured
            return
        }
        state = .connecting
        do {
            let info = try await client.testConnection(candidate)
            guard generation == connectionGeneration else { return }
            await completeConnection(candidate, info: info, generation: generation)
        } catch {
            guard generation == connectionGeneration else { return }
            await invalidateLibrary()
            guard generation == connectionGeneration else { return }
            settleNativeFeatures(.unavailable)
            state = .failed(error.userMessage)
        }
    }

    /// The on/off switch for `nativeFeaturesState`: attempts a real
    /// `NavidromeClient.login()` against the just-verified server and
    /// records whether it succeeded. Called once per successful connect
    /// (`saveAndConnect`/`refresh`), not from `testConnection` — that call
    /// verifies unsaved form credentials, while `login()` always reads the
    /// persisted store, so probing there would check the wrong server.
    private func probeNativeFeatures(generation: Int) async {
        let available: Bool
        do {
            _ = try await navidrome.login()
            guard generation == connectionGeneration else { return }
            available = true
        } catch {
            guard generation == connectionGeneration else { return }
            available = false
        }
        settleNativeFeatures(available ? .available : .unavailable)
    }

    private func settleNativeFeatures(_ state: NativeFeaturesState) {
        nativeFeaturesState = state
        guard state != .checking else { return }
        let waiters = nativeFeatureWaiters
        nativeFeatureWaiters = []
        for waiter in waiters { waiter.resume(returning: state == .available) }
    }

    func disconnect() async {
        connectionGeneration += 1
        settleNativeFeatures(.unknown)
        try? credentials.clear()
        await invalidateLibrary()
        ArtworkCache.shared.setServer(baseURL: nil)
        state = .unconfigured
    }

    /// Feedback from the last library-scan trigger (shown in Settings).
    private(set) var scanMessage: String?

    /// Ask the server to rescan its music folders. The scan itself runs
    /// server-side and asynchronously; this only kicks it off. On success,
    /// also invalidates every library projection (#24, #139, #141) — a
    /// rescan can add, remove, or retag songs *and* albums/artists, so every
    /// view should rebuild from scratch rather than serve a now-stale
    /// in-memory snapshot.
    func startLibraryScan() async {
        let generation = connectionGeneration
        guard let candidate = credentials.load() else { return }
        scanMessage = "Requesting scan…"
        do {
            var status = try await client.object(.startScan, using: candidate, as: ScanStatus.self)
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            // Only the persistent path needs a completed server snapshot. Legacy
            // callers retain the previous trigger-and-invalidate behavior.
            while status.scanning, libraryRescanHandler != nil {
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                scanMessage = "Scanning…"
                guard ContinuousClock.now < deadline else {
                    scanMessage = "Server scan is still running. Try refreshing again when it finishes."
                    return
                }
                try await Task.sleep(for: .seconds(1))
                status = try await client.object(.scanStatus, using: candidate, as: ScanStatus.self)
            }
            guard generation == connectionGeneration, credentials.load() == candidate else { return }
            let count = status.count.map { " — \($0) items" } ?? ""
            scanMessage = (status.scanning ? "Scanning" : "Scan finished") + count
            await invalidateLibrary()
            guard generation == connectionGeneration else { return }
            await libraryRescanHandler?(candidate)
        } catch {
            guard generation == connectionGeneration else { return }
            scanMessage = (error as? SubsonicError)?.userMessage ?? error.localizedDescription
        }
    }

    func persistTranscodePrefs() {
        let defaults = UserDefaults.standard
        defaults.set(transcodeEnabled, forKey: "transcodeEnabled")
        defaults.set(transcodeFormat, forKey: "transcodeFormat")
        defaults.set(transcodeMaxBitRate, forKey: "transcodeMaxBitRate")
    }
}
