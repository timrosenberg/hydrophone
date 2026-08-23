import SwiftUI
import AppKit

// NSViewRepresentable lifecycle for `MusicTrackTable`: building the table,
// its columns, and applying SwiftUI-driven updates.

/// Header view that surfaces the column-picker context menu (#37) on
/// right-click, mirroring how `InnerTableView.menu(for:)` does it for rows.
private final class InnerTableHeaderView: NSTableHeaderView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// NSTableView subclass that surfaces a per-row context menu and Return-to-play.
private final class InnerTableView: NSTableView {
    var contextMenuProvider: ((IndexSet) -> NSMenu?)?
    var onReturn: (() -> Void)?
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
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            onReturn?()
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
        table.setDraggingSourceOperationMask([.copy], forLocal: true)
        addColumns(to: table)

        if columnsCustomizable {
            let header = InnerTableHeaderView()
            header.menuProvider = { context.coordinator.columnPickerMenu(for: table) }
            table.headerView = header
            context.coordinator.observeColumnChanges(of: table)
        }

        // Restore a persisted sort — only for a column that still exists.
        if sortable, let descriptor = context.coordinator.persistedSortDescriptor(),
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
        let effectiveColumns: [TrackColumn] = {
            guard columnsCustomizable, let key = sortAutosaveKey,
                  let persisted = TrackColumnPreferences.persistedColumns(for: key) else { return columns }
            return persisted
        }()
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
        context.coordinator.parent = self
        guard let table = scroll.documentView as? InnerTableView else { return }
        table.contextMenuProvider = { context.coordinator.menuForSelection($0) }
        context.coordinator.reloadIfNeeded()
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
