import Foundation
import SwiftData

extension MetadataSchemaV1 {
    @Model
    final class CachedGenre {
        // OpenSubsonic genres have no separate server ID; the exact name is identity.
        @Attribute(.unique) var name: String
        var songCount: Int?
        var albumCount: Int?

        init(_ value: Genre) {
            name = value.value
            songCount = value.songCount
            albumCount = value.albumCount
        }

        func value() -> Genre {
            Genre(value: name, songCount: songCount, albumCount: albumCount)
        }
    }
}
