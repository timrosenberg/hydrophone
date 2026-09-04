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
    /// OpenSubsonic role-tagged credits (performer, conductor, composer,
    /// etc.), each with an optional subRole (e.g. an instrument for
    /// `performer`). Unlike `displayComposer`, the server sends no
    /// pre-joined string for these roles, so `nonEmptyDisplayPerformer`/
    /// `nonEmptyDisplayConductor` build one client-side. No `ensemble` role
    /// exists in Navidrome (checked `model/participants.go` and
    /// `resources/mappings.yaml`) — there is no field to surface for it. #103
    var contributors: [Contributor]?
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

    /// Native (Navidrome-only) work/movement metadata, joined onto this
    /// `Song` by `LibraryModel` after the Subsonic fetch — Subsonic never
    /// sends these, so they're deliberately absent from `CodingKeys` below;
    /// every `Optional` property already defaults to `nil` on its own, which
    /// is what lets synthesized `Codable` compile without a decode entry for
    /// them. `movementNumber`/`movementTotal` are separate plain-number tags,
    /// not a combined "n/total" string. See #45, epic #13.
    var work: String?
    var movementName: String?
    var movementNumber: Int?
    var movementTotal: Int?
    /// Native (Navidrome-only) bit depth, joined the same way as work/movement
    /// above — plain Subsonic has no field for it. Drives the Now Playing
    /// quality badge's "24/96k"-style label (#106); absent for lossy files
    /// (compressed audio has no fixed bit depth) and for untagged/plain-Subsonic
    /// lossless files, which fall back to `qualityDetailLabel`'s format+kbps form.
    var bitDepth: Int?

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

    /// Performer credits for display, joined the same way `displayComposer`
    /// is server-joined: "Name (subRole)" per credit, " • "-separated.
    var nonEmptyDisplayPerformer: String? { Self.joinedCredits(contributors, role: "performer") }
    /// Conductor credits for display, same join convention as performer.
    var nonEmptyDisplayConductor: String? { Self.joinedCredits(contributors, role: "conductor") }

    private static func joinedCredits(_ contributors: [Contributor]?, role: String) -> String? {
        let matches = (contributors ?? []).filter { $0.role == role }
        guard !matches.isEmpty else { return nil }
        let joined = matches.map { credit in
            guard let subRole = credit.subRole, !subRole.isEmpty else { return credit.artist.name }
            return "\(credit.artist.name) (\(subRole))"
        }.joined(separator: " • ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
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

    /// Above this bit rate, a file is treated as hi-res/CD-quality rather
    /// than a lossy encode, so `qualityDetailLabel` prefers bit depth/sample
    /// rate over the (high, meaningless-for-lossless) bit rate figure. 320
    /// kbps is the ceiling of legitimate lossy encoding (MP3/AAC's top
    /// constant-bitrate tier); every lossless format sits well above it even
    /// at CD quality (16/44.1 FLAC is ~900–1400 kbps). This also sidesteps
    /// needing a lossless-suffix list: `.m4a` alone can't tell ALAC from AAC,
    /// but their bit rates do.
    private static let hiResBitRateThresholdKbps = 320

    /// Format name + either bit depth/sample rate ("FLAC 24/96k") for files
    /// above `hiResBitRateThresholdKbps` with both fields reported, or
    /// format + bit rate ("AAC 256 kbps") otherwise — for the Now Playing
    /// badge only; the Quality column (`qualityLabel`) stays compact.
    var qualityDetailLabel: String? {
        guard let suffix = suffix?.lowercased(), !suffix.isEmpty else {
            if let bitRate, bitRate > 0 { return "\(bitRate) kbps" }
            return nil
        }
        if let bitRate, bitRate > Self.hiResBitRateThresholdKbps,
           let bitDepth, bitDepth > 0, let samplingRate, samplingRate > 0 {
            let format = Self.formatName(forSuffix: suffix, isHiRes: true)
            return "\(format) \(bitDepth)/\(Self.formatKilohertz(samplingRate))"
        }
        let format = Self.formatName(forSuffix: suffix, isHiRes: false)
        guard let bitRate, bitRate > 0 else { return format }
        return "\(format) \(bitRate) kbps"
    }

    /// `.m4a`/`.m4b` alone can't say whether the container holds lossy AAC or
    /// lossless ALAC — every other suffix names its own codec, but this one
    /// only tells the two apart via the hi-res branch (a bit rate above the
    /// threshold, with a reported bit depth).
    private static func formatName(forSuffix suffix: String, isHiRes: Bool) -> String {
        switch suffix {
        case "aif": return "AIFF"
        case "m4a", "m4b": return isHiRes ? "ALAC" : "AAC"
        default: return suffix.uppercased()
        }
    }

    /// "96k"/"44.1k"-style label: one decimal only when the rate isn't a
    /// whole number of kHz. Mirrors `formatSampleRate`'s rounding rule
    /// (`TrackTableView.swift`) without depending on UI code from this layer.
    private static func formatKilohertz(_ hertz: Int) -> String {
        let khz = Double(hertz) / 1000
        guard khz.truncatingRemainder(dividingBy: 1) != 0 else { return "\(Int(khz))k" }
        return String(format: "%.1fk", khz)
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
        case displayComposer, contributors
        case replayGain
        case displayAlbumArtist, comment, groupings, created, played, playCount, samplingRate, sortName
    }
}

/// OpenSubsonic contributor credit: a role-tagged artist with an optional
/// subRole (e.g. an instrument for the `performer` role). See `Song.contributors`.
struct Contributor: Codable, Sendable, Hashable {
    var role: String
    var subRole: String?
    var artist: ContributorArtist

    struct ContributorArtist: Codable, Sendable, Hashable {
        var id: String
        var name: String
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
