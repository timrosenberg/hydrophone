import SwiftUI
import UniformTypeIdentifiers
import QuickLook

/// The Now Playing / Up Next panel, shown as an inspector on the trailing edge:
/// a hero card for the current track (artwork, metadata, scrubber, transport)
/// above the upcoming queue with drag-to-reorder, hover-to-remove and
/// play-from-here. See docs/04-ui-ux.md.
struct NowPlayingPanel: View {
    @Environment(PlayerModel.self) private var player
    /// Queue-first mode: the hero card collapses to a compact strip so Up
    /// Next gets nearly the panel's full height. Persisted like the panel
    /// width; scrubber and transport stay reachable in the toolbar LCD.
    @AppStorage("nowPlayingHeroCollapsed") private var heroCollapsed = false

    // No empty state: the panel is only presented when something is playing
    // or queued (RootView gates the inspector on that).
    var body: some View {
        VStack(spacing: 0) {
            if let current = player.currentTrack {
                if heroCollapsed {
                    CompactTrackStrip(song: current) { setHeroCollapsed(false) }
                } else {
                    // Priority so the full-bleed square hero keeps its
                    // width-sized height; the queue list takes what's left
                    // instead of compressing the artwork.
                    CurrentTrackCard(song: current) { setHeroCollapsed(true) }
                        .layoutPriority(1)
                }
                Divider()
            }
            queue
        }
        // With a full hero, extend to the window's very top: the inspector
        // has no toolbar items, so its slice of the toolbar is dead space —
        // the artwork fills it, showing through the toolbar material. The
        // compact strip stays below the toolbar like the queue-only state.
        .ignoresSafeArea(player.currentTrack != nil && !heroCollapsed ? .container : SafeAreaRegions(),
                         edges: .top)
    }

    private func setHeroCollapsed(_ collapsed: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { heroCollapsed = collapsed }
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(.caption.weight(.bold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Clear") { player.clearUpNext() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Clear Up Next")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if player.upNext.isEmpty {
                Text("Nothing up next")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dropDestination(for: DraggedTrack.self) { items, _ in
                        // Multi-item drops arrive in no guaranteed order —
                        // the source row index restores the on-screen order.
                        let songs = items.sorted { $0.index < $1.index }.compactMap(\.song)
                        guard !songs.isEmpty else { return false }
                        player.enqueue(songs)
                        return true
                    }
            } else {
                // The ForEach holds only the upcoming slice (no conditional
                // rows — those break the List's row-drag reordering); its
                // local indices map back to queue offsets via `base`.
                let base = (player.currentIndex ?? -1) + 1
                List {
                    // NOTE: no tap gestures / contentShape on these rows —
                    // they claim the mouse-down and kill .onMove row dragging.
                    // Play-from-here is the hover button and the context menu.
                    // Positional identity: the same song can sit in the queue
                    // twice, and duplicate ids make SwiftUI coalesce rows
                    // (shared hover state, callbacks bound to the first
                    // instance, phantom removals).
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { pair in
                        QueueRow(song: pair.element,
                                 onPlay: { player.playFromQueue(at: base + pair.offset) },
                                 onRemove: { player.removeFromQueue(at: base + pair.offset) })
                            .contextMenu {
                                Button("Play") { player.playFromQueue(at: base + pair.offset) }
                                Button("Remove", role: .destructive) {
                                    player.removeFromQueue(at: base + pair.offset)
                                }
                            }
                            .listRowSeparator(.hidden)
                            // Zero row insets: the row's own 8pt padding is
                            // the hover-highlight bleed, putting content at
                            // ~16pt — aligned with the header and hero meta.
                            .listRowInsets(EdgeInsets())
                    }
                    .onMove { offsets, destination in
                        player.moveQueue(from: IndexSet(offsets.map { $0 + base }),
                                         to: destination + base)
                    }
                    // External drops (rows dragged from any track table)
                    // insert at the drop position; internal reorders still go
                    // through .onMove.
                    .onInsert(of: [.json]) { position, providers in
                        insertDropped(providers, at: base + position)
                    }
                }
                .listStyle(.plain)
                .playPauseOnSpace()
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Decode `DraggedTrack` payloads from dropped item providers and insert
    /// their songs at the given queue index. Provider order isn't guaranteed
    /// for multi-item drags — the payloads' source row indices restore the
    /// order the user grabbed.
    private func insertDropped(_ providers: [NSItemProvider], at index: Int) {
        Task {
            var dropped: [DraggedTrack] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                if let data,
                   let dragged = try? JSONDecoder().decode(DraggedTrack.self, from: data) {
                    dropped.append(dragged)
                }
            }
            let songs = dropped.sorted { $0.index < $1.index }.compactMap(\.song)
            player.insertInQueue(songs, at: index)
        }
    }
}

/// Hero card for the current track: large artwork, metadata, a scrubber with
/// elapsed/total times and a prominent transport cluster — the panel's
/// centerpiece.
private struct CurrentTrackCard: View {
    let song: Song
    var onCollapse: () -> Void
    @Environment(AppModel.self) private var app
    /// Full-resolution artwork staged for Quick Look (set on hero click).
    @State private var artworkPreviewURL: URL?
    @State private var albumHovering = false
    /// Quick Look stays disarmed briefly after the card appears: expanding
    /// from the compact strip swaps this card in under the mouse, and the
    /// click that triggered the expansion is occasionally re-delivered to
    /// the artwork's tap gesture, popping Quick Look uninvited.
    @State private var quickLookArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero artwork, full-bleed: flush with the panel edges and the
            // toolbar above, filling all available width. Click for the
            // full-resolution cover in Quick Look.
            HeroArtwork(coverArt: song.coverArt, cacheKey: song.artworkKey)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard quickLookArmed else { return }
                    Task {
                        artworkPreviewURL = await ArtworkCache.shared.originalImageFileURL(
                            coverArt: song.coverArt,
                            cacheKey: song.artworkKey,
                            displayName: song.album ?? song.title)
                    }
                }
                .quickLookPreview($artworkPreviewURL)
                .help("Show full-size artwork")

            VStack(alignment: .leading, spacing: 0) {
                // Title / artist / album. The chevron beside the title
                // collapses the card to the compact strip (queue-first mode).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(song.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse to make room for Up Next")
                    .accessibilityLabel("Collapse Now Playing")
                }
                Text(song.artist ?? "—")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
                if let album = song.album, !album.isEmpty {
                    // Clicking the album line jumps to it in the library
                    // (also Controls → Show Album in Library, ⇧⌘L).
                    Text(album)
                        .font(.callout)
                        .foregroundStyle(albumHovering ? .secondary : .tertiary)
                        .lineLimit(1)
                        .padding(.top, 1)
                        .onHover { albumHovering = $0 }
                        .onTapGesture { app.requestShowCurrentAlbum() }
                        .help("Show Album in Library")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Show \(album) in Library")
                }
                // Encoding badge ("FLAC", "320 kbps") for the quality-minded.
                if let quality = song.qualityDetailLabel {
                    Text(quality)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.tertiary, lineWidth: 1)
                        }
                        .padding(.top, 7)
                }

                // Scrubber + times, then the transport cluster.
                ScrubberBar()
                    .padding(.top, 12)

                TransportCluster(size: .panel)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            quickLookArmed = true
        }
    }
}

