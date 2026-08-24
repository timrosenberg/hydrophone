import SwiftUI

/// A server playlist's tracks, rendered with the shared `TrackTableView` (the
/// AppKit-backed Music-style table) in playlist mode: double-click-to-play, a
/// now-playing speaker indicator, reliable selection, and reorder/remove in the
/// row context menu. Header has play/shuffle + rename. See docs/04-ui-ux.md.
struct PlaylistDetailView: View {
    let playlistID: String
    @Environment(LibraryModel.self) private var library
    @State private var playlist: Playlist?
    @State private var renameText = ""
    @State private var showRename = false

    private var tracks: [Song] { playlist?.entry ?? [] }

    var body: some View {
        Group {
            if let playlist {
                VStack(spacing: 0) {
                    header(playlist)
                    Divider()
                    TrackTableView(
                        tracks: tracks,
                        columns: [.title, .artist, .album, .genre, .quality, .time],
                        sortAutosaveKey: "playlist",
                        onRemoveFromPlaylist: { offsets in remove(offsets) },
                        onMovePlaylist: { offsets, destination in move(offsets, to: destination) },
                        columnsCustomizable: true
                    )
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .task(id: playlistID) { await reload() }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    await library.renamePlaylist(id: playlistID, to: name)
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func header(_ playlist: Playlist) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(coverArt: playlist.coverArt, size: 96, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.name).font(.title2).bold()
                Text(trackSummary(tracks)).foregroundStyle(.secondary)
                HStack { PlayShuffleButtons(tracks: tracks) }
                    .padding(.top, 4)
            }
            Spacer()

            // Options live in the header now that the window toolbar is replaced
            // by the custom now-playing bar.
            Menu {
                Button("Rename…") {
                    renameText = playlist.name
                    showRename = true
                }
            } label: {
                Label("Playlist Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playlist Options")
        }
        .padding()
    }

    // MARK: - Edits

    private func reload() async {
        playlist = await library.playlist(id: playlistID)
    }

    private func remove(_ offsets: IndexSet) {
        let indexes = Array(offsets)
        playlist?.entry?.remove(atOffsets: offsets) // optimistic
        Task {
            await library.removeFromPlaylist(id: playlistID, indexes: indexes)
            await reload()
        }
    }

    private func move(_ offsets: IndexSet, to destination: Int) {
        guard var order = playlist?.entry else { return }
        order.move(fromOffsets: offsets, toOffset: destination)
        playlist?.entry = order // optimistic
        let ids = order.map(\.id)
        let name = playlist?.name ?? ""
        Task {
            await library.reorderPlaylist(id: playlistID, name: name, songIds: ids)
            await reload()
        }
    }
}
