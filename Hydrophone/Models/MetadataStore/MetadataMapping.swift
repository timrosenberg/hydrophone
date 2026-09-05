import Foundation

/// Nested wire values use explicit JSON attributes, not implicit transformables.
/// Decode failures propagate so callers can reject an unusable seed instead of
/// silently dropping metadata. Model instances must remain in their owning context;
/// only the returned Sendable values may cross an actor boundary.
enum MetadataMapping {
    enum MappingError: Error {
        case missingRelatedRecord
    }

    static func encode<Value: Encodable>(_ value: Value?) throws -> Data? {
        try value.map { try JSONEncoder().encode($0) }
    }

    static func decode<Value: Decodable>(_ data: Data?, as type: Value.Type) throws -> Value? {
        try data.map { try JSONDecoder().decode(type, from: $0) }
    }

    static func unique<Value: Identifiable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    /// SwiftData to-many arrays do not carry the server's sequence. The optional
    /// ID list preserves order, repeats, and unfetched (nil) versus fetched-empty.
    static func ordered<Value: Identifiable>(_ values: [Value], ids: [String]?) throws -> [Value]?
        where Value.ID == String {
        guard let ids else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: unique(values).map { ($0.id, $0) })
        return try ids.map {
            guard let value = byID[$0] else { throw MappingError.missingRelatedRecord }
            return value
        }
    }
}
