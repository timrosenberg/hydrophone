import SwiftUI

/// The main window shell: a NavigationSplitView with the iTunes-style sidebar,
/// a content detail area, and a persistent now-playing bar pinned to the
/// bottom. See docs/04-ui-ux.md.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(ConnectionModel.self) private var connection
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerModel.self) private var player

    // Persisted across launches so the app reopens on the last-used section.
    // @AppStorage (not @SceneStorage) so it restores regardless of the system's
    // window-restoration setting; the app is effectively single-window.
    @AppStorage("sidebarSelection") private var selectionRaw = SidebarSelection.albums.rawValue
    @State private var searchText = ""
    /// Programmatic focus for the sidebar search field (⌘F).
    @State private var searchPresented = false
    /// In-place navigation (opened album, artist hand-off) — no NavigationStack.
    @State private var navigator = Navigator()
    @AppStorage("showUpNext") private var showUpNext = false
    /// User-resizable Now Playing panel width (via the grab strip on its
    /// leading edge), persisted across launches.
    @AppStorage("nowPlayingPanelWidth") private var panelWidth = 344.0
    private static let panelWidthRange = 300.0...560.0
    @Environment(\.openSettings) private var openSettings

    private var selection: SidebarSelection? { SidebarSelection(rawValue: selectionRaw) }

    var body: some View {
        // The now-playing experience lives in the window's real unified toolbar
        // (see HydrophoneApp's window/toolbar style): transport leading, the
        // now-playing display centered, volume + panel toggle trailing; search
        // sits in the sidebar. Using the native toolbar — rather than a custom
        // bar drawn above the split view — means window dragging, traffic
        // lights, resize and full-screen are all handled by the system.
        // columnVisibility is pinned to .all: the sidebar is permanently
        // visible by design (the toggle is removed below), and leaving the
        // visibility "automatic" let the split view re-evaluate it while the
        // inspector opens/closes — briefly collapsing and restoring the
        // sidebar, which read as the whole window jumping.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selection: Binding(
                get: { selection },
                set: { selectionRaw = ($0 ?? .albums).rawValue }
            ), onReselect: {
                // Re-clicking the current section returns to its root — the
                // tap-current-tab-pops convention. Different-row clicks are
                // handled by the selectionRaw observer below.
                navigator.album = nil
            })
        } detail: {
            // The Now Playing panel is a width-animated trailing pane INSIDE
            // the detail column — deliberately NOT `.inspector` (which shoves
            // the sidebar off-screen during its insertion; verified
            // frame-by-frame) — and it opens BELOW the toolbar, so the
            // toolbar's layout is entirely untouched by the toggle: nothing
            // up there needs to move, and NSToolbar re-layout (which snaps,
            // never animates) is never triggered. The pane and the detail
            // column redistribute in one SwiftUI animation.
            VStack(spacing: 0) {
                // The pinned hairline is the toolbar's bottom border — and it
                // keeps scrollable content from extending up under the (fully
                // transparent) toolbar: scroll views only underlap a safe-area
                // edge they sit flush against, and without a NavigationStack
                // there's no scroll-edge material to blur what pokes through.
                Divider()
                HStack(spacing: 0) {
                    detail
                        .frame(maxWidth: .infinity)
                    if showUpNext && nowPlayingAvailable {
                        Divider()
                        NowPlayingPanel()
                            .frame(width: panelWidth.clamped(to: Self.panelWidthRange))
                            .transition(.move(edge: .trailing))
                            // The grab strip straddles the divider; width
                            // changes don't animate (the animation below is
                            // keyed on visibility only), so dragging is live.
                            .overlay(alignment: .leading) {
                                PanelResizeHandle(width: $panelWidth, range: Self.panelWidthRange,
                                                   anchoredEdge: .trailing)
                                    .offset(x: -5)
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.22),
                           value: showUpNext && nowPlayingAvailable)
                .clipped()
            }
        }
        .toolbar {
            // NOTE: SwiftUI on macOS cannot host custom toolbar items in the
            // strip above the sidebar (attaching them to the sidebar column
            // breaks the toolbar layout; .automatic there even drops the whole
            // NSToolbar) — so the transport leads the detail column, right
            // beside the sidebar divider, as close to the traffic lights as
            // the framework allows.
            // Keep the system-drawn bubbles' internal whitespace balanced.
            // Eight points per side preserves the previous total inset, so
            // neither item changes width or disturbs the centered LCD.
            ToolbarItem(placement: .navigation) {
                TransportControls()
                    .padding(.horizontal, 8)
            }
            ToolbarItem(placement: .principal) {
                // The LCD remains the sole principal item, so the transient
                // loading status cannot change its centered position. A
                // leading overlay updates with the app-wide loading state but
                // does not participate in the principal item's width (#102).
                NowPlayingDisplay()
                    .overlay(alignment: .leading) {
                        if library.songsAreLoading {
                            LibraryLoadingStatus()
                                // `offset` draws outside the principal item's
                                // measured bounds, leaving the LCD centered.
                                .offset(x: -(LibraryLoadingStatus.width + 16))
                        }
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 14) {
                    VolumeControl()
                    Button { withAnimation { showUpNext.toggle() } } label: {
                        Label("Now Playing", systemImage: "list.bullet.rectangle")
                    }
                    .help(showUpNext ? "Hide Now Playing" : "Show Now Playing")
                    .disabled(!nowPlayingAvailable)
                }
                .padding(.horizontal, 8)
            }
        }
        // In the sidebar (Music-style): a fixed, always-expanded field that
        // can't collapse into an icon or hop between columns the way the
        // toolbar placement did when the inspector squeezed the detail area.
        .searchable(text: $searchText, isPresented: $searchPresented,
                    placement: .sidebar, prompt: "Search")
        // ⌘F focuses the search field — a hidden shortcut button, since
        // .searchable has no command-level focus hook.
        .background {
            Button("") { searchPresented = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .overlay {
            if !isConnected { notConnectedOverlay }
        }
        // Playback failures (undecodable stream, dead server mid-track) were
        // recorded but never shown; surface them once, dismissably.
        .alert("Can't Play Track", isPresented: Binding(
            get: { player.lastError != nil },
            set: { if !$0 { player.clearError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.lastError ?? "")
        }
        .environment(navigator)
        // Switching sections or typing a query leaves the opened album.
        // (Clearing the query keeps it — "Show Album in Library" clears any
        // active search while opening the current track's album.)
        .onChange(of: selectionRaw) { navigator.album = nil }
        .onChange(of: searchText) { _, query in
            if !query.isEmpty { navigator.album = nil }
        }
        // Controls-menu requests (Go to Time…, Show Album in Library) live in
        // their own modifier — inlining them here pushed body past what the
        // type-checker resolves in reasonable time.
        .modifier(CurrentTrackCommands(searchText: $searchText, navigator: navigator))
        // Search hands an artist off to the Artists section.
        .onChange(of: navigator.pendingArtist) { _, artist in
            if artist != nil {
                selectionRaw = SidebarSelection.artists.rawValue
                searchText = ""
            }
        }
        .task {
            await connection.refresh()
        }
        // Drive section loading here rather than from each detail view's own
        // `.task`: the detail root view didn't reliably run its `.task` on
        // initial launch, which left the first screen blank.
        .task(id: selectionRaw) {
            await load(selection)
        }
    }

    private func load(_ selection: SidebarSelection?) async {
        switch selection {
        case .home: await library.loadHomeIfNeeded()
        case .albums: await library.loadAlbumsIfNeeded()
        case .artists: await library.loadArtistsIfNeeded()
        case .songs: await library.loadSongsIfNeeded()
        case .favorites: await library.loadStarredIfNeeded()
        case .composers: await library.loadComposersIfNeeded()
        case .playlist, nil: break
        }
    }

    private var isConnected: Bool {
        if case .connected = connection.state { return true }
        return connection.isConfigured
    }

    private var nowPlayingAvailable: Bool { player.hasNowPlayingContent }

    @ViewBuilder
    private var detail: some View {
        // An opened album renders in place of the current section (with its
        // own inline Back link); search results sit under that.
        if let album = navigator.album {
            AlbumDetailView(album: album)
        } else if !searchText.isEmpty {
            SearchResultsView(query: searchText)
        } else {
            switch selection {
            case .home: HomeView()
            case .albums: AlbumsView()
            case .artists: ArtistsView()
            case .songs: SongsView()
            case .favorites: FavoritesView()
            case .composers: ComposersView()
            case let .playlist(id): PlaylistDetailView(playlistID: id)
            case nil: ContentUnavailableView("Select an item", systemImage: "music.note")
            }
        }
    }

    /// Handler for Show Album in Library (⇧⌘L / the panel's album line). A
    /// separate modifier to keep RootView.body type-checkable.
    private struct CurrentTrackCommands: ViewModifier {
        @Binding var searchText: String
        let navigator: Navigator
        @Environment(AppModel.self) private var app
        @Environment(PlayerModel.self) private var player
        @Environment(LibraryModel.self) private var library

        func body(content: Content) -> some View {
            content
                .onChange(of: app.showCurrentAlbumRequests) {
                    guard let albumId = player.currentTrack?.albumId else { return }
                    Task {
                        if let album = await library.album(id: albumId) {
                            searchText = ""
                            navigator.openAlbum(album)
                        }
                    }
                }
        }
    }

    private var notConnectedOverlay: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text("Connect to your OpenSubsonic server to browse your library.")
        } actions: {
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .background(.background)
    }
}
