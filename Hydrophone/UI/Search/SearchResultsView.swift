import SwiftUI

/// Global search results: artist and album shelves (tappable, pushing the same
/// detail screens as the library) above the shared striped track table used
/// everywhere else — double-click-to-play, context menu, favorites and the
/// now-playing indicator included. Debounced and cancellation-aware via
/// `.task(id:)`. See docs/04-ui-ux.md.
struct SearchResultsView: View {
    let query: String
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @State private var results = LibraryModel.SearchResults()
    @State private var isSearching = false

    var body: some View {
        Group {
            if results.isEmpty {
                if isSearching {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                VStack(spacing: 0) {
                    if !results.artists.isEmpty {
                        artistsShelf
                        Divider()
                    }
                    if !results.albums.isEmpty {
                        AlbumShelf(albums: results.albums)
                        Divider()
                    }
                    if !results.songs.isEmpty {
                        TrackTableView(tracks: results.songs,
                                       columns: [.title, .artist, .album, .composer, .quality, .time],
                                       sortAutosaveKey: "search",
                                       columnsCustomizable: true)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Search")
        .task(id: query) {
            isSearching = true
            // Light debounce so typing doesn't fire a request per keystroke.
            // Existing results stay visible while the next search runs, so the
            // page doesn't flash a spinner on every keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let found = await library.search(query)
            // A cancelled in-flight search resolves to empty results — never
            // assign them, or the visible list blanks mid-typing (defeating
            // the keep-previous-results behavior above).
            if Task.isCancelled { return }
            results = found
            isSearching = false
        }
    }

    /// Matching artists as a shelf of circular portraits; selecting one pushes
    /// the artist's albums (same destination as the Artists section).
    private var artistsShelf: some View {
        Shelf(title: "Artists") {
            ForEach(results.artists) { artist in
                Button { navigator.openArtist(artist) } label: {
                    VStack(spacing: 6) {
                        ArtworkView(coverArt: artist.coverArt, size: 64, cornerRadius: 32)
                        Text(artist.name).font(.caption).lineLimit(1)
                    }
                    .frame(width: 90)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
