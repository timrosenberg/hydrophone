extension LibraryModel {
    private static let genrePageSize = 500

    func songs(forGenre genre: String) async -> [Song] {
        guard await metadataAllowsLoading() else { return [] }
        let generation = librarySessionGeneration
        var songs: [Song] = []
        var offset = 0
        while true {
            let endpoint = Endpoint.songsByGenre(genre, count: Self.genrePageSize, offset: offset)
            let page = (try? await client.list(endpoint, of: Song.self)) ?? []
            songs.append(contentsOf: page)
            guard page.count == Self.genrePageSize else { break }
            offset += page.count
        }
        await joinWorkInfo(into: &songs)
        guard generation == librarySessionGeneration else { return [] }
        persistMetadata(.songs(songs), generation: generation)
        return songs
    }
}
