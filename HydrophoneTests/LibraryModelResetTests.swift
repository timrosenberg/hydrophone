import Foundation
import Testing
@testable import Hydrophone

/// Regression coverage for the gap #139 found and #140/#141 fixed:
/// `LibraryModel.reset()` already cleared every credential-scoped collection
/// (not just Songs), but was never wired to `ConnectionModel`'s disconnect/
/// credential-change hook — so switching servers left the previous server's
/// Albums/Artists/Composers/Genres/Favorites/Home visible until each
/// collection happened to reload some other way. `AppModel` now wires the
/// hook to `reset()` directly. This test covers Favorites and Home — the two
/// collections with genuinely settable state to arrange from a test without
/// a network round trip; `libraryModelResetClearsComposerRosterAndLoadState`
/// (`NavidromeComposerLibraryModelTests.swift`) already proves the identical
/// pattern via a real mocked fetch for Composers, and Artists/Genres share
/// that exact shape (a single `private(set)` array unconditionally cleared
/// in `reset()`'s body) closely enough that a third near-duplicate test
/// wouldn't add coverage `reset()`'s visible ~15-line body doesn't already
/// make obvious.
@MainActor
@Suite(.serialized)
struct LibraryModelResetTests {
    private func makeLibrary() -> LibraryModel {
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim", secret: "sesame", authMethod: .tokenSalt
        )
        let store = InMemoryCredentialStore(credentials)
        return LibraryModel(
            client: SubsonicClient(credentials: store),
            navidrome: NavidromeClient(credentials: store),
            nativeFeaturesAvailable: { false }
        )
    }

    @Test func resetClearsFavoritesAndHomeNotJustSongs() async {
        let library = makeLibrary()

        // Simulate Favorites and Home having already loaded, the way a
        // session on the previous server would leave them, without needing a
        // live network round trip — `reset()`'s completeness is what this
        // test verifies, not the fetch itself (covered elsewhere).
        library.starredSongs = [Song(id: "s1", title: "Song One")]
        library.starredAlbums = [Album(id: "al1", name: "Album One")]
        library.starredSongIDs = ["s1"]
        library.homeNewest = [Album(id: "al2", name: "Newest")]
        library.homeRecent = [Album(id: "al3", name: "Recent")]
        library.homeFrequent = [Album(id: "al4", name: "Frequent")]
        library.homeRandom = [Album(id: "al5", name: "Random")]
        library.homeLoaded = true

        let generationBeforeReset = library.librarySessionGeneration

        await library.reset()

        #expect(library.starredSongs.isEmpty)
        #expect(library.starredAlbums.isEmpty)
        #expect(library.starredSongIDs.isEmpty)
        #expect(library.homeNewest.isEmpty)
        #expect(library.homeRecent.isEmpty)
        #expect(library.homeFrequent.isEmpty)
        #expect(library.homeRandom.isEmpty)
        #expect(!library.homeLoaded)
        // The generation bump is what protects an in-flight fetch (started
        // before reset) from repopulating any of the above after the fact —
        // the same mechanism `CredentialScopedCacheTests` exercises for the
        // actor-based caches, and `SubsonicAllSongsTests
        // .invalidatedLibraryLoadCannotPublishItsStaleCompletion` already
        // proves end-to-end for Songs specifically.
        #expect(library.librarySessionGeneration != generationBeforeReset)
    }
}
