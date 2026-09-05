import Foundation
import SwiftData

extension MetadataSchemaV1 {
    @Model
    final class CachedPlaylist {
        @Attribute(.unique) var id: String
        var name: String
        var owner: String?
        var `public`: Bool?
        var songCount: Int?
        var duration: Int?
        var comment: String?
        var changed: Date?
        var coverArt: String?

        var entryIDs: [String]?
        @Relationship(deleteRule: .nullify) var entries: [CachedSong] = []

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        func update(_ value: Playlist, entries: [CachedSong]) throws {
            name = value.name
            owner = value.owner
            `public` = value.public
            songCount = value.songCount
            duration = value.duration
            comment = value.comment
            changed = value.changed
            coverArt = value.coverArt
            entryIDs = value.entry?.map(\.id)
            self.entries = entries
        }

        func value() throws -> Playlist {
            var result = Playlist(id: id, name: name)
            result.owner = owner
            result.public = `public`
            result.songCount = songCount
            result.duration = duration
            result.comment = comment
            result.changed = changed
            result.coverArt = coverArt
            result.entry = try MetadataMapping.ordered(entries.map { try $0.value() }, ids: entryIDs)
            return result
        }
    }
}
