import SwiftUI

/// Starred albums (a shelf) and starred songs. Maps to getStarred2.
struct FavoritesView: View {
    @Environment(LibraryModel.self) private var library

    private var isEmpty: Bool {
        library.starredSongs.isEmpty && library.starredAlbums.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star",
                                       description: Text("Songs and albums you star will appear here."))
            } else {
                VStack(spacing: 0) {
                    if !library.starredAlbums.isEmpty {
                        AlbumShelf(albums: library.starredAlbums)
                        Divider()
                    }
                    if !library.starredSongs.isEmpty {
                        TrackTableView(tracks: library.starredSongs,
                                       columns: [.title, .artist, .album, .composer, .genre, .quality, .time],
                                       sortAutosaveKey: "favorites",
                                       scrollAutosaveKey: "favorites",
                                       columnsCustomizable: true)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Favorites")
        .task { await library.loadStarredIfNeeded() }
    }
}
