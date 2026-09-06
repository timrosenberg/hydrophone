import AppKit
import SwiftUI

/// A fixed-height, single-column native list. Cell-based drawing avoids
/// constructing a SwiftUI hosting hierarchy for every browser pane row.
struct ColumnBrowserList: NSViewRepresentable {
    let title: String
    let items: [String]
    let allLabel: String
    @Binding var selection: String
    var onSpace: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BrowserTable()
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(title)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.isEditable = false
        let cell = BrowserTextCell(textCell: "")
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.lineBreakMode = .byTruncatingTail
        cell.isScrollable = true
        column.dataCell = cell
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.onSpace = onSpace
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.update(table, from: self, initial: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? BrowserTable else { return }
        context.coordinator.update(table, from: self)
        table.onSpace = onSpace
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ColumnBrowserList
        private var updating = false

        init(_ parent: ColumnBrowserList) { self.parent = parent }

        func update(_ table: NSTableView, from value: ColumnBrowserList, initial: Bool = false) {
            let changed = parent.items != value.items || parent.allLabel != value.allLabel
            parent = value
            updating = true
            defer { updating = false }
            if initial || changed { table.reloadData() }
            let row = parent.selection.isEmpty ? 0 : parent.items.firstIndex(of: parent.selection).map { $0 + 1 }
            let rows = row.map { IndexSet(integer: $0) } ?? []
            if table.selectedRowIndexes != rows {
                table.selectRowIndexes(rows, byExtendingSelection: false)
                if let row { table.scrollRowToVisible(row) }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count + 1 }

        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            row == 0 ? parent.allLabel : parent.items[row - 1]
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            row == 0 ? parent.allLabel : parent.items[row - 1]
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            parent.selection = row > 0 ? parent.items[row - 1] : ""
        }
    }
}

private final class BrowserTable: NSTableView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onSpace?() } else { super.keyDown(with: event) }
    }
}

private final class BrowserTextCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = cellSize.height
        return NSRect(x: rect.minX + 8, y: rect.midY - height / 2,
                      width: max(0, rect.width - 16), height: height)
    }
}
