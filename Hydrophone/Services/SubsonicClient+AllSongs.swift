import Foundation

/// Loads the complete song library via paginated `search3` walks, coalesced
/// and cached per exact credential snapshot. Split from SubsonicClient for
/// the type-body-length lint (see PlayerModel's extension split).
extension SubsonicClient {
    private static let allSongsPageLimiter = AsyncLimiter(limit: 6)
    private static let allSongsPageSize = 500

    /// The result of one `buildAllSongs` attempt. Only a walk that reached
    /// exhaustion (`isComplete`) is safe to cache as "the library" — a
    /// random-sample fallback is returned to the caller but must not block
    /// the next call from retrying the real walk.
    struct AllSongsOutcome: Sendable {
        let songs: [Song]
        let isComplete: Bool
    }

    /// Returns every song exposed by the server's empty-query `search3`
    /// implementation, walking fixed-size pages to exhaustion. Only a
    /// completed walk is cached for the exact credentials that produced it;
    /// a fallback result (see `buildAllSongs`) is returned as-is but left
    /// uncached so a transient failure can't strand future callers on a
    /// stale random sample (see PR #97 review).
    func allSongs(
        onProgress: (@Sendable ([Song]) async -> Void)? = nil
    ) async throws(SubsonicError) -> [Song] {
        guard let creds = credentials.load() else { throw .notConfigured }
        if let cachedAllSongs, cachedAllSongs.credentials == creds { return cachedAllSongs.songs }
        if let inFlightAllSongs, inFlightAllSongs.credentials == creds {
            return try await allSongsResult(from: inFlightAllSongs.task)
        }

        allSongsGeneration += 1
        let generation = allSongsGeneration
        let task = Task<AllSongsOutcome, Error> {
            try await self.buildAllSongs(using: creds, onProgress: onProgress)
        }
        inFlightAllSongs = (task, creds)

        do {
            let outcome = try await task.value
            if allSongsGeneration == generation {
                if outcome.isComplete {
                    cachedAllSongs = (outcome.songs, creds)
                }
                inFlightAllSongs = nil
            }
            return outcome.songs
        } catch {
            if allSongsGeneration == generation {
                inFlightAllSongs = nil
            }
            throw error as? SubsonicError ?? .transport(error.localizedDescription)
        }
    }

    /// Retires both completed and in-flight snapshots. An already-awaiting
    /// caller may still receive its result, but that stale completion cannot
    /// repopulate the cache because its generation no longer matches.
    func invalidateAllSongs() {
        allSongsGeneration += 1
        cachedAllSongs = nil
        inFlightAllSongs = nil
    }

    private func allSongsResult(from task: Task<AllSongsOutcome, Error>) async throws(SubsonicError) -> [Song] {
        do {
            return try await task.value.songs
        } catch {
            throw error as? SubsonicError ?? .transport(error.localizedDescription)
        }
    }

    /// Walks the library and falls back to the existing random-sample
    /// behavior when the server rejects or cannot safely paginate an empty
    /// search (including a failure partway through the walk, e.g. a server
    /// that ignores offsets — see `repeatedFullPageFallsBackWithoutAnUnboundedWalk`).
    /// The fallback is marked incomplete so `allSongs()` won't cache it as
    /// the verified library.
    private func buildAllSongs(
        using creds: ServerCredentials,
        onProgress: (@Sendable ([Song]) async -> Void)?
    ) async throws(SubsonicError) -> AllSongsOutcome {
        do {
            let songs = try await walkAllSongs(using: creds, onProgress: onProgress)
            return AllSongsOutcome(songs: songs, isComplete: true)
        } catch {
            let songs = try await list(.randomSongs(size: Self.allSongsPageSize), using: creds, of: Song.self)
            return AllSongsOutcome(songs: songs, isComplete: false)
        }
    }

    // The walk keeps its probe, bounded fan-out, ordering, and progress guard
    // together so their pagination invariants stay visible in one place.
    // swiftlint:disable:next function_body_length
    private func walkAllSongs(
        using creds: ServerCredentials,
        onProgress: (@Sendable ([Song]) async -> Void)?
    ) async throws(SubsonicError) -> [Song] {
        let pageSize = Self.allSongsPageSize
        let first = try await object(
            .allSongs(count: pageSize, offset: 0), using: creds,
            as: SearchContent.self
        ).song ?? []
        if first.isEmpty {
            return try await list(.randomSongs(size: pageSize), using: creds, of: Song.self)
        }
        // Checked before the short-page return below too: a buggy server
        // that dumps its whole catalog (or repeats an id) on page one must
        // still trip this guard instead of shipping duplicate rows.
        var seenIDs = Set(first.map(\.id))
        guard seenIDs.count == first.count else {
            throw .decoding("search3 pagination returned duplicate song ids")
        }
        await publishAllSongsProgress(first, afterAppending: first, onProgress: onProgress)
        guard first.count == pageSize else { return first }

        var songs = first
        var nextOffset = pageSize
        while true {
            let offsets = (0..<6).map { nextOffset + ($0 * pageSize) }
            let pages = await withTaskGroup(
                of: (Int, Result<[Song], SubsonicError>).self
            ) { group in
                for offset in offsets {
                    group.addTask {
                        await Self.allSongsPageLimiter.run {
                            do {
                                let page = try await self.object(
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
                if page.count < pageSize { return songs }
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
}
