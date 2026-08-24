import Foundation
import Testing
@testable import Hydrophone

/// Hermetic network-level tests for `NavidromeClient.songs(byComposerId:)`
/// and `.workMetadata(songId:)`, both derived from `songIndex()`'s cache —
/// no new network calls beyond what building that cache already costs. An
/// extension of `NavidromeClientNetworkTests` (same pattern as
/// `NavidromeComposerNetworkTests.swift`), kept in its own file to stay under
/// that suite's file/type-length lint budget while still sharing its
/// `.serialized` trait and `NavidromeMockProtocol` state safely. See #25,
/// epic #11.
extension NavidromeClientNetworkTests {
    @Test func songIndexSnapshotBuildsStableIDLookupOnce() {
        let first = NativeSongRecord(id: "duplicate", title: "first", participants: nil, tags: nil)
        let duplicate = NativeSongRecord(id: "duplicate", title: "second", participants: nil, tags: nil)
        let snapshot = NativeSongIndexSnapshot(records: [first, duplicate])

        #expect(snapshot.records.map(\.title) == ["first", "second"])
        #expect(snapshot.record(id: "duplicate")?.title == "first")
    }

    /// A representative `/api/song` page: one Beethoven solo credit, one
    /// Brahms/Clara Schumann joint credit (both composer ids present on the
    /// same song), a song with no composer credit at all, a Schubert song
    /// carrying the confirmed real-library movement fixture (see #25's
    /// issue body), and a song with a work but no numbered movement (a
    /// single-movement work — each tag valid independently).
    private func songLookupFixtureHandler() -> @Sendable (URLRequest) -> NavidromeMockProtocol.Response {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                let jwt = Self.makeSongLookupJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
                let body = #"{"token":"\#(jwt)","subsonicSalt":"s","subsonicToken":"t","username":"tim"}"#
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            }
            let json = """
            [
              {"id": "beethoven-song", "title": "Symphony No. 5",
               "participants": {"composer": [{"id": "c-beethoven", "name": "Ludwig van Beethoven"}]}},
              {"id": "joint-song", "title": "Duet",
               "participants": {"composer": [
                 {"id": "c-brahms", "name": "Johannes Brahms"},
                 {"id": "c-clara", "name": "Clara Schumann"}
               ]}},
              {"id": "no-composer-song", "title": "Untagged Track"},
              {"id": "schubert-song", "title": "Schwanengesang, D. 957: XIII. Der Doppelgänger",
               "tags": {"work": ["Schwanengesang, D. 957"], "movementname": ["Der Doppelgänger"],
                        "movement": ["13"], "movementtotal": ["14"]}},
              {"id": "single-movement-song", "title": "A Single-Movement Work",
               "tags": {"work": ["Some Sonata"], "movementname": ["Some Sonata"]}}
            ]
            """
            let headers = ["Content-Type": "application/json", "X-Total-Count": "5"]
            return .init(status: 200, headers: headers, body: Data(json.utf8))
        }
    }

    private func songLookupClient() -> NavidromeClient {
        NavidromeClient(credentials: InMemoryCredentialStore(songLookupCredentials()), session: makeSongLookupSession())
    }

    private func makeSongLookupSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavidromeMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func songLookupCredentials() -> ServerCredentials {
        ServerCredentials(baseURL: URL(string: "https://music.example.com")!,
                          username: "tim", secret: "sesame", authMethod: .tokenSalt)
    }

    private static func makeSongLookupJWT(exp: TimeInterval) -> String {
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

    @Test func songsByComposerIdIncludesJointCredits() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        let brahmsSongs = try await client.songs(byComposerId: "c-brahms")
        #expect(brahmsSongs.map(\.id) == ["joint-song"])
        let claraSongs = try await client.songs(byComposerId: "c-clara")
        #expect(claraSongs.map(\.id) == ["joint-song"]) // same song, the other joint-credit id
    }

    @Test func songsByComposerIdExcludesNonMatchingAndUncreditedSongs() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        let songs = try await client.songs(byComposerId: "c-beethoven")
        #expect(songs.map(\.id) == ["beethoven-song"])

        let noMatches = try await client.songs(byComposerId: "c-nobody")
        #expect(noMatches.isEmpty)
    }

    @Test func songsByComposerIdDoesNotRefetchTheSongIndex() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        _ = try await client.songIndex()
        _ = try await client.songs(byComposerId: "c-beethoven")

        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 1) // reused the cache built by songIndex(), no extra network call
    }

    @Test func workMetadataParsesMovementAndMovementTotalAsSeparateInts() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        let info = try await client.workMetadata(songId: "schubert-song")
        #expect(info == WorkInfo(
            work: "Schwanengesang, D. 957",
            movementName: "Der Doppelgänger",
            movementNumber: 13,
            movementTotal: 14
        ))
    }

    @Test func workMetadataHandlesWorkWithoutNumberedMovement() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        let info = try await client.workMetadata(songId: "single-movement-song")
        let expected = WorkInfo(work: "Some Sonata", movementName: "Some Sonata",
                                movementNumber: nil, movementTotal: nil)
        #expect(info == expected)
    }

    @Test func workMetadataIsNilForSongWithNoWorkTagsOrUnknownId() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        #expect(try await client.workMetadata(songId: "no-composer-song") == nil) // no tags at all
        #expect(try await client.workMetadata(songId: "does-not-exist") == nil) // not in the index
    }

    @Test func workInfoForSongIdsJoinsMultipleSongsInOneBatch() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        let ids = ["schubert-song", "single-movement-song", "no-composer-song", "does-not-exist"]
        let info = try await client.workInfo(forSongIds: ids)

        #expect(info["schubert-song"] == WorkInfo(
            work: "Schwanengesang, D. 957", movementName: "Der Doppelgänger",
            movementNumber: 13, movementTotal: 14
        ))
        #expect(info["single-movement-song"] == WorkInfo(
            work: "Some Sonata", movementName: "Some Sonata",
            movementNumber: nil, movementTotal: nil
        ))
        // No tags, and not-in-the-index: both simply absent from the result.
        #expect(info["no-composer-song"] == nil)
        #expect(info["does-not-exist"] == nil)
        #expect(info.count == 2)
    }

    @Test func workInfoForSongIdsDoesNotRefetchTheSongIndex() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        _ = try await client.songIndex()
        _ = try await client.workInfo(forSongIds: ["schubert-song", "single-movement-song"])

        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 1) // reused the cache built by songIndex(), no extra network call
    }

    @Test func workInfoForSongIdsIsEmptyForEmptyInput() async throws {
        await NavidromeMockProtocol.reset()
        await NavidromeMockProtocol.setHandler(songLookupFixtureHandler())
        let client = songLookupClient()

        let info = try await client.workInfo(forSongIds: [])
        #expect(info.isEmpty)

        // No network call at all — not even to build the song index.
        let songCallCount = await NavidromeMockProtocol.count(pathSuffix: "/api/song")
        #expect(songCallCount == 0)
    }
}
