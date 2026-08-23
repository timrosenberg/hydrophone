# 01 — App Architecture

## Goals

- One unambiguous source of truth for playback state, observed by every view,
  the `MenuBarExtra` panel, and the system Now Playing center.
- A service layer that keeps `AVAudioEngine` and `URLSession` out of views, so
  queue/gapless logic is testable and the audio backend is swappable.
- Swift 6 strict concurrency by construction: `@MainActor` UI/state,
  `actor`-isolated services, `Sendable` value-type models.
- Small memory footprint: lazy data, streamed audio, aggressively released
  buffers and artwork.

## Layered design

```
┌─────────────────────────────────────────────────────────────┐
│  UI  (SwiftUI views, @MainActor)                             │
│  RootView · SidebarView · HomeView ·                         │
│  TrackTableView/MusicTrackTable ·                            │
│  ColumnBrowserView · NowPlayingToolbar · NowPlayingPanel ·   │
│  MenuBarPanel · SettingsView · SearchResultsView             │
└───────────────▲─────────────────────────────────────────────┘
                │ observes (@Observable)
┌───────────────┴─────────────────────────────────────────────┐
│  App State / ViewModels  (@MainActor, @Observable)           │
│  AppModel · PlayerModel · LibraryModel · ConnectionModel ·   │
│  Navigator                                                   │
└───────────────▲─────────────────────────────────────────────┘
                │ async calls
┌───────────────┴─────────────────────────────────────────────┐
│  Services  (actors / isolated)                               │
│  SubsonicClient (actor) · NavidromeClient (actor) ·          │
│  PlaybackService (actor) · ArtworkCache ·                    │
│  CredentialStore (Keychain) · NowPlayingCenter ·             │
│  AudioOutputDevices (Core Audio)                             │
└───────────────▲─────────────────────────────────────────────┘
                │
┌───────────────┴─────────────────────────────────────────────┐
│  System / IO                                                 │
│  URLSession · AVAudioEngine · MediaPlayer · Keychain ·       │
│  Core Audio                                                  │
└─────────────────────────────────────────────────────────────┘
```

**Rule:** views never import `AVFoundation`/`MediaPlayer`/`URLSession`; they
talk to models, and models talk to services.

## Central state: `PlayerModel` ✅

A single `@MainActor @Observable final class PlayerModel` is the source of
truth for everything "now playing":

- `currentTrack: Song?`, `queue: [Song]` (Up Next), `history: [Song]`
- `state: PlaybackState` (`.stopped`, `.buffering`, `.playing`, `.paused`)
- `position: TimeInterval`, `duration: TimeInterval` (position throttled — see
  `03`)
- `repeatMode`, `shuffle`, `volume` (the output device lives in Settings /
  `PlaybackService`, persisted by UID via `@AppStorage`)

Why central: the `MenuBarExtra` panel, the main window's header, multiple
library windows, the `MPNowPlayingInfoCenter`, and `MPRemoteCommandCenter`
handlers must all reflect and mutate the same state without drift. `PlayerModel`
forwards intent (`play(_:)`, `pause()`, `next()`, `seek(to:)`) to
`PlaybackService` and mirrors the resulting state back for observation.

The model is the *only* thing that writes to `NowPlayingCenter`, so system
metadata can never disagree with the UI.

## Service responsibilities

- **`SubsonicClient` (actor)** — all OpenSubsonic HTTP. Builds authed
  requests, decodes `Codable` models, maps errors. See `02`.
