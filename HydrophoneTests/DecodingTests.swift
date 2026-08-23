import Testing
import Foundation
@testable import Hydrophone

/// Response envelope + model decoding against representative JSON, including
/// the failed-status path. The JSON fixtures predate the generic
/// `ListBody`/`ObjectBody` payloads and are kept byte-identical — they are the
/// behavior lock for that refactor. See docs/02-opensubsonic-api.md.
struct DecodingTests {
    private let decoder = SubsonicClient.makeDecoder()

    @Test func decodesAlbumList2() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",
        "serverVersion":"0.52.0","openSubsonic":true,"albumList2":{"album":[
        {"id":"a1","name":"Kind of Blue","artist":"Miles Davis","artistId":"ar1",
        "coverArt":"al-a1","songCount":5,"duration":2645,"year":1959,"genre":"Jazz",
        "starred":"2023-04-01T10:00:00.000Z"}]}}}
        """
        let data = Data(json.utf8)
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Album>>.self, from: data)
        #expect(wrapper.response.info.status == "ok")
        #expect(wrapper.response.info.openSubsonic == true)
        let albums = try #require(wrapper.response.body?.items)
        #expect(albums.count == 1)
        #expect(albums[0].name == "Kind of Blue")
        #expect(albums[0].year == 1959)
        #expect(albums[0].isStarred)
    }

    @Test func decodesFailedStatusIntoError() throws {
        let json = """
        {"subsonic-response":{"status":"failed","version":"1.16.1",
        "error":{"code":40,"message":"Wrong username or password."}}}
        """
        let data = Data(json.utf8)
        let wrapper = try decoder.decode(SubsonicResponseWrapper<EmptyBody>.self, from: data)
        #expect(wrapper.response.info.status == "failed")
        #expect(wrapper.response.error?.code == 40)
        #expect(wrapper.response.body == nil)
    }

    @Test func failedStatusSkipsPayloadDecodingForGenericBodies() throws {
        // On a failed status InnerResponse must not attempt the payload —
        // ListBody/ObjectBody would throw on the absent payload key.
        let json = """
        {"subsonic-response":{"status":"failed","version":"1.16.1",
        "error":{"code":70,"message":"Not found."}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        #expect(wrapper.response.body == nil)
        #expect(wrapper.response.error?.code == 70)
    }

    @Test func decodesPlaylistWithEntries() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{
        "id":"pl1","name":"Roadtrip","owner":"thijs","public":false,"songCount":2,
        "duration":480,"entry":[
        {"id":"s1","title":"Track One","artist":"A","duration":240},
        {"id":"s2","title":"Track Two","artist":"B","duration":240}]}}}
        """
        let data = Data(json.utf8)
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ObjectBody<Playlist>>.self, from: data)
        let playlist = try #require(wrapper.response.body?.value)
        #expect(playlist.name == "Roadtrip")
        #expect(playlist.entry?.count == 2)
        #expect(playlist.entry?[1].title == "Track Two")
    }

    @Test func decodesOpenSubsonicGenresArray() throws {
        // Navidrome 0.62 omits the legacy `genre` string and sends `genres`.
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200,
        "genres":[{"name":"Jazz"},{"name":"Bebop"}]}]}}}
        """
        let data = Data(json.utf8)
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self, from: data)
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.genre == nil)
        #expect(song.displayGenre == "Jazz")
    }

    @Test func decodesArtistInfo2AndFlattensBioHTML() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artistInfo2":{
        "biography":"Miles Davis was an American trumpeter &amp; bandleader. \
        <a href=\\"https://www.last.fm/music/Miles+Davis\\" rel=\\"nofollow\\">Read more on Last.fm</a>",
        "largeImageUrl":"https://example/img.jpg",
        "similarArtist":[{"id":"ar2","name":"John Coltrane","coverArt":"ar-ar2","albumCount":3}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ObjectBody<ArtistInfo>>.self,
                                         from: Data(json.utf8))
        let info = try #require(wrapper.response.body?.value)
        #expect(info.similarArtist?.first?.name == "John Coltrane")
        let bio = try #require(info.plainBiography)
        #expect(bio == "Miles Davis was an American trumpeter & bandleader.")
    }

    @Test func decodesSimilarSongs2() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","similarSongs2":{"song":[
        {"id":"s1","title":"So What","artist":"Miles Davis","duration":545},
        {"id":"s2","title":"Naima","artist":"John Coltrane","duration":263}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let songs = try #require(wrapper.response.body?.items)
        #expect(songs.count == 2)
        #expect(songs[1].title == "Naima")
    }

    @Test func decodesTopSongsAndEmptyContainer() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","topSongs":{"song":[
        {"id":"s1","title":"Blue in Green","artist":"Miles Davis","duration":328}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        #expect(wrapper.response.body?.items.count == 1)

        // Servers with no data send an empty object — must decode as [].
        let empty = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","topSongs":{}}}
        """
        let emptyWrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                              from: Data(empty.utf8))
        #expect(emptyWrapper.response.body?.items.isEmpty == true)
    }

    @Test func decodesArtistIndexDespiteSiblingMetadata() throws {
        // The `artists` container carries scalar keys next to the index list —
        // the reason ListBody takes its element key from the type instead of
        // inferring "the single inner key".
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artists":{
        "ignoredArticles":"The El La Los Las Le","lastModified":1678886400000,
        "index":[
        {"name":"C","artist":[{"id":"ar1","name":"John Coltrane","albumCount":3}]},
        {"name":"D","artist":[{"id":"ar2","name":"Miles Davis","albumCount":9}]}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<ArtistIndex>>.self,
                                         from: Data(json.utf8))
        let buckets = try #require(wrapper.response.body?.items)
        #expect(buckets.count == 2)
        #expect(buckets.flatMap { $0.artist ?? [] }.map(\.name)
                == ["John Coltrane", "Miles Davis"])
    }

    @Test func missingPayloadKeyThrows() {
        // An ok envelope with no payload at all — the old non-optional bodies
        // threw here too (surfaced as SubsonicError.decoding by the client).
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1"}}
        """
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                   from: Data(json.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(SubsonicResponseWrapper<ObjectBody<Album>>.self,
                                   from: Data(json.utf8))
        }
    }

    @Test func decodesStarred2BothLists() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{
        "album":[{"id":"a1","name":"Giant Steps"}],
        "song":[{"id":"s1","title":"Naima"},{"id":"s2","title":"Countdown"}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ObjectBody<StarredContent>>.self,
                                         from: Data(json.utf8))
        let starred = try #require(wrapper.response.body?.value)
        #expect(starred.album?.count == 1)
        #expect(starred.song?.count == 2)
    }

    @Test func decodesDisplayComposer() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200,
        "displayComposer":"Johann Sebastian Bach"}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.displayComposer == "Johann Sebastian Bach")
        #expect(song.nonEmptyDisplayComposer == "Johann Sebastian Bach")
    }

    @Test func decodesDisplayComposerVerbatimForMultipleComposers() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200,
        "displayComposer":"J.S. Bach, G.F. Handel"}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.displayComposer == "J.S. Bach, G.F. Handel")
        #expect(song.nonEmptyDisplayComposer == "J.S. Bach, G.F. Handel")
    }

    @Test func decodesMissingDisplayComposerAsNil() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.displayComposer == nil)
    }

    @Test func treatsBlankDisplayComposerAsMissing() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Empty","displayComposer":""},
        {"id":"s2","title":"Whitespace","displayComposer":"     "}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let songs = try #require(wrapper.response.body?.items)
        #expect(songs.map(\.nonEmptyDisplayComposer) == [nil, nil])
    }

    @Test func decodesDatesWithoutFractionalSeconds() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","album":{
        "id":"a2","name":"X","starred":"2022-01-02T03:04:05Z"}}}
        """
        let data = Data(json.utf8)
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ObjectBody<Album>>.self, from: data)
        #expect(wrapper.response.body?.value.isStarred == true)
    }

    @Test func decodesExpandedTrackColumnFields() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200,
        "displayAlbumArtist":"Various Artists","comment":"Live take",
        "groupings":["Movement II"],"created":"2024-03-01T10:00:00.000Z",
        "played":"2024-06-15T20:30:00.000Z","playCount":42,"samplingRate":44100,
        "sortName":"Track, The"}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.displayAlbumArtist == "Various Artists")
        #expect(song.comment == "Live take")
        #expect(song.groupings == ["Movement II"])
        #expect(song.created != nil)
        #expect(song.played != nil)
        #expect(song.playCount == 42)
        #expect(song.samplingRate == 44_100)
        #expect(song.sortName == "Track, The")
    }

    @Test func decodesMissingExpandedTrackColumnFieldsAsNil() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.displayAlbumArtist == nil)
        #expect(song.comment == nil)
        #expect(song.groupings == nil)
        #expect(song.created == nil)
        #expect(song.played == nil)
        #expect(song.playCount == nil)
        #expect(song.samplingRate == nil)
        #expect(song.sortName == nil)
    }
}
