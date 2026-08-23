import SwiftUI

/// A selectable data column in the track list. The now-playing indicator and
/// favorite-star columns are always present (fixed-width affordances); these are
/// the content columns each call site opts into explicitly.
enum TrackColumn {
    case number, title, artist, composer, album, genre, quality, time
    case albumArtist, comments, grouping, dateAdded, lastPlayed, plays, sampleRate, sortTitle

    struct Widths {
        let initial: CGFloat
        let min: CGFloat
        let max: CGFloat
    }

    var id: String {
        switch self {
        case .number: "number"
        case .title: "title"
        case .artist: "artist"
        case .composer: "composer"
        case .album: "album"
        case .genre: "genre"
        case .quality: "quality"
        case .time: "time"
        case .albumArtist: "albumArtist"
        case .comments: "comments"
        case .grouping: "grouping"
        case .dateAdded: "dateAdded"
        case .lastPlayed: "lastPlayed"
        case .plays: "plays"
        case .sampleRate: "sampleRate"
        case .sortTitle: "sortTitle"
        }
    }
    var header: String {
        switch self {
        case .number: "#"
        case .title: "Title"
        case .artist: "Artist"
        case .composer: "Composer"
        case .album: "Album"
        case .genre: "Genre"
        case .quality: "Quality"
        case .time: "Time"
        case .albumArtist: "Album Artist"
        case .comments: "Comments"
        case .grouping: "Grouping"
        case .dateAdded: "Date Added"
        case .lastPlayed: "Last Played"
        case .plays: "Plays"
        case .sampleRate: "Sample Rate"
        case .sortTitle: "Sort Title"
        }
    }
    var widths: Widths {
        switch self {
        case .number: Widths(initial: 34, min: 30, max: 44)
        case .title: Widths(initial: 240, min: 120, max: 10_000)
        case .artist: Widths(initial: 170, min: 80, max: 10_000)
        case .composer: Widths(initial: 170, min: 80, max: 10_000)
        case .album: Widths(initial: 170, min: 80, max: 10_000)
        case .genre: Widths(initial: 100, min: 60, max: 400)
        case .quality: Widths(initial: 78, min: 64, max: 110)
        case .time: Widths(initial: 54, min: 54, max: 80)
        case .albumArtist: Widths(initial: 170, min: 80, max: 10_000)
        case .comments: Widths(initial: 170, min: 80, max: 10_000)
        case .grouping: Widths(initial: 140, min: 80, max: 10_000)
        case .dateAdded: Widths(initial: 100, min: 90, max: 160)
        case .lastPlayed: Widths(initial: 100, min: 90, max: 160)
        case .plays: Widths(initial: 60, min: 50, max: 90)
        case .sampleRate: Widths(initial: 84, min: 70, max: 110)
        case .sortTitle: Widths(initial: 170, min: 80, max: 10_000)
        }
    }
    /// Cell/header text alignment: numbers center (they share the column
    /// with the centered now-playing speaker), times right, text left.
    /// The new date/numeric columns follow `.time`'s right-alignment
    /// convention; the new text columns follow the existing left-aligned norm.
    var alignment: NSTextAlignment {
        switch self {
        case .number: .center
        case .time, .dateAdded, .lastPlayed, .plays, .sampleRate: .right
        default: .left
        }
    }
}
