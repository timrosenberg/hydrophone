import Testing
import Foundation
@testable import Hydrophone

/// Hermetic coverage for `NavidromeClient`'s auth/pagination plumbing: JWT
/// expiry decoding, request construction, and total-count header parsing.
/// No network — live behavior (login round-trip, real pagination, 401 retry)
/// is covered by `NavidromeLiveTests.swift`. See docs/08-testing.md, #22.
struct NavidromeClientTests {
    // MARK: - JWT expiry decoding

    /// A real JWT shape (header.payload.signature), payload
    /// `{"exp":1787615442,"sub":"demo"}` base64url-encoded, matching what
    /// `POST /auth/login` actually returns (captured 2026-08-22).
    private let sampleJWT = """
    eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
    eyJleHAiOjE3ODc2MTU0NDIsInN1YiI6ImRlbW8ifQ.\
    2YIz7nqbLP2RQK9wgBGMNjNWfa4MnTovQ9jq0JFroaY
    """

    @Test func decodesExpiryFromRealJWTShape() {
        let expiresAt = NavidromeToken.decodeExpiry(fromJWT: sampleJWT)
        #expect(expiresAt == Date(timeIntervalSince1970: 1_787_615_442))
    }

    @Test func decodeExpiryReturnsNilForMalformedToken() {
        #expect(NavidromeToken.decodeExpiry(fromJWT: "not-a-jwt") == nil)   // no "." at all
        #expect(NavidromeToken.decodeExpiry(fromJWT: "") == nil)
        #expect(NavidromeToken.decodeExpiry(fromJWT: "header.garbagepayload.sig") == nil) // not valid base64/JSON
    }

    @Test func tokenWithNoExpiryIsAlwaysExpired() {
        let token = NavidromeToken(raw: "x", expiresAt: nil)
        #expect(token.isExpired())
    }

    @Test func tokenIsExpiredWithinLeewayOfDeadline() {
        let deadline = Date(timeIntervalSince1970: 1000)
        let token = NavidromeToken(raw: "x", expiresAt: deadline)
        #expect(!token.isExpired(asOf: Date(timeIntervalSince1970: 900), leeway: 30))
        #expect(token.isExpired(asOf: Date(timeIntervalSince1970: 975), leeway: 30))  // inside the 30s leeway
        #expect(token.isExpired(asOf: Date(timeIntervalSince1970: 1001), leeway: 30)) // past deadline
    }

    // MARK: - Login response decoding

    @Test func decodesLoginResponse() throws {
        let json = """
        {"id":"u1","isAdmin":false,"name":"Demo User","subsonicSalt":"71524d",
         "subsonicToken":"3b8b4539e1a6e9c4eb315db7de816704","token":"\(sampleJWT)","username":"demo"}
        """
        let decoded = try JSONDecoder().decode(NavidromeLoginResponse.self, from: Data(json.utf8))
        #expect(decoded.token == sampleJWT)
    }

    // MARK: - Request construction

    private func client(authMethod: ServerCredentials.AuthMethod = .tokenSalt) -> NavidromeClient {
        let creds = ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                                      username: "tim", secret: "sesame", authMethod: authMethod)
        return NavidromeClient(credentials: InMemoryCredentialStore(creds))
    }

    @Test func loginRequestTargetsAuthLoginNotAPI() async throws {
        let creds = ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                                      username: "tim", secret: "sesame", authMethod: .tokenSalt)
        let request = try await client().loginRequest(using: creds)
        #expect(request.url?.path == "/auth/login")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(NavidromeLoginRequest.self, from: body)
        #expect(decoded.username == "tim")
        #expect(decoded.password == "sesame")
        #expect(!String(data: body, encoding: .utf8)!.isEmpty)
    }

    @Test func loginThrowsForAPIKeyAuth() async {
        await #expect(throws: NavidromeError.apiKeyAuthUnsupported) {
            try await self.client(authMethod: .apiKey).login()
        }
    }

    @Test func apiRequestAttachesBearerTokenAndQueryItems() async throws {
        let creds = ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                                      username: "tim", secret: "sesame", authMethod: .tokenSalt)
        let token = NavidromeToken(raw: "abc123", expiresAt: nil)
        let query = [URLQueryItem(name: "_start", value: "0"), URLQueryItem(name: "role", value: "composer")]
        let request = try await client().apiRequest(path: "artist", query: query, token: token, using: creds)
        #expect(request.url?.path == "/api/artist")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Nd-Authorization") == "Bearer abc123")
        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? [])
                .map { ($0.name, $0.value) })
        #expect(items["_start"] == "0")
        #expect(items["role"] == "composer")
        #expect(!request.url!.absoluteString.contains("sesame")) // secret never leaks into an authed request
    }

    @Test func authPathStripsTrailingSlash() {
        #expect(NavidromeClient.authPath(basePath: "") == "/auth/login")
        #expect(NavidromeClient.authPath(basePath: "/") == "/auth/login")
    }

    @Test func apiPathStripsTrailingSlash() {
        #expect(NavidromeClient.apiPath(basePath: "", resource: "song") == "/api/song")
        #expect(NavidromeClient.apiPath(basePath: "/", resource: "song") == "/api/song")
    }

    // MARK: - NativeSongRecord decoding

    /// Representative of a real `/api/song` page entry (captured shape,
    /// trimmed to the fields `NativeSongRecord` cares about): participants
    /// and work/movement tags both populated. See #24.
    @Test func decodesNativeSongRecordWithParticipantsAndTags() throws {
        let json = """
        {
          "id": "abc123",
          "title": "Symphony No. 5 in C minor, Op. 67: I. Allegro con brio",
          "participants": {
            "composer": [{"id": "c1", "name": "Ludwig van Beethoven"}],
            "artist": [{"id": "a1", "name": "Berlin Philharmonic"}],
            "albumartist": [{"id": "a1", "name": "Berlin Philharmonic"}]
          },
          "tags": {
            "work": ["Symphony No. 5 in C minor, Op. 67"],
            "movementname": ["Allegro con brio"],
            "movement": ["1"],
            "movementtotal": ["4"],
            "genre": ["Classical"]
          }
        }
        """
        let record = try JSONDecoder().decode(NativeSongRecord.self, from: Data(json.utf8))
        #expect(record.id == "abc123")
        #expect(record.title == "Symphony No. 5 in C minor, Op. 67: I. Allegro con brio")
        #expect(record.participants?.composer?.first?.name == "Ludwig van Beethoven")
        #expect(record.participants?.artist?.first?.id == "a1")
        #expect(record.tags?["work"] == ["Symphony No. 5 in C minor, Op. 67"])
        #expect(record.tags?["movementname"] == ["Allegro con brio"])
    }

    /// A missing key isn't a decode error — most songs have no work/movement
    /// tags or unusual participant roles, and the decode must tolerate that.
    @Test func decodesNativeSongRecordWithMissingParticipantsAndTags() throws {
        let json = #"{"id": "xyz789", "title": "Ordinary Track"}"#
        let record = try JSONDecoder().decode(NativeSongRecord.self, from: Data(json.utf8))
        #expect(record.id == "xyz789")
        #expect(record.participants == nil)
        #expect(record.tags == nil)
    }
}
