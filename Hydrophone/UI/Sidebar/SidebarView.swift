import SwiftUI

/// The iTunes-style sidebar: a Library section and a Playlists section with
/// create / rename / delete. See docs/04-ui-ux.md.
struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    /// Called when the already-selected row is clicked again — RootView pops
    /// back to the section root (dismisses an open album). See `04`.
    var onReselect: () -> Void = {}
    @Environment(LibraryModel.self) private var library
    @Environment(AppModel.self) private var app
    @Environment(ConnectionModel.self) private var connection

    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var deleting: Playlist?
    @State private var dropTargetID: String?

    /// The asset red for the row icons (red icons over the neutral-gray
    /// selection pill, per the iTunes reference — see `rowBackground`).
    private let iconColor = Color("AccentColor")

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                libraryItem("Home", "house", .home)
                libraryItem("Albums", "square.stack", .albums)
                libraryItem("Artists", "music.mic", .artists)
                libraryItem("Songs", "music.quarternote.3", .songs)
                libraryItem("Favorites", "star", .favorites)
                if connection.nativeFeaturesState == .available {
                    libraryItem("Composers", composerSystemImage, .composers)
                }
            }

            Section {
                if library.playlists.isEmpty {
                    Text("No playlists")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(library.playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        newName = ""
                        showNewPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Playlist")
                    .accessibilityLabel("New Playlist")
                }
            }
        }
        .background(ListSelectionHighlightDisabler())
        .background(ListReselectMonitor(onReselect: onReselect))
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        // Drop the automatic sidebar-toggle (we want the sidebar always visible).
        .toolbar(removing: .sidebarToggle)
        .task {
            await library.loadPlaylistsIfNeeded()
        }
        // File → New Playlist (⌘N) routes here via AppModel.
        .onChange(of: app.newPlaylistRequests) {
            newName = ""
            showNewPlaylist = true
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    if let created = await library.createPlaylist(name: name) {
                        selection = .playlist(id: created.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: renamingBinding, presenting: renaming) { playlist in
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let id = playlist.id
                Task { await library.renamePlaylist(id: id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Playlist", isPresented: deletingBinding, presenting: deleting) { playlist in
            Button("Delete", role: .destructive) {
                let id = playlist.id
                Task { await library.deletePlaylist(id: id) }
                if selection == .playlist(id: id) { selection = .albums }
            }
            Button("Cancel", role: .cancel) {}
        } message: { playlist in
            Text("Delete “\(playlist.name)”? This cannot be undone.")
        }
    }

    private var composerSystemImage: String {
        if #available(macOS 26.0, *) {
            "apple.classical.pages.fill"
        } else {
            "person.2"
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        Label(playlist.name, systemImage: "music.note.list")
            .listItemTint(.fixed(iconColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(SidebarSelection.playlist(id: playlist.id))
            .listRowBackground(rowBackground(selected: selection == .playlist(id: playlist.id),
                                             dropTarget: dropTargetID == playlist.id))
            .dropDestination(for: DraggedTrack.self) { items, _ in
                // Multi-item drops arrive in no guaranteed order — the
                // source row index restores the on-screen order.
                let ids = items.sorted { $0.index < $1.index }.map(\.songId)
                guard !ids.isEmpty else { return false }
                let pid = playlist.id
                Task { await library.addToPlaylist(id: pid, songIds: ids) }
                return true
            } isTargeted: { targeted in
                if targeted {
                    dropTargetID = playlist.id
                } else if dropTargetID == playlist.id {
                    dropTargetID = nil
                }
            }
            .contextMenu {
                Button("Rename…") {
                    renameText = playlist.name
                    renaming = playlist
                }
                Button("Delete", role: .destructive) { deleting = playlist }
            }
    }

    @ViewBuilder
    private func libraryItem(_ title: String, _ symbol: String, _ tag: SidebarSelection) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        // Sidebar lists color Label icons through the item tint (a plain
        // foregroundStyle on the Image is overridden).
        .listItemTint(.fixed(iconColor))
        .tag(tag)
        .listRowBackground(rowBackground(selected: selection == tag, dropTarget: false))
    }

    /// The selection pill is drawn HERE (the system's is suppressed via
    /// `ListSelectionHighlightDisabler`) in Music's neutral gray — red icons
    /// over a gray pill, per the iTunes reference — with the standard
    /// sidebar-pill insets rather than edge-to-edge.
    @ViewBuilder
    private func rowBackground(selected: Bool, dropTarget: Bool) -> some View {
        if dropTarget {
            pill(iconColor.opacity(0.25))
        } else if selected {
            pill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        }
    }

    private func pill(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
