import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

/// Hosts the production browser with isolated selection defaults and a real
/// client whose HTTP boundary is stubbed. No production test-only entrypoints.
@MainActor
final class BrowserLibraryFixture {
    private static var retainedWindows: [NSWindow] = []
    private let suite = "browser-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let library: LibraryModel
    private let connection: ConnectionModel
    private let player = PlayerModel()
    private let app: AppModel
    private let window: NSWindow
    private let standardBrowserPreferences: [String: Any]

    init() {
        standardBrowserPreferences = UserDefaults.standard.dictionaryRepresentation().filter {
            Self.isBrowserPreference($0.key)
        }
        standardBrowserPreferences.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        // Use the existing fresh-start harness so this required environment
        // object never reads the user's Keychain or restores a server queue.
        let previous = ProcessInfo.processInfo.environment["HYDROPHONE_SCREENSHOT_FRESH"]
        setenv("HYDROPHONE_SCREENSHOT_FRESH", "1", 1)
        app = AppModel()
        if let previous {
            setenv("HYDROPHONE_SCREENSHOT_FRESH", previous, 1)
        } else {
            unsetenv("HYDROPHONE_SCREENSHOT_FRESH")
        }
        defaults = UserDefaults(suiteName: suite)!
        let store = InMemoryCredentialStore(ServerCredentials(
            baseURL: URL(string: "https://browser.example.com")!, username: "test",
            secret: "test", authMethod: .tokenSalt
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserLibraryProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SubsonicClient(credentials: store, session: session)
        let native = NavidromeClient(credentials: store, session: session)
        library = LibraryModel(client: client, navidrome: native, nativeFeaturesAvailable: { false })
        connection = ConnectionModel(client: client, navidrome: native, credentials: store)
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1_100, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
        Self.retainedWindows.append(window)
    }

    func show() {
        stopSavingScroll()
        window.contentView = NSHostingView(rootView: ColumnBrowserView()
            .environment(app).environment(library).environment(connection).environment(player)
            .environment(Navigator()).defaultAppStorage(defaults)
            .frame(width: 1_100, height: 600))
        window.orderFront(nil)
    }

    func close() {
        stopSavingScroll()
        window.orderOut(nil)
        window.contentView = nil
        defaults.removePersistentDomain(forName: suite)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where Self.isBrowserPreference(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in standardBrowserPreferences { UserDefaults.standard.set(value, forKey: key) }
    }

    private static func isBrowserPreference(_ key: String) -> Bool {
        ["trackSort.browser", "trackScroll.browser", "trackColumns.browser"].contains(key)
            || key.hasPrefix("trackColumnWidth.browser.")
    }

    private func stopSavingScroll() {
        for table in tables {
            guard let coordinator = table.dataSource as? MusicTrackTable.Coordinator else { continue }
            coordinator.parent.scrollAutosaveKey = nil
            coordinator.pendingScrollSave?.cancel()
        }
    }

    private var tables: [NSTableView] {
        func collect(_ view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap(collect)
        }
        return window.contentView.map(collect) ?? []
    }

    var panes: [NSTableView] {
        tables.filter { !($0.dataSource is MusicTrackTable.Coordinator) }.sorted {
            $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x
        }
    }

    var displayed: [Song] {
        tables.compactMap { $0.dataSource as? MusicTrackTable.Coordinator }.first?.displayed ?? []
    }

    func waitForTracks(_ count: Int) async throws {
        try await waitUntil {
            self.displayed.count == count && self.panes.count == 4 && self.panes.first?.numberOfRows == 3
        }
    }

    func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<250 {
            window.contentView?.layoutSubtreeIfNeeded()
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await condition(), "Browser did not reach the expected rendered state")
        try #require(await condition())
    }

    func click(pane: Int, row: Int) throws {
        let table = try #require(panes.indices.contains(pane) ? panes[pane] : nil)
        try #require(row < table.numberOfRows)
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown))
    }
}
