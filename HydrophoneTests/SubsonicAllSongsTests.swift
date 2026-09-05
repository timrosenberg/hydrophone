import Foundation
import Testing
@testable import Hydrophone

/// Hermetic coverage for the empty-query `search3` full-library walk.
/// The protocol returns real Subsonic envelopes and records page boundaries,
/// so assertions exercise the client rather than a pagination test double.
@Suite(.serialized)
struct SubsonicAllSongsTests {
    func makeIndex() -> (index: LibrarySongIndex, store: InMemoryCredentialStore) {
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim",
            secret: "sesame",
            authMethod: .tokenSalt
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AllSongsMockProtocol.self]
        let store = InMemoryCredentialStore(credentials)
        let session = URLSession(configuration: configuration)
        let index = LibrarySongIndex(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )
        return (index, store)
    }

    @Test func walksEveryPageToTheFirstShortPageInOffsetOrder() async throws {
        await AllSongsMockProtocol.reset(songCount: 1_003)

        let songs = try await makeIndex().index.allSongs()

        #expect(songs.count == 1_003)
        #expect(songs.first?.id == "song-0")
        #expect(songs.last?.id == "song-1002")
        #expect(Set(songs.map(\.id)).count == 1_003)
        #expect(await AllSongsMockProtocol.requestedOffsets().prefix(3) == [0, 500, 1_000])
    }

    @Test func fetchesPagesAfterTheProbeConcurrently() async throws {
        // The walk now hops from `LibrarySongIndex` to `SubsonicClient` per
        // page (#140/#141) instead of a same-actor call; under heavy
        // full-suite scheduling load that hop can eat into a too-tight
        // artificial delay, so this uses the same margin already proven
        // stable elsewhere in this file (`firstPageDelay: .milliseconds(80)`).
        await AllSongsMockProtocol.reset(songCount: 1_501, responseDelay: .milliseconds(80))

        _ = try await makeIndex().index.allSongs()

        #expect(await AllSongsMockProtocol.maximumConcurrentRequests() > 1)
    }

    @Test func rejectedEmptyQueryFallsBackToTheExistingRandomSample() async throws {
        await AllSongsMockProtocol.reset(
            songCount: 12_000,
            searchBehavior: .reject,
            randomSongCount: 3
        )

        let songs = try await makeIndex().index.allSongs()

        #expect(songs.map(\.id) == ["random-0", "random-1", "random-2"])
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 1)
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/getRandomSongs.view") == 1)
    }

    @Test func emptyQueryOnANonemptyLibraryFallsBackToRandomSongs() async throws {
        await AllSongsMockProtocol.reset(
            songCount: 12_000,
            searchBehavior: .empty,
            randomSongCount: 2
        )

        let songs = try await makeIndex().index.allSongs()

        #expect(songs.map(\.id) == ["random-0", "random-1"])
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 1)
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/getRandomSongs.view") == 1)
    }

    @Test func laterPageFailureFallsBackToTheExistingRandomSample() async throws {
        await AllSongsMockProtocol.reset(
            songCount: 12_000,
            rejectAtOffset: 500,
            randomSongCount: 2
        )

        let songs = try await makeIndex().index.allSongs()

        #expect(songs.map(\.id) == ["random-0", "random-1"])
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/getRandomSongs.view") == 1)
    }

    @Test func repeatedFullPageFallsBackWithoutAnUnboundedWalk() async throws {
        await AllSongsMockProtocol.reset(
            songCount: 12_000,
            searchBehavior: .ignoreOffsets,
            rejectAtOffset: 3_500,
            randomSongCount: 2
        )

        let songs = try await makeIndex().index.allSongs()

        #expect(songs.map(\.id) == ["random-0", "random-1"])
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 7)
    }

    @Test func repeatedCallsReuseTheCredentialBoundCache() async throws {
        await AllSongsMockProtocol.reset(songCount: 3)
        let index = makeIndex().index

        _ = try await index.allSongs()
        _ = try await index.allSongs()

        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 1)
    }

    @Test func concurrentCallsCoalesceOneWalk() async throws {
        await AllSongsMockProtocol.reset(songCount: 3, firstPageDelay: .milliseconds(80))
        let index = makeIndex().index

        async let first = index.allSongs()
        async let second = index.allSongs()
        _ = try await (first, second)

        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 1)
    }

    @Test func changedCredentialsUseANewWalkAndStayConsistentWithinEachWalk() async throws {
        await AllSongsMockProtocol.reset(songCount: 1_003, firstPageDelay: .milliseconds(80))
        let (index, store) = makeIndex()

        let first = Task { try await index.allSongs() }
        while await AllSongsMockProtocol.requestedOffsets().isEmpty { await Task.yield() }
        try store.save(ServerCredentials(
            baseURL: URL(string: "https://second.example.com")!,
            username: "other",
            secret: "different",
            authMethod: .apiKey
        ))
        _ = try await first.value
        _ = try await index.allSongs()

        let hosts = await AllSongsMockProtocol.requestedHosts()
        #expect(hosts.prefix(7).allSatisfy { $0 == "music.example.com" })
        #expect(hosts.last == "second.example.com")
    }

    @Test func explicitInvalidationForcesANewWalk() async throws {
        await AllSongsMockProtocol.reset(songCount: 3)
        let index = makeIndex().index

        _ = try await index.allSongs()
        await index.invalidate()
        _ = try await index.allSongs()

        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 2)
    }

    @Test func invalidatedInFlightWalkCannotRepopulateTheCache() async throws {
        await AllSongsMockProtocol.reset(songCount: 3, firstPageDelay: .milliseconds(80))
        let index = makeIndex().index

        let stale = Task { try await index.allSongs() }
        while await AllSongsMockProtocol.requestedOffsets().isEmpty { await Task.yield() }
        await index.invalidate()
        _ = try await stale.value
        _ = try await index.allSongs()

        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 2)
    }

    @MainActor
    @Test func libraryLoadsTheCompleteWalkAndResetClearsIt() async {
        await AllSongsMockProtocol.reset(songCount: 1_003)
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
        let client = SubsonicClient(credentials: store, session: session)
        let library = LibraryModel(
            client: client,
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )

        await library.loadSongsIfNeeded()

        #expect(library.songs.count == 1_003)
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/getRandomSongs.view") == 0)
        await library.reset()
        #expect(library.songs.isEmpty)
        if case .idle = library.songsState {} else { Issue.record("Expected idle songs state") }
    }

    @MainActor
    @Test func successfulScanInvalidatesClientAndLibrarySnapshots() async throws {
        await AllSongsMockProtocol.reset(songCount: 3)
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
        let client = SubsonicClient(credentials: store, session: session)
        let navidrome = NavidromeClient(credentials: store, session: session)
        let library = LibraryModel(client: client, navidrome: navidrome,
                                   nativeFeaturesAvailable: { false })
        let connection = ConnectionModel(client: client, navidrome: navidrome,
                                         credentials: store)
        connection.setLibraryInvalidationHandler { await library.reset() }
        await library.loadSongsIfNeeded()

        await connection.startLibraryScan()
        _ = try await library.songIndex.allSongs()

        #expect(library.songs.isEmpty)
        #expect(await AllSongsMockProtocol.requestCount(pathSuffix: "/rest/search3.view") == 2)
    }

    @MainActor
    @Test func invalidatedLibraryLoadCannotPublishItsStaleCompletion() async {
        await AllSongsMockProtocol.reset(songCount: 3, firstPageDelay: .milliseconds(80))
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
        let library = LibraryModel(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )

        let stale = Task { await library.loadSongsIfNeeded() }
        while await AllSongsMockProtocol.requestedOffsets().isEmpty { await Task.yield() }
        await library.invalidateSongs()
        await stale.value

        #expect(library.songs.isEmpty)
        if case .idle = library.songsState {} else { Issue.record("Expected idle songs state") }
    }

}

