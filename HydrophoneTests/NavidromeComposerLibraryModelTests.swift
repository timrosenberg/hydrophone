import Foundation
import Testing
@testable import Hydrophone

extension NavidromeClientNetworkTests {
    @MainActor
    @Test func libraryModelLoadsComposersOnceAndCachesSuccessfulRoster() async {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeLibraryComposerHandler())
        let library = Self.makeComposerLibrary()

        await library.loadComposersIfNeeded()
        await library.loadComposersIfNeeded()

        #expect(library.composers.map(\.id) == ["bach", "mozart"])
        #expect(library.composers.map(\.name) == ["Johann Sebastian Bach", "Wolfgang Amadeus Mozart"])
        #expect(library.composers.map(\.songCount) == [24, 18])
        if case .loaded = library.composersState {
            // Expected state after the successful fetch.
        } else {
            Issue.record("Expected composersState to be loaded")
        }
        #expect(await NavidromeMockProtocol.count(pathSuffix: "/api/artist") == 1)
    }

    @MainActor
    @Test func libraryModelResetClearsComposerRosterAndLoadState() async {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(Self.makeLibraryComposerHandler())
        let library = Self.makeComposerLibrary()
        await library.loadComposersIfNeeded()

        await library.reset()

        #expect(library.composers.isEmpty)
        if case .idle = library.composersState {
            // Expected state after changing or disconnecting from a server.
        } else {
            Issue.record("Expected composersState to return to idle")
        }
    }

    @MainActor
    private static func makeComposerLibrary() -> LibraryModel {
        let credentials = ServerCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "tim",
            secret: "sesame",
            authMethod: .tokenSalt
        )
        let store = InMemoryCredentialStore(credentials)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavidromeMockProtocol.self]
        let session = URLSession(configuration: configuration)
        return LibraryModel(
            client: SubsonicClient(credentials: store, session: session),
            navidrome: NavidromeClient(credentials: store, session: session),
            nativeFeaturesAvailable: { true }
        )
    }

    private static func makeLibraryComposerHandler()
        -> @Sendable (URLRequest) async -> NavidromeMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let token = Self.makeLibraryComposerJWT()
                let body = #"{"token":"\#(token)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
            if path.hasSuffix("/api/artist") {
                let body = """
                    [{"id":"mozart","name":"Wolfgang Amadeus Mozart","stats":{"composer":{"songCount":18}}},
                     {"id":"bach","name":"Johann Sebastian Bach","stats":{"composer":{"songCount":24}}}]
                    """
                return .init(
                    status: 200,
                    headers: ["Content-Type": "application/json", "X-Total-Count": "2"],
                    body: Data(body.utf8)
                )
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    private static func makeLibraryComposerJWT() -> String {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(#"{"alg":"HS256","typ":"JWT"}"#)
        let expiration = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let payload = segment(#"{"exp":\#(expiration)}"#)
        return "\(header).\(payload).signature"
    }
}
