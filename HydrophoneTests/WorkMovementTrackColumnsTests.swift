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
            Song(id: "partial", title: "P", movementNumber: 2),
            Song(id: "four", title: "M", movementNumber: 4, movementTotal: 14),
            Song(id: "one", title: "Z", movementNumber: 1, movementTotal: 14)
        ]
        // "partial" has a number but no total — it displays "—" just like
        // "missing", so it must sort last alongside it, not by its number.
        #expect(sortedIDs(movements, by: "movement", ascending: true) == ["one", "four", "missing", "partial"])
        #expect(sortedIDs(movements, by: "movement", ascending: false) == ["four", "one", "missing", "partial"])
    }

    // MARK: - Issue #54: Title-column movement text under a work header

    @Test func romanNumeralsConvertKnownValues() {
        #expect(WorkMovementTitle.roman(1) == "I")
        #expect(WorkMovementTitle.roman(3) == "III")
        #expect(WorkMovementTitle.roman(4) == "IV")
        #expect(WorkMovementTitle.roman(9) == "IX")
        #expect(WorkMovementTitle.roman(13) == "XIII")
        #expect(WorkMovementTitle.roman(14) == "XIV")
        #expect(WorkMovementTitle.roman(39) == "XXXIX")
    }

    @Test func rule1UsesMovementNumberAndMovementName() {
        let song = Song(id: "s", title: "Der Doppelgänger", work: "Schwanengesang",
                         movementName: "Der Doppelgänger", movementNumber: 13)
        #expect(WorkMovementTitle.title(for: song) == "XIII. Der Doppelgänger")
    }

    @Test func rule1FallsBackToStrippedTitleWhenMovementNameIsNil() {
        let song = Song(id: "s", title: "Three Love Songs I. Kurai michi (A Dark Road)",
                         work: "Three Love Songs", movementNumber: 1)
        #expect(WorkMovementTitle.title(for: song) == "I. Kurai michi (A Dark Road)")
    }

    @Test func rule1GuardsAgainstDoubleNumberingWhenStrippedTitleAlreadyHasANumeral() {
        // The tagger's own "I." in the stripped title must not get a second
        // "I." prefixed just because `movementNumber` is also tagged.
        let song = Song(id: "s", title: "Two Poems By Ryokan I. Awayuki No... (Light Snow)",
                         work: "Two Poems By Ryokan", movementNumber: 1)
        #expect(WorkMovementTitle.title(for: song) == "I. Awayuki No... (Light Snow)")
    }

    @Test func rule2StripsTheWorkPrefixAndSeparatingPunctuation() {
        let song = Song(id: "s", title: "Two Poems By Ryokan II. Interlude", work: "Two Poems By Ryokan")
        #expect(WorkMovementTitle.title(for: song) == "II. Interlude")
    }

    @Test func rule3UsesBareMovementNameWhenTitleDoesNotStartWithWork() {
        let song = Song(id: "s", title: "First Eclogue After Epos Among Ainu Races",
                         work: "Some Other Work", movementName: "Interlude")
        #expect(WorkMovementTitle.title(for: song) == "Interlude")
    }

    @Test func rule4LeavesTitleUnchangedWithNoMovementMetadata() {
        let song = Song(id: "s", title: "First Eclogue After Epos Among Ainu Races - Original")
        #expect(WorkMovementTitle.title(for: song) == song.title)
    }

    @Test func titleForRowAppliesOnlyUnderAnActiveWorkHeaderToATrackWithItsOwnWork() {
        let underHeader = Song(id: "a", title: "Three Love Songs I. Kurai michi", work: "Three Love Songs")
        #expect(WorkMovementTitle.titleForRow(song: underHeader, workHeaderGroupingActive: true)
                == "I. Kurai michi")

        // No work tag on this track: untouched even though the album's
        // header grouping is active for its neighbors.
        let noWork = Song(id: "b", title: "First Eclogue After Epos Among Ainu Races")
        #expect(WorkMovementTitle.titleForRow(song: noWork, workHeaderGroupingActive: true) == noWork.title)

        // Header grouping withdrawn (e.g. a non-track-order sort): untouched
        // even though the track carries a work tag.
        #expect(WorkMovementTitle.titleForRow(song: underHeader, workHeaderGroupingActive: false)
                == underHeader.title)
    }

    @Test func workHeaderGroupingActiveTracksAlbumWorkCountAndHeaderWithdrawal() {
        let tracks = [
            Song(id: "a", title: "Sonata I. Allegro", work: "Sonata"),
            Song(id: "b", title: "Sonata II. Adagio", work: "Sonata"),
            Song(id: "c", title: "Bagatelle", work: "Bagatelle")
        ]
        let table = MusicTrackTable(
            tracks: tracks,
            columns: [.title],
            discHeaders: [:],
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        )
        let coordinator = table.makeCoordinator()
        coordinator.rebuild()
        #expect(coordinator.workHeaderGroupingActive)

        // Descending "number" sort withdraws headers (only nil-sort or
        // ascending "number" keeps them) — grouping goes inactive.
        let descendingTable = NSTableView()
        descendingTable.sortDescriptors = [NSSortDescriptor(key: "number", ascending: false)]
        coordinator.table = descendingTable
        coordinator.tableView(descendingTable, sortDescriptorsDidChange: [])
        #expect(!coordinator.workHeaderGroupingActive)
    }
}
