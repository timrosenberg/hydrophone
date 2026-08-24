import SwiftUI
import AppKit

/// The app's single track list, used everywhere (Songs, album/genre/playlist
/// detail, favorites, search). A thin SwiftUI wrapper over the AppKit-backed
/// `MusicTrackTable`, which provides Music-faithful behavior: edge-to-edge
/// stripes, double-click-to-play, Return-to-play, a now-playing speaker column,
/// click-to-sort headers, drag-to-playlist, and a favorite column. Supplying
/// `onMovePlaylist`/`onRemoveFromPlaylist` switches it to playlist mode (no
/// sorting; the context menu offers reorder + remove). See docs/04-ui-ux.md.
struct TrackTableView: View {
    let tracks: [Song]
    /// Content columns to show, in order — specified explicitly per call site.
    let columns: [TrackColumn]
    /// When set, the table's sort key/direction and customizable column
    /// preferences persist under this view-kind name (e.g. "songs", "favorites").
    var sortAutosaveKey: String?
    /// When set, the scroll offset persists too — only for views whose content
    /// is stable across launches (see `MusicTrackTable.scrollAutosaveKey`).
    var scrollAutosaveKey: String?
    var onRemoveFromPlaylist: ((IndexSet) -> Void)?
    var onMovePlaylist: ((IndexSet, Int) -> Void)?
    /// Disc → subtitle; non-nil opts into disc group headers on multi-disc
    /// content (the album page passes this).
    var discHeaders: [Int: String]?
    /// Opts into the header right-click column picker (#37). Off by default.
    var columnsCustomizable: Bool = false

