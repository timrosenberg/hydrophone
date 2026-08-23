# 08 — Testing Strategy

Use **Swift Testing** (`@Test`, `#expect`/`#require`) for unit and logic tests;
**XCTest/XCUITest** for UI automation (the supported path for UI tests). Design
for testability via protocols so services can be mocked without a live server or
audio hardware.

## What to unit-test (Swift Testing)

### Networking / API (`02`)
- **Request building:** correct `/rest/<method>` path, common params
  (`v/c/f=json`), and per-endpoint params; URL encoding of queries.
- **Auth:** token+salt — `t == md5(password + salt)` for known vectors; salt is
  random per request; API-key path emits the right params; password never
  appears in the URL.
- **Response decoding:** decode `Codable` models from **recorded JSON
  fixtures** (Navidrome responses for `getAlbumList2`, `getArtist`, `getAlbum`,
  `getPlaylists`, `search3`, `getStarred2`, `getOpenSubsonicExtensions`,
  error envelopes). Cover the single-vs-array and string-number quirks.
- **Error mapping:** Subsonic error codes (40/41/50/70/…) map to the right
  `SubsonicError` cases.
- **Pagination:** offset bookkeeping and exhaustion detection.
- **Transcoding params:** original vs transcode produce the expected `stream`
  URL (`format`/`maxBitRate` present/absent).

### Playback logic (`03`)
- **Queue/Up Next:** play-from-index, next/previous, reorder, remove,
  repeat/shuffle behavior — tested against a **mocked engine** (a fake
  conforming to the playback/stream-source protocols), no real audio.
- **Gapless scheduling decisions:** N+1 priming triggers at the right point;
  node role swap; teardown/release ordering (assert via the mock's recorded
  calls).
- **Position throttling:** updates emitted at the configured rate, derived from
  sample time (inject a clock).
- **Seek:** maps to source seek + position/Now Playing update.

### State & integration seams
- **`PlayerModel`** transitions (`PlaybackState` enum) on intent.
- **`NowPlayingCenter`** (`06`): given a `PlayerModel` change, the right
  `nowPlayingInfo` keys/playbackState are produced (test the mapping function,
  not the live `MPNowPlayingInfoCenter`).
- **Artwork cache** (`05`): key-by-id+size, eviction, no full-res reuse for
  thumbnails.

## Mocking approach ✅ (as implemented)

- Seams kept deliberately small:
  - `InMemoryCredentialStore` stands in for the Keychain, so `SubsonicClient`
    is constructible in tests (URL/auth construction asserted on the built
    requests — no network).
  - `PlayerModel` works with **no engine injected**: queue/transport logic is
    synchronous and engine-independent, and `handle(_:)` is internal so tests
    drive `PlaybackEvent`s directly (no `MockPlaybackEngine` needed).
  - `AudioStreamSource` is the decode seam; `DecodeContinuityTests` runs the
    *real* `ProgressiveAudioSource` against synthesized audio instead of
    mocking it.
- **Opt-in live tests** (`LiveDecodeTests`, `NavidromeLiveTests`): run against a
  real server only when `HYDROPHONE_HOST`/`HYDROPHONE_USER`/`HYDROPHONE_PASS`
  are set; skipped otherwise, so no credentials are committed and CI stays
  hermetic. **Known local-verification gap:** `xcodebuild test` does not
  forward the invoking shell's environment into the XCTest runner process on
  at least one dev machine — confirmed via a diagnostic assertion (the test
  process saw a handful of system-injected env vars, none of the
  `HYDROPHONE_*` ones the shell had). Both opt-in suites silently no-op in
  that case rather than fail, so a green `xcodebuild test` locally does **not**
  by itself prove the live paths ran — check the per-test duration (a
  near-zero duration means it skipped) or verify by compiling the client
  source standalone with `swiftc` (inherits the shell environment directly)
  as was done for #22. Wiring the `HydrophoneTests` scheme's Test-action
  environment variables would fix this properly; tracked as a follow-up, not
  yet done.
