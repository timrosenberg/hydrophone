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
}
