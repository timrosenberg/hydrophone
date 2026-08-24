import Foundation

extension LibraryModel {
    struct SearchResults: Sendable {
        var artists: [Artist] = []
        var albums: [Album] = []
        var songs: [Song] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
    }

    func search(_ query: String) async -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }
        do {
            let found = try await client.object(
                .search3(query: trimmed, songCount: 50, songOffset: 0, albumCount: 20, artistCount: 20),
                as: SearchContent.self
            )
            var songs = found.song ?? []
            await joinWorkInfo(into: &songs)
            return SearchResults(
                artists: found.artist ?? [],
                albums: found.album ?? [],
                songs: songs
            )
        } catch {
            return SearchResults()
        }
    }
}
