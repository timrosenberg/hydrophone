# 10 — Roadmap, Milestones & Sequencing

Phased build order with exit criteria and top risks. Each milestone is a
shippable-internally increment. The hardest item — streaming gapless via
`AVAudioEngine` — is isolated as a spike (M4) and de-risked by landing simpler
playback first (M3).

> **Live status:** M0–M6 ✅ (M2's SwiftData metadata warm start is wired on the
> #128 continuation branch;
> gapless human-verified 2026-07-03; playlist reorder verified vs Navidrome;
> output-device switching human-verified vs a USB DAC 2026-07-05, incl.
> hardware sample-rate matching) · M7 ✅ (shortcuts, full restoration incl.
> scroll, accessibility semantics AX-verified, Light/Dark verified; the `08`
> checklist passes — only the Liquid Glass look on macOS 26 awaits a Tahoe
> machine, plus by-hand VoiceOver/contrast spot checks) · M8 🚧 — Developer ID pipeline complete (notarized, stapled,
> Gatekeeper-accepted) and CI runs the unit suite on every push; MAS portal
> artifacts, icon, App Privacy remain. Post-M7 feature batch shipped: Home
> page, scrobbling, demo-server onboarding, library scan, Quick Look artwork,
> Show Album, decode-failure alerts, resizable Now Playing panel, AirPlay
> Tier 1. See `PROGRESS.md` for the detailed build log.

## M0 — Foundation ✅
- Create the Xcode app project (macOS 14 deployment — 15 at M0, lowered
  2026-07-18; Swift 6 language mode, Xcode 26 SDK), folder groups per `01`,
  unit-test + UI-test targets.
- App Sandbox + `network.client` entitlement; Hardened Runtime; Info.plist
  (min macOS 14, music category, versioning, icon placeholder) — `07`.
- Settings scene skeleton + Keychain credential store (shipped as
  `CredentialStore`) — `02`/`07`.
- App scenes wired: `WindowGroup`, `Settings`, `MenuBarExtra` (empty), shared
  `@Observable` models in the environment — `01`/`04`.
- **Exit:** app launches, builds against macOS 15 SDK, opens an empty shell +
  Settings; credentials persist to Keychain.

## M1 — Connectivity & auth ✅
- `SubsonicClient` (actor) + request builder + envelope decoding + error map.
- token+salt auth; API-key auth where supported; `getOpenSubsonicExtensions`
  capability detection — `02`.
- Settings: server URL/username/password (or API key) + **Test Connection**
  (`ping`).
- **Exit:** Test Connection succeeds against a Navidrome server; auth failures
  surface a clear re-auth path.

## M2 — Library browse ✅
- Paginated fetch for Albums/Artists/Songs/Genres through the observable
  `LibraryModel`. The original offline store proposal was dropped; #128 now
  adds SwiftData metadata seeding for faster verified, connected launches,
  followed by live refresh and complete reconciliation — `05`/`02`.
- Sidebar (Library group), dense sortable `Table`, basic now-playing header
  (non-functional transport), artwork thumbnails via `ArtworkCache` — `04`/`05`.
- **Exit:** browse a large library smoothly with pagination; sort columns;
  scroll stays fluid; memory bounded.

## M3 — Single-track playback + system integration ✅
- `PlaybackService` + `AVAudioEngine` graph playing **one track** (Option A
  progressive decode — committed decision) — `03`.
