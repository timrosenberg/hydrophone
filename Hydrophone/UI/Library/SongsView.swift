import SwiftUI

/// Songs browse view. With the column browser enabled (View menu / toolbar),
/// shows the Genre → Artist → Album browser; otherwise a flat songs table.
struct SongsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library
    @AppStorage("showColumnBrowser") private var showColumnBrowser = true

    var body: some View {
        Group {
            if showColumnBrowser {
                ColumnBrowserView()
            } else if library.songs.isEmpty, library.songsAreLoading {
                SongsLoadingProgress(songCount: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                   defaultSortKey: "title",
                                   scrollAutosaveKey: "songs",
                                   contentIsLoading: library.songsAreLoading,
                                   columnsCustomizable: true)
                }
            }
        }
        .navigationTitle("Songs")
        .task(id: showColumnBrowser) {
            if !showColumnBrowser { await library.loadSongsIfNeeded() }
        }
    }
}

/// Compact spinner + status text ("Loading songs…" / "N songs loaded").
/// Serves as the centered placeholder here before the flat Songs table's
/// first page is renderable, and — since the underlying load is app-wide,
/// not Songs-view-scoped — is reused in the toolbar (`NowPlayingToolbar`)
/// to reflect the same state regardless of which page is active (#102).
struct SongsLoadingProgress: View {
    let songCount: Int

    var statusText: String {
        songCount == 0 ? "Loading songs…" : "\(songCount.formatted()) songs loaded"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusText)
    }
}
