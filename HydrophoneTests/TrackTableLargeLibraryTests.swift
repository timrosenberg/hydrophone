import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct TrackTableLargeLibraryTests {
    private static var retainedWindows: [NSWindow] = []

    @Test func defaultTitleSortOrdersFourteenThousandRows() async throws {
        let defaultsKey = "large-default-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "trackSort.\(defaultsKey)") }
        let songs = (0..<14_082).reversed().map { index in
            Song(id: "song-\(index)", title: String(format: "Track %05d", index))
        }

        let table = try await loadedTable(
            in: host(table(tracks: songs, sortKey: defaultsKey, defaultSortKey: "title")),
            rows: songs.count
        )
        let coordinator = try #require(table.dataSource as? MusicTrackTable.Coordinator)

        #expect(table.sortDescriptors.first?.key == "title")
        #expect(table.sortDescriptors.first?.ascending == true)
        #expect(coordinator.displayed.first?.id == "song-0")
        #expect(coordinator.displayed.last?.id == "song-14081")
    }

    @Test func persistedUserSortOverridesTheDefaultTitleSort() async throws {
        let defaultsKey = "large-persisted-\(UUID().uuidString)"
        UserDefaults.standard.set("artist|desc", forKey: "trackSort.\(defaultsKey)")
        defer { UserDefaults.standard.removeObject(forKey: "trackSort.\(defaultsKey)") }
        let songs = [
            Song(id: "title-first", title: "Alpha", artist: "Alpha"),
            Song(id: "artist-first", title: "Zulu", artist: "Zulu")
        ]

        let appKitTable = try await loadedTable(
            in: host(table(tracks: songs, sortKey: defaultsKey, defaultSortKey: "title")),
            rows: songs.count
        )
        let coordinator = try #require(appKitTable.dataSource as? MusicTrackTable.Coordinator)

        #expect(appKitTable.sortDescriptors.first?.key == "artist")
        #expect(appKitTable.sortDescriptors.first?.ascending == false)
        #expect(coordinator.displayed.map(\.id) == ["artist-first", "title-first"])
    }

    @Test func equalTitlesUseSongIDAsADeterministicTieBreak() async throws {
        let defaultsKey = "large-tie-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "trackSort.\(defaultsKey)") }
        let songs = [
            Song(id: "z-id", title: "Same Title"),
            Song(id: "a-id", title: "Same Title")
        ]

        let appKitTable = try await loadedTable(
            in: host(table(tracks: songs, sortKey: defaultsKey, defaultSortKey: "title")),
            rows: songs.count
        )
        let coordinator = try #require(appKitTable.dataSource as? MusicTrackTable.Coordinator)

        #expect(coordinator.displayed.map(\.id) == ["a-id", "z-id"])
    }

    @Test func deepScrollRestoreWaitsForEnoughIncrementalRows() async throws {
        let defaultsKey = "large-scroll-\(UUID().uuidString)"
        let savedOffset: CGFloat = 12_000
        UserDefaults.standard.set(savedOffset, forKey: "trackScroll.\(defaultsKey)")
        defer { UserDefaults.standard.removeObject(forKey: "trackScroll.\(defaultsKey)") }
        let state = LargeTableFixtureState(scrollKey: defaultsKey)
        let window = host(LargeTableFixture(state: state))
        let partial = try await loadedTable(in: window, rows: 100)
        let coordinator = try #require(partial.dataSource as? MusicTrackTable.Coordinator)

        #expect(coordinator.scrollRestored == false)

        state.tracks = LargeTableFixtureState.makeSongs(count: 1_000)
        state.isLoading = false
        let complete = try await loadedTable(in: window, rows: 1_000)
        try await waitUntil("restore the deep saved offset") {
            abs((complete.enclosingScrollView?.contentView.bounds.minY ?? 0) - savedOffset) < 1
        }
        #expect(coordinator.scrollRestored)
    }

    @Test func loadingProgressRendersActivityAndThePublishedSongCount() {
        let progress = SongsLoadingProgress(songCount: 500)
        let view = NSHostingView(rootView: progress)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        view.layoutSubtreeIfNeeded()

        #expect(findSubview(NSProgressIndicator.self, in: view) != nil)
        #expect(progress.statusText == "500 songs loaded")
    }

    @Test func incomingSortedPagesPreserveTheSelectedSongAndPlaybackTarget() async throws {
        let state = LargeTableFixtureState(scrollKey: "selection-\(UUID().uuidString)")
        state.tracks = [Song(id: "b", title: "B"), Song(id: "c", title: "C")]
        let window = host(LargeTableFixture(state: state))
        let table = try await loadedTable(in: window, rows: 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(state.selection == [1])

        state.tracks.append(Song(id: "a", title: "A"))
        _ = try await loadedTable(in: window, rows: 3)
        try await waitUntil("keep C selected after inserting A") {
            table.selectedRowIndexes == IndexSet(integer: 2) && state.selection == [2]
        }
        let coordinator = try #require(table.dataSource as? MusicTrackTable.Coordinator)
        coordinator.playSelected()
        #expect(state.playedID == "c")

        state.tracks.append(Song(id: "aa", title: "AA"))
        state.isLoading = false
        _ = try await loadedTable(in: window, rows: 4)
        try await waitUntil("keep C selected on the final page") { state.selection == [3] }
        coordinator.playSelected()
        #expect(state.playedID == "c")
    }

    @Test(arguments: [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification])
    func manualScrollCancelsAPendingDeepRestore(notification: Notification.Name) async throws {
        let key = "large-scroll-cancel-\(UUID().uuidString)"
        UserDefaults.standard.set(12_000, forKey: "trackScroll.\(key)")
        defer { UserDefaults.standard.removeObject(forKey: "trackScroll.\(key)") }
        let state = LargeTableFixtureState(scrollKey: key)
        let window = host(LargeTableFixture(state: state))
        let table = try await loadedTable(in: window, rows: 100)
        let scroll = try #require(table.enclosingScrollView)
        let coordinator = try #require(table.dataSource as? MusicTrackTable.Coordinator)
        #expect(!coordinator.scrollRestored)

        // AppKit emits this for gesture/scroller tracking, not layout changes.
        if notification == NSScrollView.willStartLiveScrollNotification {
            NotificationCenter.default.post(name: notification, object: scroll)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        if notification == NSScrollView.didLiveScrollNotification {
            NotificationCenter.default.post(name: notification, object: scroll)
        }
        #expect(scroll.contentView.bounds.minY == 600)
        #expect(coordinator.scrollRestored)

        state.tracks = LargeTableFixtureState.makeSongs(count: 1_000)
        state.isLoading = false
        _ = try await loadedTable(in: window, rows: 1_000)
        #expect(scroll.contentView.bounds.minY < 2_400)
    }

    @Test func finalMetadataSortPreservesTheSelectedSong() async throws {
        let state = LargeTableFixtureState(scrollKey: "metadata-\(UUID().uuidString)")
        state.defaultSortKey = "work"
        state.tracks = [Song(id: "b", title: "B"), Song(id: "c", title: "C")]
        let window = host(LargeTableFixture(state: state))
        let table = try await loadedTable(in: window, rows: 2)
        #expect(table.sortDescriptors.first?.key == "work")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(state.selection == [1])

        state.tracks[0].work = "Zulu"
        state.tracks[1].work = "Alpha"
        state.isLoading = false
        let coordinator = try #require(table.dataSource as? MusicTrackTable.Coordinator)
        try await waitUntil("apply final Work sorting") {
            window.contentView?.layoutSubtreeIfNeeded()
            return coordinator.displayed.first?.id == "c"
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(state.selection == [0])
        coordinator.playSelected()
        #expect(state.playedID == "c")
    }

    private func table(tracks: [Song], sortKey: String, defaultSortKey: String?) -> MusicTrackTable {
        MusicTrackTable(
            tracks: tracks,
            sortAutosaveKey: sortKey,
            defaultSortKey: defaultSortKey,
            columns: [.title, .artist],
            selection: .constant([]),
            isFavorite: { _ in false },
            onPlay: { _, _ in },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        )
    }

    private func host<Content: View>(_ content: Content) -> NSWindow {
        let view = NSHostingView(rootView: content.frame(width: 360, height: 240))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 360, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        return window
    }

    private func loadedTable(in window: NSWindow, rows: Int) async throws -> NSTableView {
        try await waitUntil("load \(rows) table rows") {
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

    private func findSubview<View: NSView>(_ type: View.Type, in view: NSView?) -> View? {
        if let match = view as? View { return match }
        for child in view?.subviews ?? [] {
            if let match = findSubview(type, in: child) { return match }
        }
        return nil
    }

    private func waitUntil(_ operation: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Table did not \(operation)")
    }
}

@MainActor
@Observable
private final class LargeTableFixtureState {
    var tracks = makeSongs(count: 100)
    var isLoading = true
    var selection: Set<Int> = []
    var playedID: String?
    var defaultSortKey = "title"
    let scrollKey: String

    init(scrollKey: String) {
        self.scrollKey = scrollKey
    }

    static func makeSongs(count: Int) -> [Song] {
        (0..<count).map { Song(id: "song-\($0)", title: "Track \($0)") }
    }
}

private struct LargeTableFixture: View {
    @Bindable var state: LargeTableFixtureState

    var body: some View {
        MusicTrackTable(
            tracks: state.tracks,
            defaultSortKey: state.defaultSortKey,
            scrollAutosaveKey: state.scrollKey,
            contentIsLoading: state.isLoading,
            columns: [.title, .work],
            nativeFeaturesAvailable: true,
            selection: $state.selection,
            isFavorite: { _ in false },
            onPlay: { songs, index in state.playedID = songs[index].id },
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            makeMenu: { _, _ in nil }
        )
    }
}
