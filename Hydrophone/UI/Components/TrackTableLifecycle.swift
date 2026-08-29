import SwiftUI
import AppKit

// NSViewRepresentable lifecycle for `MusicTrackTable`: building the table,
// its columns, and applying SwiftUI-driven updates.

/// Header view that surfaces the column-picker context menu (#37) on
/// right-click, mirroring how `InnerTableView.menu(for:)` does it for rows.
final class InnerTableHeaderView: NSTableHeaderView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// A widened, comfortable hit zone (16pt) around each resizable column's
    /// trailing divider — both the hover cursor and the actual drag-to-resize
    /// read from this same geometry, so they can never disagree. AppKit's own
    /// native resize hit-test is only a few points wide, which is why simply
    /// widening the *cursor* zone past it made the cursor promise a resize
    /// that a click there didn't honor (it fell through to header-cell
    /// reorder-drag instead) — so resizing is handled entirely here too, not
    /// left to the native header drag.
    private var dividerAreas: [NSTrackingArea] = []
    private var hoveringDivider = false
    private(set) weak var observedTable: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingColumnChanges()
        guard window != nil, let tableView else { return }
        observedTable = tableView
        // A column's width can change (persisted-width restore, the picker's
        // reconciliation, a user drag) without the header view's own overall
        // frame changing — uniform autoresizing keeps the total width fixed
        // — so `updateTrackingAreas` alone never fires again. Rebuild
        // explicitly on both notifications too.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(rebuildDividerAreas),
                            name: NSTableView.columnDidResizeNotification, object: tableView)
        center.addObserver(self, selector: #selector(rebuildDividerAreas),
                            name: NSTableView.columnDidMoveNotification, object: tableView)
        rebuildDividerAreas()
    }

    private func stopObservingColumnChanges() {
        guard let observedTable else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSTableView.columnDidResizeNotification, object: observedTable)
        center.removeObserver(self, name: NSTableView.columnDidMoveNotification, object: observedTable)
        self.observedTable = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildDividerAreas()
    }

    private func dividerZones() -> [(rect: NSRect, column: NSTableColumn)] {
        guard let tableView else { return [] }
        let columns = tableView.tableColumns
        return (0..<max(columns.count - 1, 0)).compactMap { index in
            let column = columns[index]
            guard column.resizingMask.contains(.userResizingMask), column.minWidth < column.maxWidth
            else { return nil }
            let edge = headerRect(ofColumn: index).maxX
            return (NSRect(x: edge - 8, y: 0, width: 16, height: bounds.height), column)
        }
    }

    @objc private func rebuildDividerAreas() {
        dividerAreas.forEach(removeTrackingArea)
        dividerAreas.removeAll()
        for zone in dividerZones() {
            let area = NSTrackingArea(rect: zone.rect, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil)
            addTrackingArea(area)
            dividerAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hoveringDivider else { return }
        hoveringDivider = true
        NSCursor.resizeLeftRight.push()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveringDivider else { return }
        hoveringDivider = false
        NSCursor.pop()
    }

    /// A press inside a divider zone runs the resize as a manual drag loop —
    /// anywhere else falls through to AppKit's native header handling (sort,
    /// reorder, column picker menu) unchanged.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let zone = dividerZones().first(where: { $0.rect.contains(point) }), let window else {
            super.mouseDown(with: event)
            return
        }
        let column = zone.column
        let startWidth = column.width
        let startX = point.x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let currentX = convert(next.locationInWindow, from: nil).x
            let proposed = startWidth + (currentX - startX)
            column.width = min(max(proposed, column.minWidth), column.maxWidth)
            if next.type == .leftMouseUp { break }
        }
    }
}

