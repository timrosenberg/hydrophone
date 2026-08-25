import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Hydrophone

/// Optimistic star state in LibraryModel: `isStarred` precedence (override >
/// server truth once loaded > the row's own flag) and rollback when the
/// server refuses a write. Uses an unroutable server so every call fails fast.
@MainActor
struct StarringTests {
    /// SwiftUI schedules offscreen view teardown after the test returns. Retain
    /// the window so teardown cannot race another main-actor test.
    private static var retainedWindows: [NSWindow] = []

    private func offlineLibrary() -> LibraryModel {
        let creds = ServerCredentials(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            username: "u", secret: "s", authMethod: .tokenSalt)
        return LibraryModel(client: SubsonicClient(credentials: InMemoryCredentialStore(creds)),
                           navidrome: NavidromeClient(credentials: InMemoryCredentialStore(creds)),
                           nativeFeaturesAvailable: { false })
    }

    @Test func rowFlagIsTruthUntilStarredListLoads() {
        let library = offlineLibrary()
        #expect(library.isStarred(Song(id: "s1", title: "T", starred: Date())))
        #expect(!library.isStarred(Song(id: "s2", title: "U")))
        #expect(library.isStarred(album: Album(id: "a1", name: "A", starred: Date())))
        #expect(!library.isStarred(album: Album(id: "a2", name: "B")))
    }

    @Test func refusedStarRollsBack() async {
        let library = offlineLibrary()
        let song = Song(id: "s1", title: "T")
        await library.setStarred(true, songIds: ["s1"])
        // The write failed and the reconciling reload failed too — the
        // optimistic override must not survive as pretend-truth.
        #expect(!library.isStarred(song))
    }

    @Test func refusedAlbumStarRollsBack() async {
        let library = offlineLibrary()
        await library.setAlbumStarred(true, albumId: "a1")
        #expect(!library.isStarred(album: Album(id: "a1", name: "A")))
    }

    @Test func starSignatureReflectsOverrideChanges() async {
        let library = offlineLibrary()
        let before = library.starSignature
        // The failed round-trip sets and then rolls back the override; the
        // signature must end up back where it started (same display state).
        await library.setStarred(true, songIds: ["s1"])
        #expect(library.starSignature == before)
    }

    @Test func homeRendersStarredAlbumsWhenLegacyShelvesFail() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomeFavoritesMockProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim", secret: "sesame", authMethod: .tokenSalt
        )
        let store = InMemoryCredentialStore(credentials)
        let library = LibraryModel(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )

        #expect(await library.reloadStarred())
        await library.reloadHome()
        #expect(library.starredAlbums.map(\.id) == ["favorite-album"])
        #expect(!library.homeLoaded)

        let view = HomeView()
            .environment(library)
            .environment(Navigator())
            .frame(width: 700, height: 500)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        Self.retainedWindows.append(window)

        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()

        let contentPixels = nonWhitePixelsInTopRegion(of: host)
        #expect(contentPixels > 50, "Top-region content pixels: \(contentPixels)")
    }

    private func nonWhitePixelsInTopRegion(of view: NSView) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: image)
        let topEnd = Int(image.pixelsHigh * 2 / 5)
        var count = 0
        for yCoord in stride(from: 0, to: topEnd, by: 2) {
            for xCoord in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let color = image.colorAt(x: xCoord, y: yCoord)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 {
                    count += 1
                }
            }
        }
        return count
    }
}

final class HomeFavoritesMockProtocol: URLProtocol, @unchecked Sendable {
    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let status: Int
        let body: Data
        if path.hasSuffix("/rest/getStarred2.view") {
            status = 200
            body = Data("""
                {"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{"album":[
                {"id":"favorite-album","name":"Favorite Album","artist":"Favorite Artist"}]}}}
                """.utf8)
        } else {
            status = 500
            body = Data()
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
