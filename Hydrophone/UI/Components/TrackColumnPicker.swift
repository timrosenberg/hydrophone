import AppKit

// Header right-click column picker (#37), for views that opt in via
// `MusicTrackTable.columnsCustomizable`. Show/hide, reorder, and resize all
// persist through `TrackColumnPreferences`, keyed by `sortAutosaveKey` (the
// same view-kind identifier sort/scroll persistence already uses).
//
// `.number` is deliberately not offered here: it doubles as the now-playing
// indicator column (see `addColumns(to:)`), so toggling it would mean
// swapping the fixed "indicator" column in or out too — a call-site
// decision (`AlbumDetailView` wants it, `SongsView` doesn't), not something
// a generic picker should flip.

extension MusicTrackTable.Coordinator {
    private var columnViewKind: String? { parent.sortAutosaveKey }

    /// The togglable columns, in the app's canonical order, each checked if
    /// currently visible in `table`.
    func columnPickerMenu(for table: NSTableView) -> NSMenu {
        let menu = NSMenu()
        let visibleIDs = Set(table.tableColumns.map(\.identifier.rawValue))
        for column in TrackColumn.pickerColumns(
            nativeFeaturesAvailable: parent.nativeFeaturesAvailable
        ) {
            let item = NSMenuItem(title: column.header, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.id
            item.state = visibleIDs.contains(column.id) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let table, let id = sender.representedObject as? String else { return }
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let existing = table.tableColumn(withIdentifier: identifier) {
            guard contentColumns(in: table).count > 1 else { return } // always leave one visible
            table.removeTableColumn(existing)
        } else if let column = TrackColumn(id: id) {
            let newColumn = column.makeTableColumn(sortable: parent.sortable)
            if let viewKind = columnViewKind,
               let width = TrackColumnPreferences.persistedWidth(for: column.id, in: viewKind) {
                newColumn.width = width
            }
            table.addTableColumn(newColumn)
            // New columns land just before the trailing favorite column,
            // matching addColumns(to:)'s construction order.
            if let favIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "fav" }) {
                table.moveColumn(table.tableColumns.count - 1, toColumn: favIndex)
            }
        }
        persistVisibleColumnsAndOrder(table: table)
    }

    /// The table's current content columns (excludes the fixed
    /// indicator/favorite columns, which aren't `TrackColumn` cases) in
    /// their live left-to-right order.
    private func contentColumns(in table: NSTableView) -> [TrackColumn] {
        table.tableColumns.compactMap { TrackColumn(id: $0.identifier.rawValue) }
    }

    private func persistVisibleColumnsAndOrder(table: NSTableView) {
        guard let viewKind = columnViewKind else { return }
        TrackColumnPreferences.persistColumns(contentColumns(in: table), for: viewKind)
    }

    /// Applies a native-capability transition to the live table without
    /// rewriting the saved column list. Native columns disappear while the
    /// feature is unavailable and return in their saved positions if it later
    /// becomes available again.
    func reconcileNativeColumnsIfNeeded(in table: NSTableView) {
        let available = parent.nativeFeaturesAvailable
        guard parent.columnsCustomizable,
              lastNativeFeaturesAvailable != available else { return }
        lastNativeFeaturesAvailable = available

        let savedColumns: [TrackColumn] = {
            guard let viewKind = columnViewKind,
                  let persisted = TrackColumnPreferences.persistedColumns(for: viewKind) else {
                return parent.columns
            }
            return persisted
        }()
        let desired = TrackColumn.columnsAvailableForCurrentServer(
            savedColumns,
            nativeFeaturesAvailable: available
        )
        guard contentColumns(in: table) != desired else { return }

        reconcilingNativeColumns = true
        defer { reconcilingNativeColumns = false }

        for column in contentColumns(in: table) where !desired.contains(column) {
            if let existing = table.tableColumn(withIdentifier: .init(column.id)) {
                table.removeTableColumn(existing)
            }
        }
        for column in desired where table.tableColumn(withIdentifier: .init(column.id)) == nil {
            let newColumn = column.makeTableColumn(sortable: parent.sortable)
            if let viewKind = columnViewKind,
               let width = TrackColumnPreferences.persistedWidth(for: column.id, in: viewKind) {
                newColumn.width = width
            }
            table.addTableColumn(newColumn)
        }

        guard let firstContentIndex = table.tableColumns.firstIndex(where: {
            TrackColumn(id: $0.identifier.rawValue) != nil
        }) else { return }
        for (offset, column) in desired.enumerated() {
            guard let currentIndex = table.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == column.id
            }) else { continue }
            table.moveColumn(currentIndex, toColumn: firstContentIndex + offset)
        }
    }

    /// Registers the resize/reorder observers that keep persisted
    /// widths/order current. Safe to call even when `columnViewKind` is nil
    /// (a customizable table with no `sortAutosaveKey`) — the handlers just
    /// no-op, matching how scroll persistence degrades without a key.
    func observeColumnChanges(of table: NSTableView) {
        NotificationCenter.default.addObserver(self, selector: #selector(columnDidResize(_:)),
                                               name: NSTableView.columnDidResizeNotification, object: table)
        NotificationCenter.default.addObserver(self, selector: #selector(columnDidMove(_:)),
                                               name: NSTableView.columnDidMoveNotification, object: table)
    }

    /// Debounced the same way scroll-offset persistence is (see
    /// `TrackTablePersistence.scrollBoundsChanged(_:)`): a border drag fires
    /// this repeatedly, and only the width once the drag settles is worth a
    /// write.
    @objc private func columnDidResize(_ note: Notification) {
        guard !reconcilingNativeColumns,
              let viewKind = columnViewKind,
              let column = note.userInfo?["NSTableColumn"] as? NSTableColumn,
              TrackColumn(id: column.identifier.rawValue) != nil else { return }
        let columnID = column.identifier.rawValue
        let width = column.width
        pendingColumnWidthSave?.cancel()
        let work = DispatchWorkItem {
            TrackColumnPreferences.persistWidth(width, for: columnID, in: viewKind)
        }
        pendingColumnWidthSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func columnDidMove(_ note: Notification) {
        guard !reconcilingNativeColumns, let table else { return }
        persistVisibleColumnsAndOrder(table: table)
    }
}
