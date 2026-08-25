import Testing
import Foundation
@testable import Hydrophone

/// Golden request locks: the exact query-item array (name, value, **order**)
/// each endpoint factory produces. Order matters — `SubsonicClient.formBody`
/// serializes items in order — so these pin the wire format across internal
/// refactors of `Endpoint`. See docs/08-testing.md.
struct EndpointGoldenTests {
    private func q(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }

    @Test func albumList2Plain() {
        #expect(Endpoint.albumList2(type: "newest", size: 100, offset: 40).queryItems == [
            q("type", "newest"), q("size", "100"), q("offset", "40")
        ])
    }

    @Test func albumList2ByGenre() {
        #expect(Endpoint.albumList2(type: "byGenre", size: 50, offset: 0, genre: "Jazz").queryItems == [
            q("type", "byGenre"), q("size", "50"), q("offset", "0"), q("genre", "Jazz")
        ])
    }

    @Test func albumList2ByYear() {
        #expect(Endpoint.albumList2(type: "byYear", size: 50, offset: 0,
                                    fromYear: 1990, toYear: 1999).queryItems == [
            q("type", "byYear"), q("size", "50"), q("offset", "0"),
            q("fromYear", "1990"), q("toYear", "1999")
        ])
    }

    @Test func randomSongs() {
        #expect(Endpoint.randomSongs(size: 500).queryItems == [q("size", "500")])
    }

    @Test func songsByGenre() {
        #expect(Endpoint.songsByGenre("Rock", count: 200, offset: 400).queryItems == [
            q("genre", "Rock"), q("count", "200"), q("offset", "400")
        ])
    }

    @Test func idLookups() {
        #expect(Endpoint.artist(id: "ar-1").queryItems == [q("id", "ar-1")])
        #expect(Endpoint.album(id: "al-1").queryItems == [q("id", "al-1")])
        #expect(Endpoint.song(id: "sg-1").queryItems == [q("id", "sg-1")])
        #expect(Endpoint.playlist(id: "pl-1").queryItems == [q("id", "pl-1")])
        #expect(Endpoint.deletePlaylist(id: "pl-1").queryItems == [q("id", "pl-1")])
    }

    @Test func discovery() {
        #expect(Endpoint.artistInfo2(id: "ar-1", count: 12).queryItems == [
            q("id", "ar-1"), q("count", "12")
        ])
        #expect(Endpoint.similarSongs2(id: "s1", count: 50).queryItems == [
            q("id", "s1"), q("count", "50")
        ])
        #expect(Endpoint.topSongs(artist: "Steely Dan", count: 10).queryItems == [
            q("artist", "Steely Dan"), q("count", "10")
        ])
    }

    @Test func scrobbleBothForms() {
        #expect(Endpoint.scrobble(id: "s1", submission: false).queryItems == [
            q("id", "s1"), q("submission", "false")
        ])
        #expect(Endpoint.scrobble(id: "s1", submission: true).queryItems == [
            q("id", "s1"), q("submission", "true")
        ])
    }

    @Test func savePlayQueueWithCurrent() {
        let endpoint = Endpoint.savePlayQueue(ids: ["a", "b", "c"], current: "b", positionMs: 12345)
        #expect(endpoint.queryItems == [
            q("id", "a"), q("id", "b"), q("id", "c"),
            q("current", "b"), q("position", "12345")
        ])
        #expect(endpoint.usesFormPost)
    }

    @Test func savePlayQueueWithoutCurrent() {
        #expect(Endpoint.savePlayQueue(ids: ["a"], current: nil, positionMs: 0).queryItems == [
            q("id", "a")
        ])
    }

    @Test func search3() {
        #expect(Endpoint.search3(query: "kind of blue", songCount: 40, songOffset: 40,
                                 albumCount: 12, artistCount: 8).queryItems == [
            q("query", "kind of blue"), q("songCount", "40"), q("songOffset", "40"),
            q("albumCount", "12"), q("artistCount", "8")
        ])
    }

    @Test func createPlaylistForms() {
        #expect(Endpoint.createPlaylist(name: "Empty").queryItems == [q("name", "Empty")])
        #expect(Endpoint.createPlaylist(name: "Road Trip", songIds: ["1", "2"]).queryItems == [
            q("name", "Road Trip"), q("songId", "1"), q("songId", "2")
        ])
        #expect(Endpoint.createPlaylist(playlistId: "pl-9", songIds: ["c", "a"]).queryItems == [
            q("playlistId", "pl-9"), q("songId", "c"), q("songId", "a")
        ])
    }

    @Test func updatePlaylistAllParams() {
        #expect(Endpoint.updatePlaylist(id: "p1", name: "New", comment: "note",
                                        isPublic: false, songIdsToAdd: ["x", "y"],
                                        songIndexesToRemove: [2, 0]).queryItems == [
            q("playlistId", "p1"), q("name", "New"), q("comment", "note"),
            q("public", "false"),
            q("songIdToAdd", "x"), q("songIdToAdd", "y"),
            q("songIndexToRemove", "2"), q("songIndexToRemove", "0")
        ])
        #expect(Endpoint.updatePlaylist(id: "p1", isPublic: true).queryItems == [
            q("playlistId", "p1"), q("public", "true")
        ])
    }

    @Test func favoriteAllKinds() {
        #expect(Endpoint.favorite(id: "s1", starred: true).method == "star")
        #expect(Endpoint.favorite(id: "s1", starred: true).queryItems == [q("id", "s1")])
        #expect(Endpoint.favorite(id: "al-1", kind: .album, starred: true).queryItems == [q("albumId", "al-1")])
        #expect(Endpoint.favorite(id: "ar-1", kind: .artist, starred: true).queryItems == [q("artistId", "ar-1")])
        #expect(Endpoint.favorite(id: "s1", starred: false).method == "unstar")
        #expect(Endpoint.favorite(id: "al-1", kind: .album, starred: false).queryItems == [q("albumId", "al-1")])
        #expect(Endpoint.favorite(id: "ar-1", kind: .artist, starred: false).queryItems == [q("artistId", "ar-1")])
    }
}
