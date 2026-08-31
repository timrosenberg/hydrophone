import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Table rows: tracks interleaved with unselectable album group headers.
/// All external index semantics (selection binding, onPlay, drag) stay in
/// *displayed*-track space; the coordinator's delegate methods translate.
enum TrackTableRow: Equatable {
    /// `work` is non-nil only for a work header, never a disc header.
    case header(String, work: String?)
    case track(Int)   // index into the displayed track order
    /// Blank separator row at the boundary where a run of grouped tracks
    /// ends and an ungrouped run begins — a header marks every other
    /// boundary, but that one has none.
    case spacer

    static func build(tracks: [Song], headers: [Int: String]?) -> [TrackTableRow] {
        let plain = tracks.indices.map(TrackTableRow.track)
        guard let headers else { return plain }
        let discs = Set(tracks.map { $0.discNumber ?? 1 })
        let works = Set(tracks.compactMap(\.work))
        if !works.isEmpty {
            return groupedRows(tracks: tracks, key: { $0.work }, title: { work, track in
                let disc = track.discNumber ?? 1
                return discs.count > 1 ? "Disc \(disc) · \(work)" : work
            }, work: { $0 })
        }
        guard discs.count > 1 else { return plain }
        return groupedRows(tracks: tracks, key: { $0.discNumber ?? 1 }, title: { disc, _ in
            headers[disc].map { "Disc \(disc) · \($0)" } ?? "Disc \(disc)"
        }, work: { _ in nil })
    }

    /// Walks `tracks`, emitting a header row each time `key` changes (skipping
    /// runs where `key` is nil), and a track row for every track.
    private static func groupedRows<Key: Equatable>(
        tracks: [Song],
        key: (Song) -> Key?,
        title: (Key, Song) -> String,
        work: (Key) -> String?
    ) -> [TrackTableRow] {
        var rows: [TrackTableRow] = []
        var current: Key?
        var hasCurrent = false
        for (index, track) in tracks.enumerated() {
            let trackKey = key(track)
            if !hasCurrent || current != trackKey {
                if hasCurrent, current != nil, trackKey == nil {
                    rows.append(.spacer)
                }
                current = trackKey
                hasCurrent = true
                if let trackKey {
                    rows.append(.header(title(trackKey, track), work: work(trackKey)))
                }
            }
            rows.append(.track(index))
        }
        return rows
    }
}

/// AppKit `NSTableView`-backed track list — the single track view used across the
/// app — giving the Music behaviours SwiftUI can't combine: edge-to-edge
/// alternating stripes, **double-click-to-play**, reliable multi-selection,
/// click-to-sort headers, drag-to-playlist, a now-playing **speaker** column,
/// and a favorite column. See docs/04-ui-ux.md.
struct MusicTrackTable: NSViewRepresentable {
    var tracks: [Song]
    var sortable: Bool = true
    /// When set, the sort key/direction persist to UserDefaults under this
    /// name and are restored on creation (one slot per view kind).
    var sortAutosaveKey: String?
    /// Applied only when no persisted sort exists. Songs uses Title ascending
    /// so a first visit never inherits the server's arbitrary row order.
    var defaultSortKey: String?
    /// When set, the scroll offset persists under this name and is restored
    /// once the first rows arrive. Only for views whose content is stable
    /// across launches (Songs/Favorites/browser) — content-specific views
    /// (album detail, search) would restore a stranger's offset.
    var scrollAutosaveKey: String?
    /// A deep saved offset may exceed an incremental snapshot's current
    /// height. While loading, restoration waits for enough rows instead of
    /// permanently clamping to the partial table.
    var contentIsLoading: Bool = false
    /// Content columns to show, in order. Caller decides explicitly — the
    /// default/fallback list when nothing's persisted yet (or customization
    /// is off).
    var columns: [TrackColumn]
    /// Opts into the header right-click column picker (#37): show/hide,
    /// reorder, and resize persist via `TrackColumnPreferences`, keyed by
    /// `sortAutosaveKey`. Off by default — rolled out per call site
    /// (`SongsView` first; the rest in #38) rather than globally at once,
    /// since every `TrackTableView` caller shares this same implementation.
    var columnsCustomizable: Bool = false
    /// Whether the connected server supports Navidrome-only metadata. The
    /// picker uses this to omit native-only columns on plain Subsonic servers.
    var nativeFeaturesAvailable: Bool = false
    /// Disc → subtitle; non-nil opts the album page into group headers. More
    /// than one tagged work takes priority over disc grouping, prefixing the
    /// work with its disc on multi-disc albums. Headers appear only in track
    /// order — natural or ascending # — since other sorts split movements.
    var discHeaders: [Int: String]?
    /// Order-stable rendering of `discHeaders` for the reload signature.
    var discHeadersSignature: String? {
        discHeaders.map { headers in
            headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        }
    }
    var nowPlayingID: String?
    /// Star state as data (`LibraryModel.starSignature`): `isFavorite` runs
    /// after body evaluation, invisible to @Observable — this re-renders.
    var starSignature: Int = 0
    @Binding var selection: Set<Int>          // indices into the *displayed* order
    var isFavorite: (Song) -> Bool
    var onPlay: ([Song], Int) -> Void          // displayed order + start index
    var onSpace: () -> Void = {}
    var onPlayNext: (Song) -> Void             // ⌥-double-click: queue as next
    var onEnqueue: ([Song]) -> Void = { _ in }  // ⌥-double-click a work header: add to Up Next
    var onToggleFavorite: (Song) -> Void
    var makeMenu: ([Song], IndexSet) -> NSMenu?  // displayed order + selected indices
    /// ⌘I with exactly one row selected — mirrors the context menu's "Get
    /// Info" item, which is single-selection-only (#77).
    var onGetInfo: (Song) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // @MainActor matches reality (AppKit calls the delegate/datasource and
    // action selectors on the main thread) and lets the compiler verify the
    // AppKit calls inside.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MusicTrackTable
        weak var table: NSTableView?
        var updatingSelection = false
        var pendingSelection: Set<Int>?
        var pendingSelectionSave: DispatchWorkItem?
        /// Set while makeNSView applies the persisted sort, so the delegate
        /// callback doesn't clear the selection binding mid view-update.
        var restoringSort = false
        private(set) var displayed: [Song] = []
        private var sortKey: String?
        private var ascending = true
        private var signature: [String] = []
        // Scroll persistence (see TrackTablePersistence.swift). The
        // selector-based observer is auto-unregistered on dealloc.
        var scrollRestored = false
        var pendingScrollSave: DispatchWorkItem?
        // Column-resize persistence (see TrackColumnPicker.swift), debounced
        // the same way.
        var pendingColumnWidthSave: DispatchWorkItem?
        var lastNativeFeaturesAvailable: Bool?
        var reconcilingNativeColumns = false

