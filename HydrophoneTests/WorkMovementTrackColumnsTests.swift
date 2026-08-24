import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

/// Rendering, sorting, and native-feature gating for issue #46's columns.
@MainActor
struct WorkMovementTrackColumnsTests {
    private func coordinator(tracks: [Song] = []) -> MusicTrackTable.Coordinator {
        MusicTrackTable(
            tracks: tracks,
            columns: [.title],
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        ).makeCoordinator()
    }

    private func sortedIDs(_ songs: [Song], by key: String, ascending: Bool) -> [String] {
        let table = NSTableView()
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        let coordinator = coordinator(tracks: songs)
        coordinator.table = table
        coordinator.tableView(table, sortDescriptorsDidChange: [])
        return coordinator.displayed.map(\.id)
    }

    @Test func columnsExposeRequiredAppKitMetadata() {
        let work = TrackColumn.work.makeTableColumn(sortable: true)
        #expect(work.identifier.rawValue == "work")
        #expect(work.title == "Work")
        #expect(work.headerCell.alignment == .left)

        let movementName = TrackColumn.movementName.makeTableColumn(sortable: true)
        #expect(movementName.identifier.rawValue == "movementName")
        #expect(movementName.title == "Movement Name")
        #expect(movementName.headerCell.alignment == .left)

        let movement = TrackColumn.movement.makeTableColumn(sortable: true)
        #expect(movement.identifier.rawValue == "movement")
        #expect(movement.title == "Movement")
        #expect(movement.headerCell.alignment == .right)
        #expect(movement.maxWidth <= TrackColumn.time.widths.max)
    }

    @Test func pickerOmitsNativeColumnsUntilNativeFeaturesAreAvailable() {
        let unavailable = TrackColumn.pickerColumns(nativeFeaturesAvailable: false)
        #expect(!unavailable.contains(.number))
        #expect(!unavailable.contains(.work))
        #expect(!unavailable.contains(.movementName))
        #expect(!unavailable.contains(.movement))

        let available = TrackColumn.pickerColumns(nativeFeaturesAvailable: true)
        #expect(available.contains(.work))
        #expect(available.contains(.movementName))
        #expect(available.contains(.movement))
    }

    @Test func capabilityTransitionsHideAndRestorePersistedNativeColumns() {
        let persisted: [TrackColumn] = [.title, .work, .movementName, .movement, .artist]

        #expect(TrackColumn.columnsAvailableForCurrentServer(
            persisted,
            nativeFeaturesAvailable: false
        ) == [.title, .artist])
        #expect(TrackColumn.columnsAvailableForCurrentServer(
            persisted,
            nativeFeaturesAvailable: true
        ) == persisted)
    }

    @Test func unavailableEditsPreserveHiddenNativeColumnsForRestoration() {
        let persisted: [TrackColumn] = [.title, .work, .movementName, .movement, .artist]
        let editedVisible: [TrackColumn] = [.artist, .title, .album]

        let merged = TrackColumn.mergingVisibleColumns(
            editedVisible,
            into: persisted,
            nativeFeaturesAvailable: false
        )

        #expect(merged == [.artist, .work, .movementName, .movement, .title, .album])
        #expect(TrackColumn.columnsAvailableForCurrentServer(
            merged,
            nativeFeaturesAvailable: true
        ) == merged)
    }

    @Test func cellsRenderValuesAndRequireCompleteMovementNumbers() {
        let complete = Song(
            id: "complete",
            title: "Complete",
            work: "Symphony No. 3",
            movementName: "Kräftig. Entschieden.",
            movementNumber: 4,
            movementTotal: 14
        )
        let partial = Song(id: "partial", title: "Partial", movementNumber: 4)
        let missing = Song(id: "missing", title: "Missing")
        let coordinator = coordinator()

        #expect(coordinator.pickerOnlyColumnText(id: "work", song: complete) == "Symphony No. 3")
        #expect(coordinator.pickerOnlyColumnText(id: "movementName", song: complete) == "Kräftig. Entschieden.")
        #expect(coordinator.pickerOnlyColumnText(id: "movement", song: complete) == "4 of 14")
        #expect(coordinator.pickerOnlyColumnText(id: "movement", song: partial) == "—")
        #expect(coordinator.pickerOnlyColumnText(id: "work", song: missing) == "—")
        #expect(coordinator.pickerOnlyColumnText(id: "movementName", song: missing) == "—")
        #expect(coordinator.pickerOnlyColumnText(id: "movement", song: missing) == "—")
    }

    @Test func columnsSortBothDirectionsWithMissingMovementNumbersLast() {
        let works = [
            Song(id: "zulu", title: "A", work: "Zulu"),
            Song(id: "alpha", title: "Z", work: "Alpha")
        ]
        #expect(sortedIDs(works, by: "work", ascending: true) == ["alpha", "zulu"])
        #expect(sortedIDs(works, by: "work", ascending: false) == ["zulu", "alpha"])

        let names = [
            Song(id: "finale", title: "A", movementName: "Finale"),
            Song(id: "allegro", title: "Z", movementName: "Allegro")
        ]
        #expect(sortedIDs(names, by: "movementName", ascending: true) == ["allegro", "finale"])
        #expect(sortedIDs(names, by: "movementName", ascending: false) == ["finale", "allegro"])

        let movements = [
            Song(id: "missing", title: "A"),
            Song(id: "four", title: "M", movementNumber: 4),
            Song(id: "one", title: "Z", movementNumber: 1)
        ]
        #expect(sortedIDs(movements, by: "movement", ascending: true) == ["one", "four", "missing"])
        #expect(sortedIDs(movements, by: "movement", ascending: false) == ["four", "one", "missing"])
    }
}