- **`NavidromeClient` (actor)** — Navidrome's native react-admin API
  (`/api/...`, separate from Subsonic's `/rest/`), metadata-only: composer
  enumeration, a full song index, work/movement tags. Never streams or plays
  audio — that stays on `SubsonicClient`; `NavidromeClient` resolves song ids
  that `SubsonicClient`/`Song` then handle. Undocumented API, so every decode
  is tolerant and every failure degrades to Subsonic-only. See `02`, the E3
  epic (#11) and spike (#8).
- **`PlaybackService` (actor)** — owns `AVAudioEngine` and a single player
  node, the streaming decode pipeline, gapless scheduling, output-device
  routing/recovery, and a throttled position publisher. Exposes async intent
  methods and an `AsyncStream<PlaybackEvent>` back to `PlayerModel`. See `03`.
- **`LibraryModel`** — in-memory library state (albums/artists/songs/genres/
  playlists/starred), fetched per session with pagination. The planned
  SwiftData `LibraryStore` was dropped — the app is network-required by
  design. See `05`.
- **`ArtworkCache`** — two-tier (memory + disk), server-scoped, resized image
  cache. See `05`.
- **`CredentialStore`** — Keychain read/write of server URL, username, and
  password (token+salt) or API key; an in-memory variant backs tests/previews.
  See `02`/`07`.
- **`NowPlayingCenter`** — wraps `MPNowPlayingInfoCenter` /
  `MPRemoteCommandCenter`. See `06`.
- **`AudioOutputDevices`** (+ `AudioDeviceListObserver`) — Core Audio output
  device enumeration, UID↔id resolution, nominal-sample-rate control, and
  device-list change observation; `PlaybackService` applies the routing. See
  `03`.

## Concurrency model (Swift 6 strict) ✅

- UI + all `@Observable` models: `@MainActor`.
- Networking, decode, file/audio I/O: off the main actor in `actor`s or
  detached tasks. Decoding audio and reading streams must never block the UI.
- Data crossing isolation boundaries is `Sendable` value types (`struct`/
  `enum`); models map service DTOs to UI-facing value types.
- Migration approach: start the app target in Swift 6 language mode from M0
  (greenfield, so no incremental migration burden). Keep service boundaries
  narrow and `Sendable`-clean.

## State management: Observation ✅

Use the Observation framework (`@Observable`) rather than
`ObservableObject`/`@Published`. Inject models via the SwiftUI environment
(`.environment(playerModel)`) so the main window, additional windows, and the
`MenuBarExtra` scene share instances. App-level wiring lives in the `App`
struct's `body` (`WindowGroup`, `Settings`, `MenuBarExtra` scenes).

## Error handling & state modeling

- `enum`s with associated values for finite state (`PlaybackState`,
  `ConnectionState`, `LoadState<T>` = `.idle/.loading/.loaded(T)/.failed(Error)`).
- Typed throwing (`throws(SubsonicError)`) at the client boundary; surface
  user-facing errors via a lightweight alert/toast model.
- Optionals over sentinels; avoid force-unwraps outside genuinely guaranteed
  cases.

## Module / target structure

Single app target for v1 plus a unit-test target (an XCUITest target is
planned but not yet created). Folder groups inside the app target (Xcode 16+
synchronized groups — new files are picked up automatically):

```
Hydrophone/
  App/            HydrophoneApp (scenes), AppModel (composition root),
                  HydrophoneCommands (menu bar)
  Models/         PlayerModel (+RemoteCommands, +Scrobbling extensions),
                  LibraryModel, ConnectionModel, PlaybackTypes
  Networking/     Endpoint map, DTOs (SubsonicModels), envelope
                  (SubsonicResponse), SubsonicError, NavidromeModels
                  (NavidromeError/Token/DTOs)
  Playback/       PlaybackService, ProgressiveAudioSource, DataStreamLoader,
                  AudioStreamSource (protocol), AudioOutputDevices,
                  PlaybackEvent
  Services/       SubsonicClient, NavidromeClient, CredentialStore,
                  ArtworkCache, NowPlayingCenter
  UI/
    Components/  Library/  MenuBar/  NowPlaying/  Search/  Settings/  Sidebar/
    (+ RootView, Navigator at the top level)
  Resources/      Assets, entitlements
HydrophoneTests/   Swift Testing units (incl. opt-in live-server tests)
```

Keep the audio/Core Audio bridging thin and contained (most is pure Swift; only
device enumeration touches Core Audio C APIs).

## Dependency policy ✅

First-party Apple frameworks only. Everything in the prompt maps to system
frameworks (SwiftUI, AVFAudio/AVFoundation, MediaPlayer, Security/Keychain,
URLSession, SwiftData, CryptoKit/`Insecure.MD5` for the auth token). Reach for
an SPM package only if a permissive-licensed library is the sole alternative to
reinventing the wheel; record any such decision here with its license.
