import Foundation

/// Resolves native Navidrome composer-song ids into the complete Subsonic
/// `Song` values consumed by track tables and playback. Split from
/// LibraryModel for the type-body-length lint.
extension LibraryModel {
    private static let songFetchLimiter = AsyncLimiter(limit: 6)

    func songs(forComposer id: String) async -> [Song] {
        guard let records = try? await navidrome.songs(byComposerId: id),
              !records.isEmpty else { return [] }
        var songs = await fetchSongs(ids: records.map(\.id))
        await joinWorkInfo(into: &songs)
        return songs
    }

    private func fetchSongs(ids: [String]) async -> [Song] {
        guard !ids.isEmpty else { return [] }
        let client = self.client
        return await withTaskGroup(of: (Int, Song?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    await Self.songFetchLimiter.run {
                        (index, try? await client.object(.song(id: id), as: Song.self))
                    }
                }
            }
            var collected: [(Int, Song?)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }
}
