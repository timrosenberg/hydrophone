import Foundation
import Testing
@testable import Hydrophone

struct LibraryMetadataStoreTests {
    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("metadata-tests-\(UUID())")
    }

    static func credentials(_ host: String = "https://example.com", user: String = "listener",
                            secret: String = "password", method: ServerCredentials.AuthMethod = .tokenSalt)
        -> ServerCredentials {
        ServerCredentials(baseURL: URL(string: host)!, username: user, secret: secret, authMethod: method)
    }

    @Test func sessionsIsolateServersAndAccountsAndRetainFiles() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let first = try #require(await store.open(for: Self.credentials()))
        await store.write(.songs([MetadataStoreFixtures.song]), for: first)
        let other = try #require(await store.open(for: Self.credentials("https://other.example.com")))
        #expect(await store.read(for: other)?.songs.isEmpty == true)
        await store.write(.songs([Song(id: "stale", title: "Stale")]), for: first)
        #expect(await store.read(for: first) == nil)
        let account = try #require(await store.open(for: Self.credentials(user: "other")))
        #expect(await store.read(for: account)?.songs.isEmpty == true)
        await store.close()
        let returned = try #require(await store.open(for: Self.credentials("https://EXAMPLE.com:443/",
                                                                          secret: "new-password")))
        #expect(returned.scope == first.scope)
        #expect(await store.read(for: returned)?.songs == [MetadataStoreFixtures.song])
        await store.close()
        #expect(await store.read(for: returned) == nil)
        let reopened = LibraryMetadataStore(rootDirectory: root)
        let reopenedSession = try #require(await reopened.open(for: Self.credentials()))
        #expect(await reopened.read(for: reopenedSession)?.songs == [MetadataStoreFixtures.song])
        await reopened.close()
    }

    @Test func apiKeysDoNotShareAnonymousAccounts() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let first = try #require(await store.open(for: Self.credentials(user: "", secret: "key-one", method: .apiKey)))
        await store.write(.songs([MetadataStoreFixtures.song]), for: first)
        let second = try #require(await store.open(for: Self.credentials(user: "", secret: "key-two", method: .apiKey)))
        #expect(first.scope != second.scope)
        #expect(!first.scope.contains("key-one"))
        #expect(await store.read(for: second)?.songs.isEmpty == true)
        await store.close()
    }

    @Test func missingSummaryDetailPreservesFetchedGraphsAndExplicitEmptyClears() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: Self.credentials()))
        await store.write(.artists([MetadataStoreFixtures.artist]), for: session)
        await store.write(.playlist(MetadataStoreFixtures.playlist), for: session)
        await store.write(.artists([Artist(id: "artist-1", name: "Renamed")]), for: session)
        await store.write(.albums([Album(id: "album-1", name: "Renamed")]), for: session)
        await store.write(.playlists([Playlist(id: "playlist-1", name: "Renamed")]), for: session)
        let preserved = try #require(await store.read(for: session))
        #expect(preserved.artists.first?.album?.map(\.id) == ["album-1"])
        #expect(preserved.albums.first?.song?.map(\.id) == ["song-1"])
        #expect(preserved.playlists.first?.entry?.map(\.id) == ["song-1", "song-2", "song-1"])
        await store.write(.albums([Album(id: "album-1", name: "Empty", song: [])]), for: session)
        await store.write(.playlist(Playlist(id: "playlist-1", name: "Empty", entry: [])), for: session)
        let cleared = try #require(await store.read(for: session))
        #expect(cleared.albums.first?.song == [])
        #expect(cleared.playlists.first?.entry == [])
        #expect(cleared.songs.count == 2)
        await store.close()
    }

    @Test func partialSongsAndFavoritesKeepNativeAndRichFields() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        let session = try #require(await store.open(for: Self.credentials()))
        await store.write(.songs([MetadataStoreFixtures.song]), for: session)
        var raw = MetadataStoreFixtures.song
        raw.work = nil
        raw.bitDepth = nil
        await store.write(.songs([raw]), for: session)
        #expect(await store.read(for: session)?.songs.first?.work == "Suite")
        #expect(await store.read(for: session)?.favorites == nil)
        let favorite = Song(id: "song-1", title: "Movement", starred: MetadataStoreFixtures.date)
        await store.write(.favorites(MetadataFavorites(songs: [favorite], albums: [])), for: session)
        let starred = try #require(await store.read(for: session))
        #expect(starred.favorites?.songs.first?.bitDepth == 24)
        #expect(starred.songs.first?.contributors == MetadataStoreFixtures.song.contributors)
        await store.write(.favorites(MetadataFavorites(songs: [], albums: [])), for: session)
        #expect(await store.read(for: session)?.songs.first?.starred == nil)
        #expect(await store.read(for: session)?.favorites?.songs == [])
        await store.close()
    }

    @Test func unavailableRootFailsWithoutThrowing() async throws {
        let root = Self.root()
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryMetadataStore(rootDirectory: root)
        #expect(await store.open(for: Self.credentials()) == nil)
    }
}
