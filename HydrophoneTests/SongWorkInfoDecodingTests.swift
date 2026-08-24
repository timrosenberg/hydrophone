import Testing
import Foundation
@testable import Hydrophone

/// `work`/`movementName`/`movementNumber`/`movementTotal` are never sent by
/// Subsonic — they're joined client-side by `LibraryModel` (#45, epic #13) —
/// so a real Subsonic response must still decode cleanly and leave all four
/// `nil`, confirming the `CodingKeys`-exclusion trick actually works. Kept in
/// its own file rather than added to `DecodingTests.swift`, which is already
/// at that suite's type-length lint budget.
struct SongWorkInfoDecodingTests {
    private let decoder = SubsonicClient.makeDecoder()

    @Test func decodesSongWithNoWorkMovementFieldsFromSubsonic() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{"song":[
        {"id":"s1","title":"Track","artist":"A","duration":200}]}}}
        """
        let wrapper = try decoder.decode(SubsonicResponseWrapper<ListBody<Song>>.self,
                                         from: Data(json.utf8))
        let song = try #require(wrapper.response.body?.items.first)
        #expect(song.work == nil)
        #expect(song.movementName == nil)
        #expect(song.movementNumber == nil)
        #expect(song.movementTotal == nil)
    }
}
