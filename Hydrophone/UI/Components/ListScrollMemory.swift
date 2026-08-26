import AppKit
import SwiftUI

/// Adapts `Binding.scrollMemory` to a plain, unsectioned macOS `List`:
/// `scrollPosition(id:)` does not report or restore its backing table's rows.
/// Row IDs must match the List's order. Selection and keyboard handling stay
/// with SwiftUI; only the clip view's scroll position is observed/restored.
struct ListScrollMemory: NSViewRepresentable {
    let ids: [String]
    let position: Binding<String?>

    func makeNSView(context: Context) -> Observer { Observer() }

    func updateNSView(_ view: Observer, context: Context) {
        view.ids = ids
        view.position = position
        view.scheduleRestore()
    }

    static func dismantleNSView(_ view: Observer, coordinator: ()) {
        view.savePendingPosition()
        NotificationCenter.default.removeObserver(view)
    }

    final class Observer: NSView {
        var ids: [String] = []
        var position: Binding<String?> = .constant(nil)
        private weak var table: NSTableView?
        private var restored = false
        private var restoreScheduled = false
        private var pendingID: String?
        private var lastID: String?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { scheduleRestore() }
        }

        override func layout() {
            super.layout()
            if !restored { scheduleRestore() }
        }

        func scheduleRestore() {
            guard !restoreScheduled, !restored else { return }
            restoreScheduled = true
            // SwiftUI must attach/populate the table before row IDs can be
            // mapped. Updates and table layout retry this after async loads.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restoreScheduled = false
                self.restoreIfReady()
            }
        }

        private func restoreIfReady() {
            guard window != nil, let table = table ?? nearestTableView(),
                  let scroll = table.enclosingScrollView else { return }
            if self.table !== table {
                self.table = table
                scroll.contentView.postsBoundsChangedNotifications = true
                table.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                       name: NSView.boundsDidChangeNotification,
                                                       object: scroll.contentView)
                NotificationCenter.default.addObserver(self, selector: #selector(tableResized),
                                                       name: NSView.frameDidChangeNotification, object: table)
            }
            guard !restored, !ids.isEmpty, table.numberOfRows == ids.count else { return }
            if let id = position.wrappedValue, let row = ids.firstIndex(of: id) {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                                                     y: table.rect(ofRow: row).minY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            lastID = visibleID()
            restored = true
        }

        @objc private func tableResized() {
            if !restored { scheduleRestore() }
        }

        @objc private func boundsChanged() {
            guard restored, window != nil, let id = visibleID(), id != lastID else { return }
            lastID = id
            pendingID = id
            // Never write SwiftUI state during an AppKit layout callback.
            // Coalesce callbacks, and flush on teardown so immediate Back
            // navigation cannot lose the final visible row.
            DispatchQueue.main.async { [weak self] in self?.savePendingPosition() }
        }

        private func visibleID() -> String? {
            guard let table, table.numberOfRows == ids.count else { return nil }
            let row = table.rows(in: table.visibleRect).location
            return ids.indices.contains(row) ? ids[row] : nil
        }

        func savePendingPosition() {
            guard let id = pendingID else { return }
            pendingID = nil
            position.wrappedValue = id
        }
    }
}
