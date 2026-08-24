import AppKit
import Foundation
import Observation

/// Top-level composition root. Owns the long-lived services and the observable
/// view models, and wires them together. Injected into the environment by
/// `HydrophoneApp`. See docs/01-architecture.md.
@MainActor
@Observable
final class AppModel {
    /// Now-playing source of truth (track, queue, position, transport state).
    let player: PlayerModel

    /// Library browsing state (albums/artists/songs/genres/favorites).
    let library: LibraryModel

    /// Server connection + authentication state.
    let connection: ConnectionModel

    /// Bumped by File → New Playlist (⌘N); the sidebar observes it and opens
    /// its New Playlist prompt (a counter so repeat requests always fire).
    private(set) var newPlaylistRequests = 0

    func requestNewPlaylist() {
        newPlaylistRequests += 1
    }

    /// Bumped by Controls → Show Album in Library (⇧⌘L) and the panel's
    /// album line; RootView resolves the current track's album and opens it.
    private(set) var showCurrentAlbumRequests = 0

    func requestShowCurrentAlbum() {
        showCurrentAlbumRequests += 1
    }

    /// Controls → Shuffle Library and the Songs header: play a big random
    /// sample of the whole library. Subsonic has no all-songs endpoint, so
    /// 500 random songs (~a full day of music) stands in — the server already
    /// randomizes, so the batch plays as returned.
    func shuffleLibrary() {
        guard !isPreparingMix else { return }
        isPreparingMix = true
        Task {
            defer { isPreparingMix = false }
            let batch = await library.randomBatch()
            guard !batch.isEmpty else { return }
            player.play(tracks: batch)
        }
    }

    /// True while a radio mix or album shuffle is being assembled (the
    /// fetches take a beat — similar songs, then per-album tracks). Entry
    /// points disable on it, and the methods below bail re-entrantly, so an
    /// impatient second click can't stack a second station on the first.
    private(set) var isPreparingMix = false

    /// Start Radio from a song: the seed plays first, followed by the
    /// server's similar-songs mix (sonicSimilarity-backed on newer
    /// Navidrome). Falls back to the artist's mix when the song itself has
    /// no similarity data. Shuffle is switched off — a station's order is
    /// the point, and shuffling would bury the seed.
    func startRadio(from song: Song) {
        guard !isPreparingMix else { return }
        isPreparingMix = true
        Task {
            defer { isPreparingMix = false }
            var mix = await library.similarSongs(id: song.id)
            if mix.isEmpty, let artistId = song.artistId {
                mix = await library.similarSongs(id: artistId)
            }
            if mix.isEmpty, let artistId = song.artistId {
                mix = await artistShuffle(artistId: artistId)
            }
            mix.removeAll { $0.id == song.id }
            player.shuffle = false
            player.play(tracks: [song] + mix)
        }
    }

    /// Artist radio: a similar-songs mix seeded by the artist, falling back
    /// to the server's top songs, then to a shuffle of the artist's own
    /// tracks — so the button always plays something, even on servers
    /// without a metadata agent (e.g. the demo server).
    func startRadio(from artist: Artist) {
        guard !isPreparingMix else { return }
        isPreparingMix = true
        Task {
            defer { isPreparingMix = false }
            var mix = await library.similarSongs(id: artist.id)
            if mix.isEmpty { mix = await library.topSongs(artist: artist.name) }
            if mix.isEmpty { mix = await artistShuffle(artistId: artist.id) }
            guard !mix.isEmpty else { return }
            player.shuffle = false
            player.play(tracks: mix)
        }
    }

    /// Last-resort radio source: the artist's own tracks, shuffled (capped
    /// at 10 albums to bound the fetch fan-out).
    private func artistShuffle(artistId: String) async -> [Song] {
        let albums = await library.albums(forArtist: artistId).shuffled().prefix(10)
        var tracks: [Song] = []
        for album in albums { tracks += await library.songs(forAlbum: album.id) }
        return tracks.shuffled()
    }

