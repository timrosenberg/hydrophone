import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct ListScrollMemoryTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func restoresVisibleRowAfterRecreationWithoutPinningLaterScrolls() async throws {
        let state = ListScrollFixtureState()
        let first = host(state)
        let table = try await loadedTable(in: first, rows: 120)
        scroll(table, to: 40)
        #expect(topRow(table) == 40)
        try await waitUntil("record row 40") { state.storedID == "artist-40" }
        first.contentView = nil

        let second = host(state)
        let restored = try await loadedTable(in: second, rows: 120)
        try await waitUntil("restore row 40") { topRow(restored) == 40 }
        #expect(state.selectedID == "artist-45")
        #expect(restored.selectedRow == 45)

        scroll(restored, to: 65, offset: 7)
        try await waitUntil("record row 65") { state.storedID == "artist-65" }
        let offset = restored.enclosingScrollView!.contentView.bounds.minY
        state.selectedID = "artist-67"
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(restored.enclosingScrollView!.contentView.bounds.minY - offset) < 1)
    }

    @Test func waitsForAsynchronouslyLoadedRowsBeforeRestoring() async throws {
        let state = ListScrollFixtureState()
        let ids = state.ids
        state.ids = []
        state.storedID = "artist-40"
        let window = host(state)
        _ = try await loadedTable(in: window, rows: 0)
        #expect(state.storedID == "artist-40")

        state.ids = ids
        let table = try await loadedTable(in: window, rows: 120)
        try await waitUntil("restore after loading") { topRow(table) == 40 }
    }

    @Test func firstOrMissingSavedIDStaysAtTopAndCanSaveAgain() async throws {
        for savedID in ["artist-0", "removed-artist"] {
            let state = ListScrollFixtureState()
            state.storedID = savedID
            let table = try await loadedTable(in: host(state), rows: 120)
            #expect(topRow(table) == 0)

            scroll(table, to: 40)
            try await waitUntil("save after a top or stale restore") { state.storedID == "artist-40" }
            scroll(table, to: 0)
            try await waitUntil("remember returning to the top") { state.storedID == "artist-0" }
        }
    }

    @Test func restoreFollowsArtistIDWhenRowsAreInsertedBeforeIt() async throws {
        let state = ListScrollFixtureState()
        state.storedID = "artist-40"
        state.ids.insert("new-artist", at: 0)
        let table = try await loadedTable(in: host(state), rows: 121)
        try await waitUntil("restore the artist rather than the old row number") { topRow(table) == 41 }
    }

    private func host(_ state: ListScrollFixtureState) -> NSWindow {
        let view = NSHostingView(rootView: ListScrollFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 240, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return window
    }

    private func loadedTable(in window: NSWindow, rows: Int) async throws -> NSTableView {
        try await waitUntil("load \(rows) rows") {
            window.contentView?.layoutSubtreeIfNeeded()
            return findTable(in: window.contentView)?.numberOfRows == rows
        }
        // Let the representable's deferred attachment run before simulating
        // user input; the table can exist one main-loop turn before it.
        try await Task.sleep(for: .milliseconds(20))
        return try #require(findTable(in: window.contentView))
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view?.subviews ?? [] {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    private func topRow(_ table: NSTableView) -> Int {
        table.rows(in: table.visibleRect).location
    }

    private func scroll(_ table: NSTableView, to row: Int, offset: CGFloat = 0) {
        guard let scrollView = table.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func waitUntil(_ operation: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "List did not \(operation)")
    }
}

@MainActor
@Observable
private final class ListScrollFixtureState {
    var ids = (0..<120).map { "artist-\($0)" }
    var storedID = ""
    var selectedID: String? = "artist-45"
}

private struct ListScrollFixture: View {
    @Bindable var state: ListScrollFixtureState
    @State private var consumed = false

    var body: some View {
        List(selection: $state.selectedID) {
            ForEach(state.ids, id: \.self) { id in
                Text(id).tag(id)
            }
        }
        .listStyle(.plain)
        .background(ListScrollMemory(
            ids: state.ids,
            position: .scrollMemory(read: { state.storedID }, write: { state.storedID = $0 },
                                    consumed: $consumed, topIDs: { Set(state.ids.prefix(1)) })
        ))
    }
}
