import Foundation
import SwiftData

extension MetadataSchemaV1 {
    @Model
    final class CachedAlbum {
        @Attribute(.unique) var id: String
        var name: String
        var artist: String?
        var artistId: String?
        var coverArt: String?
        var songCount: Int?
        var duration: Int?
        var year: Int?
        var genre: String?
        var genresData: Data?
        var starred: Date?
        var discTitlesData: Data?

        var songIDs: [String]?
        @Relationship(deleteRule: .nullify) var songs: [CachedSong] = []

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        func update(_ value: Album, songs: [CachedSong]) throws {
            name = value.name
            artist = value.artist
            artistId = value.artistId
            coverArt = value.coverArt
            songCount = value.songCount
            duration = value.duration
            year = value.year
            genre = value.genre
            genresData = try MetadataMapping.encode(value.genres)
            starred = value.starred
            discTitlesData = try MetadataMapping.encode(value.discTitles)
            songIDs = value.song?.map(\.id)
            self.songs = songs
        }

        func value() throws -> Album {
            var result = Album(id: id, name: name)
            result.artist = artist
            result.artistId = artistId
            result.coverArt = coverArt
            result.songCount = songCount
            result.duration = duration
            result.year = year
            result.genre = genre
            result.genres = try MetadataMapping.decode(genresData, as: [GenreRef].self)
            result.starred = starred
            result.discTitles = try MetadataMapping.decode(discTitlesData, as: [DiscTitle].self)
            result.song = try MetadataMapping.ordered(songs.map { try $0.value() }, ids: songIDs)
            return result
        }
    }
}
