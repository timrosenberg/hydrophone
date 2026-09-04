import Foundation

/// Composer roster and per-song lookups (work/movement, bit depth) derived
/// from `NavidromeClient`'s cached song index. Split from NavidromeClient.swift
/// for the file-length lint, same reasoning as LibraryModel+WorkInfo.swift.
extension NavidromeClient {
    /// The full composer roster (`/api/artist?role=composer`), sorted by
    /// localized standard name order. The server-side sort keeps page boundaries
    /// stable; the final sort normalizes differences in database collation.
    /// Includes Navidrome's synthetic joint-credit rows as-is — see `Composer`'s
    /// doc comment. See #23, epic #11.
    func composers() async throws(NavidromeError) -> [Composer] {
        let composers = try await paginatedGet(
            path: "artist",
            sort: "name",
            order: "ASC",
            extraQuery: [URLQueryItem(name: "role", value: "composer")],
            as: Composer.self
        )
        return composers.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Every song crediting `composerId` as a composer (including joint
    /// credits, where one song lists several composer ids). Derived entirely
    /// from `songIndex()`'s cache — no network call beyond whatever building
    /// or reusing that cache already costs; there is no server-side "songs
    /// by composer" filter to call instead (see #24's doc comment). See #25,
    /// epic #11.
    func songs(byComposerId composerId: String) async throws(NavidromeError) -> [NativeSongRecord] {
        try await songIndexSnapshot().records.filter {
            $0.participants?.composer?.contains { $0.id == composerId } ?? false
        }
    }

    /// The work/movement metadata for one song, read from `songIndex()`'s
    /// cached `tags` — no per-song network round trip. `nil` when the song
    /// id isn't in the index, or is but carries none of the four fields.
    /// See #25, epic #11.
    func workMetadata(songId: String) async throws(NavidromeError) -> WorkInfo? {
        guard let song = try await songIndexSnapshot().record(id: songId) else { return nil }
        return Self.workInfo(from: song)
    }

    /// Batch variant of `workMetadata(songId:)`: joins work/movement metadata
    /// for many songs at once against a single dictionary built from the
    /// cached `songIndex()`, so an album's dozen tracks don't each pay
    /// `workMetadata`'s O(n) scan of the whole library. Ids with no match, or
    /// with none of the four fields, are simply absent from the result — same
    /// "nothing to show" contract as the single-song version. See #45, epic
    /// #13.
    func workInfo(forSongIds ids: [String]) async throws(NavidromeError) -> [String: WorkInfo] {
        guard !ids.isEmpty else { return [:] }
        let snapshot = try await songIndexSnapshot()
        var result: [String: WorkInfo] = [:]
        for id in ids {
            guard let song = snapshot.record(id: id), let info = Self.workInfo(from: song) else { continue }
            result[id] = info
        }
        return result
    }

    /// Batch bit-depth lookup for the Now Playing quality badge (#106), same
    /// shape and cache reuse as `workInfo(forSongIds:)`. Ids with no match, or
    /// whose record has no (or a zero) bit depth — lossy files, or a plain
    /// Subsonic/untagged source — are simply absent from the result.
    func bitDepths(forSongIds ids: [String]) async throws(NavidromeError) -> [String: Int] {
        guard !ids.isEmpty else { return [:] }
        let snapshot = try await songIndexSnapshot()
        var result: [String: Int] = [:]
        for id in ids {
            guard let song = snapshot.record(id: id), let bitDepth = song.bitDepth, bitDepth > 0 else { continue }
            result[id] = bitDepth
        }
        return result
    }

    /// `nil` when `record` carries none of the four tags — the shared "is
    /// there anything to show" rule both `workMetadata(songId:)` and
    /// `workInfo(forSongIds:)` apply.
    private static func workInfo(from record: NativeSongRecord) -> WorkInfo? {
        let tags = record.tags ?? [:]
        let info = WorkInfo(
            work: tags["work"]?.first,
            movementName: tags["movementname"]?.first,
            movementNumber: tags["movement"]?.first.flatMap(Int.init),
            movementTotal: tags["movementtotal"]?.first.flatMap(Int.init)
        )
        let isEmpty = info.work == nil && info.movementName == nil
            && info.movementNumber == nil && info.movementTotal == nil
        return isEmpty ? nil : info
    }
}