/// NSTableView subclass that surfaces per-row menus and playback keys.
final class InnerTableView: NSTableView {
    var contextMenuProvider: ((IndexSet) -> NSMenu?)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    /// ⌘I, mirroring the context menu's "Get Info" item (#77).
    var onGetInfo: (() -> Void)?
    /// Disc headers are not selectable; programmatic selection must skip them
    /// (`selectRowIndexes` bypasses the shouldSelect delegate).
    var selectableRow: ((Int) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, selectableRow?(row) != false else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(selectedRowIndexes)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let isCommandI = modifiers == .command
            && event.charactersIgnoringModifiers?.lowercased() == "i"
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            onReturn?()
        } else if event.keyCode == 49 { // Space
            onSpace?()
        } else if isCommandI {
            onGetInfo?()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension MusicTrackTable {
    func makeNSView(context: Context) -> NSScrollView {
        let table = InnerTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.contextMenuProvider = { context.coordinator.menuForSelection($0) }
        table.selectableRow = { context.coordinator.trackIndex(atRow: $0) != nil }
        table.onReturn = { context.coordinator.playSelected() }
        table.onSpace = { context.coordinator.parent.onSpace() }
        table.onGetInfo = { context.coordinator.getInfoSelected() }
        table.setDraggingSourceOperationMask([.copy], forLocal: true)
        addColumns(to: table)
        context.coordinator.lastNativeFeaturesAvailable = nativeFeaturesAvailable

        if columnsCustomizable {
            let header = InnerTableHeaderView()
            // Weak: table retains header (headerView), so a strong capture of
            // `table` here would close the loop table → header → closure → table.
            header.menuProvider = { [weak table] in
                guard let table else { return nil }
                return context.coordinator.columnPickerMenu(for: table)
            }
            table.headerView = header
            context.coordinator.observeColumnChanges(of: table)
        }

        // Restore the user's sort, or apply this view's first-visit default —
        // only when that column still exists.
        if sortable, let descriptor = context.coordinator.initialSortDescriptor(),
           table.tableColumns.contains(where: { $0.identifier.rawValue == descriptor.key }) {
            context.coordinator.restoringSort = true
            table.sortDescriptors = [descriptor]
            context.coordinator.restoringSort = false
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.table = table
        context.coordinator.rebuild()
        if scrollAutosaveKey != nil {
            context.coordinator.observeScroll(of: scroll)
        }
        return scroll
    }

    private func addColumns(to table: NSTableView) {
        func addFixedColumn(_ id: String, width: CGFloat) {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = "" // NSTableColumn's own default is a placeholder ("Field"), not blank
            col.width = width
            col.minWidth = width
            col.maxWidth = width
            table.addTableColumn(col)
        }
        // Customizable views restore the user's last visible set/order once
        // one has been persisted; everyone else (and a customizable view's
        // first launch) uses the caller's default list.
        let savedColumns: [TrackColumn] = {
            guard columnsCustomizable, let key = sortAutosaveKey,
                  let persisted = TrackColumnPreferences.persistedColumns(for: key) else { return columns }
            return persisted
        }()
        let effectiveColumns = TrackColumn.columnsAvailableForCurrentServer(
            savedColumns,
            nativeFeaturesAvailable: nativeFeaturesAvailable
        )
        // With a track-number column, the # cell itself hosts the speaker on
        // the playing row (iTunes style) — no separate indicator column.
        if !effectiveColumns.contains(.number) {
            addFixedColumn("indicator", width: 22)
        }
        for column in effectiveColumns {
            let col = column.makeTableColumn(sortable: sortable)
            if columnsCustomizable, let key = sortAutosaveKey,
               let width = TrackColumnPreferences.persistedWidth(for: column.id, in: key) {
                col.width = width
            }
            table.addTableColumn(col)
        }
        addFixedColumn("fav", width: 26)
        // Flexible columns absorb extra width so rows/stripes fill edge-to-edge.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? InnerTableView else { return }
        let selection = context.coordinator.updateTracks(from: self)
        table.contextMenuProvider = { context.coordinator.menuForSelection($0) }
        context.coordinator.reconcileNativeColumnsIfNeeded(in: table)
        context.coordinator.restoreScrollIfReady(scroll)

        let want = context.coordinator.tableRows(
            forTrackIndices: selection.filter { context.coordinator.displayed.indices.contains($0) })
        if table.selectedRowIndexes != want {
            context.coordinator.updatingSelection = true
            table.selectRowIndexes(want, byExtendingSelection: false)
            context.coordinator.updatingSelection = false
        }
    }
}
