import Testing
import Foundation
@testable import Hydrophone

/// OpenSubsonic `contributors` decoding and the Performer/Conductor Get Info
/// rows it drives. See #103; `displayComposer` has its own tests in
/// DecodingTests since the server sends it pre-joined.
struct ContributorDecodingTests {
    private let decoder = SubsonicClient.makeDecoder()

    @Test func decodesPerformerAndConductorFromContributors() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200,"contributors":[
          {"role":"performer","subRole":"violin","artist":{"id":"p1","name":"Anne-Sophie Mutter"}},
          {"role":"performer","subRole":"","artist":{"id":"p2","name":"Yo-Yo Ma"}},
          {"role":"conductor","artist":{"id":"c1","name":"Herbert von Karajan"}},
          {"role":"composer","artist":{"id":"cp1","name":"Beethoven"}}]}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.nonEmptyDisplayPerformer == "Anne-Sophie Mutter (violin) • Yo-Yo Ma")
        #expect(song.nonEmptyDisplayConductor == "Herbert von Karajan")
    }

    @Test func decodesMissingContributorsAsNilPerformerAndConductor() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.nonEmptyDisplayPerformer == nil)
        #expect(song.nonEmptyDisplayConductor == nil)
    }
}
