import SwiftUI

/// Grid of album artwork with infinite-scroll pagination. Selecting an album
/// opens its track list. See docs/04-ui-ux.md.
struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator

    /// Tracks the top-visible album id (see `Binding.scrollMemory`); cleared
    /// on filter/sort changes (a new ordering starts at the top). A saved id
    /// missing after relaunch (deep pagination) is a harmless no-op.
    @AppStorage("albumsScrollID") private var storedScrollID = ""
    /// The restore has been consumed by a user scroll (see `scrollMemory`).
    @State private var scrollRestored = false
    /// Zero means layout has not measured the grid yet; do not guess a size.
    @State private var tileWidth: CGFloat = 0
    @State private var visibleAlbumIDs: Set<Album.ID> = []

    private var prefetchRequests: [ArtworkCache.PrefetchRequest] {
        Self.artworkToPrefetch(albums: library.albums, visibleIDs: visibleAlbumIDs, tileWidth: tileWidth)
    }

    private var scrollBinding: Binding<Album.ID?> {
        .scrollMemory(read: { storedScrollID }, write: { storedScrollID = $0 },
                      consumed: $scrollRestored)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sort lives in the view's own header now that the window toolbar is
            // replaced by the custom now-playing bar.
            HStack {
                Spacer()
                Button { app.shuffleAlbums() } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(app.isPreparingMix)
                .help("Play random albums in full (uses the active filter)")
                filterMenu
                sortMenu
                    // Genre/year are list *types* server-side, so an active
                    // filter owns the ordering.
                    .disabled(library.albumFilter != .none)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ScrollView {
                AlignedAdaptiveGrid(tileMinimum: 160, spacing: 20, tileWidth: $tileWidth) {
                    ForEach(library.albums) { album in
                        Button { navigator.openAlbum(album) } label: {
                            AlbumGridCell(coverArt: album.coverArt,
                                          cacheKey: album.artworkKey,
                                          title: album.name,
                                          subtitle: album.artist ?? "—")
                        }
                        .buttonStyle(.plain)
                        .task {
                            if album.id == library.albums.last?.id {
                                await library.loadMoreAlbums()
                            }
                        }
                        .onAppear { visibleAlbumIDs.insert(album.id) }
                        .onDisappear { visibleAlbumIDs.remove(album.id) }
                    }
                }
                .padding(20)

                if case .loading = library.albumsState {
                    ProgressView().padding()
                }
            }
            .scrollPosition(id: scrollBinding, anchor: .top)
        }
        .navigationTitle("Albums")
        .onChange(of: prefetchRequests, initial: true) { _, requests in
            ArtworkCache.shared.prefetch(requests)
        }
        .onDisappear {
            visibleAlbumIDs.removeAll()
            ArtworkCache.shared.prefetch([])
        }
        .task {
            await library.loadAlbumsIfNeeded()
            await library.loadGenresIfNeeded()   // feeds the filter menu
        }
    }

    /// Derive one window from the furthest appearing cell. Measuring/resizing,
    /// scrolling and pagination all change this value and replace pending work.
    static func artworkToPrefetch(albums: [Album], visibleIDs: Set<Album.ID>,
                                  tileWidth: CGFloat) -> [ArtworkCache.PrefetchRequest] {
        guard tileWidth > 0,
              let last = albums.lastIndex(where: { visibleIDs.contains($0.id) }) else { return [] }
        let pixels = ArtworkView.fetchPixels(forSize: tileWidth)
        return albums.dropFirst(last + 1).prefix(ArtworkCache.prefetchLimit).map {
            .init(coverArt: $0.coverArt, cacheKey: $0.artworkKey, size: pixels)
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("All Albums") {
                Task { await library.changeAlbumFilter(to: .none) }
            }
            Picker("Genre", selection: filterBinding) {
                ForEach(library.genres) { genre in
                    Text(genre.value).tag(LibraryModel.AlbumFilter.genre(genre.value))
                }
            }
            .pickerStyle(.menu)
            Picker("Decade", selection: filterBinding) {
                ForEach(Array(stride(from: 2020, through: 1950, by: -10)), id: \.self) { decade in
                    Text(verbatim: "\(decade)s")
                        .tag(LibraryModel.AlbumFilter.years(from: decade, through: decade + 9))
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter Albums")
    }

    private var filterBinding: Binding<LibraryModel.AlbumFilter> {
        Binding(
            get: { library.albumFilter },
            set: { filter in
                storedScrollID = ""
                Task { await library.changeAlbumFilter(to: filter) }
            }
        )
    }

    private var filterLabel: String {
        switch library.albumFilter {
        case .none: return "Filter"
        case let .genre(name): return name
        case let .years(from, _): return "\(from)s"
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding(
                get: { library.albumSortType },
                set: { type in
                    storedScrollID = ""
                    Task { await library.changeAlbumSort(to: type) }
                }
            )) {
                Text("Recently Added").tag("newest")
                Text("Recently Played").tag("recent")
                Text("Most Played").tag("frequent")
                Text("Title").tag("alphabeticalByName")
                Text("Artist").tag("alphabeticalByArtist")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort Albums")
    }
}
