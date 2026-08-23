import Foundation

/// Value types mirroring the OpenSubsonic JSON, kept close to the wire and
/// `Sendable` so they cross actor boundaries safely.
/// See docs/02-opensubsonic-api.md.

/// OpenSubsonic multi-genre entry. Newer servers (e.g. Navidrome 0.62) return a
/// `genres` array instead of the legacy single `genre` string.
struct GenreRef: Codable, Sendable, Hashable {
    var name: String
}

struct Song: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var title: String
    var artist: String?
    var artistId: String?
    var album: String?
    var albumId: String?
    var coverArt: String?
    var duration: Int?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var bitRate: Int?
    var suffix: String?
    var contentType: String?
    var size: Int?
    var starred: Date?
    var genres: [GenreRef]?
    /// OpenSubsonic display-ready composer string (the server joins multiple
    /// composers itself). Absent when the file/server has no composer tag.
    var displayComposer: String?
    /// OpenSubsonic loudness tags, carried through by Navidrome when the
    /// files are tagged. Drives volume normalization (see ReplayGainMode).
    var replayGain: ReplayGainInfo?
    /// OpenSubsonic display-ready album-artist string (server-joined, same
    /// convention as `displayComposer`).
    var displayAlbumArtist: String?
    var comment: String?
    /// OpenSubsonic song groupings, represented as a string array. Navidrome
    /// sources these from Grouping/GRP1 tags; the array shape was confirmed
    /// live 2026-08-23 against demo.navidrome.org.
    var groupings: [String]?
    /// When this file was added to the library.
    var created: Date?
    /// When this file was last played; absent if never played.
    var played: Date?
    var playCount: Int?
    var samplingRate: Int?
    /// Sort-key title (e.g. strips a leading "The"), distinct from `title`.
    var sortName: String?

    var isStarred: Bool { starred != nil }
    /// Genre for display, preferring the legacy field, then the OpenSubsonic array.
    var displayGenre: String? { genre ?? genres?.first?.name }
    /// Composer text for UI consumers. Some servers send an empty string
    /// instead of omitting the field; treat whitespace-only values as missing
    /// while preserving non-empty server text verbatim.
    var nonEmptyDisplayComposer: String? {
        guard let displayComposer,
              !displayComposer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return displayComposer
    }

    /// File suffixes of lossless encodings, where the format says more than the
    /// (high, variable) bit rate.
    private static let losslessSuffixes: Set<String> = [
        "flac", "alac", "wav", "aif", "aiff", "ape", "dsf", "dff", "wv", "shn"
    ]

    /// Short encoding label for quality-minded listeners: the format name for
    /// lossless files ("FLAC", "AIFF"), the bit rate for lossy ones
    /// ("320 kbps"), the bare suffix as a fallback.
    var qualityLabel: String? {
        if let suffix = suffix?.lowercased(), Self.losslessSuffixes.contains(suffix) {
            return suffix == "aif" ? "AIFF" : suffix.uppercased()
        }
        if let bitRate, bitRate > 0 { return "\(bitRate) kbps" }
        return suffix?.uppercased()
    }

    /// Sort key for the Quality column: lossless above any lossy bit rate.
    var qualityRank: Int {
        if let suffix = suffix?.lowercased(), Self.losslessSuffixes.contains(suffix) {
            return 100_000 + (bitRate ?? 0)
        }
        return bitRate ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, artistId, album, albumId, coverArt, duration
        case track, discNumber, year, genre, genres, bitRate, suffix, contentType, size, starred
        case displayComposer
        case replayGain
        case displayAlbumArtist, comment, groupings, created, played, playCount, samplingRate, sortName
    }
}

struct Album: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var genres: [GenreRef]?
    var starred: Date?
    var song: [Song]?
    /// OpenSubsonic disc subtitles (TSST), present on getAlbum responses when
    /// the files are tagged. Feeds the disc headers on the album page.
    var discTitles: [DiscTitle]?

    var isStarred: Bool { starred != nil }
    var displayGenre: String? { genre ?? genres?.first?.name }

    /// Disc number → subtitle, for quick header lookup.
    var discSubtitles: [Int: String] {
        Dictionary(uniqueKeysWithValues: (discTitles ?? [])
            .compactMap { entry in
                guard let disc = entry.disc, let title = entry.title, !title.isEmpty else { return nil }
                return (disc, title)
            })
    }
}

struct DiscTitle: Codable, Sendable, Hashable {
    var disc: Int?
    var title: String?
}

/// Artwork cache identity (see ArtworkCache). Servers give every song its own
/// `coverArt` id even though all tracks of an album resolve to the same image,
/// so song and album surfaces share an album-scoped key: showing or playing a
/// track reuses art the album grid/page already fetched, and a queue of one
/// album costs a single download instead of one per row.
extension Song {
    var artworkKey: String? { albumId.map { "album:\($0)" } ?? coverArt }
}

extension Album {
    var artworkKey: String { "album:\(id)" }
}

struct Artist: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var name: String
    var coverArt: String?
    var albumCount: Int?
    var starred: Date?
    var album: [Album]?

    var isStarred: Bool { starred != nil }
}

struct Genre: Codable, Sendable, Hashable, Identifiable {
    var value: String
    var songCount: Int?
    var albumCount: Int?

    var id: String { value }
}

struct Playlist: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var name: String
    var owner: String?
    var `public`: Bool?
    var songCount: Int?
    var duration: Int?
    var comment: String?
    var changed: Date?
    var coverArt: String?
    var entry: [Song]?
}

/// OpenSubsonic `replayGain` on a song: gains are dB adjustments relative to
/// the reference loudness; peaks are linear sample maxima (1.0 = full scale).
struct ReplayGainInfo: Codable, Sendable, Hashable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?
}
