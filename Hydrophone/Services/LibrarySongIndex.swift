import Foundation

/// Owns "the library's songs": the Subsonic `search3` full-library walk
/// (always available) and the Navidrome-native `/api/song` walk (only when
/// native features are available), unified behind one interface instead of
/// the two separately hand-rolled caches (`SubsonicClient.cachedAllSongs`,
/// `NavidromeClient.cachedSongIndex`) this consolidates. See
/// docs/05-data-and-caching.md's "Design decision (#140)" (140.1) for the
/// evidence behind keeping both walks while unifying their lifecycle.
///
/// Deliberately **not** an actor: it holds no mutable state of its own —
/// every stored property below is a `let`, and the two caches are
/// independently-isolated actors already. Making this type itself an actor
/// would force the Subsonic walk and the native walk/lookups to serialize
/// against each other (every call has to enter *this* actor first), which
/// defeats the point of keeping two independent caches — a live check
/// caught exactly this: a playlist's non-blocking native join
/// (`join(into:)`) waited behind an in-progress Songs-tab Subsonic walk
/// instead of running concurrently with it, the same regression #124 fixed
/// this design is supposed to preserve. A plain `Sendable` class with two
/// actor-backed caches keeps that concurrency intact.
final class LibrarySongIndex: Sendable {
    private let client: SubsonicClient
    private let navidrome: NavidromeClient
    private let nativeFeaturesAvailable: @Sendable () async -> Bool

    private let subsonicCache = CredentialScopedCache<AllSongsOutcome>()
    private let nativeCache = CredentialScopedCache<NativeSongIndexSnapshot>()

    private static let pageLimiter = AsyncLimiter(limit: 6)
    private static let pageSize = 500

    init(client: SubsonicClient, navidrome: NavidromeClient,
         nativeFeaturesAvailable: @escaping @Sendable () async -> Bool) {
        self.client = client
        self.navidrome = navidrome
        self.nativeFeaturesAvailable = nativeFeaturesAvailable
    }

    // MARK: - Subsonic full-library walk (always available)

    /// The result of one `buildAllSongs` attempt. Only a walk that reached
    /// exhaustion (`isComplete`) is safe to cache as "the library" — a
    /// random-sample fallback is returned to the caller but must not block
    /// the next call from retrying the real walk.
    private struct AllSongsOutcome: Sendable {
        let songs: [Song]
        let isComplete: Bool
    }

    /// Every song exposed by the server's empty-query `search3` implementation,
    /// walked to exhaustion and cached per exact credential snapshot, then
    /// joined with native work/movement/bitDepth metadata when available —
    /// one call replaces the old two-step "fetch, then separately join."
    /// `onProgress` still fires on raw, unjoined partial pages exactly as
    /// before; the join runs exactly once, after the walk completes.
    func allSongs(
        onProgress: (@Sendable ([Song]) async -> Void)? = nil
    ) async throws(SubsonicError) -> [Song] {
        guard let creds = await client.currentCredentials else { throw .notConfigured }
        let outcome: AllSongsOutcome
        do {
            outcome = try await subsonicCache.resolve(using: creds) { () async throws -> (AllSongsOutcome, Bool) in
                let outcome = try await self.buildAllSongs(using: creds, onProgress: onProgress)
                return (outcome, outcome.isComplete)
            }
        } catch {
            throw error as? SubsonicError ?? .transport(error.localizedDescription)
        }
        var joined = outcome.songs
        await join(into: &joined)
        return joined
    }

    /// A pruning authority must represent an exhausted walk, never the browsing
    /// fallback. Coalesces with the normal walk and reuses its completed cache.
    func completeSongs(using creds: ServerCredentials) async throws -> [Song] {
        guard !Task.isCancelled, await client.currentCredentials == creds else {
            throw CancellationError()
        }
        let outcome = try await subsonicCache.resolve(using: creds) {
            let result = try await self.buildAllSongs(using: creds, onProgress: nil)
            return (result, result.isComplete)
        }
        guard outcome.isComplete else { throw SubsonicError.decoding("Incomplete library walk") }
        var songs = outcome.songs
        if await nativeFeaturesAvailable() {
            // Unlike the display-only join, a failed native walk cannot silently
            // become a complete snapshot that erases persisted work metadata.
            let native = try await songIndexSnapshot()
            for index in songs.indices {
                let record = native.record(id: songs[index].id)
                let work = record.flatMap(Self.workInfo(from:))
                songs[index].work = work?.work
                songs[index].movementName = work?.movementName
                songs[index].movementNumber = work?.movementNumber
                songs[index].movementTotal = work?.movementTotal
                songs[index].bitDepth = record?.bitDepth
            }
        }
        guard !Task.isCancelled, await client.currentCredentials == creds else {
            throw CancellationError()
        }
        return songs
    }

