import SwiftUI

/// Composers as an imageless master-detail split: a name+count roster and,
/// per selection, that composer's tracks with play/shuffle/queue.
struct ComposersView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ConnectionModel.self) private var connection
    @AppStorage("composersSelectedID") private var selectedID: Composer.ID?
    @AppStorage("composersListWidth") private var listWidth = 240.0
    private static let listWidthRange = 180.0...360.0

    private var selected: Composer? {
        library.composers.first { $0.id == selectedID } ?? library.composers.first
    }

    var body: some View {
        if connection.nativeFeaturesState == .unavailable {
            ContentUnavailableView(
                "Composers Unavailable", systemImage: "person.2.slash",
                description: Text("Composers requires a Navidrome server with native features enabled.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(library.composers) { composer in
                        let isSelected = composer.id == selectedID
                        HStack {
                            Text(composer.name).lineLimit(1)
                                .foregroundStyle(isSelected ? .white : .primary)
                            Spacer()
                            if let count = composer.songCount {
                                Text("\(count)").monospacedDigit()
                                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.6))
                                                                : AnyShapeStyle(.tertiary))
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(composer.id)
                        .listRowBackground(isSelected ? Color.accentColor : nil)
                    }
                }
                .listRowSeparatorTint(Color(nsColor: .separatorColor).opacity(0.75))
                .listStyle(.plain)
                .background(ListSelectionHighlightDisabler())
                .frame(width: listWidth)
                .overlay(alignment: .trailing) {
                    PanelResizeHandle(width: $listWidth, range: Self.listWidthRange, anchoredEdge: .leading)
                        .offset(x: 5)
                }

                Divider()

                if let composer = selected {
                    ComposerDetailView(composer: composer)
                        .id(composer.id)
                } else {
                    ContentUnavailableView("No Composers", systemImage: "person.2")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task {
                await library.loadComposersIfNeeded()
                if selectedID == nil { selectedID = library.composers.first?.id }
            }
        }
    }
}

/// A composer's tracks (spanning albums) with a Play/Shuffle header, reusing
/// `TrackTableView` for per-row queueing and double-click-to-play — modeled
/// directly on `ArtistDetailView`/`AlbumDetailView`'s header + table shape.
struct ComposerDetailView: View {
    let composer: Composer
    @Environment(LibraryModel.self) private var library
    @State private var tracks: [Song] = []
    @State private var loadState: Load = .loading

    private enum Load { case loading, loaded, empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView("No Songs", systemImage: "music.note",
                                       description: Text("No songs are credited to \(composer.name)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                TrackTableView(tracks: tracks,
                               columns: [.title, .album, .artist, .genre, .quality, .time],
                               sortAutosaveKey: "composerDetail",
                               scrollAutosaveKey: "composerDetail-\(composer.id)",
                               columnsCustomizable: true)
            }
        }
        .task(id: composer.id) {
            loadState = .loading
            let loaded = await library.songs(forComposer: composer.id)
            if Task.isCancelled { return }
            tracks = loaded
            loadState = loaded.isEmpty ? .empty : .loaded
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(composer.name).font(.largeTitle).bold()
            Text(trackSummary(tracks)).font(.callout).foregroundStyle(.secondary)
            HStack {
                PlayShuffleButtons(tracks: tracks)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal).padding(.top, 14).padding(.bottom, 10)
    }
}
