import Foundation
import Testing
@testable import Hydrophone

struct NativeSongMappingTests {
    @Test func nativeZeroValuesMatchSubsonicOmittedMetadata() throws {
        let data = Data("""
        {"id":"song","title":"Title","album":"","albumId":"","artist":"","artistId":"",
         "trackNumber":0,"discNumber":0,"year":0,"duration":0.5,"bitRate":0,"size":0,
         "playCount":0,"genre":"","suffix":"","sampleRate":0,"rgTrackPeak":0.91}
        """.utf8)
        let song = try JSONDecoder().decode(NativeSongRecord.self, from: data).asSong()
        #expect(song.album == nil)
        #expect(song.albumId == nil)
        #expect(song.artist == nil)
        #expect(song.artistId == nil)
        #expect(song.track == nil)
        #expect(song.discNumber == nil)
        #expect(song.year == nil)
        #expect(song.duration == nil)
        #expect(song.bitRate == nil)
        #expect(song.size == nil)
        #expect(song.playCount == nil)
        #expect(song.genre == nil)
        #expect(song.suffix == nil)
        #expect(song.samplingRate == 0)
        #expect(song.replayGain == ReplayGainInfo(trackPeak: 0.91))
    }

    @Test(arguments: [
        ("m4a", "audio/mp4"), ("aac", "audio/mp4"), ("wav", "audio/x-wav"),
        ("aif", "audio/x-aiff"), ("AIFF", "audio/x-aiff"), ("opus", "audio/ogg"),
        ("ape", "audio/x-monkeys-audio"), ("dsf", "audio/x-dsf")
    ])
    func usesNavidromeFormatLabels(suffix: String, expected: String) {
        var record = NativeSongRecord(id: "song")
        record.suffix = suffix
        #expect(record.asSong().contentType == expected)
    }

    @Test func preservesComposerCreditSubroles() throws {
        let data = Data("""
        {"id":"song","participants":{"composer":[
          {"id":"a","name":"Composer","subRole":"arrangement"},
          {"id":"b","name":"Other Composer","subRole":""}]}}
        """.utf8)
        let song = try JSONDecoder().decode(NativeSongRecord.self, from: data).asSong()
        #expect(song.displayComposer == "Composer (arrangement) • Other Composer")
    }

    @Test func sparseRecordRemainsPlayableWithoutInventingMetadata() throws {
        let record = try JSONDecoder().decode(NativeSongRecord.self, from: Data(#"{"id":"song"}"#.utf8))
        let song = record.asSong()
        #expect(song.id == "song")
        #expect(song.title.isEmpty)
        #expect(song.coverArt == "song")
        #expect(song.artworkKey == "song")
        #expect(song.duration == nil)
        #expect(song.contentType == nil)
        #expect(song.replayGain == nil)
        #expect(song.displayComposer == nil)
        #expect(!song.isStarred)
    }

    @Test func optionalInvalidDatesAndUnrepresentableDurationDoNotBreakRows() throws {
        let data = Data("""
        {"id":"song","title":"Title","duration":1e100,"sortTitle":"","orderTitle":"title",
         "createdAt":"not-a-date","playCount":0,"playDate":"0001-01-01T00:00:00Z",
         "starred":false,"starredAt":"2025-01-01T00:00:00Z","suffix":"mp3"}
        """.utf8)
        let song = try JSONDecoder().decode(NativeSongRecord.self, from: data).asSong()
        #expect(song.title == "Title")
        #expect(song.duration == nil)
        #expect(song.created == nil)
        #expect(song.played == nil)
        #expect(song.sortName == "title")
        #expect(song.contentType == "audio/mpeg")
        #expect(!song.isStarred)
    }
}
