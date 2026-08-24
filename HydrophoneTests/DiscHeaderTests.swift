import Testing
import Foundation
@testable import Hydrophone

/// Album group headers: row building keeps track indices stable while
/// interleaving unselectable disc or classical-work headers.
@MainActor
struct DiscHeaderTests {
    private func song(_ id: String, disc: Int?, track: Int, work: String? = nil) -> Song {
        var song = Song(id: id, title: id, duration: 100, track: track, discNumber: disc)
        song.work = work
        return song
    }

    @Test func multiDiscGetsHeadersWithStableTrackIndices() {
        let tracks = [song("a", disc: 1, track: 1), song("b", disc: 1, track: 2),
                      song("c", disc: 2, track: 1)]
        let rows = TrackTableRow.build(tracks: tracks, headers: [:])
        #expect(rows == [.header("Disc 1", work: nil), .track(0), .track(1),
                         .header("Disc 2", work: nil), .track(2)])
    }

    @Test func discSubtitleJoinsTheHeader() {
        let tracks = [song("a", disc: 1, track: 1), song("b", disc: 2, track: 1)]
        let rows = TrackTableRow.build(
            tracks: tracks, headers: [2: "Live at Wembley"])
        #expect(rows.contains(.header("Disc 1", work: nil)))
        #expect(rows.contains(.header("Disc 2 · Live at Wembley", work: nil)))
    }

    @Test func singleDiscStaysHeaderless() {
        let tracks = [song("a", disc: 1, track: 1), song("b", disc: 1, track: 2)]
        let rows = TrackTableRow.build(tracks: tracks, headers: [:])
        #expect(rows == [.track(0), .track(1)])
    }

    @Test func missingDiscNumbersCountAsDiscOne() {
        let tracks = [song("a", disc: nil, track: 1), song("b", disc: nil, track: 2)]
        let rows = TrackTableRow.build(tracks: tracks, headers: [:])
        #expect(rows == [.track(0), .track(1)])
    }

    @Test func optOutProducesPlainRows() {
        let tracks = [song("a", disc: 1, track: 1), song("b", disc: 2, track: 1)]
        let rows = TrackTableRow.build(tracks: tracks, headers: nil)
        #expect(rows == [.track(0), .track(1)])
    }

    @Test func multipleWorksUseFlatHeadersWithStableTrackIndices() {
        let tracks = [
            song("a", disc: 1, track: 1, work: "Piano Sonata No. 14"),
            song("b", disc: 1, track: 2, work: "Piano Sonata No. 14"),
            song("c", disc: 1, track: 3, work: "Bagatelle No. 25")
        ]
        let rows = TrackTableRow.build(tracks: tracks, headers: [:])
        #expect(rows == [.header("Piano Sonata No. 14", work: "Piano Sonata No. 14"), .track(0), .track(1),
                         .header("Bagatelle No. 25", work: "Bagatelle No. 25"), .track(2)])
    }

    @Test func multiDiscWorkHeadersFoldInDiscNumber() {
        let tracks = [
            song("a", disc: 1, track: 1, work: "Piano Sonata No. 14"),
            song("b", disc: 1, track: 2, work: "Piano Sonata No. 14"),
            song("c", disc: 2, track: 1, work: "Bagatelle No. 25")
        ]
        let rows = TrackTableRow.build(tracks: tracks, headers: [2: "The Late Works"])
        #expect(rows == [.header("Disc 1 · Piano Sonata No. 14", work: "Piano Sonata No. 14"), .track(0), .track(1),
                         .header("Disc 2 · Bagatelle No. 25", work: "Bagatelle No. 25"), .track(2)])
    }

    @Test func oneWorkKeepsExistingDiscHeaders() {
        let tracks = [
            song("a", disc: 1, track: 1, work: "The Ring"),
            song("b", disc: 2, track: 1, work: "The Ring")
        ]
        let rows = TrackTableRow.build(tracks: tracks, headers: [2: "Götterdämmerung"])
        #expect(rows == [.header("Disc 1", work: nil), .track(0),
                         .header("Disc 2 · Götterdämmerung", work: nil), .track(1)])
    }

    @Test func repeatedWorkGetsAHeaderForEachContiguousRun() {
        let tracks = [
            song("a", disc: 1, track: 1, work: "Work A"),
            song("b", disc: 1, track: 2, work: "Work B"),
            song("c", disc: 1, track: 3, work: "Work A")
        ]
        let rows = TrackTableRow.build(tracks: tracks, headers: [:])
        #expect(rows == [.header("Work A", work: "Work A"), .track(0),
                         .header("Work B", work: "Work B"), .track(1),
                         .header("Work A", work: "Work A"), .track(2)])
    }

    @Test func workMetadataStillHonorsHeaderOptOut() {
        let tracks = [song("a", disc: 1, track: 1, work: "Work A"),
                      song("b", disc: 1, track: 2, work: "Work B")]
        let rows = TrackTableRow.build(tracks: tracks, headers: nil)
        #expect(rows == [.track(0), .track(1)])
    }

    @Test func albumDecodesDiscTitles() throws {
        let json = Data("""
        {"id":"al1","name":"Big Album","discTitles":
            [{"disc":1,"title":"The Slow Side"},{"disc":2,"title":"The Fast Side"},{"disc":3}]}
        """.utf8)
        let album = try SubsonicClient.makeDecoder().decode(Album.self, from: json)
        #expect(album.discSubtitles == [1: "The Slow Side", 2: "The Fast Side"])
    }
}
