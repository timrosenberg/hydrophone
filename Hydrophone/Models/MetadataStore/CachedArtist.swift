import Foundation
import SwiftData

extension MetadataSchemaV1 {
    @Model
    final class CachedArtist {
        @Attribute(.unique) var id: String
        var name: String
        var coverArt: String?
        var albumCount: Int?
        var starred: Date?

        var albumIDs: [String]?
        @Relationship(deleteRule: .nullify) var albums: [CachedAlbum] = []

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        func update(_ value: Artist, albums: [CachedAlbum]) throws {
            name = value.name
            coverArt = value.coverArt
            albumCount = value.albumCount
            starred = value.starred
            albumIDs = value.album?.map(\.id)
            self.albums = albums
        }

        func value() throws -> Artist {
            var result = Artist(id: id, name: name)
            result.coverArt = coverArt
            result.albumCount = albumCount
            result.starred = starred
            result.album = try MetadataMapping.ordered(albums.map { try $0.value() }, ids: albumIDs)
            return result
        }
    }
}