- `PlayerModel` intent (play/pause/seek), throttled position, now-playing header
  functional.
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` + media keys; App Nap
  prevention — `06`.
- **Exit:** play/pause/seek a track; Now Playing widget + media keys work;
  artwork + elapsed time correct.

## M4 — Gapless + queue + column browser ✅ (was highest risk)
- **Spike:** streaming **gapless** + pre-buffering on the committed Option A
  progressive-decode pipeline (the planned dual player nodes resolved to a
  single node + canonical timeline format — `03`); also harden Option A's
  known rough edges (seek accuracy done; magic cookie documented as a
  limitation). Meet the M4 spike checklist.
- Up Next / queue (reorder, remove, play-from-here) — `04`.
- Column browser (Genre → Artist → Album) — `04`.
- **Exit:** gapless verified on a gapless album; sample-rate change handled;
  queue editing updates pre-buffer target; column browser filters the table.

## M5 — Playlists & favorites ✅
- Playlists CRUD + **reorder** (`createPlaylist`/`updatePlaylist`/
  `deletePlaylist`); drag rows to playlists — `02`/`04`.
- Favorites: `getStarred2`, `star`/`unstar`, Favorites sidebar item, ★ column.
- **Exit:** full playlist lifecycle round-trips to the server; starring works
  everywhere.

## M6 — MenuBarExtra, search, output device ✅
- `MenuBarExtra` `.window` Now Playing panel sharing `PlayerModel` — `04`.
- Global search (`search3`) with debounce/cancellation — `02`/`04`.
- Output-device enumeration/selection + route-change handling — `03`.
- **Exit:** menu-bar panel controls playback with main window closed; search is
  responsive; device switching is robust.

## M7 — Polish: accessibility, restoration, transcoding, appearance ✅
(Tahoe/Liquid Glass verification pending a macOS 26 machine)
- Accessibility pass (VoiceOver, Dynamic Type, contrast, keyboard nav) — `04`.
- State restoration (windows/selection/sort/scroll) — `06`.
- Transcoding settings (format/bitrate) wired to `stream` — `02`.
- Liquid Glass verification on Tahoe + Sequoia fallback; full menu/shortcuts —
  `04`.
- **Exit:** manual verification checklist in `08` passes.

## M8 — Distribution 🚧
- App icon, App Privacy details, reviewer notes/demo credentials — `07`.
- MAS signing/notarization pipeline; (optional) Developer ID build.
- ✅ CI: build + full unit suite on every push/PR
  (`.github/workflows/tests.yml`, macOS 15 runner) — `08`.
- **Exit:** signed MAS build uploads to App Store Connect; tests green.

## AirPlay
- **Tier 1 (code complete, live test pending):** connected AirPlay routes are
  regular Core Audio devices — labeled in the picker, rate-matching skipped
  (fixed network clock). Needs one pass against a real AirPlay 2 receiver
  (another Mac / HomePod / Apple TV) — see `PROGRESS.md` 2026-07-08.
- **Tier 2 (post-v1):** in-app discovery/multi-room via
  `AVSampleBufferAudioRenderer` + `AVRoutePickerView` — a parallel render
  path beside the `AVAudioEngine` pipeline; significant rework.

## Post-v1 feature milestones — ecosystem gap analysis (2026-07-17)

From a survey of ~35 Subsonic/OpenSubsonic clients (desktop, web, mobile).
Where Hydrophone already leads: cross-device queue sync via `savePlayQueue`
(almost unclaimed ecosystem-wide), hardware sample-rate matching, true
streaming gapless. The gaps below are ordered by how hard the ecosystem
pressures them vs implementation cost. Sizes: S ≈ days, M ≈ a week-plus,
L ≈ engine-level rework.

### M9 — Ratings, synced lyrics, sleep timer (S/S/S)
The three most conspicuous table-stakes gaps; all fit the current
architecture without engine changes.
- **5-star ratings** (`setRating`) — we sync favorites only; nearly every
  maintained client syncs both, and Navidrome tracks them separately. New
  rating column beside ★ in `MusicTrackTable`, control in Get Info +
  context menu — `02`/`04`.
- **Synced lyrics** — the signature feature of every 2025–2026 client.
  OpenSubsonic `getLyricsBySongId` (songLyrics extension; capability
  detection already in place via `getOpenSubsonicExtensions`), legacy
  `getLyrics` fallback for unsynced. Lyrics view in the Now Playing panel,
  line highlight driven by the existing throttled position stream,
  click-a-line-to-seek. Word-level timing (songLyrics v2, Navidrome 0.63)
  is a later polish pass — `02`/`04`.
- **Sleep timer** — Controls menu + menu-bar panel; pause at end of timer
  or end of current track. Trivial; ubiquitous elsewhere.
- **Exit:** ratings round-trip vs Navidrome and sort correctly; synced
  lyrics track the playhead and seek on click on a real server; timer
  pauses cleanly mid-stream.

### M10 — Discovery: artist info, instant mix, radio ✅ (except internet radio)
Server-powered features; API + UI work only, no engine risk.
**Status 2026-07-18:** artist info, Start Radio (with artist-shuffle
fallback for agent-less servers) and album shuffle shipped and
human-verified against a real server. Internet radio deferred by choice —
the ICY spike below remains open.
- **Artist metadata** (`getArtistInfo2`) — bio, artist image, similar-artist
  links on the artist detail page (currently just an album list) — `02`/`04`.
- **Instant mix / artist radio** — `getSimilarSongs2` + `getTopSongs`;
  "Start Radio" from song/artist context menus feeding the existing queue.
  Detect and prefer the `sonicSimilarity` extension (Navidrome 0.62,
  audio-analysis-based) when the server offers it — `02`.
- **Richer shuffle** — Shuffle by Albums (whole albums in random order, via
  `getAlbumList2 type=random`) alongside the existing 500-song Shuffle
  Library; genre/decade-filtered shuffle reuses the Albums filter model —
  `04`.
- **Internet radio stations** (`getInternetRadioStations`) — sidebar
  section. ⚠️ Engine caveat: ICY streams are endless and unseekable, which
  breaks the progressive pipeline's known-length assumptions; needs a spike
  (likely a separate lightweight `AVPlayer`-style path or a stream-source
  variant) before committing — `03`. If the spike is ugly, ship M10 without
  it.
- **Exit:** artist pages show bio + similar artists; Start Radio fills the
  queue with plausible picks vs a real server; album shuffle queues full
  albums.

### M11 — Audiophile engine batch: EQ, signal-path indicator, hog mode (L)
Aligned with the app's identity (rate matching, gapless, quality badges);
this is where the direct macOS competitors (EKO, Supersonic) compete.
- **Optional graphic EQ** — `AVAudioUnitEQ` (10-band) inserted in the
  engine graph; per-preset storage. Stretch: AutoEQ headphone-profile
  import (plain-text profiles, no dependency) — `03`.
- **Signal-path integrity indicator** — surfaced in Now Playing/Get Info:
  "bit-perfect" state lights only when EQ/ReplayGain/volume leave the
  stream untouched and the device rate matches. Resolves the EQ-vs-purity
  tension explicitly; we already have most of the state — `03`/`04`.
- **Exclusive / hog-mode output** (already a tracked deferral) —
  `kAudioDevicePropertyHogMode` + mixability off while playing; completes
  the bit-perfect story next to rate matching — `03`.
- **playbackReport extension** — richer playback telemetry next to the
  existing scrobbler; cheap, and Navidrome 0.62's Now Playing uses it —
  `02`.
- **Crossfade — explicitly deferred**, not in M11: the single-node
  back-to-back scheduling that makes gapless work leaves no second node to
  overlap into; it's a dual-node/dual-chain rework with route-recovery
  implications (`03`). Revisit only on demand.
- **Exit:** EQ audibly works and bypasses losslessly when flat/off; hog
  mode verified vs the USB DAC incl. route-change recovery; indicator
  state matches reality in all combinations.

### Tracked, unscheduled (revisit on demand)
- ~~SwiftUI scroll-position persistence~~ — shipped 2026-07-18 for the
  Albums grid, Home, and artist detail via `scrollPosition(id:)` +
  `@AppStorage`. Artists master-list restoration followed on 2026-08-25
  (#29), using a native-list bridge with the same ID-based scroll memory.
- **Cache genre songs / playlist detail in LibraryModel** so Back doesn't
  refetch with a spinner flash. S.
- **Public share links** (`createShare`) — "Copy Share Link" context
  action; Navidrome supports it, few clients expose it. S.
- **Bookmarks + playback speed** (`getBookmarks`/`createBookmark`) — the
  audiobook/long-mix story; near-absent on desktop. S–M.
- **Folder browsing** (`getIndexes`/`getMusicDirectory`) — tag-only today;
  matters for messy-tag libraries. M.
- **Waveform seekbar** — distinctive but needs whole-file peak data the
  streaming pipeline doesn't naturally have. M–L.
- **Jukebox mode** (`jukeboxControl`) — rare on desktop (Feishin just
  added it). M.
- **Offline caching** stays a `00` non-goal but is table stakes on every
  maintained mobile client and marked ⏳ there — first non-goal to revisit
  post-MAS. Smart playlists / multi-server / podcasts remain safe skips.

## Risk register

| Risk | Milestone | Mitigation |
| --- | --- | --- |
| Streaming gapless decode complexity (Core Audio / format changes) | M3/M4 | Committed to Option A progressive decode; `AudioStreamSource` protocol keeps Option B droppable-in; M4 checklist gates; magic-cookie/seek hardening tracked |
| API-key auth availability varies by server | M1 | Capability detection; token+salt fallback |
| Output-device/route-change engine rebuilds cause glitches | M6 | Observe config-change + Core Audio listeners; rebuild + resume; manual test matrix |
| Subsonic JSON quirks (single-vs-array, string numbers) | M1 | Tolerant decoders + recorded fixtures (`08`) |
| Large-library performance/memory | M2/M5 | Pagination + virtualization + bounded caches (`05`) |
| Liquid Glass / Tahoe-only API drift | M7 | Standard controls only; `#available` guards (`04`) |
| App Review needs a working server | M8 | Demo credentials + graceful no-server onboarding |

## Out of scope (post-v1)
Offline caching/downloads, direct Last.fm/ListenBrainz clients (server
scrobbling shipped), smart playlists, multi-server, Cover Flow,
local-file playback, tag editing — see `00`.
