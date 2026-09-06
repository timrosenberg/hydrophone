import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct ArtworkLifecycleTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func visiblePlaceholderRecoversAfterTheCacheExhaustsItsRetry() async throws {
        try await withFixture { fixture in
            fixture.protocolState.configure("recover", succeedsAt: 3, heldAttempts: [3])
            let hosted = host(
                ArtworkView(coverArt: "recover", cacheKey: "album:recover", size: 80,
                            cache: fixture.cache, recoveryDelay: .zero)
            )
            try await waitUntil("third request starts") {
                fixture.protocolState.count(for: "recover") == 3
            }
            let placeholder = snapshot(hosted.view)
            #expect(fixture.cache.cachedVariant(key: "album:recover") == nil)
            fixture.protocolState.completeHeld(id: "recover")

            try await waitUntil("third request completes") {
                fixture.cache.cachedVariant(key: "album:recover") != nil
            }
            try await waitUntil("completed recovery renders artwork") {
                snapshot(hosted.view) != placeholder
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.protocolState.count(for: "recover") == 3)
            await close(hosted.window)
        }
    }

    @Test func visibleTerminalFailureObservesALaterPrefetchCompletion() async throws {
        try await withFixture { fixture in
            fixture.protocolState.configure("late-prefetch", succeedsAt: 5, heldAttempts: [5])
            let hosted = host(
                ArtworkView(coverArt: "late-prefetch", cacheKey: "album:late", size: 80,
                            cache: fixture.cache, recoveryDelay: .zero)
            )

            try await waitUntil("bounded visible attempts finish") {
                fixture.protocolState.count(for: "late-prefetch") == 4
            }
            let placeholder = snapshot(hosted.view)
            fixture.cache.prefetch([
                .init(coverArt: "late-prefetch", cacheKey: "album:late", size: 160)
            ])

            try await waitUntil("prefetch request starts") {
                fixture.protocolState.count(for: "late-prefetch") == 5
            }
            #expect(fixture.cache.cachedVariant(key: "album:late") == nil)
            fixture.protocolState.completeHeld(id: "late-prefetch")
            try await waitUntil("prefetch completion reaches the cache") {
                fixture.cache.cachedVariant(key: "album:late") != nil
            }
            try await waitUntil("prefetch completion reaches the mounted view") {
                snapshot(hosted.view) != placeholder
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.protocolState.count(for: "late-prefetch") == 5)
            await close(hosted.window)
        }
    }

    @Test func sameCacheIdentityRestartsForMissingAndChangedFetchIDs() async throws {
        try await withFixture { fixture in
            let input = ArtworkInput()
            let hosted = host(ArtworkInputHarness(input: input, cache: fixture.cache))

            input.coverArt = "first"
            try await waitUntil("nil to value starts loading") {
                fixture.protocolState.ids == ["first"]
            }
            input.coverArt = "second"
            try await waitUntil("changed fetch id restarts loading") {
                fixture.protocolState.ids == ["first", "second"]
            }

            await close(hosted.window)
        }
    }

    @Test func lateCompletionCannotReplaceAReusedViewsNewArtwork() async throws {
        try await withFixture { fixture in
            fixture.protocolState.configure("held-old", heldAttempts: [1])
            let input = ArtworkInput(coverArt: "held-old")
            let hosted = host(ArtworkInputHarness(input: input, cache: fixture.cache))

            try await waitUntil("old request starts") {
                fixture.protocolState.ids == ["held-old"]
            }
            input.coverArt = "new"
            try await waitUntil("new request finishes") {
                fixture.protocolState.ids == ["held-old", "new"]
                    && fixture.cache.cachedVariant(key: "album:stable") != nil
            }
            let current = try #require(fixture.cache.cachedVariant(key: "album:stable"))
            let currentRendering = snapshot(hosted.view)

            fixture.protocolState.completeHeld(id: "held-old")
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.cache.cachedVariant(key: "album:stable") === current)
            #expect(snapshot(hosted.view) == currentRendering)
            #expect(fixture.protocolState.ids == ["held-old", "new"])
            await close(hosted.window)
        }
    }

    @Test func lateRetiredFetchCannotOverwriteCurrentDiskArtwork() async throws {
        try await withFixture { fixture in
            fixture.protocolState.configure("held-old", heldAttempts: [1])
            let oldRequest = try #require(fixture.cache.request(
                coverArt: "held-old", cacheKey: "album:stable", size: 160
            ))
            let oldTask = Task { await fixture.cache.image(for: oldRequest) }
            try await waitUntil("old disk request starts") {
                fixture.protocolState.ids == ["held-old"]
            }

            let newRequest = try #require(fixture.cache.request(
                coverArt: "new", cacheKey: "album:stable", size: 160,
                refreshingCacheIdentity: true
            ))
            #expect(isBlue(await fixture.cache.image(for: newRequest)))
            fixture.protocolState.completeHeld(id: "held-old")
            #expect(await oldTask.value == nil)

            fixture.cache.purge()
            let diskReload = await fixture.cache.image(
                coverArt: "new", cacheKey: "album:stable", size: 160
            )
            #expect(isBlue(diskReload))
            #expect(fixture.protocolState.ids == ["held-old", "new"])
        }
    }

    @Test func sameServerSessionChangeRetiresAndRestartsVisibleDemand() async throws {
        try await withFixture { fixture in
            fixture.protocolState.configure("session-art", heldAttempts: [1])
            let hosted = host(
                ArtworkView(coverArt: "session-art", cacheKey: "album:session", size: 80,
                            cache: fixture.cache, recoveryDelay: .zero)
            )
            let placeholder = snapshot(hosted.view)
            try await waitUntil("first session request starts") {
                fixture.protocolState.count(for: "session-art") == 1
            }

            fixture.cache.setServer(baseURL: fixture.baseURL)
            try await waitUntil("new session request renders") {
                fixture.protocolState.count(for: "session-art") == 2
                    && snapshot(hosted.view) != placeholder
            }

            fixture.protocolState.completeHeld(id: "session-art")
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.protocolState.count(for: "session-art") == 2)
            await close(hosted.window)
        }
    }

    @Test func twoVisibleConsumersJoinPrefetchAndBothRenderItsCompletion() async throws {
        try await withFixture { fixture in
            fixture.protocolState.configure("held-shared", heldAttempts: [1])
            fixture.cache.prefetch([
                .init(coverArt: "held-shared", cacheKey: "album:shared", size: 160)
            ])
            try await waitUntil("prefetch starts") {
                fixture.protocolState.count(for: "held-shared") == 1
            }

            let first = host(
                ArtworkView(coverArt: "held-shared", cacheKey: "album:shared", size: 80,
                            cache: fixture.cache, recoveryDelay: .zero)
            )
            let second = host(
                ArtworkView(coverArt: "held-shared", cacheKey: "album:shared", size: 80,
                            cache: fixture.cache, recoveryDelay: .zero)
            )
            let firstPlaceholder = snapshot(first.view)
            let secondPlaceholder = snapshot(second.view)

            fixture.protocolState.completeHeld(id: "held-shared")
            try await waitUntil("both joined consumers render") {
                snapshot(first.view) != firstPlaceholder
                    && snapshot(second.view) != secondPlaceholder
            }
            #expect(fixture.protocolState.count(for: "held-shared") == 1)
            await close(first.window)
            await close(second.window)
        }
    }

    private func withFixture(
        _ body: (ArtworkLifecycleFixture) async throws -> Void
    ) async throws {
        let fixture = ArtworkLifecycleFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.finish()
            throw error
        }
        await fixture.finish()
    }

    private func host<V: View>(_ rootView: V) -> (window: NSWindow, view: NSHostingView<V>) {
        let view = NSHostingView(rootView: rootView)
        view.frame = NSRect(x: 0, y: 0, width: 80, height: 80)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func snapshot(_ view: NSView) -> Data {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Data() }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    private func isBlue(_ image: NSImage?) -> Bool {
        guard let data = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
        return color.blueComponent > color.redComponent
    }

    private func close(_ window: NSWindow) async {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for \(description)")
    }
}

