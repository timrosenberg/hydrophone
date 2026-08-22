import SwiftUI

/// A selectable data column in the track list. The now-playing indicator and
/// favorite-star columns are always present (fixed-width affordances); these are
/// the content columns each call site opts into explicitly.
enum TrackColumn {
    case number, title, artist, composer, album, genre, quality, time

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
        }
    }
    /// Cell/header text alignment: numbers center (they share the column
    /// with the centered now-playing speaker), times right, text left.
    var alignment: NSTextAlignment {
        switch self {
        case .number: .center
        case .time: .right
        default: .left
        }
    }
}
