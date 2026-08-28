import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct ColumnBrowserSelectionTests {
    private static var retainedWindows: [NSWindow] = []

    @Test(arguments: ["Genres", "Artists", "Albums", "Composers"])
    func allRowClearsAnExistingSelection(paneName: String) async throws {
        let state = ColumnBrowserSelectionFixture()
        let pane = ColumnBrowserPane(
            title: paneName,
            items: ["Johann Sebastian Bach", "Caroline Shaw"],
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            allLabel: "All \(paneName)"
        )
        let window = host(pane)
        let table = try await loadedTable(in: window, rows: 3)

        try #require(table.selectedRow == 1)
        try click(row: 0, in: table, window: window)
        try await waitUntil("clear the composer selection") { state.selection.isEmpty }

        #expect(state.selection.isEmpty)
        try click(row: 2, in: table, window: window)
        try await waitUntil("select another item after resetting") { state.selection == "Caroline Shaw" }
    }

    private func host<Content: View>(_ content: Content) -> NSWindow {
        let view = NSHostingView(rootView: content.environment(PlayerModel()).frame(width: 260, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 260, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return window
    }

    private func loadedTable(in window: NSWindow, rows: Int) async throws -> NSTableView {
        try await waitUntil("load the composer pane") {
            window.contentView?.layoutSubtreeIfNeeded()
            return findTable(in: window.contentView)?.numberOfRows == rows
        }
        return try #require(findTable(in: window.contentView))
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view?.subviews ?? [] {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    private func click(row: Int, in table: NSTableView, window: NSWindow) throws {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        // NSTableView tracks until mouse-up; queue it before entering that loop.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown))
    }

    private func waitUntil(_ operation: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Column browser did not \(operation)")
    }
}

@MainActor
@Observable
private final class ColumnBrowserSelectionFixture {
    var selection = "Johann Sebastian Bach"
}
