import Foundation

extension NativeSongRecord {
    /// Metadata conversion only: streaming and artwork still use Subsonic.
    /// Native duration is fractional; Subsonic truncates it to whole seconds.
    func asSong() -> Song {
        var song = Song(id: id, title: title ?? "")
        song.artist = Self.nonempty(artist)
        song.artistId = Self.nonempty(artistId)
        song.album = Self.nonempty(album)
        song.albumId = Self.nonempty(albumId)
        // getCoverArt accepts the song id (legacy Subsonic identity). A cache
        // key alone cannot fetch art; artworkKey still shares it by albumId.
        song.coverArt = id
        song.duration = Self.nonzero(duration.flatMap { Int(exactly: $0.rounded(.towardZero)) })
        song.track = Self.nonzero(trackNumber)
        song.discNumber = Self.nonzero(discNumber)
        song.year = Self.nonzero(year)
        song.genre = Self.nonempty(genre)
        song.genres = genres
        song.bitRate = Self.nonzero(bitRate)
        song.samplingRate = sampleRate
        song.suffix = Self.nonempty(suffix)
        song.contentType = suffix.flatMap { Self.contentTypes[$0.lowercased()] }
        song.size = Self.nonzero(size)
        song.displayComposer = participants?.composer?.map { credit in
            guard let role = credit.subRole, !role.isEmpty else { return credit.name }
            return "\(credit.name) (\(role))"
        }.joined(separator: " • ")
        song.contributors = Self.contributors(from: participants)
        song.displayAlbumArtist = albumArtist
        song.comment = comment
        song.groupings = tags?["grouping"]
        song.sortName = sortTitle.flatMap { $0.isEmpty ? nil : $0 } ?? orderTitle
        song.playCount = Self.nonzero(playCount)
        song.created = Self.date(createdAt)
        song.played = (playCount ?? 0) > 0 ? Self.date(playDate) : nil
        song.starred = starred == true ? Self.date(starredAt) ?? .distantPast : nil
        if rgTrackGain != nil || rgAlbumGain != nil || rgTrackPeak != nil || rgAlbumPeak != nil {
            song.replayGain = ReplayGainInfo(trackGain: rgTrackGain, albumGain: rgAlbumGain,
                                            trackPeak: rgTrackPeak, albumPeak: rgAlbumPeak)
        }
        return song
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }

    // Navidrome's Subsonic Child omits these zero/empty fields, unlike its
    // native row. Preserve nil-last sorting and avoid Year 0 / Track 0 in Info.
    private static func nonzero(_ value: Int?) -> Int? {
        value.flatMap { $0 == 0 ? nil : $0 }
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    // Composer keeps its own pre-joined displayComposer string (unchanged,
    // tested behavior); performer/conductor instead feed the same
    // Song.contributors + nonEmptyDisplayPerformer/-Conductor path the
    // regular Subsonic decode uses, so Get Info shows the same rows
    // regardless of which fetch built the Song. See #103.
    private static func contributors(from participants: Participants?) -> [Contributor]? {
        let roled: [(String, [Credit]?)] = [
            ("performer", participants?.performer),
            ("conductor", participants?.conductor)
        ]
        let mapped = roled.flatMap { role, credits in
            (credits ?? []).map { credit in
                Contributor(role: role, subRole: credit.subRole,
                            artist: .init(id: credit.id, name: credit.name))
            }
        }
        return mapped.isEmpty ? nil : mapped
    }

    // Navidrome's default resources/mime_types.yaml. OS MIME aliases differ
    // (e.g. audio/x-m4a vs audio/mp4) and would change Get Info's Format row.
    // Unknown/custom server formats keep the suffix rather than invent a MIME.
    private static let contentTypes = [
        "mp3": "audio/mpeg", "ogg": "audio/ogg", "oga": "audio/ogg", "opus": "audio/ogg",
        "aac": "audio/mp4", "alac": "audio/mp4", "m4a": "audio/mp4", "m4b": "audio/mp4",
        "flac": "audio/flac", "wav": "audio/x-wav", "wma": "audio/x-ms-wma",
        "ape": "audio/x-monkeys-audio", "mpc": "audio/x-musepack", "shn": "audio/x-shn",
        "aif": "audio/x-aiff", "aiff": "audio/x-aiff", "m3u": "audio/x-mpegurl", "pls": "audio/x-scpls",
        "dsf": "audio/x-dsf", "wv": "audio/x-wavpack", "wvp": "audio/x-wavpack",
        "tak": "audio/tak", "mka": "audio/x-matroska"
    ]
}
