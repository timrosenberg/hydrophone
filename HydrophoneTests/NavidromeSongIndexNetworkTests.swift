import Foundation
import Testing
@testable import Hydrophone

// Shares the suite's serialized trait and mock protocol without growing its main file.
extension NavidromeClientNetworkTests {
    @Test func songIndexExcludesMissingFilesOnEveryPageAndRetry() async throws {
        await NavidromeMockProtocol.reset()
        let requests = SongIndexRequests()
        await NavidromeMockProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/auth/login") == true {
                return Self.makeHandler(jwtExpiresIn: 3600)(request)
            }
            let attempt = await requests.record(request)
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let start = query.first { $0.name == "_start" }.flatMap { $0.value }.flatMap(Int.init) ?? 0
            if start == 500, attempt == 1 {
                return .init(status: 401, headers: [:], body: Data())
            }
            let rows = (start..<min(start + 500, 1001)).map { #"{"id":"s\#($0)"}"# }
            return .init(
                status: 200, headers: ["Content-Type": "application/json", "X-Total-Count": "1001"],
                body: Data("[\(rows.joined(separator: ","))]".utf8)
            )
        }
        let client = NavidromeClient(credentials: InMemoryCredentialStore(creds()), session: makeSession())

        let index = try await client.songIndex()

        #expect(index.count == 1001)
        #expect(index.first?.id == "s0")
        #expect(index.last?.id == "s1000")
        let urls = await requests.urls
        #expect(urls.count == 4)
        for url in urls {
            #expect(url.path == "/api/song")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.filter { $0.name == "missing" } == [URLQueryItem(name: "missing", value: "false")])
        }
        let ranges = urls.map { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = query.first { $0.name == "_start" }?.value ?? ""
            let end = query.first { $0.name == "_end" }?.value ?? ""
            return "\(start):\(end)"
        }
        #expect(ranges.sorted() == ["0:500", "1000:1500", "500:1000", "500:1000"])
    }
}

private actor SongIndexRequests {
    var urls: [URL] = []

    func record(_ request: URLRequest) -> Int {
        guard let url = request.url else { return 0 }
        urls.append(url)
        return urls.filter { $0 == url }.count
    }
}
