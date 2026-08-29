import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct TrackTableHeaderTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func removingAColumnRefreshesDividerTrackingAreas() async throws {
        let key = "header-remove-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let window = host(table(sortKey: key))
        let table = try await loadedTable(in: window)
        let header = try #require(table.headerView)
        header.updateTrackingAreas()

        let staleRects = dividerTrackingRects(in: header)
        let coordinator = try #require(table.dataSource as? MusicTrackTable.Coordinator)
        let artistItem = try #require(coordinator.columnPickerMenu(for: table).items.first {
            ($0.representedObject as? String) == TrackColumn.artist.id
        })
        let action = try #require(artistItem.action)
        #expect(NSApp.sendAction(action, to: artistItem.target, from: artistItem))
        #expect(table.tableColumn(withIdentifier: .init(TrackColumn.artist.id)) == nil)

        let refreshedRects = dividerTrackingRects(in: header)
        #expect(refreshedRects != staleRects)
        #expect(refreshedRects == expectedDividerRects(in: header, table: table))
    }

    @Test func detachedHeaderStopsObservingColumnNotificationsAndReattaches() async throws {
        let key = "header-lifecycle-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let window = host(table(sortKey: key))
        let hostedTable = try await loadedTable(in: window)
        let header = try #require(hostedTable.headerView as? InnerTableHeaderView)
        let contentView = try #require(window.contentView)
        header.updateTrackingAreas()
        #expect(header.observedTable === hostedTable)

        let attachedAreas = dividerTrackingAreas(in: header)
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: hostedTable
        )
        #expect(dividerTrackingAreas(in: header) != attachedAreas)

        window.contentView = NSView(frame: contentView.frame)
        header.viewDidMoveToWindow()
        header.updateTrackingAreas()
        #expect(header.observedTable == nil)
        let detachedAreas = dividerTrackingAreas(in: header)
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: hostedTable
        )
        #expect(dividerTrackingAreas(in: header) == detachedAreas)

        window.contentView = contentView
        window.contentView?.layoutSubtreeIfNeeded()
        let reattachedAreas = dividerTrackingAreas(in: header)
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: hostedTable
        )
        #expect(dividerTrackingAreas(in: header) != reattachedAreas)
    }

    private func table(sortKey: String) -> MusicTrackTable {
        MusicTrackTable(
            tracks: [Song(id: "song", title: "Title", artist: "Artist")],
            sortAutosaveKey: sortKey,
            columns: [.title, .artist, .album],
            columnsCustomizable: true,
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        )
    }

    private func host<Content: View>(_ content: Content) -> NSWindow {
        let view = NSHostingView(rootView: content.frame(width: 500, height: 240))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return window
    }

    private func loadedTable(in window: NSWindow) async throws -> NSTableView {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let table = findTable(in: window.contentView), table.numberOfRows == 1 {
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

    private func dividerTrackingAreas(in header: NSTableHeaderView) -> [ObjectIdentifier] {
        header.trackingAreas.compactMap { area in
            guard area.owner as AnyObject? === header,
                  area.options.contains(.mouseEnteredAndExited) else { return nil }
            return ObjectIdentifier(area)
        }
    }

    private func dividerTrackingRects(in header: NSTableHeaderView) -> [NSRect] {
        header.trackingAreas.compactMap { area in
            guard area.owner as AnyObject? === header,
                  area.options.contains(.mouseEnteredAndExited) else { return nil }
            return area.rect
        }.sorted { $0.minX < $1.minX }
    }

    private func expectedDividerRects(in header: NSTableHeaderView, table: NSTableView) -> [NSRect] {
        let columns = table.tableColumns
        return (0..<max(columns.count - 1, 0)).compactMap { index in
            let column = columns[index]
            guard column.resizingMask.contains(.userResizingMask), column.minWidth < column.maxWidth
            else { return nil }
            let edge = header.headerRect(ofColumn: index).maxX
            return NSRect(x: edge - 8, y: 0, width: 16, height: header.bounds.height)
        }
    }

    private func clearColumnPreferences(for key: String) {
        UserDefaults.standard.removeObject(forKey: "trackColumns.\(key)")
        for column in TrackColumn.allCases {
            UserDefaults.standard.removeObject(forKey: "trackColumnWidth.\(key).\(column.id)")
        }
    }
}
