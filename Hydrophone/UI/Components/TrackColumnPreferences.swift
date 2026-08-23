import Foundation

/// Per-view column visibility, order, and width — the model #37's header
/// context-menu picker will read and write. No UI here; this is storage
/// only. Persisted in UserDefaults, keyed by `viewKind`, which reuses
/// `MusicTrackTable.sortAutosaveKey` (already unique per `TrackTableView`
/// call site) rather than inventing a second per-view identifier. Same
/// lightweight delimited-string persistence `TrackTablePersistence.swift`
/// already uses for sort — no JSON, no Codable.
enum TrackColumnPreferences {
    private static func columnsKey(for viewKind: String) -> String {
        "trackColumns.\(viewKind)"
    }
    private static func widthKey(for columnID: String, in viewKind: String) -> String {
        "trackColumnWidth.\(viewKind).\(columnID)"
    }

    /// The visible columns, in order, for `viewKind`. A stored id that no
    /// longer maps to a `TrackColumn` case (a removed/renamed column) is
    /// silently dropped rather than crashing. Returns nil if nothing has
    /// been persisted yet, or everything stored has since become
    /// unrecognized — either way the caller falls back to its own default
    /// column list. `defaults` defaults to `.standard`; tests inject an
    /// isolated suite instead of touching the real app's prefs.
    static func persistedColumns(for viewKind: String, defaults: UserDefaults = .standard) -> [TrackColumn]? {
        guard let stored = defaults.string(forKey: columnsKey(for: viewKind)) else { return nil }
        let columns = stored.split(separator: "|").compactMap { TrackColumn(id: String($0)) }
        return columns.isEmpty ? nil : columns
    }

    static func persistColumns(_ columns: [TrackColumn], for viewKind: String, defaults: UserDefaults = .standard) {
        let joined = columns.map(\.id).joined(separator: "|")
        defaults.set(joined, forKey: columnsKey(for: viewKind))
    }

    /// The persisted width for one column in one view, or nil if never set
    /// (the caller falls back to `TrackColumn.widths.initial`).
    static func persistedWidth(
        for columnID: String,
        in viewKind: String,
        defaults: UserDefaults = .standard
    ) -> CGFloat? {
        let key = widthKey(for: columnID, in: viewKind)
        guard defaults.object(forKey: key) != nil else { return nil }
        return CGFloat(defaults.double(forKey: key))
    }

    static func persistWidth(
        _ width: CGFloat,
        for columnID: String,
        in viewKind: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(Double(width), forKey: widthKey(for: columnID, in: viewKind))
    }
}
