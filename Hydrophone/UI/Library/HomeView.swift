import SwiftUI

/// The Home page: a time-of-day greeting, a "Jump Back In" hero card for the
/// most recently played album (blurred-artwork backdrop, inline Play), then
/// discovery shelves at varied sizes. Backed by the server's `getAlbumList2`
/// list types; Recently/Most Played are fed by the app's own scrobbling.
/// See docs/04-ui-ux.md.
struct HomeView: View {
    @Environment(LibraryModel.self) private var library

    /// Section-level scroll memory (see `Binding.scrollMemory`) — the
    /// shelves are the scroll targets; the greeting is the top id.
    @AppStorage("homeScrollID") private var storedScrollID = ""
    /// The restore has been consumed by a user scroll (see `scrollMemory`).
    @State private var scrollRestored = false

    private var scrollBinding: Binding<String?> {
        .scrollMemory(read: { storedScrollID }, write: { storedScrollID = $0 },
                      consumed: $scrollRestored, topIDs: { ["greeting"] })
    }

    private var allEmpty: Bool {
        library.homeNewest.isEmpty && library.homeRecent.isEmpty
            && library.homeFrequent.isEmpty && library.homeRandom.isEmpty
    }

    var body: some View {
        Group {
            if !library.homeLoaded {
                ProgressView()
            } else if allEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "house",
                                       description: Text("Albums appear here as your library grows."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(greeting)
                            .font(.system(size: 28, weight: .bold))
                            .padding(.horizontal, 20)
                            .id("greeting")

                        if let hero = library.homeRecent.first {
                            HomeHeroCard(album: hero)
                                .padding(.horizontal, 20)
                                .id("hero")
                        }

                        // The hero already features the most recent album, so
                        // its shelf continues from the second entry.
                        shelf("Keep Listening", Array(library.homeRecent.dropFirst()))
                            .id("keepListening")
                        shelf("Recently Added", library.homeNewest, tile: 150)
                            .id("recentlyAdded")
                        shelf("Most Played", library.homeFrequent)
                            .id("mostPlayed")
                        if !library.starredAlbums.isEmpty {
                            AlbumShelf(title: "Favorites", albums: library.starredAlbums)
                                .id("favorites")
                        }
                        if !library.homeRandom.isEmpty {
                            AlbumShelf(title: "Random", albums: library.homeRandom,
                                       accessory: AnyView(rerollButton))
                                .id("random")
                        }
                    }
                    .padding(.vertical, 20)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: scrollBinding, anchor: .top)
            }
        }
        .navigationTitle("Home")
        .task { await library.loadHomeIfNeeded() }
        .task { await library.loadStarredIfNeeded() }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good Morning"
        case 12..<18: "Good Afternoon"
        default: "Good Evening"
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ albums: [Album], tile: CGFloat = 110) -> some View {
        if !albums.isEmpty {
            AlbumShelf(title: title, albums: albums, tileSize: tile)
        }
    }

    private var rerollButton: some View {
        Button {
            Task { await library.rerollRandomAlbums() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New random picks")
        .accessibilityLabel("New random picks")
    }
}

/// Full-width feature card for the most recently played album: cover art on a
/// blurred, dimmed blow-up of itself, with an inline Play. Clicking the card
/// opens the album; the Play button starts it immediately.
private struct HomeHeroCard: View {
    let album: Album
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Navigator.self) private var navigator
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 22) {
            ArtworkView(coverArt: album.coverArt, cacheKey: album.artworkKey,
                        size: 150, cornerRadius: 8)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Jump back in")
                    .font(.caption.weight(.semibold)).textCase(.uppercase).kerning(1.1)
                    .foregroundStyle(.white.opacity(0.65))
                Text(album.name)
                    .font(.title.bold()).foregroundStyle(.white).lineLimit(2)
                Text(album.artist ?? "—")
                    .font(.title3).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Button {
                    Task {
                        let songs = await library.songs(forAlbum: album.id)
                        player.play(tracks: songs)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .padding(.top, 10)
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The album's own art, blown up and blurred, carries the card's
            // color; the scrim keeps the white text readable on any cover.
            ZStack {
                ArtworkView(coverArt: album.coverArt, cacheKey: album.artworkKey,
                            size: 700, cornerRadius: 0)
                    .blur(radius: 60)
                    .saturation(1.3)
                Rectangle().fill(.black.opacity(hovering ? 0.28 : 0.38))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { navigator.openAlbum(album) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jump back in: \(album.name) by \(album.artist ?? "unknown artist")")
    }
}
