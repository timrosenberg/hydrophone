import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
private final class HeaderEventWindow: NSWindow {
    var queuedEvents: [NSEvent] = []

    override func nextEvent(
        matching mask: NSEvent.EventTypeMask,
        until expiration: Date?,
        inMode mode: RunLoop.Mode,
        dequeue deqFlag: Bool
    ) -> NSEvent? {
        guard let event = queuedEvents.first else { return nil }
        if deqFlag { queuedEvents.removeFirst() }
        return event
    }
}

@MainActor
@Suite(.serialized)
struct TrackTableHeaderTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func wideningAColumnPreservesNeighborWidthsAndExpandsContent() async throws {
        let key = "header-independent-resize-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let window = host(table(sortKey: key), width: 700)
        let table = try await loadedTable(in: window)
        let title = try #require(table.tableColumn(withIdentifier: .init(TrackColumn.title.id)))
        let artist = try #require(table.tableColumn(withIdentifier: .init(TrackColumn.artist.id)))
        let album = try #require(table.tableColumn(withIdentifier: .init(TrackColumn.album.id)))
        let titleWidth = title.width
        let artistWidth = artist.width
        let albumWidth = album.width
        let contentWidth = table.frame.width

        try dragTrailingDivider(of: title, in: table, by: 300)
        table.layoutSubtreeIfNeeded()

        #expect(title.width == titleWidth + 300)
        #expect(artist.width == artistWidth)
        #expect(album.width == albumWidth)
        #expect(table.frame.width > contentWidth)
    }

    @Test func tableUsesIndependentColumnSizing() async throws {
        let key = "header-independent-style-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let window = host(table(sortKey: key))
        let table = try await loadedTable(in: window)

        #expect(table.columnAutoresizingStyle == .noColumnAutoresizing)
    }

    @Test func overflowingColumnsCanScrollHorizontally() async throws {
        let key = "header-horizontal-scroll-\(UUID().uuidString)"
        defer { clearColumnPreferences(for: key) }
        let window = host(table(sortKey: key))
        let table = try await loadedTable(in: window)
        let scroll = try #require(table.enclosingScrollView)
        let title = try #require(table.tableColumn(withIdentifier: .init(TrackColumn.title.id)))

        title.width += 300
        table.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)

        #expect(scroll.hasHorizontalScroller)
        #expect(table.frame.width > scroll.contentSize.width)
        #expect(scroll.contentView.bounds.origin.x == 100)
    }

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

    private func host<Content: View>(_ content: Content, width: CGFloat = 500) -> NSWindow {
        let view = NSHostingView(rootView: content.frame(width: width, height: 240))
        let window = HeaderEventWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 240),
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

    private func dragTrailingDivider(
        of column: NSTableColumn,
        in table: NSTableView,
        by distance: CGFloat
    ) throws {
        let header = try #require(table.headerView)
        let window = try #require(header.window as? HeaderEventWindow)
        let columnIndex = try #require(table.tableColumns.firstIndex(of: column))
        let startInHeader = NSPoint(x: header.headerRect(ofColumn: columnIndex).maxX, y: header.bounds.midY)
        let startInWindow = header.convert(startInHeader, to: nil)
        let endInWindow = NSPoint(x: startInWindow.x + distance, y: startInWindow.y)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startInWindow,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let dragged = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endInWindow,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endInWindow,
            modifierFlags: [],
            timestamp: timestamp + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ))
        #expect(dragged.locationInWindow.x - down.locationInWindow.x == distance)
        window.queuedEvents = [dragged, mouseUp]
        header.mouseDown(with: down)
    }

    private func clearColumnPreferences(for key: String) {
        UserDefaults.standard.removeObject(forKey: "trackColumns.\(key)")
        for column in TrackColumn.allCases {
            UserDefaults.standard.removeObject(forKey: "trackColumnWidth.\(key).\(column.id)")
        }
    }
}
