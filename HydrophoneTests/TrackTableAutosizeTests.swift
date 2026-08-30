import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct TrackTableAutosizeTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func doubleClickingDividerFitsColumnToVisibleCellText() async throws {
        let key = "autosize-visible-title-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let title = "A Title Long Enough to Require a Wider Visible Column Than Its Default"
        let window = host(table(sortKey: key, tracks: [Song(id: "song", title: title)]))
        let table = try await loadedTable(in: window)
        let column = try column(.title, in: table)
        let cell = try #require(table.view(atColumn: table.column(withIdentifier: column.identifier),
                                           row: 0, makeIfNecessary: false) as? NSTableCellView)
        let label = try #require(cell.textField)
        cell.layoutSubtreeIfNeeded()
        let expected = fittedWidth(for: column, label: label, in: cell)

        try doubleClickTrailingDivider(of: column, in: table)

        #expect(abs(column.width - expected) < 0.5)
        #expect(column.width > TrackColumn.title.widths.initial)
    }

    @Test func doubleClickingDividerFitsQualityBadgeText() async throws {
        let key = "autosize-quality-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let song = Song(id: "song", title: "Title", bitRate: .max, suffix: "mp3")
        let window = host(table(sortKey: key, tracks: [song], columns: [.quality, .title]))
        let table = try await loadedTable(in: window)
        let column = try column(.quality, in: table)
        let cell = try #require(table.view(atColumn: table.column(withIdentifier: column.identifier),
                                           row: 0, makeIfNecessary: false) as? QualityBadgeCell)
        let label = try #require(cell.textField)
        cell.layoutSubtreeIfNeeded()
        let expected = fittedWidth(for: column, label: label, in: cell)

        try doubleClickTrailingDivider(of: column, in: table)

        #expect(abs(column.width - expected) < 0.5)
        #expect(column.width == column.maxWidth)
    }

    @Test func autosizedWidthRestoresInARecreatedTable() async throws {
        let key = "autosize-persistence-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let song = Song(
            id: "song",
            title: "A Persisted Title That Is Considerably Wider Than the Default Column"
        )
        let firstWindow = host(table(sortKey: key, tracks: [song]))
        let firstTable = try await loadedTable(in: firstWindow)
        let firstColumn = try column(.title, in: firstTable)

        try doubleClickTrailingDivider(of: firstColumn, in: firstTable)
        let fittedWidth = firstColumn.width
        for _ in 0..<100 where TrackColumnPreferences.persistedWidth(for: TrackColumn.title.id, in: key) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let secondWindow = host(table(sortKey: key, tracks: [song]))
        let secondTable = try await loadedTable(in: secondWindow)
        let restoredColumn = try column(.title, in: secondTable)
        #expect(abs(restoredColumn.width - fittedWidth) < 0.5)
    }

    @Test func autosizeIgnoresOffscreenRowsAndClampsToMinimumWidth() async throws {
        let key = "autosize-visible-only-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        var songs = (0..<29).map { Song(id: "short-\($0)", title: "Short") }
        songs.append(Song(id: "offscreen", title: String(repeating: "W", count: 400)))
        let window = host(table(sortKey: key, tracks: songs), height: 120)
        let table = try await loadedTable(in: window, expectedRows: songs.count)
        let column = try column(.title, in: table)
        #expect(!table.rows(in: table.visibleRect).contains(songs.count - 1))

        try doubleClickTrailingDivider(of: column, in: table)

        #expect(column.width == column.minWidth)
    }

    @Test func autosizeUsesHeaderWhenItIsWiderThanVisibleCellText() async throws {
        let key = "autosize-header-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let song = Song(id: "song", title: "Title", movementName: "I")
        let window = host(table(
            sortKey: key,
            tracks: [song],
            columns: [.movementName, .title],
            nativeFeaturesAvailable: true
        ))
        let table = try await loadedTable(in: window)
        let column = try column(.movementName, in: table)
        let expected = clamped(column.headerCell.cellSize.width, for: column)

        try doubleClickTrailingDivider(of: column, in: table)

        #expect(abs(column.width - expected) < 0.5)
    }

    @Test func autosizeUsesHeaderWhenTableHasNoRows() async throws {
        let key = "autosize-empty-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let window = host(table(
            sortKey: key,
            tracks: [],
            columns: [.movementName, .title],
            nativeFeaturesAvailable: true
        ))
        let table = try await loadedTable(in: window, expectedRows: 0)
        let column = try column(.movementName, in: table)
        let expected = clamped(column.headerCell.cellSize.width, for: column)

        try doubleClickTrailingDivider(of: column, in: table)

        #expect(abs(column.width - expected) < 0.5)
    }

    private func table(
        sortKey: String,
        tracks: [Song],
        columns: [TrackColumn] = [.title, .artist],
        nativeFeaturesAvailable: Bool = false
    ) -> MusicTrackTable {
        MusicTrackTable(
            tracks: tracks,
            sortAutosaveKey: sortKey,
            columns: columns,
            columnsCustomizable: true,
            nativeFeaturesAvailable: nativeFeaturesAvailable,
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        )
    }

    private func host<Content: View>(
        _ content: Content,
        width: CGFloat = 500,
        height: CGFloat = 240
    ) -> NSWindow {
        let view = NSHostingView(rootView: content.frame(width: width, height: height))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return window
    }

    private func loadedTable(in window: NSWindow, expectedRows: Int = 1) async throws -> NSTableView {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let table = findTable(in: window.contentView), table.numberOfRows == expectedRows {
                return table
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(findTable(in: window.contentView), "Table did not load")
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view?.subviews ?? [] {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    private func column(_ column: TrackColumn, in table: NSTableView) throws -> NSTableColumn {
        try #require(table.tableColumn(withIdentifier: .init(column.id)))
    }

    private func fittedWidth(
        for column: NSTableColumn,
        label: NSTextField,
        in cell: NSTableCellView
    ) -> CGFloat {
        let labelFrame = cell.convert(label.bounds, from: label)
        let insets = labelFrame.minX + cell.bounds.maxX - labelFrame.maxX
        return clamped(max(column.headerCell.cellSize.width, label.intrinsicContentSize.width + insets), for: column)
    }

    private func clamped(_ width: CGFloat, for column: NSTableColumn) -> CGFloat {
        min(max(width, column.minWidth), column.maxWidth)
    }

    private func doubleClickTrailingDivider(of column: NSTableColumn, in table: NSTableView) throws {
        let header = try #require(table.headerView)
        let window = try #require(header.window)
        let columnIndex = try #require(table.tableColumns.firstIndex(of: column))
        let point = NSPoint(x: header.headerRect(ofColumn: columnIndex).maxX, y: header.bounds.midY)
        let location = header.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        header.mouseDown(with: event)
    }

    private func clearColumnPreferences(for key: String) {
        UserDefaults.standard.removeObject(forKey: "trackColumns.\(key)")
        for column in TrackColumn.allCases {
            UserDefaults.standard.removeObject(forKey: "trackColumnWidth.\(key).\(column.id)")
        }
    }
}
