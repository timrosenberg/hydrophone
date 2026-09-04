import Foundation

/// Composer roster lookup. Split from NavidromeClient.swift for the
/// file-length lint. Per-song lookups (work/movement, bit depth, composer
/// song filtering) that used to live here moved to `LibrarySongIndex` along
/// with the native song-index cache they read through — see
/// docs/05-data-and-caching.md's "Design decision (#140)".
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
}