final class AllSongsMockProtocol: URLProtocol, @unchecked Sendable {
    enum SearchBehavior: Sendable, Equatable {
        case supported
        case reject
        case empty
        case ignoreOffsets
    }

    private struct Configuration: Sendable {
        var songCount: Int
        var responseDelay: Duration
        var firstPageDelay: Duration
        var searchBehavior: SearchBehavior
        var rejectAtOffset: Int?
        var randomSongCount: Int
        var rejectRandom: Bool
    }

    private actor State {
        var songCount = 0
        var offsets: [Int] = []
        var responseDelay: Duration = .zero
        var firstPageDelay: Duration = .zero
        var activeRequests = 0
        var maximumActiveRequests = 0
        var searchBehavior: SearchBehavior = .supported
        var randomSongCount = 0
        var rejectRandom = false
        var rejectAtOffset: Int?
        var paths: [String] = []
        var hosts: [String] = []

        func reset(_ configuration: Configuration) {
            songCount = configuration.songCount
            responseDelay = configuration.responseDelay
            firstPageDelay = configuration.firstPageDelay
            searchBehavior = configuration.searchBehavior
            rejectAtOffset = configuration.rejectAtOffset
            randomSongCount = configuration.randomSongCount
            rejectRandom = configuration.rejectRandom
            offsets = []
            activeRequests = 0
            maximumActiveRequests = 0
            paths = []
            hosts = []
        }

        func response(for request: URLRequest) async -> Data {
            let path = request.url?.path ?? ""
            paths.append(path)
            hosts.append(request.url?.host ?? "")
            if path.hasSuffix("/rest/getRandomSongs.view") {
                return randomResponse()
            }
            if path.hasSuffix("/rest/startScan.view") {
                return scanResponse()
            }
            if searchBehavior == .reject {
                return failedResponse(message: "Empty query unsupported")
            }
            if searchBehavior == .empty {
                let body = """
                {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{}}}
                """
                return Data(body.utf8)
            }
            return await searchResponse(for: request)
        }

        private func searchResponse(for request: URLRequest) async -> Data {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let count = query.first { $0.name == "songCount" }?.value.flatMap(Int.init) ?? 0
            let offset = query.first { $0.name == "songOffset" }?.value.flatMap(Int.init) ?? 0
            offsets.append(offset)
            if offset == rejectAtOffset {
                return failedResponse(message: "Page rejected")
            }
            activeRequests += 1
            maximumActiveRequests = max(maximumActiveRequests, activeRequests)
            if offset == 0 {
                try? await Task.sleep(for: firstPageDelay)
            } else {
                try? await Task.sleep(for: responseDelay)
            }
            activeRequests -= 1
            let effectiveOffset = searchBehavior == .ignoreOffsets ? 0 : offset
            let end = min(effectiveOffset + count, songCount)
            let rows = effectiveOffset < end ? (effectiveOffset..<end).map { index in
                #"{"id":"song-\#(index)","title":"Track \#(index)"}"#
            } : []
            let body = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
            "song":[\(rows.joined(separator: ","))]}}}
            """
            return Data(body.utf8)
        }

        private func randomResponse() -> Data {
            if rejectRandom { return failedResponse(message: "Random request rejected") }
            let rows = (0..<randomSongCount).map { index in
                #"{"id":"random-\#(index)","title":"Random \#(index)"}"#
            }
            let body = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","randomSongs":{
            "song":[\(rows.joined(separator: ","))]}}}
            """
            return Data(body.utf8)
        }

        private func scanResponse() -> Data {
            let body = """
            {"subsonic-response":{"status":"ok","version":"1.16.1",
            "scanStatus":{"scanning":true,"count":3}}}
            """
            return Data(body.utf8)
        }

        private func failedResponse(message: String) -> Data {
            let body = """
            {"subsonic-response":{"status":"failed","version":"1.16.1",
            "error":{"code":0,"message":"\(message)"}}}
            """
            return Data(body.utf8)
        }

        func requestCount(pathSuffix: String) -> Int {
            paths.count { $0.hasSuffix(pathSuffix) }
        }
    }

    private static let state = State()

    static func reset(songCount: Int, responseDelay: Duration = .zero,
                      firstPageDelay: Duration = .zero,
                      searchBehavior: SearchBehavior = .supported,
                      rejectAtOffset: Int? = nil,
                      randomSongCount: Int = 0, rejectRandom: Bool = false) async {
        await state.reset(Configuration(
            songCount: songCount,
            responseDelay: responseDelay,
            firstPageDelay: firstPageDelay,
            searchBehavior: searchBehavior,
            rejectAtOffset: rejectAtOffset,
            randomSongCount: randomSongCount,
            rejectRandom: rejectRandom
        ))
    }
    static func requestedOffsets() async -> [Int] { await state.offsets.sorted() }
    static func maximumConcurrentRequests() async -> Int { await state.maximumActiveRequests }
    static func requestedHosts() async -> [String] { await state.hosts }
    static func requestCount(pathSuffix: String) async -> Int {
        await state.requestCount(pathSuffix: pathSuffix)
    }

    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Task { @Sendable [self] in
            let body = await Self.state.response(for: request)
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
