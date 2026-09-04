import SwiftUI

// The now-playing experience lives in the window's top toolbar (a radical move
// from the classic bottom bar): transport controls sit at the leading edge, an
// "LCD" now-playing display is centered, and volume sits trailing. These views
// are wired into the toolbar from `RootView`. See docs/04-ui-ux.md.

// MARK: - Transport (above the sidebar)

/// Previous, play/pause and next — the transport cluster shown in the toolbar
/// strip above the sidebar, right next to the window controls (the classic
/// iTunes corner). Shuffle and repeat live in the Now Playing panel.
///
/// Following Apple's guidance (only one prominent control), prev/next are
/// bright (`.primary`) with the play button emphasized in an accent-filled
/// circle. SF Symbols are sized with `.font(.system(size:))` rather than
/// `.resizable()` so they stay crisp.
struct TransportControls: View {
    @Environment(PlayerModel.self) private var player

    /// Size of the emphasized play/pause circle.
    private let playDiameter: CGFloat = 32

    var body: some View {
        HStack(spacing: 14) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 14))
            }
            .accessibilityLabel("Previous")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: playDiameter, height: playDiameter)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .accentColor.opacity(0.45), radius: 3, y: 1)
                    .contentShape(Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 14))
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(player.currentTrack == nil)
    }
}

// MARK: - Library-load status (leading overlay beside the LCD)

/// Compact "Loading songs…" / "N songs loaded" status shown while the songs
/// library is loading. RootView draws it just before `NowPlayingDisplay` as a
/// non-layout overlay: it remains visually separate while the LCD stays the
/// sole measured, centered `.principal` toolbar item (#102).
struct LibraryLoadingStatus: View {
    static let width: CGFloat = 160

    @Environment(LibraryModel.self) private var library

    var body: some View {
        SongsLoadingProgress(songCount: library.songs.count)
            .frame(width: Self.width - 20)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.4), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
    }
}

// MARK: - Now-playing display (centered)

/// The centered "LCD" capsule: artwork, centered title with artist — album
/// beneath, elapsed / total time trailing, and a thin accent progress bar along
/// the bottom edge. Clicking it toggles the Now Playing panel (where the full
/// scrubber lives).
struct NowPlayingDisplay: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage("showUpNext") private var showUpNext = false
    @State private var hovering = false

    /// LCD geometry. The artwork is inset by the same amount on its leading,
    /// top and bottom sides, and its corners are **concentric** with the
    /// panel's: innerRadius = outerRadius − inset, so the two curves share a
    /// center and the gap between them stays optically even around the corner.
    private enum LCD {
        static let height: CGFloat = 44
        static let cornerRadius: CGFloat = 10
        static let artworkInset: CGFloat = 5
        static var artworkSize: CGFloat { height - 2 * artworkInset }         // 34
        static var artworkRadius: CGFloat { cornerRadius - artworkInset }     // 5
    }

    var body: some View {
        HStack(spacing: 11) {
            ArtworkView(coverArt: player.currentTrack?.coverArt,
                        cacheKey: player.currentTrack?.artworkKey,
                        size: LCD.artworkSize, cornerRadius: LCD.artworkRadius)
                .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)

            VStack(spacing: 1) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.caption).fontWeight(.semibold).lineLimit(1)
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            if player.currentTrack != nil {
                Text("\(formatTime(player.position)) / \(formatTime(player.duration))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
        // Leading matches the artwork's concentric inset; trailing keeps the
        // roomier gap the time text wants.
        .padding(.leading, LCD.artworkInset)
        .padding(.trailing, 11)
        .frame(height: LCD.height)
        // Flexible up to 560pt, but with a restrained ideal width: the unified
        // toolbar lays principal items out at their ideal size, and an ideal
        // that only fits on wide windows shoves the trailing items (or the LCD
        // itself) into the overflow menu once the inspector is open.
        // monospaced-digit times keep it from reflowing.
        .frame(minWidth: 260, idealWidth: 400, maxWidth: 560)
        // Recessed "LCD screen" look: a dark translucent fill with a soft inner
        // shadow from the top and a hairline highlight along the edge — the
        // subtle depth (matching the design's inset box-shadows) that makes the
        // capsule read as a little inset display rather than a flat chip.
        // The progress hairline lives inside the background stack and is
        // clipped there with the capsule fill — clipping at the outer view
        // level let the bar's square end poke out of the rounded corner.
        .background {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: LCD.cornerRadius)
                    .fill(Color.black.opacity(0.30)
                        .shadow(.inner(color: .black.opacity(0.45), radius: 2.5, y: 1)))
                // Playback progress as a hairline along the LCD's bottom edge.
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progressFraction, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LCD.cornerRadius))
        }
        .overlay {
            RoundedRectangle(cornerRadius: LCD.cornerRadius)
                .strokeBorder(.white.opacity(hovering ? 0.22 : 0.10), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: LCD.cornerRadius))
        .onTapGesture {
            // The panel is only relevant while something is playing or queued.
            // withAnimation: the inspector, the split columns, and this
            // flexible LCD all resize in ONE coordinated pass — bare toggles
            // let each layer settle separately, which reads as the whole
            // window jittering (the sidebar most visibly).
            if player.hasNowPlayingContent {
                withAnimation { showUpNext.toggle() }
            }
        }
        .onHover { hovering = $0 }
        // NOTE: no .contextMenu here — NSToolbar swallows right-clicks on its
        // items (it shows its own customize menu), so the affordance lives on
        // the panel's album line and in Controls → Show Album in Library.
        .help(showUpNext ? "Hide Now Playing" : "Show Now Playing")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Now Playing")
    }

    private var subtitle: String {
        guard let track = player.currentTrack else { return "—" }
        let artist = track.artist ?? "—"
        if let album = track.album, !album.isEmpty { return "\(artist) — \(album)" }
        return artist
    }

    private var progressFraction: CGFloat {
        guard player.currentTrack != nil, player.duration > 0 else { return 0 }
        return min(max(player.position / player.duration, 0), 1)
    }
}

