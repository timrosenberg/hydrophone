import SwiftUI

/// iTunes-style column browser: Genre → Artist → Album → Composer panes above
/// a filtered track table. Selecting in a pane narrows the panes to its right
/// and the tracks below. See docs/04-ui-ux.md.
struct ColumnBrowserView: View {
    @Environment(LibraryModel.self) private var library

    @State private var genrePresentation = SongPresentation([])
    @State private var isLoading = false
    @State private var genreLoadGeneration = 0

    // Pane selections persist across launches ("" = nothing selected). The
    // cascade (genre resets artist+album+composer, artist resets
    // album+composer, album resets composer) lives in the binding setters so
    // restore doesn't re-trigger it.
    @AppStorage("browser.genre") private var storedGenre = ""
    @AppStorage("browser.artist") private var storedArtist = ""
    @AppStorage("browser.album") private var storedAlbum = ""
    @AppStorage("browser.composer") private var storedComposer = ""

    private var selectedGenre: String? { storedGenre.isEmpty ? nil : storedGenre }
    private var selectedArtist: String? { storedArtist.isEmpty ? nil : storedArtist }
    private var selectedAlbum: String? { storedAlbum.isEmpty ? nil : storedAlbum }
    private var selectedComposer: String? { storedComposer.isEmpty ? nil : storedComposer }

    private var genreSelection: Binding<String> {
        Binding(
            get: { storedGenre },
            set: { genre in
                storedGenre = genre
                storedArtist = ""
                storedAlbum = ""
                storedComposer = ""
            })
    }

    private var artistSelection: Binding<String> {
        Binding(
            get: { storedArtist },
            set: { artist in
                storedArtist = artist
                storedAlbum = ""
                storedComposer = ""
            })
    }

    private var albumSelection: Binding<String> {
        Binding(
            get: { storedAlbum },
            set: { album in
                storedAlbum = album
                storedComposer = ""
            })
    }

    private var composerSelection: Binding<String> {
        Binding(get: { storedComposer }, set: { storedComposer = $0 })
    }

    /// With no genre selected, browse the complete song library; otherwise
    /// use the genre-specific paginated result.
    private var presentation: SongBrowserPresentation.Result {
        library.songBrowserPresentation.resolve(
            base: selectedGenre == nil ? library.songPresentation : genrePresentation,
            artist: selectedArtist, album: selectedAlbum, composer: selectedComposer
        )
    }

    var body: some View {
        let presentation = presentation
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pane(title: "Genre",
                     items: library.genres.map(\.value),
                     selection: genreSelection,
                     allLabel: "All Genres")
                Divider()
                pane(title: "Artist",
                     items: presentation.artists,
                     selection: artistSelection,
                     allLabel: "All Artists")
                Divider()
                pane(title: "Album",
                     items: presentation.albums,
                     selection: albumSelection,
                     allLabel: "All Albums")
                Divider()
                pane(title: "Composer",
                     items: presentation.composers,
                     selection: composerSelection,
                     allLabel: "All Composers")
            }
            .frame(height: 200)

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackTableView(tracks: presentation.tracks.songs,
                               columns: [.title, .artist, .album, .composer, .genre, .quality, .time],
                               presentation: presentation.tracks,
                               sortAutosaveKey: "browser",
                               defaultSortKey: "title",
                               scrollAutosaveKey: "browser",
                               contentIsLoading: selectedGenre == nil && library.songsAreLoading,
                               columnsCustomizable: true)
            }
        }
        .task(id: LibraryViewLoadID(selection: storedGenre, generation: library.librarySessionGeneration,
                                    ready: library.metadataReadiness == .ready)) {
            guard !Task.isCancelled else { return }
            let genre = selectedGenre
            let session = library.librarySessionGeneration
            genrePresentation = SongPresentation([])
            genreLoadGeneration += 1
            await library.loadSongsIfNeeded()
            guard !Task.isCancelled, session == library.librarySessionGeneration else { return }
            await library.loadGenresIfNeeded()
            // Restore: a persisted genre needs its songs loaded (without the
            // cascade — the restored artist/album selections must survive).
            guard !Task.isCancelled, session == library.librarySessionGeneration else { return }
            await loadGenre(genre)
        }
    }

    @ViewBuilder
    private func pane(title: String, items: [String],
                      selection: Binding<String>, allLabel: String) -> some View {
        ColumnBrowserPane(title: title, items: items, selection: selection, allLabel: allLabel)
    }

    private func loadGenre(_ genre: String?) async {
        guard !Task.isCancelled, selectedGenre == genre else { return }
        genreLoadGeneration += 1
        let generation = genreLoadGeneration
        let session = library.librarySessionGeneration
        guard let genre else { isLoading = false; return }
        isLoading = true
        let fetched = await library.songs(forGenre: genre)
        // A canceled or retired request cannot publish into a newer selection
        // or account, including an A -> B -> A genre round trip.
        guard generation == genreLoadGeneration, storedGenre == genre,
              session == library.librarySessionGeneration, !Task.isCancelled else { return }
        genrePresentation = SongPresentation(fetched)
        isLoading = false
    }

}

/// One selectable pane in the column browser. Kept as a separate view so the
/// AppKit-backed `List` selection behavior can be exercised without building
/// the rest of the app environment.
struct ColumnBrowserPane: View {
    let title: String
    let items: [String]
    @Binding var selection: String
    let allLabel: String
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Styled to match the track table's header row below (same type,
            // height and hairline), so the browser reads as one table system.
            Text(title)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24, alignment: .leading)
            Divider()
            ColumnBrowserList(title: title, items: items, allLabel: allLabel,
                              selection: $selection, onSpace: { player.togglePlayPause() })
        }
        .frame(maxWidth: .infinity)
    }
}
