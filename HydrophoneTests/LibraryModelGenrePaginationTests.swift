import Foundation
import Testing
@testable import Hydrophone

/// Hermetic coverage for the Column Browser's genre-song walk. The protocol
/// stub returns real Subsonic envelopes while recording the requested page
/// boundaries, so these tests exercise `LibraryModel` and `SubsonicClient`
/// together without reaching a server.
@MainActor
@Suite(.serialized)
struct LibraryModelGenrePaginationTests {
    private func makeLibrary() -> LibraryModel {
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim",
            secret: "sesame",
            authMethod: .tokenSalt
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenrePaginationMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = InMemoryCredentialStore(credentials)
        return LibraryModel(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { false }
        )
    }

    @Test func walksEveryFullPageUntilTheShortFinalPage() async {
        await GenrePaginationMockProtocol.reset(songCount: 1_003)

        let songs = await makeLibrary().songs(forGenre: "Classical")

        #expect(songs.count == 1_003)
        #expect(songs.first?.id == "song-0")
        #expect(songs.last?.id == "song-1002")
        #expect(await GenrePaginationMockProtocol.pageRequests() == [
            .init(count: 500, offset: 0),
            .init(count: 500, offset: 500),
            .init(count: 500, offset: 1_000)
        ])
    }

    @Test func aShortFirstPageCostsOneRequest() async {
        await GenrePaginationMockProtocol.reset(songCount: 2)

        let songs = await makeLibrary().songs(forGenre: "Chamber")

        #expect(songs.map(\.id) == ["song-0", "song-1"])
        #expect(await GenrePaginationMockProtocol.pageRequests() == [
            .init(count: 500, offset: 0)
        ])
    }
}

private final class GenrePaginationMockProtocol: URLProtocol, @unchecked Sendable {
    struct PageRequest: Equatable, Sendable {
        let count: Int
        let offset: Int
    }

    private actor State {
        var songCount = 0
        var requests: [PageRequest] = []

        func reset(songCount: Int) {
            self.songCount = songCount
            requests = []
        }

        func response(for request: URLRequest) -> (PageRequest, Data) {
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let count = queryItems.first { $0.name == "count" }?.value.flatMap(Int.init) ?? 0
            let offset = queryItems.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            let pageRequest = PageRequest(count: count, offset: offset)
            requests.append(pageRequest)

            let end = min(offset + count, songCount)
            let rows = offset < end ? (offset..<end).map { index in
                #"{"id":"song-\#(index)","title":"Track \#(index)"}"#
            } : []
            let body = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","songsByGenre":{
            "song":[\(rows.joined(separator: ","))]}}}
            """
            return (pageRequest, Data(body.utf8))
        }
    }

    private static let state = State()

    static func reset(songCount: Int) async {
        await state.reset(songCount: songCount)
    }

    static func pageRequests() async -> [PageRequest] {
        await state.requests
    }

    // Overriding URLProtocol's required `class func`s, not new declarations.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Task { @Sendable [self] in
            let (_, body) = await Self.state.response(for: request)
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