    /// Walks the library and falls back to the existing random-sample
    /// behavior when the server rejects or cannot safely paginate an empty
    /// search before any page has reached the caller. The fallback is marked
    /// incomplete so `allSongs()` won't cache it as the verified library.
    ///
    /// If the walk instead fails *after* already publishing progress via
    /// `onProgress`, the caller may already be showing those real songs —
    /// silently replacing them with an unrelated random sample would look
    /// like data loss, so the original error is propagated instead and the
    /// caller keeps its last good partial snapshot (see PR #98 review).
    private func buildAllSongs(
        using creds: ServerCredentials,
        onProgress: (@Sendable ([Song]) async -> Void)?
    ) async throws(SubsonicError) -> AllSongsOutcome {
        let marker = onProgress.map { _ in ProgressMarker() }
        let trackedProgress: (@Sendable ([Song]) async -> Void)?
        if let onProgress, let marker {
            trackedProgress = { songs in
                await marker.markPublished()
                await onProgress(songs)
            }
        } else {
            trackedProgress = nil
        }
        do {
            return try await walkAllSongs(using: creds, onProgress: trackedProgress)
        } catch {
            if let marker, await marker.published {
                throw error
            }
            let songs = try await client.list(.randomSongs(size: Self.pageSize), using: creds, of: Song.self)
            return AllSongsOutcome(songs: songs, isComplete: false)
        }
    }

    /// Records whether the walk has published at least one page, so
    /// `buildAllSongs` can tell a fresh failure apart from one that would
    /// clobber progress a caller already rendered.
    private actor ProgressMarker {
        private(set) var published = false
        func markPublished() { published = true }
    }

