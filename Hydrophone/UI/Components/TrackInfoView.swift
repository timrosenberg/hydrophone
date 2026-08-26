import SwiftUI

/// Read-only "Get Info" sheet for a track: artwork + primary metadata on top,
/// then the technical details the server reports. Tag editing is post-v1
/// (see docs/00-overview.md), so everything here is display-only.
struct TrackInfoView: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ArtworkView(coverArt: song.coverArt, cacheKey: song.artworkKey,
                            size: 88, cornerRadius: 8)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    SelectableText(text: song.title, font: .boldSystemFont(ofSize: 15),
                                    maximumNumberOfLines: 2)
                    SelectableText(text: song.artist ?? "—", color: .secondaryLabelColor)
                    if let album = song.album, !album.isEmpty {
                        SelectableText(text: album, font: .systemFont(ofSize: 12),
                                        color: .tertiaryLabelColor)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            Form {
                if let genre = song.displayGenre {
                    LabeledContent("Genre") { SelectableText(text: genre) }
                }
                if let composer = song.nonEmptyDisplayComposer {
                    LabeledContent("Composer") { SelectableText(text: composer) }
                }
                if let year = song.year {
                    LabeledContent("Year") { SelectableText(text: String(year)) }
                }
                if let track = song.track {
                    LabeledContent("Track") {
                        SelectableText(text: song.discNumber.map { "\(track) on disc \($0)" }
                            ?? String(track))
                    }
                }
                LabeledContent("Time") { SelectableText(text: formatTime(song.duration)) }
                if let format = format {
                    LabeledContent("Format") { SelectableText(text: format) }
                }
                if let bitRate = song.bitRate {
                    LabeledContent("Bit Rate") { SelectableText(text: "\(bitRate) kbps") }
                }
                if let size = song.size {
                    LabeledContent("Size") {
                        SelectableText(text: ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file))
                    }
                }
                if song.isStarred {
                    LabeledContent("Favorite", value: "★")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    /// "MP3 (audio/mpeg)"-style format line from the suffix + content type.
    private var format: String? {
        switch (song.suffix?.uppercased(), song.contentType) {
        case let (suffix?, type?): "\(suffix) (\(type))"
        case let (suffix?, nil): suffix
        case let (nil, type?): type
        case (nil, nil): nil
        }
    }
}
