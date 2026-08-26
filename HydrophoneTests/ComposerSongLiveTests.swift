import Foundation
import Testing
@testable import Hydrophone

/// Opt in explicitly: requires a classical library containing Bach and
/// Beethoven, not an arbitrary demo server. No credentials or track ids logged.
@MainActor
struct ComposerSongLiveTests {
    @Test func largeComposersMapWithoutPerTrackRequests() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HYDROPHONE_COMPOSER_LIVE"] == "1",
              let host = env["HYDROPHONE_HOST"], let url = URL(string: host),
              let user = env["HYDROPHONE_USER"], let pass = env["HYDROPHONE_PASS"] else { return }
        let store = InMemoryCredentialStore(ServerCredentials(
            baseURL: url, username: user, secret: pass, authMethod: .tokenSalt
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComposerLiveProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SubsonicClient(credentials: store, session: session)
        let native = NavidromeClient(credentials: store, session: session)
        let library = LibraryModel(client: client, navidrome: native, nativeFeaturesAvailable: { true })
        let roster = try await native.composers()
        for name in ["Johann Sebastian Bach", "Ludwig van Beethoven"] {
            let composer = try #require(roster.first { $0.name == name })
            await ComposerLiveProtocol.resetCount()
            let start = Date()
            let songs = await library.songs(forComposer: composer.id)
            let count = await ComposerLiveProtocol.songRequests()
            print("Composer live: \(name), \(songs.count) songs, getSong=\(count), "
                  + "\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
            try #require(songs.count >= 500)
            #expect(count == 0)
            #expect(Set(songs.map(\.id)).count == songs.count)
            let cached = await library.songs(forComposer: composer.id)
            print("Composer live cached: \(name), elapsed including first load "
                  + "\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
            let cachedRowsMatch = cached == songs
            #expect(cachedRowsMatch, "Cached composer rows must match the first resolution")
            #expect(await ComposerLiveProtocol.songRequests() == 0)

            // Independent reference requests are verification-only, after the
            // zero-request assertion. Compare rows from throughout each list.
            for index in [0, songs.count / 2, songs.count - 1] {
                let song = songs[index]
                let reference = try await client.object(.song(id: song.id), as: Song.self)
                let differences = Self.metadataDifferences(song, reference)
                if differences.contains("format") {
                    print("Format parity: suffix=\(song.suffix ?? "nil"), "
                          + "mapped=\(song.contentType ?? "nil"), reference=\(reference.contentType ?? "nil")")
                }
                #expect(differences.isEmpty, "Mapped metadata differs: \(differences)")
                let artURL = try await client.coverArtURL(id: try #require(song.coverArt), size: 160)
                let (art, response) = try await URLSession.shared.data(from: artURL)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(!art.isEmpty)
                let referenceURL = try await client.coverArtURL(id: try #require(reference.coverArt), size: 160)
                let (referenceArt, _) = try await URLSession.shared.data(from: referenceURL)
                let artworkMatches = art == referenceArt
                #expect(artworkMatches, "Mapped coverArt must fetch the reference image, not an HTTP-200 placeholder")
            }
        }
    }

    private static func metadataDifferences(_ song: Song, _ reference: Song) -> [String] {
        let checks: [(String, Bool)] = [
            ("title", song.title == reference.title), ("artist", song.artist == reference.artist),
            ("artistId", song.artistId == reference.artistId), ("album", song.album == reference.album),
            ("albumId", song.albumId == reference.albumId), ("duration", song.duration == reference.duration),
            ("track", song.track == reference.track), ("disc", song.discNumber == reference.discNumber),
            ("year", song.year == reference.year), ("genre", song.displayGenre == reference.displayGenre),
            ("quality", song.qualityLabel == reference.qualityLabel), ("bitRate", song.bitRate == reference.bitRate),
            ("format", song.contentType == reference.contentType), ("size", song.size == reference.size),
            ("composer", song.nonEmptyDisplayComposer == reference.nonEmptyDisplayComposer),
            ("albumArtist", song.displayAlbumArtist == reference.displayAlbumArtist),
            ("comment", (song.comment ?? "") == (reference.comment ?? "")),
            ("groupings", (song.groupings ?? []) == (reference.groupings ?? [])),
            ("sampleRate", song.samplingRate == reference.samplingRate),
            ("sort", song.sortName == reference.sortName), ("created", song.created == reference.created),
            ("played", song.played == reference.played), ("plays", song.playCount == reference.playCount),
            ("favorite", song.isStarred == reference.isStarred),
            ("replayGain", (song.replayGain ?? ReplayGainInfo()) == (reference.replayGain ?? ReplayGainInfo()))
        ]
        return checks.compactMap { $0.1 ? nil : $0.0 }
    }
}

/// Forwards real traffic through a separate session, counting only endpoint
/// paths. No authenticated URLs, request headers, or payloads are recorded.
private final class ComposerLiveProtocol: URLProtocol, @unchecked Sendable {
    private actor Counter {
        var count = 0
        func record(_ request: URLRequest) {
            if request.url?.path.hasSuffix("/rest/getSong.view") == true { count += 1 }
        }
        func reset() { count = 0 }
    }
    private static let counter = Counter()
    static func resetCount() async { await counter.reset() }
    static func songRequests() async -> Int { await counter.count }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Task { @Sendable [self] in
            await Self.counter.record(request)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                // Redact the underlying URL-bearing error in test output.
                client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            }
        }
    }
    override func stopLoading() {}
}