    /// Controls → Shuffle Albums and the Albums-grid shuffle: whole albums
    /// back-to-back in random order (the gapless-friendly shuffle), honoring
    /// the grid's genre/decade filter. Shuffle mode is switched off so the
    /// albums play through intact.
    func shuffleAlbums() {
        guard !isPreparingMix else { return }
        isPreparingMix = true
        Task {
            defer { isPreparingMix = false }
            let albums = await library.randomAlbums()
            var tracks: [Song] = []
            for album in albums { tracks += await library.songs(forAlbum: album.id) }
            guard !tracks.isEmpty else { return }
            player.shuffle = false
            player.play(tracks: tracks)
        }
    }

    // Services (not observed directly by views).
    let credentials: CredentialStore
    let client: SubsonicClient
    let playback: PlaybackService
    let nowPlaying: NowPlayingCenter

    init() {
        let credentials = Self.makeCredentialStore()
        let client = SubsonicClient(credentials: credentials)
        // Native Navidrome feature detection (#26). `LibraryModel` also holds
        // a reference (#45, epic #13) to join work/movement metadata onto
        // fetched songs; local `connection` (not `self.connection`) is
        // captured below so the closure doesn't need `self` before this
        // init finishes assigning every stored property.
        let navidrome = NavidromeClient(credentials: credentials)
        let playback = PlaybackService(client: client)
        let nowPlaying = NowPlayingCenter()
        let connection = ConnectionModel(client: client, navidrome: navidrome, credentials: credentials)

        self.credentials = credentials
        self.client = client
        self.playback = playback
        self.nowPlaying = nowPlaying
        self.connection = connection
        self.library = LibraryModel(client: client, navidrome: navidrome,
                                    nativeFeaturesAvailable: { connection.nativeFeaturesState == .available })
        self.player = PlayerModel(playback: playback, nowPlaying: nowPlaying,
                                  scrobbler: { id, submission in
            // Best-effort: a failed scrobble should never surface in the UI.
            _ = try? await client.sendStatus(.scrobble(id: id, submission: submission))
        },
                                  queueStore: { snapshot in
            // Best-effort, like scrobbles: a failed save never surfaces.
            _ = try? await client.sendStatus(.savePlayQueue(
                ids: snapshot.songIds, current: snapshot.currentId,
                positionMs: snapshot.positionMs))
        })

        // Give the shared artwork cache access to the authenticated client, and
        // scope it to the current server so artwork never mixes across servers.
        ArtworkCache.shared.clientBox = ClientBox(client)
        ArtworkCache.shared.setServer(baseURL: credentials.load()?.baseURL)

        // Bring back the last session's queue (paused; never interrupts).
        Task { await restorePlayQueue() }
        // Final snapshot on quit — best-effort (pause/track-change saves are
        // the reliable ones; this catches the played-through-then-quit case).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated { player?.saveQueueIfNeeded(force: true) }
        }
    }

    /// Screenshot/dev harness (Debug builds only): when
    /// `HYDROPHONE_SCREENSHOT_SERVER/_USER/_PASS` are set in the environment,
    /// credentials live in an ephemeral in-memory store instead of the
    /// Keychain, so a run against a throwaway server can never disturb the
    /// real primary-server item. See docs/08-testing.md.
    private static func makeCredentialStore() -> CredentialStore {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // Fresh-start variant: empty in-memory store, so a demo recording can
        // walk the real onboarding/connect flow against a throwaway server.
        if env["HYDROPHONE_SCREENSHOT_FRESH"] == "1" {
            return InMemoryCredentialStore()
        }
        if let server = env["HYDROPHONE_SCREENSHOT_SERVER"],
           let url = URL(string: server),
           let user = env["HYDROPHONE_SCREENSHOT_USER"],
           let pass = env["HYDROPHONE_SCREENSHOT_PASS"] {
            return InMemoryCredentialStore(ServerCredentials(
                baseURL: url, username: user, secret: pass, authMethod: .tokenSalt))
        }
        #endif
        return KeychainCredentialStore()
    }

    /// Fetch the server-saved play queue and hand it to the player, restored
    /// paused at the saved playhead. Silently does nothing when no server is
    /// configured, the server has no saved queue, or playback already started.
    private func restorePlayQueue() async {
        guard await client.isConfigured,
              let saved = try? await client.object(.playQueue, as: PlayQueue.self),
              let entries = saved.entry, !entries.isEmpty else { return }
        let index = saved.current
            .flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
        let position = TimeInterval(saved.position ?? 0) / 1000
        player.restoreQueue(entries, currentIndex: index, position: position)
    }
}
