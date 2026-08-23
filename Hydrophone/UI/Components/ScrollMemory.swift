import SwiftUI

extension Binding where Value == String? {
    /// Bridges a persisted scroll id (an `@AppStorage` string; the empty
    /// string is the nil sentinel) to the optional binding
    /// `.scrollPosition(id:)` wants. Views persist scroll (not `@State`)
    /// when opening an album replaces them in the detail column, so Back can
    /// land on the same spot.
    ///
    /// The stored id is a **one-shot restore target, not a live mirror**:
    /// `get` serves it only until the first user scroll writes back
    /// (`consumed` flips), then returns nil for the rest of the view's life.
    /// `.scrollPosition` re-asserts whatever target its binding reports each
    /// time the view updates — mid-scroll that re-assertion snaps the
    /// current top item flush to the anchor, a visible ~half-row skip once
    /// per scroll settle (window-width dependent; present since scroll
    /// persistence shipped 2026-07-18, diagnosed 2026-07-29). A nil target
    /// re-asserts nothing, so consuming the restore makes the snap
    /// impossible while writes keep recording for the next restore.
    ///
    /// Rules shared by every adopter:
    /// - ids in `topIDs` read as nil: they're what's reported while the
    ///   view's header is visible, and restoring to them would scroll the
    ///   header off — the top stays the top.
    /// - `scope` namespaces the stored value as `"scope|id"` for views
    ///   reused across content (the artist page): another scope's memory
    ///   reads as nil, so switching content starts at the top and only Back
    ///   restores.
    @MainActor
    static func scrollMemory(read: @escaping @MainActor () -> String,
                             write: @escaping @MainActor (String) -> Void,
                             consumed: Binding<Bool>,
                             scope: String? = nil,
                             topIDs: @escaping @MainActor () -> Set<String> = { [] }) -> Binding<String?> {
        Binding<String?>(
            get: {
                guard !consumed.wrappedValue else { return nil }
                var stored = read()
                if let scope {
                    let parts = stored.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2, parts[0] == scope else { return nil }
                    stored = parts[1]
                }
                guard !stored.isEmpty, !topIDs().contains(stored) else { return nil }
                return stored
            },
            set: { id in
                consumed.wrappedValue = true
                switch (id, scope) {
                case (nil, _): write("")
                case let (id?, nil): write(id)
                case let (id?, scope?): write("\(scope)|\(id)")
                }
            }
        )
    }
}
