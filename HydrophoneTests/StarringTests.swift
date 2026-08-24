import Testing
import Foundation
@testable import Hydrophone

/// Optimistic star state in LibraryModel: `isStarred` precedence (override >
/// server truth once loaded > the row's own flag) and rollback when the
/// server refuses a write. Uses an unroutable server so every call fails fast.
@MainActor
struct StarringTests {
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
}
