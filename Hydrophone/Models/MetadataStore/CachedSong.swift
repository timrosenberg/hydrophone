import Foundation
import SwiftData

extension MetadataSchemaV1 {
    @Model
    final class CachedSong {
        @Attribute(.unique) var id: String
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
        var genresData: Data?
        var displayComposer: String?
        var contributorsData: Data?
        var replayGainData: Data?
        var displayAlbumArtist: String?
        var comment: String?
        var groupings: [String]?
        var created: Date?
        var played: Date?
        var playCount: Int?
        var samplingRate: Int?
        var sortName: String?
        var work: String?
        var movementName: String?
        var movementNumber: Int?
        var movementTotal: Int?
        var bitDepth: Int?

        init(id: String, title: String) {
            self.id = id
            self.title = title
        }

        func update(_ value: Song) throws {
            title = value.title
            artist = value.artist
            artistId = value.artistId
            album = value.album
            albumId = value.albumId
            coverArt = value.coverArt
            duration = value.duration
            track = value.track
            discNumber = value.discNumber
            year = value.year
            genre = value.genre
            bitRate = value.bitRate
            suffix = value.suffix
            contentType = value.contentType
            size = value.size
            starred = value.starred
            genresData = try MetadataMapping.encode(value.genres)
            displayComposer = value.displayComposer
            contributorsData = try MetadataMapping.encode(value.contributors)
            replayGainData = try MetadataMapping.encode(value.replayGain)
            displayAlbumArtist = value.displayAlbumArtist
            comment = value.comment
            groupings = value.groupings
            created = value.created
            played = value.played
            playCount = value.playCount
            samplingRate = value.samplingRate
            sortName = value.sortName
            work = value.work
            movementName = value.movementName
            movementNumber = value.movementNumber
            movementTotal = value.movementTotal
            bitDepth = value.bitDepth
        }

        func value() throws -> Song {
            var result = Song(id: id, title: title)
            result.artist = artist
            result.artistId = artistId
            result.album = album
            result.albumId = albumId
            result.coverArt = coverArt
            result.duration = duration
            result.track = track
            result.discNumber = discNumber
            result.year = year
            result.genre = genre
            result.bitRate = bitRate
            result.suffix = suffix
            result.contentType = contentType
            result.size = size
            result.starred = starred
            result.genres = try MetadataMapping.decode(genresData, as: [GenreRef].self)
            result.displayComposer = displayComposer
            result.contributors = try MetadataMapping.decode(contributorsData, as: [Contributor].self)
            result.replayGain = try MetadataMapping.decode(replayGainData, as: ReplayGainInfo.self)
            result.displayAlbumArtist = displayAlbumArtist
            result.comment = comment
            result.groupings = groupings
            result.created = created
            result.played = played
            result.playCount = playCount
            result.samplingRate = samplingRate
            result.sortName = sortName
            result.work = work
            result.movementName = movementName
            result.movementNumber = movementNumber
            result.movementTotal = movementTotal
            result.bitDepth = bitDepth
            return result
        }
    }
}
