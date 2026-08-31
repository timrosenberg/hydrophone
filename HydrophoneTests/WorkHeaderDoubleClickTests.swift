import AppKit
import Testing
@testable import Hydrophone

/// Double-click-a-work-header playback from issue #55: the shared
/// `resolveWorkTracks` ordering, and the `Coordinator` lookups
/// `doubleClicked()` uses to tell a work header apart from a disc header
/// or a track row. `table.clickedRow` isn't settable outside real AppKit
/// mouse tracking, so the actual `doubleAction` firing is live-verified
/// instead (see `docs/PROGRESS.md`).
@MainActor
struct WorkHeaderDoubleClickTests {
    private func song(_ id: String, disc: Int? = nil, track: Int, work: String? = nil, movement: Int? = nil) -> Song {
        var song = Song(id: id, title: id, duration: 100, track: track, discNumber: disc, movementNumber: movement)
        song.work = work
        return song
    }

    private func coordinator(tracks: [Song]) -> MusicTrackTable.Coordinator {
        let coordinator = MusicTrackTable(
            tracks: tracks,
            columns: [.title],
            discHeaders: [:],
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        ).makeCoordinator()
        coordinator.rebuild()
        return coordinator
    }

    @Test func resolveWorkTracksOrdersByMovementFallingBackToTrack() {
        let tracks = [
            song("movement-2", track: 1, work: "Winterreise", movement: 2),
            song("other-work", track: 1, work: "Schwanengesang"),
            song("fallback-3", track: 3, work: "Winterreise"),
            song("movement-1", track: 99, work: "Winterreise", movement: 1)
        ]
        let resolved = resolveWorkTracks(work: "Winterreise", among: tracks)
        #expect(resolved.map(\.id) == ["movement-1", "movement-2", "fallback-3"])
    }

    @Test func resolveWorkTracksIgnoresDisplaySortByOperatingOnTheGivenArray() {
        let natural = [
            song("first", track: 1, work: "Winterreise", movement: 1),
            song("second", track: 2, work: "Winterreise", movement: 2)
        ]
        let reversed = Array(natural.reversed())
        #expect(resolveWorkTracks(work: "Winterreise", among: natural).map(\.id) == ["first", "second"])
        #expect(resolveWorkTracks(work: "Winterreise", among: reversed).map(\.id) == ["first", "second"])
    }

    @Test func workHeaderRowResolvesItsWorkIdentity() {
        let tracks = [
            song("a", track: 1, work: "Winterreise", movement: 1),
            song("b", track: 2, work: "Winterreise", movement: 2),
            song("c", track: 3, work: "Schwanengesang")
        ]
        let coordinator = coordinator(tracks: tracks)
        #expect(coordinator.work(atRow: 0) == "Winterreise")
        #expect(coordinator.trackIndex(atRow: 0) == nil)
        #expect(coordinator.work(atRow: 1) == nil)
        #expect(coordinator.trackIndex(atRow: 1) == 0)
        #expect(coordinator.work(atRow: 3) == "Schwanengesang")
    }

    @Test func discHeaderRowHasNoWorkIdentity() {
        let tracks = [song("a", disc: 1, track: 1), song("b", disc: 2, track: 1)]
        let coordinator = coordinator(tracks: tracks)
        #expect(coordinator.work(atRow: 0) == nil)
        #expect(coordinator.trackIndex(atRow: 0) == nil)
    }

    @Test func multiDiscWorkHeaderStillResolvesTheFoldedInWork() {
        let tracks = [
            song("a", disc: 1, track: 1, work: "Piano Sonata No. 14"),
            song("b", disc: 2, track: 1, work: "Bagatelle No. 25")
        ]
        let coordinator = coordinator(tracks: tracks)
        #expect(coordinator.work(atRow: 0) == "Piano Sonata No. 14")
        #expect(coordinator.work(atRow: 2) == "Bagatelle No. 25")
    }
}