/// Full-bleed square artwork: fills the panel's width edge-to-edge, so no
/// corner rounding, border or shadow.
private struct HeroArtwork: View {
    let coverArt: String?
    var cacheKey: String?

    var body: some View {
        GeometryReader { geo in
            ArtworkView(coverArt: coverArt, cacheKey: cacheKey,
                        size: geo.size.width, cornerRadius: 0)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Collapsed stand-in for the hero card: small artwork plus title/artist on
/// a single strip, giving Up Next nearly the panel's full height. Clicking
/// anywhere on the strip (it lives outside the queue List, so a tap gesture
/// is safe here) restores the full card.
private struct CompactTrackStrip: View {
    let song: Song
    var onExpand: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(coverArt: song.coverArt, cacheKey: song.artworkKey,
                        size: 36, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.body.weight(.medium)).lineLimit(1)
                Text(song.artist ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hovering ? .secondary : .tertiary)
        }
        // 16pt insets to match the queue header and the hero card's meta.
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .onHover { hovering = $0 }
        .help("Expand Now Playing")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Expand Now Playing")
    }
}

/// A queued track with a soft rounded hover highlight. Hovering reveals a
/// play button over the artwork and swaps the duration for a remove button —
/// buttons only, so the row body stays free for drag-to-reorder.
private struct QueueRow: View {
    let song: Song
    var onPlay: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                ArtworkView(coverArt: song.coverArt, cacheKey: song.artworkKey,
                            size: 36, cornerRadius: 6)
                    .overlay {
                        if hovering {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.black.opacity(0.45))
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Play")
            .accessibilityLabel("Play \(song.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.body.weight(.medium)).lineLimit(1)
                Text(song.artist ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
            } else {
                Text(formatTime(song.duration))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        // Concentric hover pill: the 36pt artwork (radius 6) is inset by the
        // same 5pt on its leading/top/bottom sides, so the pill's radius is
        // 6 + 5 = 11 and the two corner curves share a center. The trailing
        // side keeps a roomier 8 for the time / remove button.
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 11))
        .onHover { hovering = $0 }
    }
}
