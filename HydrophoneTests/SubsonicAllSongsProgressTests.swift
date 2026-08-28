import Foundation
import Testing
@testable import Hydrophone

extension SubsonicAllSongsTests {
    @Test func publishesTheFirstPageBeforeDelayedLaterPagesFinish() async throws {
        await AllSongsMockProtocol.reset(songCount: 1_003, responseDelay: .milliseconds(80))
        let client = makeClient().client
        let recorder = AllSongsProgressRecorder()

        let load = Task {
            try await client.allSongs { songs in
                await recorder.append(songs.count)
            }
        }
        while await recorder.counts.isEmpty { await Task.yield() }

        #expect(await recorder.counts == [500])
        let songs = try await load.value
        #expect(songs.count == 1_003)
        #expect(await recorder.counts == [500, 1_000, 1_003])
    }

    @MainActor
    @Test func libraryPublishesPartialRowsWhileTheWalkRemainsLoading() async {
        await AllSongsMockProtocol.reset(songCount: 1_003, responseDelay: .milliseconds(80))
        let library = makeProgressLibrary()

        let load = Task { await library.loadSongsIfNeeded() }
        while library.songs.isEmpty { await Task.yield() }

        #expect(library.songs.count == 500)
        if case .loading = library.songsState {} else { Issue.record("Expected loading songs state") }
        await load.value
        #expect(library.songs.count == 1_003)
        if case .loaded = library.songsState {} else { Issue.record("Expected loaded songs state") }
    }

    /// A caller watching `onProgress` has already rendered the songs from
    /// offset 0 by the time offset 500 fails. Overwriting that render with
    /// an unrelated random sample (even a fetchable one) would look like
    /// silent data loss, so the walk's own error must propagate instead
    /// (see PR #98 review).
    @Test func laterPageFailureAfterProgressPropagatesInsteadOfFallingBack() async throws {
        await AllSongsMockProtocol.reset(
            songCount: 12_000,
            rejectAtOffset: 500,
            randomSongCount: 2
        )
        let client = makeClient().client

        await #expect(throws: SubsonicError.self) {
            _ = try await client.allSongs { _ in }
        }

        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/getRandomSongs.view") == 0)
    }

    @MainActor
    @Test func failedPartialLoadKeepsPartialRowsInsteadOfARandomSample() async {
        await AllSongsMockProtocol.reset(songCount: 1_003, rejectAtOffset: 500, randomSongCount: 2)
        let library = makeProgressLibrary()
        await library.loadSongsIfNeeded()

        // The walk already rendered 500 real songs before offset 500 failed;
        // the fallback (which would have succeeded, unlike
        // failedPartialLoadCanRetryOnTheNextVisit's rejectRandom case) must
        // not silently replace them with an unrelated random sample.
        #expect(library.songs.count == 500)
        #expect(library.songs.first?.id == "song-0")
        if case .failed = library.songsState {} else { Issue.record("Expected failed songs state") }
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/getRandomSongs.view") == 0)
    }

    @MainActor
    @Test func failedPartialLoadCanRetryOnTheNextVisit() async {
        await AllSongsMockProtocol.reset(songCount: 1_003, rejectAtOffset: 500, rejectRandom: true)
        let library = makeProgressLibrary()
        await library.loadSongsIfNeeded()

        #expect(library.songs.count == 500)
        if case .failed = library.songsState {} else { Issue.record("Expected failed songs state") }

        await AllSongsMockProtocol.reset(songCount: 1_003)
        await library.loadSongsIfNeeded()

        #expect(library.songs.count == 1_003)
        if case .loaded = library.songsState {} else { Issue.record("Retry did not finish loading") }
    }

    @MainActor
    private func makeProgressLibrary() -> LibraryModel {
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim",
            secret: "sesame",
            authMethod: .tokenSalt
        )
        let store = InMemoryCredentialStore(credentials)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AllSongsMockProtocol.self]
        let session = URLSession(configuration: configuration)
        return LibraryModel(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )

    }
}

private actor AllSongsProgressRecorder {
    private(set) var counts: [Int] = []

    func append(_ count: Int) {
        counts.append(count)
    }
}