// MARK: - Volume (trailing)

/// Speaker icon and volume slider, shown at the trailing edge of the toolbar.
struct VolumeControl: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 7) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary).font(.caption)
                .accessibilityHidden(true)
            // Shielded: the unified toolbar is a window-drag region, and a
            // SwiftUI DragGesture doesn't opt out of it the way native
            // controls do — dragging the slider would move the whole window.
            WindowDragShield {
                SlimSlider(value: $player.volume, range: 0...1,
                           fill: .primary.opacity(0.55), thumbSize: 9)
                    .frame(width: 70)
                    .accessibilityLabel("Volume")
            }
        }
    }
}

/// Hosts content in an `NSHostingView` that refuses `mouseDownCanMoveWindow`,
/// so drag gestures on custom controls in the toolbar operate the control
/// instead of dragging the window. (AppKit asks the NSView under the initial
/// mouse-down; SwiftUI's own hosting view says yes for custom-drawn content.)
private struct WindowDragShield<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = ShieldingHostingView(rootView: content())
        view.sizingOptions = .intrinsicContentSize
        return view
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content()
    }
}

private final class ShieldingHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Slim slider

/// A slim, refined slider — thin track, colored fill, small white thumb — that
/// matches the design's LCD scrubber and volume bar far better than the chunky
/// default macOS `Slider`. Dragging updates `value`; `onEditingChanged(false)`
/// fires on release so the scrubber can seek once rather than continuously.
struct SlimSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var fill: Color = .accentColor
    var trackHeight: CGFloat = 3
    var thumbSize: CGFloat = 8
    /// Spoken value for assistive tech (e.g. "1:23 of 4:05"); defaults to a
    /// percentage of the range.
    var accessibilityValueText: String?
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var editing = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbRadius = thumbSize / 2
            let usable = max(width - thumbSize, 0.0001)
            let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let thumbX = thumbRadius + fraction * usable

            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.16))
                    .frame(height: trackHeight)
                Capsule().fill(fill)
                    .frame(width: thumbX, height: trackHeight)
                Circle().fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: thumbX - thumbRadius)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !editing { editing = true; onEditingChanged(true) }
                        let dragFraction = min(max((drag.location.x - thumbRadius) / usable, 0), 1)
                        value = range.lowerBound + dragFraction * span
                    }
                    .onEnded { _ in
                        editing = false
                        onEditingChanged(false)
                    }
            )
            // Custom gesture-driven control → expose slider semantics by hand:
            // a value plus increment/decrement (also drives Full Keyboard Access).
            .accessibilityElement()
            .accessibilityValue(accessibilityValueText ?? "\(Int((fraction * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step = span / 20
                onEditingChanged(true)
                switch direction {
                case .increment: value = min(range.upperBound, value + step)
                case .decrement: value = max(range.lowerBound, value - step)
                @unknown default: break
                }
                onEditingChanged(false)
            }
        }
        // A taller invisible hit area than the thin visual track, so it's easy to
        // grab (and so drags near it don't fall through to the draggable bar).
        .frame(height: 16)
    }
}
