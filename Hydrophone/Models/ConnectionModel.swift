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
        if let (_, info) = await verifyForm() { state = .connected(info) }
    }

    /// Test then persist the credentials to the Keychain on success.
    func saveAndConnect() async {
        guard let (candidate, info) = await verifyForm() else { return }
        do {
            try credentials.save(candidate)
            persistTranscodePrefs()
            // Re-scope the artwork cache to the (possibly new) server.
            ArtworkCache.shared.setServer(baseURL: candidate.baseURL)
            state = .connected(info)
            await probeNativeFeatures()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Shared preamble of the two calls above: validate the form fields and
    /// verify them against the server, reporting failures via `state`.
    private func verifyForm() async -> (ServerCredentials, ServerInfo)? {
        guard let candidate = formCredentials() else {
            state = .failed("Enter a valid server address (including http:// or https://).")
            return nil
        }
        state = .connecting
        do {
            return (candidate, try await client.testConnection(candidate))
        } catch {
            state = .failed(error.userMessage)
            return nil
        }
    }

    /// Re-verify already-saved credentials (e.g. at launch).
    func refresh() async {
        guard isConfigured else { state = .unconfigured; return }
        state = .connecting
        do {
            let info = try await client.ping()
            state = .connected(info)
            await probeNativeFeatures()
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// The on/off switch for `nativeFeaturesState`: attempts a real
    /// `NavidromeClient.login()` against the just-verified server and
    /// records whether it succeeded. Called once per successful connect
    /// (`saveAndConnect`/`refresh`), not from `testConnection` — that call
    /// verifies unsaved form credentials, while `login()` always reads the
    /// persisted store, so probing there would check the wrong server.
    private func probeNativeFeatures() async {
        nativeFeaturesState = .checking
        let available: Bool
        do {
            _ = try await navidrome.login()
            nativeFeaturesState = .available
            available = true
        } catch {
            nativeFeaturesState = .unavailable
            available = false
        }
        let waiters = nativeFeatureWaiters
        nativeFeatureWaiters = []
        for waiter in waiters { waiter.resume(returning: available) }
    }

    func disconnect() {
        try? credentials.clear()
        ArtworkCache.shared.setServer(baseURL: nil)
        state = .unconfigured
        nativeFeaturesState = .unknown
    }

    /// Feedback from the last library-scan trigger (shown in Settings).
    private(set) var scanMessage: String?

    /// Ask the server to rescan its music folders. The scan itself runs
    /// server-side and asynchronously; this only kicks it off. On success,
    /// also invalidates the cached native song index (#24) — a rescan can
    /// add, remove, or retag songs, so the next Composers-view open should
    /// rebuild from scratch rather than serve a now-stale in-memory snapshot.
    func startLibraryScan() async {
        scanMessage = "Requesting scan…"
        do {
            let status = try await client.object(.startScan, as: ScanStatus.self)
            let count = status.count.map { " — \($0) items" } ?? ""
            scanMessage = (status.scanning ? "Scanning" : "Scan finished") + count
            await navidrome.invalidateSongIndex()
        } catch {
            scanMessage = error.userMessage
        }
    }

    func persistTranscodePrefs() {
        let defaults = UserDefaults.standard
        defaults.set(transcodeEnabled, forKey: "transcodeEnabled")
        defaults.set(transcodeFormat, forKey: "transcodeFormat")
        defaults.set(transcodeMaxBitRate, forKey: "transcodeMaxBitRate")
    }
}