@MainActor
@Observable
private final class ArtworkInput {
    var coverArt: String?

    init(coverArt: String? = nil) {
        self.coverArt = coverArt
    }
}

private struct ArtworkInputHarness: View {
    let input: ArtworkInput
    let cache: ArtworkCache

    var body: some View {
        ArtworkView(coverArt: input.coverArt, cacheKey: "album:stable", size: 80,
                    cache: cache, recoveryDelay: .zero)
    }
}

@MainActor
private final class ArtworkLifecycleFixture {
    let baseURL = URL(string: "https://artwork.example.com")!
    let protocolState = ArtworkLifecycleProtocol.state
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session: URLSession
    private var ownedCache: ArtworkCache?
    var cache: ArtworkCache { ownedCache! }

    init() {
        protocolState.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkLifecycleProtocol.self]
        session = URLSession(configuration: configuration)
        ownedCache = ArtworkCache(session: session, directory: directory, failureRetryDelay: .zero)
        let credentials = ServerCredentials(baseURL: baseURL, username: "u", secret: "s",
                                            authMethod: .tokenSalt)
        cache.clientBox = ClientBox(SubsonicClient(credentials: InMemoryCredentialStore(credentials)))
        cache.setServer(baseURL: baseURL)
    }

    func finish() async {
        cache.prefetch([])
        protocolState.completeAllHeld()
        let drainingCache = WeakArtworkCache(ownedCache)
        ownedCache = nil
        for _ in 0..<500 {
            if drainingCache.value == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(drainingCache.value == nil, "Artwork lifecycle work must drain before teardown")
        guard drainingCache.value == nil else { return }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class WeakArtworkCache {
    weak var value: ArtworkCache?

    init(_ value: ArtworkCache?) {
        self.value = value
    }
}

private struct ArtworkLifecycleRule {
    var succeedsAt = 1
    var heldAttempts: Set<Int> = []
}

private enum ArtworkLifecycleAction {
    case succeed
    case fail
    case hold
}

private final class ArtworkLifecycleProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var rules: [String: ArtworkLifecycleRule] = [:]
        private var started: [String] = []
        private var held: [String: [ArtworkLifecycleProtocol]] = [:]

        var ids: [String] { lock.withLock { started } }

        func reset() {
            lock.withLock {
                rules = [:]
                started = []
                held = [:]
            }
        }

        func configure(_ id: String, succeedsAt: Int = 1, heldAttempts: Set<Int> = []) {
            lock.withLock {
                rules[id] = ArtworkLifecycleRule(succeedsAt: succeedsAt, heldAttempts: heldAttempts)
            }
        }

        func count(for id: String) -> Int {
            lock.withLock { started.count(where: { $0 == id }) }
        }

        func begin(_ request: ArtworkLifecycleProtocol, id: String) -> ArtworkLifecycleAction {
            lock.withLock {
                started.append(id)
                let attempt = started.count(where: { $0 == id })
                let rule = rules[id] ?? ArtworkLifecycleRule()
                if rule.heldAttempts.contains(attempt) {
                    held[id, default: []].append(request)
                    return .hold
                }
                return attempt >= rule.succeedsAt ? .succeed : .fail
            }
        }

        func completeHeld(id: String) {
            let requests = lock.withLock { held.removeValue(forKey: id) ?? [] }
            requests.forEach { $0.complete() }
        }

        func completeAllHeld() {
            let requests = lock.withLock {
                let requests = held.values.flatMap { $0 }
                held = [:]
                return requests
            }
            requests.forEach { $0.complete() }
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value ?? "missing"
        switch Self.state.begin(self, id: id) {
        case .succeed:
            complete()
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .hold:
            break
        }
    }

    override func stopLoading() {}

    func complete() {
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value
        let oldArtwork = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAADhl"
            + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAqADAAQAAAAB"
            + "AAAAAgAAAADO0J6QAAAAE0lEQVQIHWP8z8AARAwMTCACBAAfFwICa0Cb+wAAAABJRU5ErkJggg=="
        let currentArtwork = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAADhl"
            + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAqADAAQAAAAB"
            + "AAAAAgAAAADO0J6QAAAAFElEQVQIHWNkYPj/nwEImEAECAAAHRkCAlI8MnoAAAAASUVORK5CYII="
        let encoded = id == "held-old"
            ? oldArtwork
            : currentArtwork
        let data = Data(base64Encoded: encoded)!
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "image/png",
                                                          expectedContentLength: data.count,
                                                          textEncodingName: nil),
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
