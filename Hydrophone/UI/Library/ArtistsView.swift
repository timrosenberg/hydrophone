import SwiftUI

/// Artists as a master-detail split (no push navigation): the artist list on
/// the left, the selected artist's albums on the right. Search hands an artist
/// off via `Navigator.pendingArtist`. See docs/04-ui-ux.md.
struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    /// Persisted, not @State: opening an album replaces this whole view in
    /// the detail column (RootView), so view state dies while browsing an
    /// album — Back must land on the same artist. Doubles as cross-launch
    /// restoration (the app-wide @AppStorage pattern, docs/06).
    @AppStorage("artistsSelectedID") private var selectedID: Artist.ID?
    @AppStorage("artistsListScrollID") private var storedScrollID = ""
    @State private var scrollRestored = false

    private var scrollBinding: Binding<Artist.ID?> {
        .scrollMemory(read: { storedScrollID }, write: { storedScrollID = $0 },
                      consumed: $scrollRestored,
                      topIDs: { Set(library.artists.prefix(1).map(\.id)) })
    }

    /// User-resizable Artists list width (via the grab strip on its trailing
    /// edge), persisted across launches — mirrors RootView's
    /// nowPlayingPanelWidth pattern.
    @AppStorage("artistsListWidth") private var listWidth = 240.0
    private static let listWidthRange = 180.0...360.0

    private var selected: Artist? {
        library.artists.first { $0.id == selectedID } ?? library.artists.first
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(library.artists) { artist in
                    let isSelected = artist.id == selectedID
                    HStack {
                        Text(artist.name).lineLimit(1)
                            .foregroundStyle(isSelected ? .white : .primary)
                        Spacer()
                        if let count = artist.albumCount {
                            Text("\(count)").monospacedDigit()
                                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.6))
                                                            : AnyShapeStyle(.tertiary))
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(artist.id)
                    // Accent selection matching the track list (the system
                    // highlight — suppressed below — renders the accent
                    // muted through the list material).
                    .listRowBackground(isSelected ? Color.accentColor : nil)
                    .contextMenu {
                        Button("Start Artist Radio") { app.startRadio(from: artist) }
                            .disabled(app.isPreparingMix)
                    }
                }
            }
            .listRowSeparatorTint(Color(nsColor: .separatorColor).opacity(0.75))
            .listStyle(.plain)
            .playPauseOnSpace()
            .background(ListSelectionHighlightDisabler())
            .background(ListScrollMemory(ids: library.artists.map(\.id), position: scrollBinding))
            .frame(width: listWidth)
            .overlay(alignment: .trailing) {
                PanelResizeHandle(width: $listWidth, range: Self.listWidthRange, anchoredEdge: .leading)
                    .offset(x: 5)
            }

            Divider()

            if let artist = selected {
                ArtistDetailView(artist: artist)
            } else {
                ContentUnavailableView("No Artists", systemImage: "music.mic")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await library.loadArtistsIfNeeded()
            if selectedID == nil { selectedID = library.artists.first?.id }
        }
        // Consume an artist handed off from search results.
        .task(id: navigator.pendingArtist) {
            if let artist = navigator.pendingArtist {
                selectedID = artist.id
                navigator.pendingArtist = nil
            }
        }
    }
}

/// The selected artist's albums as a grid, under a header with the artist's
/// name (no artwork — see #61) and an Artist Radio button. Selecting an
/// album opens it in place (via `Navigator`). Hydrophone does not fetch or
/// display third-party artist biographies or a Similar Artists shelf
/// (product decision, #112) — album loading is the only work this view does.
struct ArtistDetailView: View {
    let artist: Artist
    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @State private var albums: [Album] = []

    /// Per-artist scroll memory (see `Binding.scrollMemory`): scoped by
    /// artist id so only Back-from-an-album restores; the first album is the
    /// top id.
    @AppStorage("artistDetailScroll") private var storedScroll = ""
    /// The restore has been consumed by a user scroll (see `scrollMemory`).
    @State private var scrollRestored = false

    private var scrollBinding: Binding<Album.ID?> {
        .scrollMemory(read: { storedScroll }, write: { storedScroll = $0 },
                      consumed: $scrollRestored, scope: artist.id,
                      topIDs: { Set(albums.prefix(1).map(\.id)) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                AlignedAdaptiveGrid(tileMinimum: 150, spacing: 16) {
                    ForEach(albums) { album in
                        Button { navigator.openAlbum(album) } label: {
                            AlbumGridCell(coverArt: album.coverArt,
                                          cacheKey: album.artworkKey,
                                          title: album.name,
                                          subtitle: album.year.map(String.init))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: scrollBinding, anchor: .top)
        .task(id: artist.id) {
            let loadedAlbums = await library.albums(forArtist: artist.id)
            // A cancelled load (artist switched underneath) resolves empty —
            // don't clobber the shown artist's grid with it.
            if Task.isCancelled { return }
            albums = loadedAlbums
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artist.name).font(.largeTitle).bold()
            Button {
                app.startRadio(from: artist)
            } label: {
                Label {
                    Text("Artist Radio")
                } icon: {
                    if app.isPreparingMix {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(app.isPreparingMix)
            .help("Play a mix of this artist and similar music")
        }
        .padding(.horizontal).padding(.top, 14)
    }
}
