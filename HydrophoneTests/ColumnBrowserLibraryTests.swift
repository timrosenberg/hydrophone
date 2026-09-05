import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct ColumnBrowserLibraryTests {
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
}