        private(set) var rows: [TrackTableRow] = []
        /// True when the current build shows work-grouping headers (issue
        /// #54's Title-column movement text applies only then, and only to
        /// rows whose own track carries a `work` tag — see `textCell`).
        private(set) var workHeaderGroupingActive = false

        init(_ parent: MusicTrackTable) { self.parent = parent }

        /// Recompute the displayed (optionally sorted) order and reload.
        func rebuild() {
            displayed = sortedTracks()
            let headers = activeDiscHeaders
            rows = TrackTableRow.build(tracks: displayed, headers: headers)
            workHeaderGroupingActive = headers != nil && !Set(displayed.compactMap(\.work)).isEmpty
            table?.reloadData()
        }

        func reloadIfNeeded() {
            var sig = parent.tracks.map(\.id)
            sig.append(contentsOf: parent.tracks.map { "group:\($0.discNumber ?? 1)|\($0.work ?? "")" })
            sig.append("sort:\(sortKey ?? "")\(ascending)")
            sig.append("np:\(parent.nowPlayingID ?? "")")
            sig.append("discs:" + (parent.discHeadersSignature ?? "off"))
            sig.append("stars:\(parent.starSignature)")
            sig.append(contentsOf: parent.tracks.map { parent.isFavorite($0) ? "1" : "0" })
            guard sig != signature else { return }
            signature = sig
            rebuild()
        }

        /// Album headers require track order: no user sort, or the disc-aware
        /// # sort ascending. Any other sort interleaves groups, so they withdraw.
        private var activeDiscHeaders: [Int: String]? {
            guard let headers = parent.discHeaders else { return nil }
            switch sortKey {
            case nil: return headers
            case "number": return ascending ? headers : nil
            default: return nil
            }
        }

        /// The displayed-track index at a table row (nil for a header).
        func trackIndex(atRow row: Int) -> Int? {
            guard rows.indices.contains(row), case let .track(index) = rows[row] else { return nil }
            return index
        }

        /// The work identity at a table row (nil for a disc header or a track).
        func work(atRow row: Int) -> String? {
            guard rows.indices.contains(row), case let .header(_, work) = rows[row] else { return nil }
            return work
        }

        func tableRows(forTrackIndices indices: Set<Int>) -> IndexSet {
            IndexSet(indices.compactMap { rows.firstIndex(of: .track($0)) })
        }

        func menuForSelection(_ selectedRows: IndexSet) -> NSMenu? {
            parent.makeMenu(displayed, IndexSet(selectedRows.compactMap { trackIndex(atRow: $0) }))
        }

        private func sortedTracks() -> [Song] {
            guard let key = sortKey else { return parent.tracks }
            let asc = ascending
            if key == "title" { return titleSortedTracks(ascending: asc) }
            return nonTitleSortedTracks(for: key, ascending: asc)
        }

