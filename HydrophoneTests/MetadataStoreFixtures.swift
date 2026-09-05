import Foundation
import SwiftData
@testable import Hydrophone

enum MetadataStoreFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static var song: Song {
        Song(id: "song-1", title: "Movement", artist: "Artist", artistId: "artist-1",
             album: "Album", albumId: "album-1", coverArt: "art-1", duration: 243,
             track: 2, discNumber: 3, year: 2024, genre: "Classical", bitRate: 2800,
             suffix: "flac", contentType: "audio/flac", size: 123456, starred: date,
             genres: [GenreRef(name: "Classical"), GenreRef(name: "Chamber")],
             displayComposer: "Composer", contributors: [
                Contributor(role: "performer", subRole: "saxophone",
                            artist: .init(id: "performer-1", name: "Performer"))
             ], replayGain: ReplayGainInfo(trackGain: -3.5, albumGain: -2.5,
                                           trackPeak: 0.9, albumPeak: 0.95),
             displayAlbumArtist: "Album Artist", comment: "Comment", groupings: ["Suite", "Set"],
             created: date, played: date, playCount: 4, samplingRate: 96000, sortName: "Sort",
             work: "Suite", movementName: "Allegro", movementNumber: 2, movementTotal: 4, bitDepth: 24)
    }

    static var album: Album {
        Album(id: "album-1", name: "Album", artist: "Artist", artistId: "artist-1",
              coverArt: "album-art", songCount: 1, duration: 243, year: 2024,
              genre: "Classical", genres: [GenreRef(name: "Chamber")], starred: date,
              song: [song], discTitles: [DiscTitle(disc: 3, title: "Finale")])
    }

    static var artist: Artist {
        Artist(id: "artist-1", name: "Artist", coverArt: "artist-art", albumCount: 1,
               starred: date, album: [album])
    }

    static var playlist: Playlist {
        Playlist(id: "playlist-1", name: "Favorites", owner: "Listener", public: false,
                 songCount: 3, duration: 500, comment: "Ordered", changed: date, coverArt: "playlist-art",
                 entry: [song, Song(id: "song-2", title: "Other"), song])
    }

    static func container(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: MetadataSchemaV1.self)
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: MetadataMigrationPlan.self,
                                  configurations: [configuration])
    }
}

@ModelActor
actor MetadataStoreReader {
    func songs() throws -> [Song] {
        try modelContext.fetch(FetchDescriptor<CachedSong>()).map { try $0.value() }
    }
}
