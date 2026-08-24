import SwiftUI

/// Restores the global playback shortcut when a SwiftUI `List` consumes Space.
/// Apply to the list itself so row mouse gestures and drag handling stay untouched.
extension View {
    func playPauseOnSpace(_ action: @escaping () -> Void) -> some View {
        onKeyPress(.space) {
            action()
            return .handled
        }
    }

    /// Convenience for the common case: toggles `PlayerModel` directly, so
    /// call sites don't each need their own `@Environment(PlayerModel.self)`.
    func playPauseOnSpace() -> some View {
        modifier(PlayPauseOnSpaceModifier())
    }
}

private struct PlayPauseOnSpaceModifier: ViewModifier {
    @Environment(PlayerModel.self) private var player

    func body(content: Content) -> some View {
        content.playPauseOnSpace { player.togglePlayPause() }
    }
}