        private func nonTitleSortedTracks(for key: String, ascending: Bool) -> [Song] {
            func text(_ lhs: String?, _ rhs: String?) -> Bool {
                (lhs ?? "").localizedCaseInsensitiveCompare(rhs ?? "") == .orderedAscending
            }
            return parent.tracks.sorted { lhs, rhs in
                if let result = pickerOnlyColumnOrderedBefore(
                    id: key, lhs: lhs, rhs: rhs, ascending: ascending
                ) {
                    return result
                }
                let result: Bool
                switch key {
                case "number":  // disc-aware track order
                    result = (lhs.discNumber ?? 1, lhs.track ?? 0)
                        < (rhs.discNumber ?? 1, rhs.track ?? 0)
                case "artist": result = text(lhs.artist, rhs.artist)
                case "composer": result = text(lhs.nonEmptyDisplayComposer, rhs.nonEmptyDisplayComposer)
                case "album": result = text(lhs.album, rhs.album)
                case "genre": result = text(lhs.displayGenre, rhs.displayGenre)
                case "quality": result = lhs.qualityRank < rhs.qualityRank
                case "time": result = (lhs.duration ?? 0) < (rhs.duration ?? 0)
                default: result = text(lhs.title, rhs.title)
                }
                return ascending ? result : !result
            }
        }

        private func titleSortedTracks(ascending: Bool) -> [Song] {
            return parent.tracks.sorted { lhs, rhs in
                let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                let order = titleOrder == .orderedSame
                    ? lhs.id.localizedStandardCompare(rhs.id)
                    : titleOrder
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            trackIndex(atRow: row) == nil ? NSTableRowView() : TrackRowView()
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            trackIndex(atRow: row) == nil
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            trackIndex(atRow: row) != nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if let descriptor = tableView.sortDescriptors.first {
                sortKey = descriptor.key
                ascending = descriptor.ascending
            } else {
                sortKey = nil
            }
            persistSort(key: sortKey, ascending: ascending)
            signature = [] // force rebuild
            reloadIfNeeded()
            guard !restoringSort else { return }
            pendingSelectionSave?.cancel()
            pendingSelection = nil
            parent.selection = []
            tableView.deselectAll(nil)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let index = trackIndex(atRow: row),
                  let data = try? JSONEncoder().encode(DraggedTrack(songId: displayed[index].id,
                                                                    index: index,
                                                                    song: displayed[index]))
            else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.json.identifier))
            return item
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let index = trackIndex(atRow: row) else {
                // Group rows get a single full-width view (tableColumn is nil).
                if case let .header(title, _) = rows[row] { return discHeaderCell(title) }
                return nil
            }
            guard let id = tableColumn?.identifier.rawValue else { return nil }
            let song = displayed[index]

            switch id {
            case "indicator":
                return indicatorCell(for: song)
            case "number" where song.id == parent.nowPlayingID:
                // The # column doubles as the now-playing column (iTunes
                // style): the speaker replaces the track number.
                return indicatorCell(for: song)
            case "quality":
                guard let label = song.qualityLabel else { return NSTableCellView() }
                return QualityBadgeCell(text: label)
            case "fav":
                return favoriteCell(for: song, trackIndex: index)
            default:
                return textCell(id: id, song: song)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table else { return }
            pendingSelectionSave?.cancel()
            pendingSelection = nil
            parent.selection = Set(table.selectedRowIndexes.compactMap { trackIndex(atRow: $0) })
        }

        // ⌥-double-click queues next (a track) or adds to Up Next (a work)
        // instead of playing immediately.
        @objc func doubleClicked() {
            guard let table else { return }
            let isOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
            if let index = trackIndex(atRow: table.clickedRow) {
                if isOption { parent.onPlayNext(displayed[index]) } else { parent.onPlay(displayed, index) }
            } else if let work = work(atRow: table.clickedRow) {
                let workTracks = resolveWorkTracks(work: work, among: parent.tracks)
                if isOption { parent.onEnqueue(workTracks) } else { parent.onPlay(workTracks, 0) }
            }
        }

        @objc func favoriteClicked(_ sender: NSButton) {
            guard displayed.indices.contains(sender.tag) else { return }
            parent.onToggleFavorite(displayed[sender.tag])
        }

        func playSelected() {
            guard let row = table?.selectedRowIndexes.min(),
                  let index = trackIndex(atRow: row) else { return }
            parent.onPlay(displayed, index)
        }

        func getInfoSelected() {
            guard let selected = table?.selectedRowIndexes, selected.count == 1,
                  let row = selected.first, let index = trackIndex(atRow: row) else { return }
            parent.onGetInfo(displayed[index])
        }
    }
}
