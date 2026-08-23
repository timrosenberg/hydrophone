import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

/// Rendering and sort behavior for the expanded track columns from issue #35.
@MainActor
struct ExpandedTrackColumnsTests {
    private func sortedIDs(_ songs: [Song], by key: String, ascending: Bool) -> [String] {
        let table = NSTableView()
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        let parent = MusicTrackTable(
            tracks: songs,
            columns: [.title],
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        )
        let coordinator = parent.makeCoordinator()
        coordinator.table = table
        coordinator.tableView(table, sortDescriptorsDidChange: [])
        return coordinator.displayed.map(\.id)
    }

    @Test func missingDatesAndNumbersSortLastInBothDirections() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        let created = [
            Song(id: "missing", title: "Missing"),
            Song(id: "later", title: "Later", created: later),
            Song(id: "earlier", title: "Earlier", created: earlier)
        ]
        #expect(sortedIDs(created, by: "dateAdded", ascending: true) == ["earlier", "later", "missing"])
        #expect(sortedIDs(created, by: "dateAdded", ascending: false) == ["later", "earlier", "missing"])

        let played = [
            Song(id: "missing", title: "Missing"),
            Song(id: "later", title: "Later", played: later),
            Song(id: "earlier", title: "Earlier", played: earlier)
        ]
        #expect(sortedIDs(played, by: "lastPlayed", ascending: true) == ["earlier", "later", "missing"])
        #expect(sortedIDs(played, by: "lastPlayed", ascending: false) == ["later", "earlier", "missing"])

        let plays = [
            Song(id: "missing", title: "Missing"),
            Song(id: "high", title: "High", playCount: 20),
            Song(id: "low", title: "Low", playCount: 5)
        ]
        #expect(sortedIDs(plays, by: "plays", ascending: true) == ["low", "high", "missing"])
        #expect(sortedIDs(plays, by: "plays", ascending: false) == ["high", "low", "missing"])

        let sampleRates = [
            Song(id: "missing", title: "Missing"),
            Song(id: "high", title: "High", samplingRate: 96_000),
            Song(id: "low", title: "Low", samplingRate: 44_100)
        ]
        #expect(sortedIDs(sampleRates, by: "sampleRate", ascending: true) == ["low", "high", "missing"])
        #expect(sortedIDs(sampleRates, by: "sampleRate", ascending: false) == ["high", "low", "missing"])
    }
}
