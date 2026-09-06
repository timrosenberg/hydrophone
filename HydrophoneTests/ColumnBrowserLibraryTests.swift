import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct ColumnBrowserLibraryTests {
    @Test func canceledInitialWalkCannotStrandTheReplacementGenre() async throws {
        await BrowserLibraryProtocol.state.reset(holdFirstSearch: true)
        let fixture = BrowserLibraryFixture()
        defer {
            fixture.close()
            Task { await BrowserLibraryProtocol.state.releaseFirstSearch() }
        }
        await fixture.library.loadGenresIfNeeded()
        fixture.show()
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.searchRequests == 1 }
        try fixture.click(pane: 0, row: 2)
        try await fixture.waitForTracks(1)
        #expect(fixture.displayed.map(\.id) == ["jazz"])
        await BrowserLibraryProtocol.state.releaseFirstSearch()
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.firstSearchResumed }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.displayed.map(\.id) == ["jazz"])
    }

    @Test func selectedGenreReloadsAfterSessionResetWithoutAnotherClick() async throws {
        await BrowserLibraryProtocol.state.reset(holdFirstGenre: true)
        let fixture = BrowserLibraryFixture()
        defer {
            fixture.close()
            Task { await BrowserLibraryProtocol.state.releaseFirstGenre() }
        }
        fixture.show()
        try await fixture.waitForTracks(1_003)
        try fixture.click(pane: 0, row: 1)
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.classicalRequests == 1 }
        await fixture.library.reset()
        try await fixture.waitForTracks(2)
        #expect(fixture.defaults.string(forKey: "browser.genre") == "Classical")
        await BrowserLibraryProtocol.state.releaseFirstGenre()
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.firstGenreDelivered }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.displayed.map(\.id) == ["new-0", "new-1"])
    }

    @Test func browserFixtureDoesNotReplaceSharedArtworkClient() {
        let original = ArtworkCache.shared.clientBox
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        #expect(ArtworkCache.shared.clientBox === original)
    }

    // Catches returning to a sampled base or deriving panes only from page one.
    @Test func completeLibraryIncludesLateArtistsAlbumsAndAllComposerTracks() async throws {
        await BrowserLibraryProtocol.state.reset()
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        fixture.show()
        try await fixture.waitForTracks(1_003)
        #expect(fixture.panes.map(\.numberOfRows) == [3, 3, 3, 3])

        // Late metadata appears only after the first 500-song page.
        try fixture.click(pane: 3, row: 1)
        try await fixture.waitForTracks(503)
        #expect(fixture.displayed.allSatisfy { $0.displayComposer == "Late Composer" })
        #expect(Set(fixture.displayed.map(\.id)).count == 503)

        // The actual binding setters, not a test copy of the cascade.
        try fixture.click(pane: 1, row: 2)
        try await fixture.waitForTracks(500)
        #expect(fixture.defaults.string(forKey: "browser.composer") == "")
        #expect(fixture.defaults.string(forKey: "browser.album") == "")
        try fixture.click(pane: 2, row: 1)
        try fixture.click(pane: 3, row: 1)
        try fixture.click(pane: 2, row: 0)
        try await fixture.waitUntil { fixture.defaults.string(forKey: "browser.composer") == "" }
        try fixture.click(pane: 0, row: 1)
        try await fixture.waitForTracks(1_003)
        for key in ["artist", "album", "composer"] {
            #expect(fixture.defaults.string(forKey: "browser.\(key)") == "")
        }
    }

    // Catches restore accidentally passing through cascading setters, or
    // genre pagination being lost between the API and the rendered browser.
    @Test func restoredGenreAndDownstreamSelectionsSurviveARecreatedView() async throws {
        await BrowserLibraryProtocol.state.reset()
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        fixture.defaults.set("Classical", forKey: "browser.genre")
        fixture.defaults.set("Late Artist", forKey: "browser.artist")
        fixture.defaults.set("Late Album", forKey: "browser.album")
        fixture.defaults.set("Late Composer", forKey: "browser.composer")
        fixture.show()
        try await fixture.waitForTracks(503)
        #expect(fixture.panes.map(\.selectedRow) == [1, 1, 1, 1])
        fixture.show()
        try await fixture.waitForTracks(503)
        #expect(fixture.panes.map(\.selectedRow) == [1, 1, 1, 1])
        #expect(fixture.displayed.first?.id == "song-500")
        #expect(fixture.displayed.last?.id == "song-1002")
    }

    // Catches the A -> B -> A hole in a guard comparing only the genre name.
    @Test func olderGenreResponseCannotReplaceANewerRequestForTheSameGenre() async throws {
        await BrowserLibraryProtocol.state.reset(holdFirstGenre: true)
        let fixture = BrowserLibraryFixture()
        defer {
            fixture.close()
            Task { await BrowserLibraryProtocol.state.releaseFirstGenre() }
        }
        fixture.show()
        try await fixture.waitForTracks(1_003)
        try fixture.click(pane: 0, row: 1)
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.classicalRequests == 1 }
        try fixture.click(pane: 0, row: 2)
        try await fixture.waitForTracks(1)
        #expect(fixture.displayed.first?.id == "jazz")
        try fixture.click(pane: 0, row: 1)
        try await fixture.waitForTracks(2)
        await BrowserLibraryProtocol.state.releaseFirstGenre()
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.firstGenreDelivered }
        // Drain the response and SwiftUI update, then verify the latest rows.
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.displayed.map(\.id) == ["new-0", "new-1"])
    }

    @Test func allGenresDismissesAnOutstandingGenreRequest() async throws {
        await BrowserLibraryProtocol.state.reset(holdFirstGenre: true)
        let fixture = BrowserLibraryFixture()
        defer {
            fixture.close()
            Task { await BrowserLibraryProtocol.state.releaseFirstGenre() }
        }
        fixture.show()
        try await fixture.waitForTracks(1_003)
        try fixture.click(pane: 0, row: 1)
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.classicalRequests == 1 }
        try fixture.click(pane: 0, row: 0)
        try await fixture.waitForTracks(1_003)
        await BrowserLibraryProtocol.state.releaseFirstGenre()
        try await fixture.waitUntil { await BrowserLibraryProtocol.state.firstGenreDelivered }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.displayed.count == 1_003)
    }

    // Uses the real rendered view; timing is diagnostic, not a flaky CI limit.
    @Test func fullSizeBrowserRendersAndFiltersFourteenThousandSongs() async throws {
        await BrowserLibraryProtocol.state.reset()
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        fixture.library.songs = (0..<14_082).map { index in
            Song(id: "large-\(index)", title: String(format: "Track %05d", index),
                 artist: "Artist \(index % 700)", album: "Album \(index % 1_400)",
                 displayComposer: "Composer \(index % 20)")
        }
        let start = ContinuousClock.now
        fixture.show()
        try await fixture.waitForTracks(14_082)
        let rendered = ContinuousClock.now
        #expect(fixture.panes.map(\.numberOfRows) == [3, 701, 1_401, 21])
        try fixture.click(pane: 3, row: 1)
        try await fixture.waitForTracks(705)
        #expect(fixture.displayed.allSatisfy { $0.displayComposer == "Composer 0" })
        print("Browser 14082: initial=\(start.duration(to: rendered)), composer-click=\(rendered.duration(to: .now))")
    }

    // #145: same scale/cardinality as the test above, but with realistic
    // Unicode-heavy metadata (diacritics, mixed scripts) standing in for its
    // plain-ASCII synthetic titles — the classical/international repertoire
    // this fork treats as a first-class browsing axis
    // (docs/00-fork-divergence.md). `localizedCaseInsensitiveCompare`'s ICU
    // collation is markedly more expensive on non-ASCII text; this is the
    // scenario that actually reproduces the reported click-to-render lag
    // (#145's investigation measured the *comparator alone* at ~15ms for
    // ASCII vs. ~410ms here, on the same 14,082-row scale). Diagnostic only,
    // matching this file's existing convention — not a CI-gating threshold.
    @Test func fullSizeBrowserRendersWithUnicodeHeavyMetadata() async throws {
        await BrowserLibraryProtocol.state.reset()
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        let titleRoots = [
            "Symphonie fantastique, Op. 14: I. Rêveries — Passions",
            "Клавирные сочинения: Прелюдия и фуга № 2",
            "交響曲第9番ニ短調作品125《合唱》",
            "Étude en forme de Valse, Op. 52 No. 6",
            "細川俊夫: 嘆き（オーケストラのための）"
        ]
        let artistRoots = ["Дмитрий Шостакович", "細川俊夫", "Krzysztof Pęderecki", "Éliane Radigue", "Kaija Saariaho"]
        let albumRoots = ["Sinfonía núm. 5 — Édition intégrale", "楽興の時", "Études-Tableaux, Vol. II", "Пиковая дама"]
        fixture.library.songs = (0..<14_082).map { index in
            Song(id: "large-\(index)",
                 title: "\(titleRoots[index % titleRoots.count]) — \(String(format: "%05d", index))",
                 artist: "\(artistRoots[index % artistRoots.count]) \(index % 700)",
                 album: "\(albumRoots[index % albumRoots.count]) \(index % 1_400)",
                 displayComposer: "Composer \(index % 20)")
        }
        let start = ContinuousClock.now
        fixture.show()
        try await fixture.waitForTracks(14_082)
        let rendered = ContinuousClock.now
        #expect(fixture.panes.map(\.numberOfRows) == [3, 701, 1_401, 21])
        print("Browser 14082 (Unicode-heavy metadata): initial=\(start.duration(to: rendered))")
    }

    // #161: artists/albums/composers/filteredTracks are memoized (process-wide,
    // keyed by content + exactly the selections each one depends on) so they
    // don't rescan the library on every `body` re-evaluation. These prove the
    // cache actually hits/invalidates correctly, via the compute-count
    // counters (mirroring #157's `sortComputeCount` pattern) rather than a
    // flaky timing assertion.
    @Test func selectionChangeInvalidatesOnlyItsDependents() async throws {
        await BrowserLibraryProtocol.state.reset()
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        fixture.library.songs = (0..<200).map { index in
            Song(id: "song-\(index)", title: "Track \(index)",
                 artist: "Artist \(index % 10)", album: "Album \(index % 20)",
                 displayComposer: "Composer \(index % 4)")
        }
        fixture.show()
        try await fixture.waitForTracks(200)

        let artistsBefore = ColumnBrowserView.artistsComputeCount
        let albumsBefore = ColumnBrowserView.albumsComputeCount
        let composersBefore = ColumnBrowserView.composersComputeCount
        let tracksBefore = ColumnBrowserView.filteredTracksComputeCount

        // Select an artist (pane 1, row 1 = "Artist 0"): narrows
        // album/composer/tracks, but `artists` never looks at the artist
        // selection, so it shouldn't recompute.
        try fixture.click(pane: 1, row: 1)
        try await fixture.waitForTracks(20)

        #expect(ColumnBrowserView.artistsComputeCount == artistsBefore)
        #expect(ColumnBrowserView.albumsComputeCount == albumsBefore + 1)
        #expect(ColumnBrowserView.composersComputeCount == composersBefore + 1)
        #expect(ColumnBrowserView.filteredTracksComputeCount == tracksBefore + 1)
    }
}
