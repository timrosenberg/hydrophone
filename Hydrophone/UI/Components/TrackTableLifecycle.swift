import SwiftUI
import AppKit

// NSViewRepresentable lifecycle for `MusicTrackTable`: building the table,
// its columns, and applying SwiftUI-driven updates.

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
        func addColumn(_ id: String, _ title: String, width: CGFloat, min: CGFloat, max: CGFloat,
                       sortKey: String? = nil, alignment: NSTextAlignment = .left) {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = min
            col.maxWidth = max
            // Match the header's alignment to the cell content (e.g.
            // right-aligned Time, centered #).
            col.headerCell.alignment = alignment
            if sortable, let sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
            }
            table.addTableColumn(col)
        }
        // With a track-number column, the # cell itself hosts the speaker on
        // the playing row (iTunes style) — no separate indicator column.
        if !columns.contains(.number) {
            addColumn("indicator", "", width: 22, min: 22, max: 22)
        }
        for column in columns {
            let widths = column.widths
            addColumn(column.id, column.header, width: widths.initial, min: widths.min, max: widths.max,
                      sortKey: column.id, alignment: column.alignment)
        }
        addColumn("fav", "", width: 26, min: 26, max: 26)
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
