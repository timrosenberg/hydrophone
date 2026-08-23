import AppKit

// Cell text + sort support for the 8 "expanded" track columns (#35: Album
// Artist, Comments, Grouping, Date Added, Last Played, Plays, Sample Rate,
// Sort Title). Kept in a separate extension, same reasoning as
// TrackTablePersistence.swift's split: folding these into MusicTrackTable's
// own textCell/sortedTracks pushed both past SwiftLint's cyclomatic-
// complexity and type-body-length limits.

extension MusicTrackTable.Coordinator {
    /// Numbers center under the # header (sharing the column with the
    /// centered now-playing speaker); Time and the new date/numeric columns
    /// stay right-aligned, matching their header alignment
    /// (`TrackColumn.alignment`). Returns the label's trailing constraint
    /// constant (tighter for the monospaced right-aligned columns).
    @MainActor func styleAlignment(of label: NSTextField, id: String) -> CGFloat {
        let rightAlignedIDs: Set<String> = ["time", "dateAdded", "lastPlayed", "plays", "sampleRate"]
        if id == "number" {
            label.alignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            return -4.0
        } else if rightAlignedIDs.contains(id) {
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            return -6.0
        }
        return -4.0
    }

    /// Formatted display text for one of the 8 expanded columns, or nil if
    /// `id` isn't one of them (the caller falls back to its own default).
    func expandedColumnText(id: String, song: Song) -> String? {
        switch id {
        case "albumArtist": return song.displayAlbumArtist ?? "—"
        case "comments": return song.comment ?? "—"
        case "grouping":
            let joined = (song.groupings ?? []).joined(separator: ", ")
            return joined.isEmpty ? "—" : joined
        case "dateAdded": return formatShortDate(song.created)
        case "lastPlayed": return formatShortDate(song.played)
        case "plays": return song.playCount.map(String.init) ?? "—"
        case "sampleRate": return formatSampleRate(song.samplingRate)
        case "sortTitle": return song.sortName ?? "—"
        default: return nil
        }
    }

    /// Ascending-order comparison for one of the 8 expanded columns, or nil
    /// if `id` isn't one of them. Missing dates/counts coalesce to the
    /// lowest sentinel — the same "absent sorts first ascending" convention
    /// as `.quality`'s `qualityRank` and the text columns' empty-string
    /// coalesce.
    func expandedColumnAscending(id: String, lhs: Song, rhs: Song) -> Bool? {
        func text(_ lhs: String?, _ rhs: String?) -> Bool {
            (lhs ?? "").localizedCaseInsensitiveCompare(rhs ?? "") == .orderedAscending
        }
        switch id {
        case "albumArtist": return text(lhs.displayAlbumArtist, rhs.displayAlbumArtist)
        case "comments": return text(lhs.comment, rhs.comment)
        case "grouping":
            return text(lhs.groupings?.joined(separator: ", "), rhs.groupings?.joined(separator: ", "))
        case "dateAdded": return (lhs.created ?? .distantPast) < (rhs.created ?? .distantPast)
        case "lastPlayed": return (lhs.played ?? .distantPast) < (rhs.played ?? .distantPast)
        case "plays": return (lhs.playCount ?? 0) < (rhs.playCount ?? 0)
        case "sampleRate": return (lhs.samplingRate ?? 0) < (rhs.samplingRate ?? 0)
        case "sortTitle": return text(lhs.sortName, rhs.sortName)
        default: return nil
        }
    }
}