- **Network-behavior seam** (`NavidromeClientNetworkTests`): a stubbed
  `URLProtocol` (`NavidromeMockProtocol`) registered on a per-test
  `URLSessionConfiguration.ephemeral`, so it never touches the network or
  other tests. Used where request-building assertions alone can't reach the
  behavior — token-cache reuse across calls, expiry-triggered refresh,
  credential-change invalidation, and one-retry-only 401 handling all need a
  full request/response cycle with a controllable server. The suite is
  `@Suite(.serialized)`: its tests share one static mock-protocol state (by
  design — it stands in for one real server across a session), so they'd race
  each other under Swift Testing's default parallel execution.

## Current suite (Swift Testing, 154 tests)

`AuthTests` · `RequestBuildingTests` · `DecodingTests` · `ConnectionTests` ·
`PlaylistEndpointTests` · `PlaybackConfigTests` · `PlayerQueueTests` ·
`QueueEditingTests` · `QualityLabelTests` · `ArtworkCacheTests` ·
`NowPlayingCenterTests` · `DecodeContinuityTests` · `DiscHeaderTests` ·
`EndpointGoldenTests` · `FlacStreamingTests` · `AlbumFilterEndpointTests` ·
`ReplayGainTests` · `StarringTests` · `NavidromeClientTests` ·
`NavidromeClientNetworkTests` · `LiveDecodeTests` (opt-in) ·
`NavidromeLiveTests` (opt-in).

## UI tests (XCUITest) ⏳ (target not yet created)

- Planned smoke flows: configure server (mocked via launch-argument stub),
  browse a library, play a track, scrub, next/previous, create/reorder a
  playlist, search.
- Interim: end-to-end flows have been verified by driving the real app
  (computer-use) against a live Navidrome — see `PROGRESS.md`.

## Manual verification checklist (hardware-dependent)

These can't be fully automated — verify by hand each release. Status as of
2026-07-07:
- [x] Now Playing widget shows correct title/artist/album/artwork + elapsed
      (M3/M7, live-verified).
- [x] Media keys (F7/F8/F9) and Control Center transport control the app
      (hardened + verified during the M7 media-keys pass).
- [x] **Gapless**: Abbey Road medley, human-confirmed seamless (2026-07-03).
- [x] Output-device switch mid-track recovers cleanly (USB DAC, 2026-07-05).
- [x] Route changes: pinned-device vanish → fallback, replug → re-pin
      (2026-07-05). AirPods specifically untested; same recovery path.
- [x] App doesn't sleep/App-Nap mid-track (`beginActivity` held during
      playback; long sessions observed without throttling).
- [x] State restoration: relaunch restores section, panel/browser visibility,
      browser selections, table sort, and scroll offset (2026-07-07).
- [x] Light/Dark verified (dark in daily use; light via per-app Aqua
      override, 2026-07-07). VoiceOver semantics verified via the AX API
      (sliders expose value + increment/decrement; favorite buttons expose
      state-aware labels + AXPress); keyboard: table arrows/⏎, ⌘F, transport
      and view shortcuts. Remaining by hand: increased-contrast and
      reduce-transparency spot checks (system-settings toggles), a full
      VoiceOver listening pass.
- [ ] Liquid Glass appearance on macOS 26 — **blocked on a Tahoe machine**
      (dev machine runs macOS 15); standard-controls-only design means low
      risk. Clean native look on Sequoia verified.
- [x] Memory stable over a long listening session — leak audit 2026-07-07:
      zero app-code leaks; footprint declines during playback.

## CI 🔶 (unit job ✅)

- ✅ Unit tests run on every push to `main` and every PR:
  `.github/workflows/tests.yml` (macOS 15 runner, newest installed Xcode
  selected at runtime, `CODE_SIGNING_ALLOWED=NO`; `LiveDecodeTests`
  self-skip without env credentials).
- ⏳ Build the signed MAS artifact in a release job (see `07`) —
  `scripts/release.sh`/`publish.sh` remain local.
- (Adjacent: `.github/workflows/pages.yml` deploys the website on release —
  see `07`.)
