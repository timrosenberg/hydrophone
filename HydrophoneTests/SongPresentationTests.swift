import Testing
@testable import Hydrophone

@MainActor
@Suite(.serialized)
struct SongPresentationTests {
    @Test func publicationRevisesMetadataButNotIdenticalValues() {
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        let library = fixture.library
        let songs = [Song(id: "one", title: "First", artist: "Artist")]
        library.songs = songs
        let initial = library.songPresentation
        library.songs = songs
        #expect(library.songPresentation === initial)
        library.songs[0].title = "Changed without changing ID"
        #expect(library.songPresentation !== initial)
        #expect(library.songPresentation.songs[0].title == "Changed without changing ID")
        #expect(initial.songs[0].title == "First")
    }

    @Test func sessionResetRetiresPreparedResults() async {
        let fixture = BrowserLibraryFixture()
        defer { fixture.close() }
        fixture.library.songs = [Song(id: "one", title: "First")]
        let old = fixture.library.songPresentation
        let browser = fixture.library.songBrowserPresentation
        await fixture.library.reset()
        #expect(fixture.library.songPresentation !== old)
        #expect(fixture.library.songPresentation.songs.isEmpty)
        #expect(fixture.library.songBrowserPresentation !== browser)
        fixture.library.songs = old.songs
        #expect(fixture.library.songPresentation !== old)
    }

    @Test func anotherCollectionCannotEvictASortAndSortChangesRemainDistinct() {
        let songs = [Song(id: "b", title: "B"), Song(id: "a", title: "A")]
        let presentation = SongPresentation(songs)
        let other = SongPresentation([Song(id: "c", title: "C")])
        var computations = 0
        func titleSort() -> [Song] { computations += 1; return songs.reversed() }
        #expect(presentation.sorted(key: "title", ascending: true, compute: titleSort).first?.id == "a")
        _ = other.sorted(key: "title", ascending: true) { other.songs }
        #expect(presentation.sorted(key: "title", ascending: true, compute: titleSort).first?.id == "a")
        #expect(computations == 1)
        #expect(presentation.sorted(key: "title", ascending: false) { songs }.first?.id == "b")
        #expect(presentation.sorted(key: "artist", ascending: true) { songs }.first?.id == "b")
        #expect(presentation.sorted(key: "title", ascending: true, compute: titleSort).first?.id == "a")
        #expect(computations == 1)
    }

    @Test func browserReusesUnchangedProjectionAndTracksSelectionDependencies() {
        let base = SongPresentation([
            Song(id: "a", title: "A", artist: "One", album: "Album One", displayComposer: "Composer One"),
            Song(id: "b", title: "B", artist: "Two", album: "Album Two", displayComposer: "Composer Two")
        ])
        let browser = SongBrowserPresentation()
        let all = browser.resolve(base: base, artist: nil, album: nil, composer: nil)
        #expect(all.tracks === base)
        let selected = browser.resolve(base: base, artist: "Two", album: nil, composer: nil)
        #expect(selected.artists == all.artists)
        #expect(selected.albums == ["Album Two"])
        #expect(selected.composers == ["Composer Two"])
        #expect(selected.tracks.songs.map(\.id) == ["b"])
        let repeatVisit = browser.resolve(base: base, artist: "Two", album: nil, composer: nil)
        #expect(repeatVisit.tracks === selected.tracks)
        let narrowed = browser.resolve(base: base, artist: "Two", album: "Album Two", composer: "missing")
        #expect(narrowed.artists == selected.artists)
        #expect(narrowed.albums == selected.albums)
        #expect(narrowed.composers == selected.composers)
        #expect(narrowed.tracks.songs.isEmpty)
        let replaced = browser.resolve(base: SongPresentation([]), artist: nil, album: nil, composer: nil)
        #expect(replaced.artists.isEmpty && replaced.albums.isEmpty && replaced.composers.isEmpty)
        #expect(replaced.tracks.songs.isEmpty)
    }
}
