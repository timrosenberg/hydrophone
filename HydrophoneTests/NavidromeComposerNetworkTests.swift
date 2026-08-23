import Foundation
import Testing
@testable import Hydrophone

extension NavidromeClientNetworkTests {
    /// Navidrome's database collation can put an accented spelling before
    /// its otherwise-identical unaccented spelling. `composers()` promises
    /// the macOS-localized order consumed by the UI, independent of that
    /// server-side collation.
    @Test func composersSortsServerRosterWithLocalizedStandardOrder() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeComposerJWT(
                    exp: Date().addingTimeInterval(3600).timeIntervalSince1970
                )
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
            let body = #"[{"id":"accented","name":"André Caplet"},{"id":"plain","name":"Andre Caplet"}]"#
            let headers = ["Content-Type": "application/json", "X-Total-Count": "2"]
            return .init(status: 200, headers: headers, body: Data(body.utf8))
        }
        let client = NavidromeClient(
            credentials: InMemoryCredentialStore(composerCredentials()),
            session: makeComposerSession()
        )

        let names = try await client.composers().map(\.name)

        #expect(names == ["Andre Caplet", "André Caplet"])
    }

    private func makeComposerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavidromeMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func composerCredentials() -> ServerCredentials {
        ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim",
            secret: "sesame",
            authMethod: .tokenSalt
        )
    }

    private static func makeComposerJWT(exp: TimeInterval) -> String {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = segment(#"{"exp":\#(Int(exp))}"#)
        return "\(header).\(payload).signature"
    }
}