    @Environment(AppModel.self) private var app
    @Environment(ConnectionModel.self) private var connection
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Navigator.self) private var navigator

    @State private var selection = Set<Int>()
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var pendingSongIds: [String] = []
    /// Track shown in the "Get Info" sheet (nil = none).
    @State private var infoSong: Song?

    private var isPlaylist: Bool { onMovePlaylist != nil || onRemoveFromPlaylist != nil }

    var body: some View {
        MusicTrackTable(
            tracks: tracks,
            sortable: !isPlaylist,
            sortAutosaveKey: sortAutosaveKey,
            scrollAutosaveKey: isPlaylist ? nil : scrollAutosaveKey,
            columns: columns,
            columnsCustomizable: columnsCustomizable,
            nativeFeaturesAvailable: connection.nativeFeaturesState == .available,
            discHeaders: discHeaders,
            nowPlayingID: player.currentTrack?.id,
            starSignature: library.starSignature,
            selection: $selection,
            isFavorite: { library.isStarred($0) },
            onPlay: { displayed, index in player.play(tracks: displayed, startAt: index) },
            onPlayNext: { song in player.playNext([song]) },
            onToggleFavorite: { song in toggleStar([song.id], star: !library.isStarred(song)) },
            makeMenu: { displayed, indices in buildMenu(displayed, indices) }
        )
        .sheet(item: $infoSong) { song in
            TrackInfoView(song: song)
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = pendingSongIds
                guard !name.isEmpty else { return }
                Task { await library.createPlaylist(name: name, songIds: ids) }
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("Enter a name for the new playlist.")
        }
    }

    private func buildMenu(_ displayed: [Song], _ indices: IndexSet) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let chosen = indices.sorted().compactMap { displayed.indices.contains($0) ? displayed[$0] : nil }
        guard !chosen.isEmpty else { return menu }

        menu.addItem(ClosureMenuItem(title: "Play") {
            player.play(tracks: displayed, startAt: indices.min() ?? 0)
        })
        menu.addItem(ClosureMenuItem(title: "Play Next") { player.playNext(chosen) })
        menu.addItem(ClosureMenuItem(title: "Add to Up Next") { player.enqueue(chosen) })
        menu.addItem(.separator())

        menu.addItem(addToPlaylistItem(chosen))

        let allStarred = chosen.allSatisfy { library.isStarred($0) }
        menu.addItem(ClosureMenuItem(title: allStarred ? "Remove from Favorites" : "Add to Favorites") {
            toggleStar(chosen.map(\.id), star: !allStarred)
        })

        // Get Info + navigation to the track's album/artist — single selection.
        if chosen.count == 1, let song = chosen.first {
            addSingleSongItems(to: menu, song: song)
        }

        if isPlaylist {
            addPlaylistModeItems(to: menu, indices: indices)
        }
        return menu
    }

    private func addToPlaylistItem(_ chosen: [Song]) -> NSMenuItem {
        let addSub = NSMenu()
        addSub.autoenablesItems = false
        addSub.addItem(ClosureMenuItem(title: "New Playlist…") {
            pendingSongIds = chosen.map(\.id)
            newPlaylistName = ""
            showNewPlaylist = true
        })
        if !library.playlists.isEmpty {
            addSub.addItem(.separator())
            for playlist in library.playlists {
                addSub.addItem(ClosureMenuItem(title: playlist.name) {
                    let ids = chosen.map(\.id)
                    Task { await library.addToPlaylist(id: playlist.id, songIds: ids) }
                })
            }
        }
        let addItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        addItem.submenu = addSub
        return addItem
    }

    private func addSingleSongItems(to menu: NSMenu, song: Song) {
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Start Radio", enabled: !app.isPreparingMix) {
            app.startRadio(from: song)
        })
        menu.addItem(ClosureMenuItem(title: "Get Info") { infoSong = song })
        if let albumId = song.albumId {
            menu.addItem(ClosureMenuItem(title: "Go to Album") {
                Task {
                    if let album = await library.album(id: albumId) {
                        navigator.openAlbum(album)
                    }
                }
            })
        }
        if let artistId = song.artistId {
            menu.addItem(ClosureMenuItem(title: "Go to Artist") {
                navigator.openArtist(Artist(id: artistId, name: song.artist ?? "—"))
            })
        }
    }

    private func addPlaylistModeItems(to menu: NSMenu, indices: IndexSet) {
        menu.addItem(.separator())
        let lo = indices.min() ?? 0, hi = indices.max() ?? 0
        if let onMovePlaylist {
            menu.addItem(ClosureMenuItem(title: "Move to Top", enabled: lo != 0) {
                onMovePlaylist(indices, 0)
            })
            menu.addItem(ClosureMenuItem(title: "Move Up", enabled: lo != 0) {
                onMovePlaylist(indices, lo - 1)
            })
            menu.addItem(ClosureMenuItem(title: "Move Down", enabled: hi != tracks.count - 1) {
                onMovePlaylist(indices, hi + 2)
            })
            menu.addItem(ClosureMenuItem(title: "Move to Bottom", enabled: hi != tracks.count - 1) {
                onMovePlaylist(indices, tracks.count)
            })
        }
        if let onRemoveFromPlaylist {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Remove from Playlist") { onRemoveFromPlaylist(indices) })
        }
    }

    private func toggleStar(_ songIds: [String], star: Bool) {
        Task { await library.setStarred(star, songIds: songIds) }
    }
}

func formatTime(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "—" }
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
}

func formatTime(_ seconds: TimeInterval) -> String {
    formatTime(Int(seconds.rounded()))
}

/// Short localized date for the Date Added / Last Played columns.
func formatShortDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .abbreviated, time: .omitted)
}

/// "44 kHz"-style label for the Sample Rate column; one decimal only when
/// the rate isn't a whole number of kHz (e.g. 44.1 kHz).
func formatSampleRate(_ hertz: Int?) -> String {
    guard let hertz, hertz > 0 else { return "—" }
    let khz = Double(hertz) / 1000
    guard khz.truncatingRemainder(dividingBy: 1) != 0 else { return "\(Int(khz)) kHz" }
    return String(format: "%.1f kHz", khz)
}
