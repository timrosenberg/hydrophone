import AppKit
import Testing
@testable import Hydrophone

/// Work-level context-menu behavior from issue #48.
@MainActor
struct TrackTableWorkMenuTests {
    private func song(
        _ id: String,
        work: String? = "Schwanengesang, D. 957",
        movement: Int? = nil,
        track: Int? = nil
    ) -> Song {
        Song(id: id, title: id, track: track, work: work, movementNumber: movement)
    }

    private func perform(_ item: NSMenuItem?) {
        guard let item, let action = item.action else {
            Issue.record("Expected an actionable menu item")
            return
        }
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
    }

    @Test func workSubmenuFiltersAndOrdersMovementsForBothActions() {
        let clicked = song("movement-2", movement: 2, track: 1)
        let tracks = [
            clicked,
            song("other-work", work: "Winterreise", movement: 1, track: 1),
            song("fallback-3", movement: nil, track: 3),
            song("movement-1", movement: 1, track: 99)
        ]
        var playedIDs: [String] = []
        var startIndex: Int?
        var enqueuedIDs: [String] = []

        let item = makeWorkMenuItem(
            for: clicked,
            among: tracks,
            onPlay: { songs, index in
                playedIDs = songs.map(\.id)
                startIndex = index
            },
            onEnqueue: { enqueuedIDs = $0.map(\.id) }
        )

        #expect(item?.title == "Schwanengesang, D. 957")
        #expect(item?.submenu?.items.map(\.title) == ["Play Work", "Add Work to Up Next"])

        perform(item?.submenu?.items[0])
        #expect(playedIDs == ["movement-1", "movement-2", "fallback-3"])
        #expect(startIndex == 0)

        perform(item?.submenu?.items[1])
        #expect(enqueuedIDs == ["movement-1", "movement-2", "fallback-3"])
    }

    @Test func songWithoutWorkHasNoWorkSubmenu() {
        let untagged = song("untagged", work: nil, track: 1)

        let item = makeWorkMenuItem(
            for: untagged,
            among: [untagged],
            onPlay: { _, _ in },
            onEnqueue: { _ in }
        )

        #expect(item == nil)
    }
}
