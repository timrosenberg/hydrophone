import SwiftUI

/// A dedicated album screen, shown in place of the current section (no
/// navigation stack — the inline Back link closes it via `Navigator`): a
/// header with artwork, title, artist, year + play/shuffle/favorite, then the
/// track list rendered with the shared `TrackTableView`.
struct AlbumDetailView: View {
    let album: Album
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @State private var tracks: [Song] = []
    @State private var discSubtitles: [Int: String] = [:]

    // The library owns star state, optimistic overrides included — the star
    // here, the table rows, and ⌘L all read the same `isStarred`.
    private var isStarred: Bool { library.isStarred(album: album) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TrackTableView(tracks: tracks, columns: [.number, .title, .artist, .composer, .genre, .quality, .time],
                           sortAutosaveKey: "album",
                           discHeaders: discSubtitles,
                           columnsCustomizable: true)
        }
        .task(id: album.id) {
            // "Go to Album" call sites already ran a full getAlbum fetch to
            // get here (they needed the album's own metadata to navigate) —
            // its song list is right there on `album`, so use it instead of
            // fetching again. List-sourced albums (grid/shelf taps) arrive
            // with `song` nil and still need the one fetch.
            if let song = album.song {
                tracks = song
                discSubtitles = album.discSubtitles
            } else {
                // A cancelled fetch (album switched underneath) resolves
                // nil — don't clobber with empty.
                let detail = await library.album(id: album.id)
                if Task.isCancelled { return }
                tracks = detail?.song ?? []
                discSubtitles = detail?.discSubtitles ?? [:]
            }
            await library.loadStarredIfNeeded()
        }
    }

    @ViewBuilder
    private var header: some View {
        // Inline back affordance replacing the navigation stack's chrome.
        HStack {
            Button { navigator.closeAlbum() } label: {
                Label("Back", systemImage: "chevron.backward")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Back")
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 10)

        HStack(alignment: .top, spacing: 16) {
            ArtworkView(coverArt: album.coverArt, cacheKey: album.artworkKey,
                        size: 96, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.name).font(.title2).bold()
                Text(album.artist ?? "—").foregroundStyle(.secondary)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                HStack {
                    PlayShuffleButtons(tracks: tracks)

                    Button {
                        let new = !isStarred
                        Task { await library.setAlbumStarred(new, albumId: album.id) }
                    } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isStarred ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(isStarred ? "Remove from Favorites" : "Add to Favorites")
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding()
    }

    private var subtitle: String {
        let summary = trackSummary(tracks)
        guard let year = album.year else { return summary }
        return "\(year) · \(summary)"
    }
}
