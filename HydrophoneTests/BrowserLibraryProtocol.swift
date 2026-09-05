import Foundation
@testable import Hydrophone

final class BrowserLibraryProtocol: URLProtocol, @unchecked Sendable {
    actor State {
        var classicalRequests = 0
        var firstGenreDelivered = false
        var searchRequests = 0
        var firstSearchResumed = false
        private var holdFirstSearch = false
        private var firstSearch: CheckedContinuation<Void, Never>?
        private var holdFirstGenre = false
        private var firstGenre: CheckedContinuation<Void, Never>?

        func reset(holdFirstGenre: Bool = false, holdFirstSearch: Bool = false) {
            firstGenre?.resume()
            firstGenre = nil
            classicalRequests = 0
            firstGenreDelivered = false
            self.holdFirstGenre = holdFirstGenre
            firstSearch?.resume()
            firstSearch = nil
            searchRequests = 0
            firstSearchResumed = false
            self.holdFirstSearch = holdFirstSearch
        }

        func releaseFirstSearch() { firstSearch?.resume(); firstSearch = nil }

        func releaseFirstGenre() {
            firstGenre?.resume()
            firstGenre = nil
        }

        func markFirstGenreDelivered() { firstGenreDelivered = true }

        func response(_ request: URLRequest) async throws -> (Data, Bool) {
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
            let offset = Int(value("offset")) ?? Int(value("songOffset")) ?? 0
            let count = Int(value("count")) ?? Int(value("songCount")) ?? 500
            var firstHeld = false
            let payload: [String: Any]
            switch url.lastPathComponent {
            case "getGenres.view":
                payload = ["genres": ["genre": [
                    ["value": "Classical", "songCount": 1_003, "albumCount": 2],
                    ["value": "Jazz", "songCount": 1, "albumCount": 1]
                ]]]
            case "search3.view":
                searchRequests += 1
                if holdFirstSearch, searchRequests == 1 {
                    await withCheckedContinuation { firstSearch = $0 }
                    firstSearchResumed = true
                }
                payload = ["searchResult3": ["song": Self.page(offset: offset, count: count)]]
            case "getSongsByGenre.view":
                if value("genre") == "Jazz" {
                    payload = ["songsByGenre": ["song": [["id": "jazz", "title": "Jazz"]]]]
                } else if holdFirstGenre {
                    classicalRequests += 1
                    firstHeld = classicalRequests == 1
                    if firstHeld { await withCheckedContinuation { firstGenre = $0 } }
                    let rows = firstHeld ? [["id": "old", "title": "Old"]] : [
                        ["id": "new-0", "title": "New 0"], ["id": "new-1", "title": "New 1"]
                    ]
                    payload = ["songsByGenre": ["song": rows]]
                } else {
                    payload = ["songsByGenre": ["song": Self.page(offset: offset, count: count)]]
                }
            default:
                payload = [:]
            }
            var envelope = payload
            envelope["status"] = "ok"
            envelope["version"] = "1.16.1"
            return (try JSONSerialization.data(withJSONObject: ["subsonic-response": envelope]), firstHeld)
        }

        private static func page(offset: Int, count: Int) -> [[String: Any]] {
            let end = min(offset + count, 1_003)
            guard offset < end else { return [] }
            return (offset..<end).map { index in
                let prefix = index < 500 ? "Sample" : "Late"
                return ["id": "song-\(index)", "title": String(format: "Track %04d", index),
                        "artist": "\(prefix) Artist", "album": "\(prefix) Album",
                        "displayComposer": "\(prefix) Composer", "genre": "Classical"]
            }
        }
    }

    static let state = State()

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task { @Sendable [self] in
            do {
                let (body, firstHeld) = try await Self.state.response(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
                if firstHeld { await Self.state.markFirstGenreDelivered() }
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
