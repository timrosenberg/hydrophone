import Foundation
import SwiftData

/// Disk metadata is a disposable warm-start index; the server remains authoritative.
/// Freeze v1 once released. Future structural changes add a new VersionedSchema
/// and migration stage rather than editing the persisted v1 definition in place.
enum MetadataSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [CachedArtist.self, CachedAlbum.self, CachedSong.self,
         CachedGenre.self, CachedPlaylist.self, LibrarySyncState.self]
    }
}

enum MetadataMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MetadataSchemaV1.self] }
    // No previous on-disk metadata schema exists. Add stages alongside v2+.
    static var stages: [MigrationStage] { [] }
}

typealias CachedArtist = MetadataSchemaV1.CachedArtist
typealias CachedAlbum = MetadataSchemaV1.CachedAlbum
typealias CachedSong = MetadataSchemaV1.CachedSong
typealias CachedGenre = MetadataSchemaV1.CachedGenre
typealias CachedPlaylist = MetadataSchemaV1.CachedPlaylist
typealias LibrarySyncState = MetadataSchemaV1.LibrarySyncState
