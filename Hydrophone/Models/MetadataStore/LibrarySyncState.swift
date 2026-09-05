import Foundation
import SwiftData

/// Collection-local bookkeeping, not a server entity or a claim that a partial
/// page is a completed sync. The later sync coordinator owns completion updates.
struct LibrarySyncSnapshot: Sendable, Equatable {
    var collection: String
    var offset: Int = 0
    var generation: Int = 0
    var lastSyncedAt: Date?
}

extension MetadataSchemaV1 {
    @Model
    final class LibrarySyncState {
        @Attribute(.unique) var collection: String
        var offset: Int
        var generation: Int
        var lastSyncedAt: Date?

        init(_ value: LibrarySyncSnapshot) {
            collection = value.collection
            offset = value.offset
            generation = value.generation
            lastSyncedAt = value.lastSyncedAt
        }

        func value() -> LibrarySyncSnapshot {
            LibrarySyncSnapshot(collection: collection, offset: offset,
                                generation: generation, lastSyncedAt: lastSyncedAt)
        }
    }
}
