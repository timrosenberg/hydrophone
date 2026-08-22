import SwiftUI

/// Songs browse view. With the column browser enabled (View menu / toolbar),
/// shows the Genre → Artist → Album browser; otherwise a flat songs table.
/// Note: Subsonic has no "all songs" endpoint, so the flat list shows a random
/// sample (see docs/05-data-and-caching.md, known limitation).
struct SongsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library
    @AppStorage("showColumnBrowser") private var showColumnBrowser = true

    var body: some View {
        Group {
            if showColumnBrowser {
                ColumnBrowserView()
            } else if library.songs.isEmpty, case .loading = library.songsState {
                ProgressView()
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        // Whole-library shuffle (fresh random batch, not this
                        // sample) — also in Controls → Shuffle Library.
                        Button {
                            app.shuffleLibrary()
                        } label: {
                            Label("Shuffle All", systemImage: "shuffle")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    TrackTableView(tracks: library.songs,
                                   columns: [.title, .artist, .album, .composer, .genre, .quality, .time],
                                   sortAutosaveKey: "songs",
                                   scrollAutosaveKey: "songs")
                }
            }
        }
        .navigationTitle("Songs")
        .task(id: showColumnBrowser) {
            if !showColumnBrowser { await library.loadSongsIfNeeded() }
        }
    }
}