    // The walk keeps its probe, bounded fan-out, ordering, and progress guard
    // together so their pagination invariants stay visible in one place.
    // swiftlint:disable:next function_body_length
    private func walkAllSongs(
        using creds: ServerCredentials,
        onProgress: (@Sendable ([Song]) async -> Void)?
    ) async throws(SubsonicError) -> AllSongsOutcome {
        let pageSize = Self.pageSize
        let first = try await client.object(
            .allSongs(count: pageSize, offset: 0), using: creds,
            as: SearchContent.self
        ).song ?? []
        if first.isEmpty {
            let sample = try await client.list(.randomSongs(size: pageSize), using: creds, of: Song.self)
            return AllSongsOutcome(songs: sample, isComplete: sample.isEmpty)
        }
        // Checked before the short-page return below too: a buggy server
        // that dumps its whole catalog (or repeats an id) on page one must
        // still trip this guard instead of shipping duplicate rows.
        var seenIDs = Set(first.map(\.id))
        guard seenIDs.count == first.count else {
            throw .decoding("search3 pagination returned duplicate song ids")
        }
        await publishAllSongsProgress(first, afterAppending: first, onProgress: onProgress)
        guard first.count == pageSize else { return AllSongsOutcome(songs: first, isComplete: true) }

        var songs = first
        var nextOffset = pageSize
        while true {
            let offsets = (0..<6).map { nextOffset + ($0 * pageSize) }
            let pages = await withTaskGroup(
                of: (Int, Result<[Song], SubsonicError>).self
            ) { group in
                for offset in offsets {
                    group.addTask {
                        await Self.pageLimiter.run {
                            do {
                                let page = try await self.client.object(
                                    .allSongs(count: pageSize, offset: offset),
                                    using: creds,
                                    as: SearchContent.self
                                ).song ?? []
                                return (offset, .success(page))
                            } catch {
                                return (offset, .failure(
                                    error as? SubsonicError ?? .transport(error.localizedDescription)
                                ))
                            }
                        }
                    }
                }
                var results: [(Int, Result<[Song], SubsonicError>)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            for (_, result) in pages {
                let page = try result.get()
                let pageIDs = Set(page.map(\.id))
                guard pageIDs.count == page.count, seenIDs.isDisjoint(with: pageIDs) else {
                    throw .decoding("search3 pagination did not advance")
                }
                songs.append(contentsOf: page)
                seenIDs.formUnion(pageIDs)
                await publishAllSongsProgress(songs, afterAppending: page, onProgress: onProgress)
                if page.count < pageSize { return AllSongsOutcome(songs: songs, isComplete: true) }
            }
            nextOffset += pageSize * offsets.count
        }
    }

    private func publishAllSongsProgress(
        _ songs: [Song],
        afterAppending page: [Song],
        onProgress: (@Sendable ([Song]) async -> Void)?
    ) async {
        guard !page.isEmpty, let onProgress else { return }
        await onProgress(songs)
    }

    // MARK: - Native song index (Navidrome-only, when available)

    /// Every non-missing song in the library, with per-role `participants`
    /// credits and raw `tags` — paginates `/api/song` and caches the result;
    /// repeat calls within the same session return the cached copy without
    /// refetching, unless credentials changed or `invalidate()` was called.
    /// See #24, epic #11.
    func songIndex() async throws(NavidromeError) -> [NativeSongRecord] {
        try await songIndexSnapshot().records
    }

    /// Every song crediting `composerId` as a composer (including joint
    /// credits, where one song lists several composer ids). Derived entirely
    /// from the cached native song index — no network call beyond whatever
    /// building or reusing that cache already costs; there is no server-side
    /// "songs by composer" filter to call instead. See #24/#25, epic #11.
    func songs(byComposerId composerId: String) async throws(NavidromeError) -> [NativeSongRecord] {
        try await songIndexSnapshot().records.filter {
            $0.participants?.composer?.contains { $0.id == composerId } ?? false
        }
    }

    /// The work/movement metadata for one song, read from the cached native
    /// song index — no per-song network round trip. `nil` when the song id
    /// isn't in the index, or is but carries none of the four fields.
    func workMetadata(songId: String) async throws(NavidromeError) -> WorkInfo? {
        guard let song = try await songIndexSnapshot().record(id: songId) else { return nil }
        return Self.workInfo(from: song)
    }

    /// Batch work/movement lookup against the cached native song index. Ids
    /// with no match, or with none of the four fields, are simply absent.
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
    /// cache reuse as `workInfo(forSongIds:)`.
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

    /// Joins `work`/`movementName`/`movementNumber`/`movementTotal`, and
    /// `bitDepth`, onto `songs` in place, from the cached native song index.
    /// A no-op — including on any native-side failure — when native features
    /// aren't available, so a plain Subsonic server never pays for or sees
    /// this. Was `LibraryModel.joinWorkInfo(into:)`; callers unchanged.
    func join(into songs: inout [Song]) async {
        guard !songs.isEmpty, await nativeFeaturesAvailable() else { return }
        let ids = songs.map(\.id)
        if let info = try? await workInfo(forSongIds: ids), !info.isEmpty {
            for index in songs.indices {
                guard let work = info[songs[index].id] else { continue }
                songs[index].work = work.work
                songs[index].movementName = work.movementName
                songs[index].movementNumber = work.movementNumber
                songs[index].movementTotal = work.movementTotal
            }
        }
        if let bitDepths = try? await bitDepths(forSongIds: ids), !bitDepths.isEmpty {
            for index in songs.indices {
                songs[index].bitDepth = bitDepths[songs[index].id]
            }
        }
    }

    /// `nil` when `record` carries none of the four tags — the shared "is
    /// there anything to show" rule both lookups above apply.
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

    /// Walks `/api/song?missing=false` fully, caching the result per exact
    /// credential snapshot. Pinned to one `creds` snapshot for the entire
    /// walk (and its 401 retry), same reasoning as the Subsonic walk above.
    private func songIndexSnapshot() async throws(NavidromeError) -> NativeSongIndexSnapshot {
        guard let creds = await navidrome.currentCredentials else { throw .notConfigured }
        do {
            return try await nativeCache.resolve(using: creds) {
                let records = try await self.navidrome.paginatedGet(
                    path: "song", sort: "id", order: "ASC",
                    extraQuery: [URLQueryItem(name: "missing", value: "false")],
                    pageSize: 500, using: creds, as: NativeSongRecord.self
                )
                return NativeSongIndexSnapshot(records: records)
            }
        } catch {
            throw error as? NavidromeError ?? .transport("\(error)")
        }
    }

    // MARK: - Invalidation

    /// Retires both walks together — disconnect, a credential change, and a
    /// successful library scan all need every projection of the library
    /// invalidated, not just the Subsonic side (today's asymmetry, where
    /// disconnect skipped the native cache, is what this fixes).
    func invalidate() async {
        await subsonicCache.invalidate()
        await nativeCache.invalidate()
    }
}
