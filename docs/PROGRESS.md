# Build Progress Log

A running record of what's been implemented, verified, and deferred. Newest
milestone first. See `10-roadmap.md` for the full milestone plan.

## Conventions
- ✅ done & verified · 🚧 in progress · ⏳ deferred (tracked) · 🔬 spike pending

## Environment
- Local verification: Xcode 26.6, Swift 6.3.3, macOS 26.5 SDK. Swift 6 language mode (strict
  concurrency) enabled on all targets.
- Bundle identifier: `app.hydrophone`. App Sandbox + `network.client`
  entitlement; Hardened Runtime on.
- Project uses Xcode 16+ **synchronized file groups**, so new `.swift` files
  under `Hydrophone/` and `HydrophoneTests/` are picked up automatically without
  editing the project file.
- **Debug builds sign with the Developer ID identity** (Huell B.V.,
  `4HNWJ993V9`; manual style, hardened runtime off for Debug). Ad-hoc signing
  gave every build a new designated requirement, so the keychain re-prompted
  for the server credential on each rebuild; the certificate-based requirement
  is stable, so one "Always Allow" sticks. Release signs Manual + Developer ID
  with the hardened runtime ON (see the M8 pipeline entry).

## Milestone status
M0 ✅ · M1 ✅ (auth/endpoints live-verified vs Navidrome 0.62) ·
M2 ✅ (UI/data live-verified; persistent metadata warm-start is now wired;
artwork and server metadata cached on disk; Songs and selected genres paginate
to exhaustion;
incremental Songs, stable default sorting, and deep scroll restoration confirmed;
final #82 review-fix live recheck passed on 2026-08-28; #128 warm-start
continuation and all six sub-issues are implemented, verified, and landed
2026-09-05 (PR #152, #153); per-item album/artist detail fetches now cache
within a session (#114)) ·
Issue #84 ✅ (complete-browser panes, selection cascades, and genre generation
guard verified at full-library size; isolated browser and artwork fixtures) ·
M3 ✅ (playback live-verified end-to-end; seek + Now Playing/media keys work) ·
M4 ✅ (gapless human-confirmed seamless 2026-07-03; only a cross-sample-rate
transition remains untested — needs mixed-rate tracks in the library) ·
M5 ✅ (playlist CRUD + reorder-by-replace verified vs Navidrome 0.62
2026-07-03; favorites persist) ·
M6 ✅ (MenuBarExtra panel + search verified; output-device switching,
vanish-fallback and re-pin human-verified vs a USB DAC 2026-07-05) ·
M7 ✅ (shortcuts incl. focus-safe Space play/pause and Caps Lock-safe ⌘I Get
Info, restoration incl. independently resizable per-view track columns with
horizontal overflow and divider double-click autosizing, scroll offset, and
Artists master-list position, accessibility semantics
AX-verified, Light/Dark verified — the `08` checklist passes; only the
Liquid Glass look awaits a macOS 26 machine, plus by-hand VoiceOver/contrast
spot checks) ·
M8 ✅ (Developer ID pipeline: notarized, stapled, Gatekeeper-accepted
builds via publish.sh; CI on every push; **Mac App Store: 0.6.2 approved
and released 2026-08-16** after three review rounds — window-scene fix,
rights-cleared screenshots, and the recorded evidence package did it;
store page linked from website + README) ·
E4 ✅ (Navidrome composer roster + song lookup — #71; native-gated sidebar
route and resizable composer master list — #72; composer track detail with
play/shuffle/queue and a native-unavailable fallback — #73; song index excludes
missing/deleted files — #86; cached native rows resolve directly to playable
songs with no per-track requests — #85) ·
E5 ✅ (WorkInfo join, Work/Movement columns, album work-grouping headers, and
Work context-menu actions complete — #45-48; follow-up polish: #54
Title-column movement text under a work header, #53 spacer row, #55
work-header double-click, and #120 single-work-album grouping all done) ·
E7 ✅ (bounded artwork prefetch and cache budget; build, full tests, lint,
and live artwork verification pass — see the 2026-08-26 entry below)

## How to build / test
```sh
xcodebuild -project Hydrophone.xcodeproj -scheme Hydrophone \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Hydrophone.xcodeproj -scheme Hydrophone \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

---

## Issue #114: cache per-item album/artist detail fetches (2026-09-05)

- `LibraryModel.album(id:)` and `albums(forArtist:)` previously hit the network
  on every call, including revisiting an already-fetched album or artist in
  the same session — the only two `LibraryModel` loaders with no memoization
  at all (`docs/05`'s "not a cache" list). Added a session-scoped, id-keyed
  cache for both (`albumDetailCache`/`artistAlbumsCache`), cleared by `reset()`
  and by a completed background full reconciliation (`LibraryModel+Metadata.swift`),
  matching how the rest of the library index already invalidates. `songs(forAlbum:)`
  stays uncached — its only callers are the Home/AppModel shuffle-album paths,
  which pick albums at random rather than revisiting a selection, so caching it
  wouldn't address a real revisit case.
- Only a *successful* fetch populates the cache: `albums(forArtist:)`'s prior
  behavior silently mapped a network failure to `[]`, and caching that would
  have permanently locked in an empty artist for the rest of the session after
  one hiccup. Fixed to distinguish "artist fetch failed" from "artist has zero
  albums" before deciding whether to cache.
- Split `LibraryModel+AlbumDetail.swift` out of `LibraryModel.swift` (file-length
  lint) and relocated `mutate(_:thenReload:)` into `LibraryModel+Playlists.swift`,
  its only caller, to keep `LibraryModel`'s type body under the line-length lint
  after the two new cache properties.
- Overlaps with open issue #112 (artist-page lag): this closes #112's caching
  cause for `albums(forArtist:)` but leaves its separate blocking-on-`artistInfo`
  cause untouched.
- New `LibraryModelDetailCacheTests.swift`: cache-hit reuse for both fetchers,
  distinct ids cached independently, `reset()` clears the cache so the next
  visit refetches, and a failed artist fetch is not cached.
- Full gate: unsigned app build **zero warnings**; full suite **417 tests / 440
  executions, 0 failures**; SwiftLint **0 violations** (170 files).
- Live: 2026-09-05, Tim's configured Navidrome 0.63.2, exact executable
  `/Users/trosenberg/Library/Developer/Xcode/DerivedData/Hydrophone-fhlpqojgwcqtjgdrttaspftiigar/Build/Products/Debug/Hydrophone.app`,
  PID **11586**. With temporary instrumentation (removed before the final gate
  run above) logging each cache decision: selecting Alfred Brendel (12 albums)
  logged a network fetch; switching to Aaron Robinson and back within the same
  quick round-trip logged a cache hit for Brendel with no repeat `getArtist`
  call. Opening the *Schwanengesang* album, going Back, and reselecting the
  same album logged a cache hit for the album with no repeat `getAlbum` call.
  A single background full reconciliation completed mid-session and correctly
  forced one fresh re-fetch for both previously-cached ids on the next visit,
  confirming the invalidation path fires live, not just in the hermetic tests.
  Playback of *Before Bach: Benediction* (Brad Mehldau) continued undisturbed
  throughout.

## PR #153: review remediation (2026-09-05)

- Evaluated all seven inline findings at `7003d3b`. The connection, empty
  fallback, playlist-detail revision, genre reload and native-waiter findings
  reproduced in regression tests before their fixes.
- Failed unsaved form tests now preserve the verified library/store and the
  persisted session generation; failed persisted connect paths still invalidate.
  Empty random fallback never establishes completeness, even with zero rows.
  Replacement native probes leave existing waiters pending until a terminal
  result instead of reporting unavailable while still checking.
- Playlist details are guarded per ID, so editing B cannot retire A. A completed
  edit triggers one selected-detail reload while optimistic rows remain visible.
  The genre browser follows selection/session/readiness changes and rejects
  canceled predecessors before they can alter the replacement load's state.
- For a failed playlist detail, added one bounded retry of the entire playlist
  listing/detail inventory. This recovers transient failure and deletion during
  sync without accepting a partial snapshot. Persistent failure still cancels
  reconciliation and retains the prior complete snapshot. Returning stale genre
  or album rows was rejected as a remedy because it would break account isolation.
- Whole-table identity-map construction on each small write is confirmed as a
  performance limitation and documented in `docs/05` for targeted profiling and
  optimization. No persistence redesign or new cache is included in this repair.
- Full gate: **413 tests / 436 executions, 0 failures/skips**, canonical bundle
  `/tmp/hydrophone-153-review-final.xcresult`; unsigned app build **zero warnings**;
  SwiftLint **0 violations**; `git diff --check` clean. Rendered tests cover the
  session-reset genre reload, canceled initial walk and optimistic playlist
  removal. The full gate caught a duplicate post-edit reload; it was corrected
  before this passing run. Independent follow-up review found no remaining issue
  within the repair scope.
- Live: 2026-09-05, Tim's configured Navidrome 0.63.2, exact executable
  `/private/tmp/hydrophone-153-review-dd/Build/Products/Debug/Hydrophone.app`,
  PID **25134**. An unsaved invalid path on the same server produced the expected
  Test Connection error; the selected Jazz pane remained populated afterward.
  Restored the original form address and verified it successfully without Save
  & Connect. A real scan reported **Scan finished — 14231 items**; the existing
  Jazz filter repopulated the track table without another genre click. Restored
  the original All Genres selection afterward. Stored credentials were not
  changed; playback remained paused.

## Issue #128: acceptance completion and lifecycle review (2026-09-05)

- Completes #146–151 for joint review in #152/#153. The schema remains on its
  foundation branch; all continuation fixes and evidence are on the epic branch.
- Added acceptance coverage for slow and failed persistence without delayed
  live rows, actual fetch-to-disk writes, manual scan completion followed by a
  second full store refresh, and recovery when the initial collection request
  fails but the complete sync succeeds.
- Independent review found and the branch fixes ID-ordered album publication,
  stale favorite flags from ordinary detail writes, obsolete playlist detail/
  enrichment writes after edits, and a form test abandoning the native probe.
  Initial live-load writes are drained before full sync so they cannot replay
  over a later server snapshot. Selected sections and playlist details restart
  after seeding/session changes; ordinary playlist listings do not retire an
  in-flight detail request. Follow-up review found no remaining blockers.
- Updated the #125 inventory: session walk coalescing/native joins, observable
  projections, mutation guards, auth/capability state and artwork each retain a
  distinct responsibility. No redundant-cache removal follow-up was identified.
- Verification: unsigned app build **zero warnings**; full suite **407 tests /
  428 executions, 0 failures, 0 skips**, read from
  `/tmp/hydrophone-128-complete-final.xcresult`; SwiftLint **0 violations**;
  `git diff --check` clean. The preceding clean-DerivedData run passed 406 tests;
  its test compilation exposed the existing `ArtworkCacheTests.swift:223`
  weak-variable warning. The production app build emits no compiler warnings.
- Live: 2026-09-05, Tim's configured Navidrome **0.63.2**, exact executable
  `/private/tmp/hydrophone-128-gate-sept5/Build/Products/Debug/Hydrophone.app`.
  Confirmed process exit, then new PID **80900**: Home initially showed cached
  favorites and **14,231 songs**, then live Keep Listening/Recently Added/Most
  Played/Random shelves populated. Confirmed exit of 80900, then new PID
  **82090**: launch directly into the saved *2027 Faculty Recital* playlist
  rendered **10 songs / 59:21** without navigating away. Album browsing is
  alphabetical; the on-disk snapshot contains **14,231 songs / 1,152 albums**.
  A real **Scan Library** reported **Scan finished — 14231 items**; the disk
  sync state advanced to generation **5**, timestamp **2026-09-05 13:42:41 UTC**.
  After rescan, the selected playlist again showed 10 songs / 59:21 with Work
  metadata populated, without navigating away.
  Playback remained paused. These are functional live checks, not timing or
  audio-quality benchmarks; the earlier 0.88-second claim below is withdrawn.

## Issue #128 continuation: persistent metadata warm start (2026-09-04)

- The continuation branch wires the #146 schema through an actor-owned
  `LibraryMetadataStore`, scoped by normalized server/account identity. A
  verified ping is required before opening and reading a seed; disconnect and
  credential changes retire sessions while retaining disk data for a later
  reconnect. Accepted writes are serialized and best-effort.
- `LibraryModel` presents seeded songs, albums, artists, genres, playlists,
  and favorites before live requests. Successful live results replace or
  reconcile those rows while generation checks prevent stale sessions from
  repopulating the UI. A complete song walk is required before full-sync
  pruning; random fallback, cancellation, repeated pages, and failed pages
  remain non-authoritative.
- Full reconciliation is transactional and replays newer favorites/playlist
  writes over the fetched snapshot. Manual library scans poll until the server
  reports completion, then run the same complete refresh. No periodic timer or
  new network endpoint was added beyond `getScanStatus`.
- Hermetic store coverage includes disk reopen, account/API-key isolation,
  corrupt/unwritable roots, rollback, stale sessions, graph validation,
  deletion pruning, write replay, native-field preservation/clearing, and a
  14,000-to-7,000 song reconciliation. The independent Swift runtime suite
  passes **15 tests**; the earlier full app suite passed **398 tests,
  0 failures, 0 skips** (canonical `xcresulttool` summary at
  `/tmp/hydrophone-128-final.xcresult`). SwiftLint is clean and
  `git diff --check` is clean. The unsigned app build passes; only the normal
  no-AppIntents metadata notice is emitted.
- Live verification: 2026-09-04, Tim's configured Navidrome server, exact
  executable `/private/tmp/hydrophone-128-dd-escalated/Build/Products/Debug/Hydrophone.app`.
  First branch launch showed the connected library while the walk progressed
  (6,500 songs visible), later reaching **14,231 songs loaded**. The previously
  recorded 0.88-second warm-relaunch estimate is withdrawn: that operation
  inspected the existing process rather than establishing a restart.
  The server-scoped store was nonempty at
  `~/Library/Caches/app.hydrophone/Metadata/.../metadata.store` (**14,393,344
  bytes**). No audio claim was made during this metadata check.

## Issue #146: versioned metadata schema foundation (2026-09-04)

- Adds `MetadataSchemaV1` (1.0.0) and `MetadataMigrationPlan` with six cached
  entity families. #128 is now started; production store lifecycle and reads/
  writes remain in #147–151. No launch-speed improvement is claimed by #146.
- Preserves every current Song/Album/Artist/Genre/Playlist value field,
  including Song's native work/movement/bit-depth fields that its wire
  `CodingKeys` omit. Nested metadata uses explicit JSON attributes; decoding
  corruption or missing referenced rows rejects the seed rather than dropping
  credits/tracks silently. Sync bookkeeping maps to `LibrarySyncSnapshot`.
- Stores exact server IDs (genre name for genres; collection key for sync),
  explicit relationship ordering, repeated playlist entries, and unfetched
  versus fetched-empty detail. Deleting an album/playlist does not cascade
  into shared songs. Models stay context-confined; only Sendable values cross
  actor boundaries.
- `MetadataRecords` supplies context-confined upsert mapping, with no save,
  network, container lifecycle, or scheduling. It reuses canonical records
  before linking graphs: implicit SwiftData unique merging of separate album/
  playlist graphs failed on SQLite. The corrected disk round-trip and pending
  overlapping-graph tests cover that case. Inputs map complete represented
  snapshots; partial-fetch merge and transaction policies belong to #149.
- Added 16 tests covering rich/sparse values, disk reopen through the v1
  migration plan, all stable keys, ordering, duplicate entries, deletion
  safety, invalid seeds, and a ModelActor value boundary. The pending-graph
  case runs against both memory and disk stores after read-only review.
- Verification: unsigned app build succeeds with **zero warnings**; full suite
  **375 tests / 396 executions, 0 failures, 0 skips** (canonical
  `xcresulttool` top-level count, `/tmp/hydrophone-146-final.xcresult`);
  SwiftLint **0 violations in 152 files**; `git diff --check` clean.
  Baseline was 359 tests; its clean test compilation emitted a pre-existing
  `ArtworkCacheTests.swift:223` weak-variable warning. Final test run emitted
  only the no-AppIntents-dependency tooling notice, no compiler warnings.
- Live regression smoke: 2026-09-04, Tim's configured Navidrome server,
  exact worktree build verified by executable path. Launch walk reached
  **14,231 songs**; Brad Mehldau's *After Bach* loaded **12 songs / 69:16**
  with composer metadata. Played *Before Bach: Benediction*, observed
  **0:09 / 5:25**, **ALAC 16/44.1k**, and Pause state, then paused playback.
  No audio-quality claim beyond the observed stream/progress state.
- The repository's configured Developer ID certificate was unavailable;
  live verification used build-command-only ad-hoc signing overrides. No
  project signing settings changed. No production metadata container opens
  in this foundation PR; schema persistence is verified by hermetic tests.

## Issue #141: implement song-index consolidation & cache abstraction (2026-09-04)

- Implements #140's design decision exactly, with one correction found during
  live verification (below). Closes out the #125 audit epic (#118, #124,
  #139, #140, #141).
- New `Services/LibrarySongIndex.swift`: single owner of both full-library
  walks (Subsonic `search3`, native `/api/song`), replacing the hand-rolled
  cache/generation/in-flight state previously split across
  `SubsonicClient.cachedAllSongs` and `NavidromeClient.cachedSongIndex`. One
  entry point, `allSongs(onProgress:)`, now performs the native
  work/movement/bitDepth join itself before returning, instead of
  `LibraryModel` calling the walk and the join as two separate steps.
- New `Services/CredentialScopedCache.swift`: the generic credentials-guard +
  generation-counter + in-flight-coalescing + explicit-invalidate primitive,
  adopted by `LibrarySongIndex`'s two caches and by
  `NavidromeClient`'s token cache (fixing a minor thundering-herd gap there —
  concurrent callers under a cold token now coalesce onto one `login()`).
- `SubsonicClient`/`NavidromeClient` reverted to pure transport actors;
  `NavidromeClient` gained a pinned `paginatedGet(...using:as:)` overload so
  the native walk (and its 401 retry) can pin one credential snapshot across
  its whole walk, mirroring `SubsonicClient.perform(_:using:)`.
- `LibraryModel`'s six single-shot collections (artists/composers/genres/
  starred/home/playlists) and `albums`'s pagination state now share one
  `librarySessionGeneration` counter, bumped by `reset()` — **not**
  `CredentialScopedCache` as #140.2 originally decided; implementing it
  surfaced that wrapping `@MainActor`/`@Observable` UI state in an
  actor-based cache reintroduces a loading flicker on every tab revisit for
  no correctness benefit a plain generation guard doesn't already give. The
  actual #139 fix is `ConnectionModel`'s composition-root wiring calling
  `library.reset()` (which already cleared every collection correctly) on
  disconnect/credential-change/scan, instead of the narrower
  `invalidateSongs()` it called before — that one-line wiring change is what
  stops switching servers from showing stale Albums/Artists/Composers/
  Genres/Favorites/Home/Playlists. A library scan now also invalidates those six
  collections, which it didn't before.
- Review follow-up: `reset()` now clears playlist listing; playlist reloads
  and the Home Random re-roll discard completions from a retired session.
  Home, Genres, Favorites, and playlist listing use generation-owned in-flight
  identities so an old server's suspended request cannot block the first load
  after credentials change. `LibrarySessionInvalidationTests.swift` holds real
  loader responses at `URLProtocol` and covers all six regressions.
- `ConnectionModel`'s invalidation hook, `invalidateLibrary()`, and
  `disconnect()` all became `async` — required so `reset()` can `await` its
  actor-cache invalidation directly rather than fire-and-forget it, closing a
  real race (a `disconnect()` immediately followed by a fresh fetch could
  otherwise read stale actor state). `SettingsView`'s Disconnect button wraps
  the call in `Task { await ... }`, matching its sibling buttons.
- Full docs/05-data-and-caching.md rewrite of the #139 inventory and #140
  decision sections to describe the shipped architecture (owners, resolved
  invalidation gaps, the `librarySessionGeneration` pivot and why).
- New tests: `CredentialScopedCacheTests.swift` (hermetic, endpoint-agnostic —
  cache-hit reuse, credential-mismatch rebuild, concurrent coalescing,
  invalidate, stale-completion guard, uncacheable-result-not-cached);
  `LibraryModelResetTests.swift` (proves `reset()` clears Favorites/Home and
  bumps the shared generation — the direct regression test for #139's
  finding). Existing `SubsonicAllSongsTests`/`NavidromeClientNetworkTests`/
  `NavidromeSongIndexNetworkTests`/`NavidromeComposerSongLookupTests`/
  `ConnectionModelNativeFeaturesTests` cases migrated to target the new
  types; same assertions, reused mock infrastructure.
- **Live-verification finding (real bug, fixed before landing):** the first
  implementation made `LibrarySongIndex` an actor. Live-testing against
  Tim's real ~14,000-track Navidrome server surfaced that this reintroduced
  the exact blocking #124 fixed — opening a playlist while the Songs tab's
  eager Subsonic walk was running made the playlist's non-blocking native
  join wait behind it, because entering `LibrarySongIndex`'s own actor
  serialized both walks against each other even though their two
  `CredentialScopedCache`s were independently isolated. `LibrarySongIndex`
  holds no mutable state of its own, so it didn't need to be an actor at
  all; converting it to a plain `final class: Sendable` removed that
  serialization point. No hermetic test caught this — it needed real
  concurrent load against a real server to surface. Confirmed fixed by
  re-testing after the change.
- **Live-verification findings (confirmed pre-existing, not regressions):**
  with temporary timing instrumentation (since removed), confirmed (a) the
  native `/api/song` walk itself took ~30–40s against Tim's real library —
  unrelated to this change, walk logic untouched, matches #124's already-
  documented cold-cache-walk cost; (b) concurrent callers (three playlists
  opened mid-walk plus the Songs tab's own join) correctly coalesced onto
  the one walk rather than each starting their own (confirmed by identical
  completion timestamps across differing per-caller wait durations); (c) a
  Songs-tab revisit after the walk completes produces zero new cache/network
  activity (confirmed via the same instrumentation showing no log output),
  so a separately-reported "~1s tab click" lag is unrelated to this layer —
  most likely AppKit track-table rendering cost for 14,000+ rows, out of
  scope here. Tim independently confirmed the overall feel matches
  pre-#139 `main`.
- Gate: unsigned build succeeds; Xcode emits only its known duplicate-
  destination and no-AppIntents-dependency notices. Full suite passes (**359
  test cases / 379 executions, 0 failures/skips** — 14 cases more than #139's
  baseline, all new); SwiftLint 0 violations across 140 files. Live:
  2026-09-04, Tim's real
  configured Navidrome server — Songs tab, playlists (opened both during and
  after the Songs walk), and the actor-contention regression/fix cycle above
  all verified by hand. Review-fix follow-up live-verified the candidate Debug
  build against `demo.navidrome.org`: Home, Genres, Favorites, and three
  playlists loaded after a cold session start; the Random shelf refresh
  replaced its album set. The held-response tests above cover the credential-
  switch timing that a public server cannot make deterministic.

## Issue #140: song-index consolidation & cache-abstraction design decision (2026-09-04)

- Docs-only, no code changes (explicit non-goal). Part of the #125 audit epic,
  depends on #139 (landed as PR #142); precedes #141 (implementation).
- `docs/05-data-and-caching.md` gained a "Design decision (#140)" section,
  recording an explicit architectural decision so #141 can implement without
  reopening it:
  - **Keep two full-library walks** (Subsonic `search3` and Navidrome-native
    `/api/song`) rather than collapsing to one — `docs/02` confirms
    work/movement, bit depth, and composer credit *ids* exist only in the
    native response, and the native walk is unavailable on non-Navidrome/
    API-key-auth servers, so neither walk can subsume the other. Rejected
    making the native-derived `NativeSongRecord.asSong()` the Songs tab's
    primary source for Navidrome users: two of its fields (`coverArt`,
    `contentType`) are derived approximations never exercised at full-library
    scale today, a correctness risk on the app's one universal list.
  - **Unify both walks behind one new interface**, `LibrarySongIndex`,
    replacing the split cache/generation/in-flight state currently hand-rolled
    across `SubsonicClient.cachedAllSongs` and `NavidromeClient.cachedSongIndex`,
    with the work/movement/bitDepth join folded into its single `allSongs()`
    entry point instead of `LibraryModel` calling both separately.
  - **Build one generic cache primitive**, `CredentialScopedCache<Value>`,
    and adopt it for `LibrarySongIndex`'s two walks, `NavidromeClient.cachedToken`
    (fixes a minor thundering-herd gap — no generation/coalescing today), and
    `LibraryModel`'s single-shot collections (artists/composers/genres/
    starred/home). The last one directly fixes the gap #139 found
    (`LibraryModel.reset()` unwired in production) — once those collections
    self-invalidate on credential mismatch, switching servers no longer
    leaves stale data behind. Explicitly *not* adopted for `formPostSupport`
    (different scope key) or `LibraryModel.albums` (incremental/paginated,
    not a single cached blob) — differing policies, kept bespoke.
  - **Warm-up ownership stays as today**: Subsonic walk eager at connect
    (#118), native walk lazy/on-demand (#124) — reaffirmed with reasons
    rather than reopened, since #124 already weighed and declined eager
    native warm-up and nothing new here overturns that call.
  - **#128 unchanged in relationship**: still session-only vs. persistent;
    #128 would plug into `LibrarySongIndex`'s single join point rather than
    duplicating it.
  - Recorded rejected alternatives, a concrete file-level migration surface,
    and a test contract (including a new regression test that credential
    changes invalidate the LibraryModel collections without `reset()`) for
    #141 to implement against.
- Gate: docs-only change, no source touched, but the full gate was still run
  as a sanity check. Unsigned build succeeds with zero warnings; full suite
  passes; SwiftLint clean. No live verification applicable — no runtime
  behavior changed.

## Issue #139: library metadata-cache lifecycle inventory (2026-09-04)

- Docs-only, no code changes. Part of the #125 metadata-caching audit epic;
  precedes #140 (design) and #141 (implementation).
- `docs/05-data-and-caching.md` gained an "In-memory metadata caches
  (inventory)" section: a lifecycle matrix covering every credential-scoped
  and session-scoped cache/load-state in `SubsonicClient` (`cachedAllSongs`,
  `formPostSupport`), `NavidromeClient` (`cachedToken`, `cachedSongIndex`),
  and `LibraryModel` (albums/artists/composers/genres/starred/home/songs),
  with scope, warm trigger, coalescing, invalidation, and retry/failure
  behavior for each, plus a classification (authoritative/derived/
  capability/view-state).
- Flagged for #140's design pass: the `cachedAllSongs`/`cachedSongIndex`
  duplicate-walk overlap (already known from #125), the repeated
  cache+guard+generation+coalescing shape hand-rolled three times, and an
  invalidation-consistency table showing `cachedSongIndex`/`cachedToken`
  have no explicit disconnect/credential-change invalidation (harmless today
  only because of the credential-mismatch fallback).
- New finding not previously tracked: `LibraryModel.reset()` — which clears
  albums/artists/composers/genres/starred/home — is wired nowhere in the
  running app (only in test teardown), so none of those collections are
  invalidated on disconnect or server/account change; they show the previous
  server's data until independently reloaded, which most never are. Left for
  #140/#141 to decide the fix; not touched here (no-behavior-change scope).
- Documented how this in-memory layer relates to #128's persistent-cache
  proposal: orthogonal (session-only vs. cross-launch), but #128 should
  inherit the same invalidation triggers rather than rediscovering them.
- Gate: docs-only change, no source touched, but the full gate was still run
  as a sanity check. Unsigned build succeeds with zero warnings; full suite
  passes (365 passed, 0 failed, 0 skipped); SwiftLint 0 violations across
  134 files. No live verification applicable — no runtime behavior changed.

## Issue #124: playlists render before the native work-info join (2026-09-04) ✅

- `PlaylistDetailView.reload()` previously made one blocking
  `await library.playlist(id:)` that included the native work/movement/
  bit-depth join, so opening a playlist paid for a full cold
  `songIndexSnapshot()` walk (`/api/song`, paginated) before any track could
  render — a completely separate cache from the Subsonic `allSongs()` walk
  that #118 made eager (docs/02).
- `LibraryModel.playlist(id:)` is now the fast, unjoined fetch (the
  playlist's own entries only); a new `LibraryModel.joinWorkInfo
  (intoPlaylist:)` applies work/movement/bit-depth as a non-blocking
  follow-up pass, mirroring `allSongs()`'s partial-publish pattern.
  `PlaylistDetailView.reload()` renders immediately after the fast fetch,
  then updates `playlist` again once the join resolves.
- Deliberately picked "render immediately, join non-blocking" over the
  issue's other suggested direction (eagerly pre-warming
  `songIndexSnapshot()` at launch alongside #118's Songs walk) — the chosen
  fix resolves the literal blocking complaint regardless of cache warmth,
  and doesn't add a second concurrent full-library walk to every app launch.
  Pre-warming the native index remains a legitimate follow-up (noted in the
  PR), not folded in here.
- `LibraryModelWorkInfoJoinTests`'s playlist coverage split into two tests
  matching the new two-phase contract: the fast fetch carries no work info
  and makes zero `/api/song` calls, and `joinWorkInfo(intoPlaylist:)`
  correctly enriches an already-loaded playlist.
- Gate: unsigned build succeeds with zero compiler warnings; full suite
  passes (345 cases / 365 executions, 0 failures, 0 skips); SwiftLint 0
  violations.
- Live (2026-09-04), Tim's configured real Navidrome server: opened a
  10-song playlist with a cold native-index cache and all tracks rendered
  instantly with their standard metadata. The added `Work` column populated
  a few seconds later with the expected tagged and untagged values, with no
  re-render delay or missing-track flash.
- Review follow-up: a per-view load generation now prevents a superseded
  fetch or delayed enrichment from overwriting a newer playlist or an
  optimistic reorder/removal. A rendered, gated-network regression reproduces
  the stale overwrite and verifies that the optimistic row set remains intact.
- Review follow-up live smoke (2026-09-04), Tim's configured real Navidrome
  server: the exact DerivedData candidate reopened the same 10-song playlist
  with every row, standard metadata, and expected work values intact. No live
  playlist mutation was performed.

## Issue #113: "Go to Album" fetched the same album twice (2026-09-04) ✅

- `AlbumDetailView.task(id:)` always re-ran `getAlbum` from scratch, even when
  the caller had already fetched the full `Album` (with its song list) just to
  navigate there — both "Go to Album" call sites (`TrackTableView.swift`'s
  track context menu, `RootView.swift`'s Show Current Album handler) do
  exactly that. Now the view uses the caller's `album.song` directly when it's
  already populated, and only fetches when it's `nil` — the case for the four
  list-sourced `openAlbum` call sites (Albums grid, Artists page, Home
  shelves, Up Next shelf), which are unaffected.
- Gate: unsigned build succeeds with zero compiler diagnostics; full test
  suite passes; SwiftLint 0 violations.
- Live (2026-09-04): the configured Navidrome server (14,231 songs loaded).
  Right-clicked "Nightingale" (Norah Jones) in Songs → Go to Album; the
  album page for *Come Away With Me* rendered all 14 tracks immediately.
  Temporary stderr instrumentation on the request path confirmed a single
  `getAlbum` call followed only by the unrelated `getStarred2` (favorite-state
  check) — no duplicate fetch. Instrumentation was removed before committing.

---

## Issue #134: balanced transport/volume toolbar bubble padding (2026-09-04) ✅

- Replaced the transport's one-sided 16pt leading inset and the volume/panel
  cluster's one-sided 16pt trailing inset with 8pt horizontal padding. Each
  toolbar item retains the same 16pt total inset, so the system-drawn bubble
  widths and the established transport, loading-status, centered-LCD, and
  trailing-item layout remain unchanged while the controls sit centrally
  inside their bubbles.
- Test seam: macOS owns the toolbar bubble chrome and does not expose stable
  geometry to a hermetic unit test. With Tim's approval, this targeted visual
  correction uses before/after app captures instead of a contrived source-text
  assertion; the existing automated suite remains the regression gate.
- Gate: unsigned build succeeds with zero compiler diagnostics; full suite
  **341 test cases / 361 executions, 0 failures/skips** (canonical xcresult
  summary); SwiftLint 0 violations and `git diff --check` passes.
- Live (2026-09-04): uniquely named baseline and candidate builds against the
  configured Navidrome server verified light and dark appearances at the
  default 1,180pt and minimum 1,000pt window widths, with the Now Playing panel
  both closed and open and the library status idle/loading. The controls moved
  8pt toward each bubble's visual center without changing bubble or LCD
  placement. The pre-existing minimum-width loading-status/transport overlap
  is unchanged and remains outside #134.

## Issue #118: Songs library walk now starts at launch, not on first visit (2026-09-04) ✅

- `AppModel` now wires `ConnectionModel`'s successful persisted-connection
  lifecycle to `library.loadSongsIfNeeded()`. Both launch-time `refresh()` and
  later `saveAndConnect()` calls await that hook after the native-feature
  probe, so the all-songs walk (`search3`, paginated to exhaustion per `05`)
  starts regardless of which sidebar section is visible — including first-time
  setup and reconnects after an initially unconfigured or failed launch.
  `loadSongsIfNeeded()` remains idempotent via `songsState`, so a concurrent
  per-selection request from Songs still coalesces onto one walk.
- Hermetic `ConnectionModelNativeFeaturesTests` regressions compose the real
  connection, app, and library models over a stubbed HTTP boundary. They prove
  both a saved-credential launch refresh and a first `Save & Connect` complete
  one eager `search3` walk without relying on `RootView` appearance.
- Deliberately out of scope (flagged in the issue's own follow-up comment):
  the separate native `/api/song` index walk that `NavidromeClient.
  songIndexSnapshot()` feeds to playlists/Composers/work-grouping — that's
  issue #124's fix to design, not this one's.
- Gate: unsigned build succeeds with zero compiler warnings; full suite passes
  343 test cases / 363 executions with 0 failures and 0 skips; SwiftLint 0
  violations; `git diff --check` clean.
- Live (2026-09-04), Tim's configured real Navidrome server: with
  `sidebarSelection` forced to `artists` (never visiting Songs), a fresh
  launch of the exact Debug build showed the toolbar's "N songs loaded" pill
  climbing to the full 14,231-song count within a few seconds while the
  Artists list was on screen — confirming the walk starts eagerly at launch
  rather than waiting for a Songs visit. Repeated across several relaunches
  restarting the walk from scratch each time (in-memory cache dies with the
  process, per `05`), never regressing to the old click-to-start behavior.
  Note for future live-verification: this Debug build (`CODE_SIGNING_ALLOWED=NO`,
  effectively unsigned) reads `~/Library/Preferences/app.hydrophone.plist`
  directly, not the sandboxed container copy the notarized release uses —
  `defaults write app.hydrophone …` silently redirects to the container path
  instead, so forcing `@AppStorage` values for a Debug-build test needs the
  explicit plain-path `defaults write ~/Library/Preferences/app.hydrophone.plist`
  form (or a uniquely bundle-ID'd probe build, as issue #102 did below).
- Review-fix live recheck (2026-09-04), public Navidrome demo: launched the
  actual Debug app with `HYDROPHONE_SCREENSHOT_FRESH=1` so the real Keychain
  remained untouched, selected Artists before connecting, and used the first-
  time Demo Server flow. Without opening Songs, the toolbar showed "Loading
  songs…", advanced to "500 songs loaded", and then cleared when the complete
  walk finished.
## Issue #102: library-loading spinner moved into the top toolbar (2026-09-04) ✅

- The "Loading songs…" / "N songs loaded" status no longer renders in a
  bottom overlay on the Songs page. `LibraryLoadingStatus` now reads
  `LibraryModel.songsAreLoading` and renders in a fixed-width pill between the
  transport cluster and LCD. RootView draws the pill as a leading overlay
  outside `NowPlayingDisplay`'s measured bounds, leaving the LCD as the sole
  centered principal toolbar item; the transient status therefore cannot
  shift either neighboring control. The underlying app-wide state keeps the
  status correct regardless of which page is on screen and reserves no space
  when loading is idle.
- The Songs page keeps its own centered placeholder (`SongsLoadingProgress`,
  reused) for the moment before the first page is renderable — unrelated
  per-view empty-state UI, same pattern `AlbumsView` uses for `albumsState`.
- Gate: unsigned build succeeds with zero compiler diagnostics; full suite
  **324 test cases / 344 executions, 0 failures/skips** (canonical xcresult
  summary); SwiftLint 0 violations and `git diff --check` passes.
- Live (2026-09-04): a uniquely named probe build
  (`HydrophoneIssue102Probe`, bundle ID `app.hydrophone.issue102probe`) against
  the configured Navidrome server removed any ambiguity with other open
  Hydrophone builds. Opening Songs showed the pill count through 3,500,
  12,500, and 14,231 loaded songs between the unchanged transport and LCD.
  Loading and idle captures at the same 1,180pt window width confirmed the LCD
  keeps the same horizontal position when the pill appears or disappears. The
  transport/volume bubble-padding polish remains deliberately out of scope.

## Issue #106: bit depth/sample rate in the Now Playing quality badge (2026-09-03 – 2026-09-04) ✅

- Confirmed live against demo.navidrome.org that Navidrome's native `/api/song`
  carries a `bitDepth` field (present on FLAC and ALAC-in-`.m4a` records,
  absent on lossy suffixes) that plain Subsonic never exposes — the open
  question the issue flagged.
- Added `bitDepth` to `NativeSongRecord` and `Song` (native-only, joined
  post-fetch, same convention as work/movement). `NavidromeClient.bitDepths(forSongIds:)`
  mirrors `workInfo(forSongIds:)`'s cache-reuse shape; `LibraryModel.joinWorkInfo(into:)`
  now joins both onto the same six track-table sources.
- `Song.qualityDetailLabel` now always names the codec, splitting on a 320
  kbps threshold rather than a lossless-suffix list: above it, with a bit
  depth and sample rate both reported, format name + "24/96k"; at or below
  it, or missing either field, format name + bit rate ("AAC 256 kbps", "MP3
  192 kbps"). The threshold doubles as an ALAC/AAC resolver for `.m4a`/`.m4b`,
  which the suffix alone can't distinguish. The Quality column (`qualityLabel`)
  is unchanged — Tim's live-review feedback on the first round drove this
  reshape from the original lossless-only "24/96k" (no codec name).
- Split `NavidromeClient`'s composer/song-lookup extension into
  `NavidromeClient+SongLookup.swift` to stay under the file-length lint after
  the new method landed.
- Gate: unsigned build passes with zero compiler warnings; full suite
  **333 test cases / 353 executions, 0 failures/skips**; SwiftLint 0
  violations.
- Live (2026-09-03): the configured Navidrome server (14,327 songs) played a
  FLAC track ("String Quintet in C Major, Op. 163, D. 956") whose Now Playing
  badge read "24/48k" (pre-refinement format).
- Live (2026-09-04, post-refinement): the same server (14,231–14,327 songs
  across two loads) showed **"FLAC 24/192k"** for a Mahler symphony FLAC track
  and **"AAC 603 kbps"** for a high-bitrate `.m4a` track that has no reported
  bit depth — confirming both the codec-name-always behavior and the
  threshold-gated ALAC/AAC resolution.

## Issue #103: Performers/Conductor rows in Get Info (2026-09-03)

- Data-availability check first, as the issue asked: checked Navidrome's own
  source (`model/participants.go`) and the OpenSubsonic spec. `performer` and
  `conductor` are real Navidrome participant roles, carried on every regular
  `getAlbum`/`getSong` response via the standard OpenSubsonic `contributors`
  array (role + optional subRole, e.g. an instrument for performer) — no
  native walk needed, unlike work/movement. `ensemble` does not exist
  anywhere in Navidrome: not a participant role, not a tag mapping
  (`resources/mappings.yaml` has no ensemble entry either). Scope dropped
  Ensemble as a result — there is no field to surface for it.
- Added `Song.contributors: [Contributor]?` (decoded from OpenSubsonic
  `contributors`) plus `nonEmptyDisplayPerformer`/`nonEmptyDisplayConductor`
  computed properties that filter+join by role, same "Name (subRole)"
  convention `displayComposer` uses. `NativeSongRecord+Song.swift` synthesizes
  the same `contributors` shape from `participants.performer`/`.conductor` so
  Songs built via the Composers-roster native path (bypassing regular
  Subsonic fetch) show the same rows. Two new `TrackInfoView` rows,
  Composer-pattern (`LabeledContent` + `SelectableText`, hidden when absent).
- Build clean (zero warnings), full test suite passes, swiftlint clean (one
  `ContributorDecodingTests.swift` split out of `DecodingTests.swift` to stay
  under the 250-line type-body-length rule).
- Live-verified against Tim's real Navidrome server (not just the demo
  server, whose ~500-track library has zero performer/conductor tags
  anywhere — checked via the native `/api/song` walk): Get Info opened
  cleanly on a real classical track (Schubert "Ava Maria", Rochester
  Philharmonic Orchestra) — Composer row correct, no crash, no broken
  Performer/Conductor row when those tags are absent. Did not find a track in
  the browsed library with actual performer/conductor tags to confirm the
  populated-row path live; that path is covered by unit tests
  (`ContributorDecodingTests`, `NativeSongMappingTests`) built against the
  exact JSON shape confirmed from Navidrome's source and the OpenSubsonic
  spec, not by live observation.

---

## Issue #120: work header and movement grouping for single-work albums (2026-08-31) ✅

- `TrackTableRow.build` and `Coordinator.workHeaderGroupingActive`
  (`MusicTrackTable.swift`) gated work-header grouping on `works.count > 1`,
  so an album where every track shares the same tagged Work (a whole
  symphony, opera, or song cycle) never got a work-header row or the
  movement-title formatting (`WorkMovementTitle.titleForRow`) that
  multi-work albums get. Both gates now trip on `!works.isEmpty` instead, so
  a single-work album gets one header of its own — its title isn't
  necessarily redundant with the album title — and its tracks get the same
  movement-title treatment.
- `groupedRows` already emitted exactly one header when every track shares
  the same key, so no change was needed there. One consequence worth noting:
  a single Work spanning multiple discs now gets a single header (folding in
  only the first disc's number) instead of per-disc headers with any
  server-supplied disc subtitle — the same "fold the key's first disc into
  the header" behavior multi-work multi-disc albums already had.
- Updated `docs/04-ui-ux.md`'s work-grouping section to state the new
  contract (previously "albums with zero or one Work retain the existing
  disc-header behavior unchanged" — now only *zero* tagged Works do).
- `DiscHeaderTests` gained cases for a single-work single-disc album, a
  single work spanning two discs (dropping the disc-header fallback), and a
  lone tagged track amid untagged ones (grouping now applies, spacers
  included). `oneWorkKeepsExistingDiscHeaders` and `noSpacerWhenNoGrouping
  Applies` were rewritten for the new behavior; a stale comment in
  `WorkHeaderDoubleClickTests` was corrected.
- Gate: unsigned build clean, zero compiler warnings; full suite **326 test
  cases / 346 executions, 0 failures/skips**; SwiftLint 0 violations across
  131 files.
- Live (2026-08-31), Tim's configured real Navidrome server (via the signed
  Debug build sharing his Keychain credentials): *Variations on a Melancholy
  Theme* (Brad Mehldau) — the exact single-Work album #47's live
  verification (2026-08-24 entry) recorded as "remained headerless" — now
  shows one **Variations on a Melancholy Theme** header above its 15 tracks,
  with movement-stripped titles (`Theme`, `Variation 1`… `Variation 11`,
  `Cadenza`, `Postlude`, `Encore: Variations "X" & "Y"`). No credentials were
  read, logged, or copied.

## Issue #108: double-click column-divider autosizing (2026-08-30) ✅

- Double-clicking a resizable track-table divider now fits that column to its
  header or widest row in the complete currently displayed track model,
  including offscreen rows and the nested Quality badge label, while honoring
  the column's existing minimum and maximum width.
- The fit scans display strings rather than row views, so a large library gets
  complete-column accuracy without creating offscreen cells. It reuses the
  rendered cells' text, font, and padding rules, including monospaced
  numeric/date columns. Ordinary divider dragging, header sorting/reordering,
  horizontal overflow, and adjacent-column widths remain unchanged. Autosized
  widths use the existing debounced per-view persistence.
- Eight rendered AppKit regressions cover visible Title text, compact and
  maximum-width Quality badges, header precedence, empty tables, convergence
  on an offscreen widest row from both too-narrow and too-wide starting widths,
  exact monospaced date metrics, min/max clamping, no offscreen view creation,
  and restoration in a recreated table. Gate: unsigned build passes with zero
  compiler warnings; full suite **324 test cases / 344 executions,
  0 failures/skips** (canonical xcresult summary); SwiftLint 0 violations and
  `git diff --check` passes.
- Live (2026-08-30): an ad-hoc-signed temporary copy of the exact Debug build
  loaded **14,327 songs** from the configured Navidrome server. From a
  deliberately too-narrow state, double-clicking the Title divider expanded
  it to the full-library widest title in about 0.6 seconds; playback and Up
  Next stayed unchanged. The temporary process was closed with the original
  width preferences intact. The too-wide convergence is covered by the
  rendered AppKit regression. The local Developer ID private key was
  unavailable, so project signing settings were not changed.

## Issue #104: independent track-table column resizing (2026-08-30) ✅

- Track tables now use independent AppKit column sizing, so widening a column
  keeps every neighboring width unchanged and expands the table content to the
  right instead of redistributing the added width.
- Enabled horizontal scrolling for overflow while preserving the shared header
  divider tracking, column picker, reorder behavior, and per-view width/order
  persistence.
- Added rendered AppKit regressions that drive the real header drag loop and
  assert neighbor widths, expanded document width, the no-autoresize policy,
  and horizontal scrolling. Gate: build passes with zero compiler warnings;
  full suite **316 test cases / 336 executions, 0 failures/skips**; SwiftLint 0
  violations and `git diff --check` passes.
- Live (2026-08-30): the configured Navidrome server rendered the 14,327-song
  library. Expanding Title by 250pt left Artist unchanged, pushed later columns
  right, and exposed a working horizontal scroll range; the width persisted
  after leaving and returning to Songs. The original Title width was restored.

## Composers/Artists list spacing and separator polish (2026-08-28) ✅

- The Composers and Artists roster rows read as too tight together, with a
  row separator that was too dark.
- Added 3pt of vertical padding per row, lightened the row separator
  (`.listRowSeparatorTint`, ~25% lighter than the system default), and
  lightened the trailing track/album count text (`.tertiary` unselected,
  `.white.opacity(0.6)` selected — down from `.secondary`/`0.8`). An
  interim attempt to hide the count below 2 was tried live and reverted in
  favor of the lighter color alone.
- Gate: build passes with zero warnings; full suite **311 test cases / 331
  executions, 0 failures/skips**; SwiftLint 0 violations.
- Live: Tim reviewed the running app against his connected library across
  several rebuild/relaunch iterations and confirmed the final spacing and
  color result.

## Track table column divider resize cursor (2026-08-28) ✅

- Track table column headers (Songs, Album detail, Favorites, column browser,
  playlists, search) never hinted that a divider was draggable — no cursor
  changed on hover. AppKit's native resize hit zone turned out to be only a
  few points wide with no cursor of its own, and raw `resetCursorRects`/
  `addCursorRect` don't reliably fire on AppKit content hosted inside SwiftUI
  (this app's own `PanelResizeHandle` already worked around the same
  limitation with tracking areas + `NSCursor.push()/pop()`).
- `InnerTableHeaderView` now derives a shared 16pt hit zone around each
  resizable column's trailing divider (`dividerZones()`), used by both the
  hover cursor (tracking areas) and the resize itself (a manual drag loop in
  `mouseDown`) so the two can never disagree — an earlier pass that widened
  only the cursor zone past AppKit's native, narrower resize hit-test caused
  clicks inside the wider zone to fall through into header-cell reorder-drag
  instead.
- Zones rebuild on `NSTableView.columnDidResizeNotification`/
  `columnDidMoveNotification`, not just the header's own layout pass — a
  column's width can change (persisted-width restore, the column picker's
  reconciliation) without the header view's own overall frame changing,
  since `uniformColumnAutoresizingStyle` keeps the total width fixed by
  redistributing the difference.
- Review follow-up: column-picker add/remove and native-column reconciliation
  now refresh divider tracking immediately after the table's structure
  changes. Header notification observers are owned only while the header is
  attached to a window, preventing duplicate callbacks across detach/
  reattach cycles.
- Added rendered AppKit regressions for picker removal and header observer
  lifetime. Gate: build passes with zero warnings; full suite **313 cases /
  333 executions, 0 failures/skips**; SwiftLint 0 violations and
  `git diff --check` passes.
- Live (2026-08-28): the configured private Navidrome server passed Test
  Connection and rendered the 14,117-song library. Removing Artist through
  the live picker reflowed the headers immediately, and the remaining Album/
  Composer divider resized normally; the original columns/order/width and Now
  Playing layout were restored afterward.

## Issue #84: complete-library column browser (2026-08-28) ✅

- The merged #81/#82/#83 work already supplies the browser with complete
  unfiltered songs and fully paginated genres. No API, playback, or filtering
  semantics were changed here.
- Added rendered browser coverage for metadata appearing after page one,
  a 503-track composer, real selection cascades, persisted selections after
  view recreation, All Genres during loading, and 14,082-song interaction.
- Reproduced an A → B → A race: the old A response overwrote the newer A
  result because `loadGenre` compared only the selected name. A view-local
  request generation now guards publication as well. The regression failed
  before the fix and passed after it.
- Synthetic Debug measurements on this Mac: initial browser render about
  0.29–0.31 seconds; composer click about 0.11 seconds (including AppKit
  rendering and the test polling interval). No pane cache was justified by
  these measurements or the responsive full-library live interaction.
- With Tim's approval, added an injected `AppModel` initializer so the browser
  fixture does not configure shared artwork/media state or restore a server
  queue. Normal app startup retains its existing wiring. A regression failed
  before this isolation fix and passes afterward. The fixture saves/restores
  browser preferences and cancels deferred scroll/column-width writes.
- Also with Tim's approval, fixed existing artwork-test teardown: reproducing
  the full-suite crash with all new browser tests excluded confirmed that an
  artwork retry could create a task after its session was invalidated. Fixtures
  now release held requests and drain cache work before session invalidation.
  Production artwork scheduling remains unchanged.
- Verified: unsigned build succeeds with zero compiler warnings; full suite
  passes **311 cases / 331 executions, zero failures or skips**; SwiftLint has
  zero violations and `git diff --check` passes. Focused browser coverage is
  7 cases / 10 executions including the existing parameterized selection test.
- Live verification (2026-08-28, configured private Navidrome server): a
  separately signed, isolated app loaded **14,117 songs**. Full-library Bach
  filtering, genre resets, Classical → Jazz → Classical, and artist/album
  filtering rendered responsive, matching rows. Relaunch restored the selected
  genre, artist, album, and composer with matching album tracks after loading.
  No playback or queue actions were performed; project signing settings and
  the user's running app were left unchanged.

## Issue #82 PR review follow-up: fallback no longer clobbers published progress (2026-08-28) ✅

- Fixed a bug found in `/code-review` on PR #98: when the eager `allSongs()`
  walk failed *after* already publishing partial pages via `onProgress`
  (e.g. `LibraryModel.songs` already showing thousands of real songs), the
  random-sample fallback in `buildAllSongs` silently replaced that partial
  render with an unrelated small random sample and reported success
  (`isComplete: false`, but the flag was never surfaced) — so the Songs
  list would visibly grow, then snap down to ~500 unrelated songs with no
  error shown.
- `buildAllSongs` (`Hydrophone/Services/SubsonicClient+AllSongs.swift`) now
  tracks, via a small private `ProgressMarker` actor, whether the walk
  published at least one page to its caller before failing. The
  random-sample fallback is used only for a failure *before* any progress
  was published (matching every existing tested scenario, since those all
  call `allSongs()` without `onProgress`); once progress has been
  published, the original error propagates instead. `LibraryModel`'s
  existing `.failed` handling in `loadSongsIfNeeded` already keeps the last
  good partial `songs` snapshot in that case ("Partial rows remain usable,
  but must not prevent a fresh attempt") — no caller-side change was
  needed.
- New hermetic coverage: `laterPageFailureAfterProgressPropagatesInsteadOfFallingBack`
  (`SubsonicAllSongsProgressTests.swift`) asserts the client throws rather
  than falling back once progress was published, and that
  `getRandomSongs.view` is never called; `failedPartialLoadKeepsPartialRowsInsteadOfARandomSample`
  asserts the `LibraryModel`-level outcome: 500 real partial songs retained,
  `.failed` state, no random-sample request. Existing fallback-on-immediate-failure
  tests (e.g. `laterPageFailureFallsBackToTheExistingRandomSample`, which uses
  plain `allSongs()` with no `onProgress`) pass unchanged.
- Verified: unsigned build succeeds with zero compiler warnings; full test
  suite passes (targeted `SubsonicAllSongsTests`/`SubsonicAllSongsProgressTests`
  run plus a full-suite run, both green); SwiftLint reports 0 violations.
  Live-verified the unaffected normal path only (the fix's own behavior is a
  failure-path change not reproducible against a healthy real server, which is
  why it's covered hermetically with mocked failure injection instead): a
  fresh launch against the live Navidrome server completed a full walk and
  rendered the Songs column browser with real data, no errors.
- Finding posted as an inline PR review comment on #98; fix committed to the
  same `issue-82-full-songs-view` branch per Tim's explicit go-ahead.

## Issue #82: incremental full-library Songs browsing (2026-08-26; verified 2026-08-28) ✅

- The complete `allSongs()` walk now publishes its first page and ordered
  later pages into `LibraryModel` while keeping the loading state active.
  Songs and the unfiltered column browser render partial rows with a live
  loaded-song count; native WorkInfo enrichment remains one final pass.
- First-visit Songs/browser sorting defaults to locale-aware Title ascending,
  with song-id tie-breaking. A saved user sort still wins. Deep scroll restore
  waits until enough rows arrive instead of clamping permanently to page one.
  User scrolling cancels a pending restore, and selected songs stay selected
  through new pages and final metadata-driven reordering. Failed partial loads
  remain retryable on the next visit.
  Shuffle All's separate fresh random-batch request remains unchanged.
- Tim approved including the column-browser All-row bug found during live
  testing. All Genres/Artists/Albums/Composers now use a concrete empty-string
  selection tag, so clicking All clears the filter through the existing
  cascade. Returning to All Genres clears any in-flight genre loading state.
- Rendered AppKit tests cover 14,082-row sorting, saved-sort precedence,
  deterministic equal titles, deep incremental scroll restoration, progress
  UI, All-row clicks, failed-partial retries, selection/playback identity, and
  user-scroll cancellation. The reset-click test fails with the original nil
  tags and passes with the fix; other item selections remain functional.
- Local verification rerun **2026-08-28**: unsigned build succeeds with
  **zero compiler warnings**; full
  suite **303 cases / 323 executions including parameters, 0 failures/skips**
  (canonical xcresult summary). SwiftLint reports **0 violations** and
  `git diff --check` passes. A fresh build emits only Xcode's non-compiler
  AppIntents metadata-extraction notice (no AppIntents.framework dependency).
  An earlier full run aborted in `ArtworkCache.fetch`/URLSession; the focused
  table suite and subsequent complete suite passed. No unrelated artwork code
  was changed.
- Earlier live verification, **2026-08-26, authorized private Navidrome
  0.63.2 server (host redacted)**: the isolated branch app rendered its first
  500 rows while loading, progressed to **14,128 songs**, and dismissed the
  count after the final metadata join. The flat table rendered Title-ascending
  rows. Mid-load resident memory was approximately **362 MiB**.
- Tim subsequently confirmed, **2026-08-26 on the same private Navidrome
  server**, the column-browser reset test and the deep-scroll
  restoration test: after scrolling roughly three-quarters down and relaunching,
  the completed library restores roughly the same position without snapping
  back after further scrolling. These confirmations resolve those two pending
  checks following the rebuilt app's earlier connection timeouts.
- Tim also confirmed that Title, Artist, and Album header sorting remains
  responsive across the full library, and two Shuffle All runs produce fresh
  mixes without changing the visible Songs list. No view cap was needed.
- Final pre-PR review added partial-failure retry, selection-identity, and
  pending-scroll-cancellation safeguards, all with failing-then-passing
  regression coverage. HTTP 502 responses blocked the 2026-08-26 live recheck;
  the server recovered and the final recheck **passed on 2026-08-28**.
- Final live recheck, **2026-08-28, same authorized private Navidrome server
  (host redacted)**: a fresh isolated build rendered 500 songs while loading,
  advanced to the current **14,117 songs**, and removed progress after the
  metadata join. A track selected before completion remained selected, and
  Get Info opened that same track. Scrolling during loading retained its
  position after completion with no snap-back. Composer filtering and clicking
  All Composers restored the unfiltered list. This recheck did not start
  playback or alter the queue; Tim's earlier Shuffle All confirmation stands.
- Project signing and saved connection settings are unchanged;
  the isolated local test copy uses ad-hoc signing with the app's existing
  sandbox/network entitlements because no Developer ID identity is available.

## Issue #81: load the complete song library (2026-08-26)

- The Songs view and unfiltered column browser now consume the ecosystem's
  empty-query `search3` all-songs primitive instead of a 500-song random
  sample. A 500-song probe is followed by six-at-a-time bounded page fetches;
  results return in offset order and stop at the first short page.
- The full result is coalesced and cached for one exact credential snapshot.
  Credential changes, disconnects, and successful library scans invalidate
  both the client cache and visible `LibraryModel` snapshot. Generation checks
  prevent retired client or model loads from publishing stale completions.
- Servers that reject the empty query, return no songs, fail on a later page,
  repeat ids, or ignore offsets fall back to the existing bounded
  `getRandomSongs` sample. Shuffle Library remains independently random.
- Hermetic tests cover endpoint parameters, page exhaustion/order,
  concurrency, cache reuse/coalescing, credential isolation, explicit/scan
  invalidation, stale-completion races, no-progress protection, and every
  fallback path. The former random-only load, stale model completion, and
  repeated-page regressions were each observed failing before their fixes.
- Independent read-only review found the stale `LibraryModel` completion and
  repeated-page loop risks; both findings were fixed and regression-tested.
- Final local gate: unsigned build succeeds with zero compiler warnings; the
  full suite passes **291 test cases / 307 executions
  including parameters, 0 failures/skips** (canonical xcresult summary).
  SwiftLint and `git diff --check` pass.
- Live verification: **2026-08-26, user-authorized private Navidrome 0.63.2
  server (host redacted)**. An isolated signed branch app loaded **14,082
  songs with 14,082 unique ids**; the complete walk plus the unchanged native
  WorkInfo join took **50.1 seconds**, and real rows rendered in Songs.
  Temporary count-only instrumentation was removed; credentials, playback,
  saved connection settings, and project signing settings were unchanged.
- **Follow-up `/code-review` pass on the open PR** found four correctness
  issues and split both oversized types into extension files:
  - A walk failure at any offset fell back to `getRandomSongs`, but
    `allSongs()` cached that fallback as the verified complete library, so a
    transient mid-walk failure could strand later callers on a stale random
    sample until an unrelated invalidation. `buildAllSongs` now tags its
    result `isComplete`; only a walk that reached exhaustion is cached — a
    fallback is still returned but leaves the cache empty so the next call
    retries the full walk. The existing fallback-triggers-on-any-failure
    tests (`laterPageFailureFallsBackToTheExistingRandomSample`,
    `repeatedFullPageFallsBackWithoutAnUnboundedWalk`) still pass unchanged.
  - The short-first-page fast path skipped the duplicate-id guard the
    multi-page path applies; a buggy server returning fewer than 500 songs
    with a repeated id would have shipped duplicate rows instead of tripping
    the decoding-error fallback. The guard now runs before either return.
  - `AppModel`'s `setSongsInvalidationHandler` closure captured `library`
    strongly while `library`'s own init closure captured `connection`,
    forming a two-way retain cycle inconsistent with the `[weak player]`
    pattern used lines later in the same initializer. Now `[weak library]`.
  - `SubsonicClient` and `LibraryModel` had each grown past the
    `type_body_length`/`file_length` warning thresholds and suppressed the
    lint instead of splitting, unlike `PlayerModel`'s established
    `+RemoteCommands`/`+Scrobbling`/`+PlayQueue` precedent. The all-songs
    walk moved to `SubsonicClient+AllSongs.swift` (also consolidating the
    5-property cache into two credential-tagged tuples) and the Songs
    load/invalidate lifecycle moved to `LibraryModel+Songs.swift`; both
    suppressions are gone and SwiftLint is clean without them.
  - Not changed: the fixed 6-way concurrent page fan-out (search3 has no
    total-count header to size batches against, unlike `paginatedGet`'s
    `X-Total-Count` walk) and the duplication between the two actors'
    hand-rolled `withTaskGroup` pagination loops — both are real but
    lower-priority, and reworking either risks the already-verified request
    counts the hermetic tests pin.
  - Local gate re-run after the fixes: build clean (zero warnings), full
    suite still **291 test cases / 307 executions, 0 failures**, SwiftLint
    **0 violations in 122 files** (previously 120, now +2 for the new
    extension files), `git diff --check` clean.
  - **Live verification not repeated for this pass.** The env-gated live
    tests (`NavidromeLiveTests`, `LiveDecodeTests`, `ComposerSongLiveTests`)
    require `HYDROPHONE_HOST/USER/PASS`, which this shell session has set,
    but `xcodebuild test` does not propagate them to the spawned test
    process here — confirmed by a throwaway gated test that recorded
    `HOST=nil` inside the process before being deleted — so those suites'
    "passed" results in this pass were silent no-ops, not real network
    contact. There is no GUI-automation path available in this session to
    repeat the original manual isolated-app check. The golden path is
    unchanged code-wise (same request shape, same `AllSongsOutcome.songs`
    returned on success) and is covered by the hermetic suite above, but a
    real-server check of Songs loading before merge is still owed.

## Issue #83: paginate genre songs to exhaustion (2026-08-26)

- `LibraryModel.songs(forGenre:)` now walks 500-song `getSongsByGenre` pages
  until the first short page, preserving response order and applying the
  existing native WorkInfo join once after the complete genre is assembled.
  The broader unfiltered `allSongs()` work tracked by #20 remains out of scope.
- Hermetic serialized URL-protocol tests cover a 1,003-song genre with exact
  offsets `0`, `500`, and `1000`, plus a two-song genre that stops after one
  request. Both regressions were observed failing against the former single
  100-song request before the implementation passed them.
- Independent read-only review found no critical or important findings. Two
  minor suggestions would harden future tests around later-page WorkInfo
  enrichment and rejecting an unexpected endpoint/genre; neither identified a
  production defect in this issue's implementation.
- Final local gate: unsigned build succeeds with zero compiler warnings; the
  full suite passes **275 test cases / 291 executions including parameters,
  0 failures/skips** (canonical xcresult summary). SwiftLint and
  `git diff --check` pass. Xcode emits the existing AppIntents metadata
  extraction notice, not a compiler warning.
- Live verification: **2026-08-26, user-authorized private Navidrome 0.63.2
  server (host redacted)**. Classical loaded exactly **7,384 tracks** in an
  isolated signed Debug app, and the table scrolled through its final rows.
  Temporary count instrumentation and the isolated app copy were removed;
  credentials and saved connection settings were unchanged.
- The OpenSubsonic and testing contracts now record the eager genre walk,
  exact request coverage, and current suite totals. The remaining column-
  browser limitation below is narrowed to the unfiltered all-songs sample.

## Issue #85: resolve composer songs without per-track requests (2026-08-26)

- `LibraryModel.songs(forComposer:)` maps the existing cached native records
  directly to `Song`, removing the six-way `getSong` fan-out. Composer
  filtering, source order, `missing=false`, cache invalidation, and the
  existing WorkInfo join are unchanged. No second library cache or #81
  dependency was introduced.
- Expanded optional native metadata covers table, playback, and Get Info
  fields, including fractional duration, composer subroles, ReplayGain,
  dates, genre/grouping, and sort title. Zero/empty values follow Subsonic
  omission semantics; malformed optional dates cannot discard the index.
  MIME labels match Navidrome's default map instead of macOS aliases.
  The legacy song-id artwork identity fetches the same bytes as the
  reference `getSong.coverArt`; album-id cache sharing is retained.
- Native star annotations seed rows, with loaded favorites and optimistic
  overrides taking precedence, including Get Info's direct star flag.
- Regression tests cover 600 songs over two native pages, repeat-cache
  reads, zero `getSong` calls even when that endpoint fails, metadata/work
  parity, favorite overrides, sparse/zero fields, malformed dates, format
  aliases, and partial ReplayGain. Request and metadata regressions were
  observed failing before their fixes. Independent read-only review found
  no remaining actionable findings.
- Final local gate: unsigned build succeeds with zero warnings; the full
  suite passes **273 test cases / 289 executions including parameters,
  0 failures/skips** (canonical xcresult summary). SwiftLint and
  `git diff --check` pass. Test compilation emits the existing AppIntents
  extraction notice, not a compiler warning. The opt-in live test also ran
  separately and passed; its ordinary no-op is not counted as live evidence.
- Live verification: **2026-08-26, user-authorized private Navidrome 0.63.2
  server (host redacted)**. Bach returned **596** rows and Beethoven
  **514**, each with **zero resolution `getSong` calls**. Three independent
  reference rows per composer matched metadata and artwork bytes. Cold
  Bach load, including the full native-index walk, took **44.873 s**;
  cached Bach took about **12 ms**, Beethoven's first mapped load **29 ms**,
  and cached Beethoven about **11 ms**. The cold index cost is not fixed
  or hidden by this change.
- Exact signed-app UI check: both lists displayed titles, albums, artists,
  durations and quality. Bach's Get Info showed the actual cover, composer,
  year/track/disc, format, bitrate, size, and a favorite surviving reload.
  The temporary favorite was restored and independently confirmed unstarred
  on the server. Bach's first fugue played with the timer advancing from
  **0:18 to 0:30**; Beethoven's first variation played from **0:06 to 0:14**.
  Playback was paused and the verification app closed. Local Developer ID
  command-line overrides and strict signature verification were used;
  project signing settings and saved credentials were unchanged.
- Earlier verification attempts: simultaneous cold UI/test index walks
  encountered a server timeout; the final isolated live run passed. One
  initial Beethoven playback attempt aborted in the unchanged
  `PlaybackService.currentSampleTime()` / `AVAudioPlayerNode` path; after
  relaunch the same mapped track and Bach played successfully. That
  intermittent engine failure is recorded, not diagnosed or fixed here.
- API/testing contracts (`02`, `08`) are synchronized. No UI, engine,
  authentication, pagination, or broader #20/#81 work is included.

## Issue #86: exclude missing files from the native song index (2026-08-26)

- `songIndexSnapshot()` now adds `missing=false` to its `PageQuery`.
  The existing pagination and 401 retry paths carry the filter through every
  request, so the cached index and composer/work metadata consumers exclude
  Navidrome records for missing/deleted files. Cache invalidation, credential
  snapshots, sort order, concurrency, and Subsonic playback are unchanged.
- Added a regression in `NavidromeSongIndexNetworkTests.swift`, an extension
  of the existing serialized network suite. It checks the filter and page
  boundaries on three pages plus a retried middle page, returning 1,001
  fixture songs. The original implementation failed all four filter
  assertions; the fix passed. Shared test helpers remain test-only.
- The opt-in live song-index test now independently requests
  `/api/song?_start=0&_end=1&missing=false` and compares its `X-Total-Count`
  with the index length. `TEST_RUNNER_HYDROPHONE_*` successfully forwards
  the opt-in environment into this toolchain's test runner; the live path
  was observed executing, not merely reported as a no-op pass.
- Final gate: unsigned build succeeds with zero warnings; full suite passes
  **264 test cases, 273 executions including parameters, 0 failures/skips**
  (canonical xcresult summary). Strict SwiftLint and `git diff --check` are
  clean. The test build reports only the existing AppIntents extraction
  notice (no AppIntents framework), not a compiler warning.
- Live verification: **2026-08-26, demo.navidrome.org, Navidrome 0.63.2
  (be10f89c)**. The production-client harness and the live test both returned
  **501 indexed songs**, matching the independently requested filtered total;
  a second index call retained all 501 cached songs. The server reported zero
  missing songs, so this confirms live compatibility/counts, while the
  hermetic request assertions prove the exclusion filter is actually sent.
- Both focused opt-in live tests (song index and composer roster) pass with
  nonzero execution times. Two broader five-test runs passed the index check
  but hit HTTP 429 on the final composer-roster test after the rapid login
  probes. The isolated two-test run passes both; no authentication or retry
  behavior was changed to accommodate the public demo's throttling.
- Signed-app check: the available local Developer ID identity was supplied
  via build-command overrides; strict signature verification passed without
  changing project signing settings. Settings → Connection → Use Demo Server
  connected with native features available. After a connected relaunch,
  Composers loaded its roster and the two 2 Mello tracks; “Outro” from
  *Chrono Jigga* played with an advancing timer. Playback was paused and the
  verification instance closed. Only in-memory demo credentials were used;
  the saved connection was unchanged.
- No UI, playback, authentication, generic pagination, or #20 rework is
  included. API and testing contracts are synchronized in `02` and `08`.

## PR #87 review fixes: bounded artwork prefetch and geometry refresh (2026-08-26)

- Continued the existing `copilot/epic-e7-artwork-performance` branch in its
  matching worktree; the primary checkout remains on `main` unchanged.
- Replaced per-cell fire-and-forget fetches with one replaceable window of
  at most 24 requests and one speculative worker. Obsolete pending requests
  are discarded on scroll, resize, leaving Albums, or server change. One
  active request may finish so a visible caller sharing it is not cancelled;
  speculative work cannot occupy all six network slots.
- Albums tracks appearing IDs and derives its window after the furthest one.
  It waits for measured geometry and refreshes on size/list/visibility changes.
  The artist grid, cache identity, 200 MB budget, retries, and playback are
  unchanged. Cache tests use an isolated URLSession and temporary disk store.
- Regression evidence: the original cache delayed a newly visible image
  behind 24 speculative requests (1.31 s with mocked 250 ms responses); the
  fixed cache started it alongside the sole active prefetch (0.27 s).
  A temporary harness hosting the actual AlbumsView showed the original's
  final window stuck at 320 px at a 740-point view width; the fixed final
  window uses 480 px after layout settles. The same rendered-view harness
  also passes resize (640 px at 570 points), leaving Albums (empty window),
  and returning (refilled measured window). These are controlled diagnostics,
  not live-server verification.
- Focused verification: all **12 ArtworkCacheTests** pass (0 failures/skips,
  canonical xcresult summary). Added coverage for visible demand, window
  replacement/clearing, visible in-flight joins, server changes, bounding,
  cache reuse, and measured-size/visible-ID selection. Only this test file
  was compiled for the initial focused run; the full suite now passes too.
- Full-suite compilation: two mock URLProtocol tasks in
  `ComposerSongLibraryModelTests` and `ConnectionModelNativeFeaturesTests`
  now declare `@Sendable [self]` explicitly. Both protocol types already
  conform to `@unchecked Sendable` and keep shared state in actors. This
  resolves the current compiler's sending-closure diagnostics without
  excluding tests or changing their behavior. The PR base also reproduced
  the compilation failure; no compiler-version change is assumed as its
  cause. Full suite: **263 test cases, 272 executions including parameters,
  0 failures, 0 skipped**, from the canonical xcresult summary.
- Local signing: built with the available user Developer ID identity via
  command-line overrides; strict code-signature verification passes.
  Project signing settings are unchanged; no protections were bypassed.
- Live attempt: **2026-08-26, demo.navidrome.org, Navidrome 0.63.2**. The
  signed app used an ephemeral credential store and Settings → Connection
  → Use Demo Server. Connection and album metadata succeeded, but covers
  remained placeholders while scrolling. Independent authenticated
  requests outside the app also timed out for three different covers at
  160 px, 480 px, and original size (35-second timeout each). This does not
  establish successful live artwork behavior; the alternate real-server
  check below resolves this initial verification blocker.
- Completed live verification: **2026-08-26, user-authorized private
  Navidrome 0.63.2 (be10f89c) server** (address and library details withheld).
  The signed PR build used the existing saved connection without changing
  credentials. Artwork remained loaded across multi-page scrolling,
  pagination, window zoom/restore, opening an album and returning to the
  grid. Album tracks loaded from the server, and a new artwork cache file
  was written during the check. Existing artwork caches were retained;
  this is a functional live check, not a cold-cache timing benchmark.
  The test instance was closed after verification.

## Issue #15: artwork prefetch + cache budget (E7, 2026-08-26)

- `ArtworkCache.prefetch(coverArt:cacheKey:size:)` is a fire-and-forget
  warmer sharing `image`'s cache/in-flight de-dup, so a prefetch that's
  already cached or loading is a no-op. Raised the in-memory tier from a
  400-entry `countLimit` to a byte-based budget (`totalCostLimit`, ~200 MB
  of decoded pixels) plus a looser 1,000-entry backstop, so a large grid's
  visible + prefetched range doesn't get evicted by count alone.
- `AlignedAdaptiveGrid` now reports its actual on-screen tile width via an
  optional `tileWidth: Binding<CGFloat>?` (unused by `ArtistDetailView`'s
  grid, which is unchanged). `ArtworkView.fetchPixels(forSize:)` is now a
  static helper shared by the view and the new prefetch driver, so a
  prefetched size lands on the same cache entry the view goes on to
  request instead of warming a variant nobody asks for.
- `AlbumsView` drives a viewport-ahead prefetch from each cell's
  `onAppear` (SwiftUI's lazy grid has no first-class prefetch hook): warms
  the next 24 albums past the one that just scrolled into view, sized to
  the grid's live tile width. `ArtistDetailView`'s smaller per-artist grid
  is out of scope for this pass.
- New tests: `prefetchIgnoresMissingCoverArt` (nil/empty coverArt is a
  no-op, matching `image`'s guard) and `fetchPixelsQuantizesToA160PxGrid`
  (the shared sizing helper's quantum boundaries).
- Gate: **not run — cloud session, no Xcode/simulator/server available**
  (see `docs/11-agent-workflow.md`'s cloud-session procedure). Build,
  tests, SwiftLint, and live verification against a real server are
  deferred to a local machine before merge; PR opened as a draft.

## Issue #29: restore Artists master-list scroll position (2026-08-25)

- Artists now stores the top-visible artist ID separately from its selection
  (`artistsListScrollID`). Back and relaunch restore once after rows load;
  first-row memory stays at the top and removed IDs are ignored. Later
  scrolling updates memory without snapping back to the restored row.
- Reused `Binding.scrollMemory` unchanged. A small `ListScrollMemory`
  representable observes/restores the native List's backing table because
  the issue's suggested `scrollPosition(id:)` wiring does not report or
  restore its rows on macOS 26.6.2. Native selection, keyboard handling,
  context menus, resize handling, and the right album grid are unchanged.
- Four rendered native-list regressions cover recreation, free scrolling,
  selection preservation, asynchronous loading, first/missing saved IDs,
  returning to the top, and insertion before the saved artist. All four
  fail when the bridge is replaced with the suggested SwiftUI modifier.
- Gate: build **passes with zero warnings**; full suite **255 test cases,
  264 executions including parameters, 0 failures, 0 skipped** (canonical
  `xcresulttool` totals); SwiftLint **0 violations**; `git diff --check`
  clean. The test build emits the existing AppIntents metadata-extraction
  tool notice (no AppIntents framework); no compiler warnings.
- Live: **2026-08-25, demo.navidrome.org, Navidrome 0.63.2**, isolated local
  verification copy with an ephemeral credential store. With Various
  Artists selected and Binaerpilot at the top-visible row, opened NCS:
  Infinity and returned: the artist row/selection and the independently
  scrolled album grid restored. Quit/relaunch, reconnect, and reload also
  restored the saved row. Returning the list to the top survived another
  album/Back cycle. Arrow selection and letter type-select worked; started
  Back On Earth's **Brighten** and Space in the focused artist list paused
  playback. The user's configured connection and playback queue were not
  changed by the isolated verification copy.
- Independent read-only implementation review found no actionable issues.
  Other-list audit only: column-browser and Composer master lists also lack
  explicit scroll memory; no changes here. Playlist track scroll persistence
  remains deliberately excluded by the existing stored-order contract.

## PR #79: refresh after Get Info text-selection merge (2026-08-25)

- Merged `origin/main` at `b17b28f` into the PR branch without rebasing.
  Resolved the sole conflict in this log by retaining both branches' entries
  verbatim. No application code was edited during conflict resolution.
- Reverified the combined branch: unsigned macOS build passes with zero
  compiler warnings; **251 test cases, 260 executions including parameters,
  0 failures, 0 skipped** (`xcresulttool` summary); SwiftLint **0 violations**;
  `git diff --check` clean. Xcode still emits the previously documented
  AppIntents missing-framework metadata warning.
- Live-verified 2026-08-25 against Tim's saved real Navidrome server using a
  separately staged Debug app signed with the available local Developer ID
  certificate (command-line overrides only). Verified the executable path,
  signature, and matching built-library SHA-256. A selected track opened the
  wider Get Info sheet with artwork and metadata, both before and after
  toggling Caps Lock. Multiple selection and search-field focus remained
  inert. Restored Caps Lock, closed the temporary app, and reopened the
  original app; playback remained paused.

## PR #79 follow-up: ⌘I with Caps Lock (2026-08-25)

- Ignore only Caps Lock in the existing ⌘I modifier comparison. Other
  modifier handling, selection rules, focus routing, and playback keys are
  unchanged.
- Extended `TrackTableKeyboardTests` with Caps Lock on/off and nonmatching
  modifier coverage. The Caps Lock case failed before the fix with
  `infoCount == 0` and passes afterward.
- Verification: unsigned macOS build passes with zero compiler warnings;
  full suite **251 test cases, 260 executions including parameters, 0 failures,
  0 skipped** (`xcresulttool` summary); SwiftLint **0 violations**;
  `git diff --check` clean. Xcode's AppIntents metadata tool emits its
  missing-framework warning during test/signing builds; no compiler warnings.
- Live-verified 2026-08-25 against Tim's saved real Navidrome server with a
  separately staged app signed using the available local Developer ID
  certificate (command-line override only; project signing unchanged).
  Confirmed its running executable path and matching built-library SHA-256.
  A selected track's Get Info sheet opened before and after toggling Caps
  Lock; restored Caps Lock afterward. Multiple selection and search-field
  focus stayed inert.
  Playback was left paused. The compiled-module AppKit probe also passed
  zero/multiple selection, disc headers, sorted-row mapping, and text-field
  focus checks.

## Issue #77: ⌘I opens Get Info (2026-08-25)
Get Info was reachable only from the track table's right-click context menu.
Added ⌘I as a shortcut, matching Music.app.

- Followed the existing ⏎/Space pattern rather than a menu-bar `CommandGroup`:
  `InnerTableView.keyDown` (`TrackTableLifecycle.swift`) now also recognizes
  ⌘I and calls a new `onGetInfo` closure, wired through `MusicTrackTable`'s
  `Coordinator.getInfoSelected()` up to `TrackTableView`'s existing `infoSong`
  sheet state — the same trigger the context menu's "Get Info" item already
  uses. `getInfoSelected()` mirrors that item's single-selection-only
  constraint (a no-op with zero or multiple rows selected).
  Table-focus-scoped rather than global sidesteps needing SwiftUI
  `@FocusedValue` plumbing to resolve "the selected row in whichever table
  has focus" from a menu-bar command — ⏎/Space already don't appear in the
  menu bar either, for the same reason.
- `docs/04-ui-ux.md` updated with the shortcut.

Verification: unsigned macOS build clean, zero compiler warnings; the full
Swift Testing suite passes (249 executed cases, 0 failures); SwiftLint is
clean. Live-verified 2026-08-25 against Tim's real Navidrome server:
selecting a single track and pressing ⌘I opened its Get Info sheet, matching
the context-menu item; confirmed inert with zero or multiple rows selected.

## Issue #44: selectable text in the Get Info sheet (2026-08-25)
`TrackInfoView`'s title/artist/album header and every metadata row (genre,
composer, year, track, time, format, bit rate, size) were plain SwiftUI
`Text`/`LabeledContent`, with no way to select or copy a value out of the
sheet.

- First pass added `.textSelection(.enabled)` to the header `VStack` and the
  `Form`, per the issue's suggested fix direction. Live testing surfaced two
  problems that fix couldn't clear: no I-beam cursor over selectable text,
  and — after adding an `.onHover`-driven cursor — click-drag selection was
  still flaky, most likely `Form`'s own gesture handling fighting SwiftUI's
  text-selection drag.
- Replaced that with `SelectableText`, a small `NSViewRepresentable` around a
  non-editable, selectable `NSTextField` (the standard "selectable label"
  recipe) — the same "drop to AppKit where SwiftUI can't deliver reliable
  behavior" pattern `MusicTrackTable` already uses for the track list. Native
  `NSTextField` selection gives a correct I-beam cursor, reliable
  click-drag, and a right-click Copy menu for free. The decorative "★"
  favorite marker stays plain, unselectable text, per the issue's note.
  `LabeledContent`'s own row label (e.g. "Genre") stays plain text too — only
  the value is selectable, matching Finder/Music's Get Info panels.
- `SelectableText` initially starved the header's `ArtworkView` of its layout
  space and left long titles clipped instead of wrapping: an
  `NSViewRepresentable` with no `sizeThatFits` override reports its full
  unconstrained intrinsic width regardless of what SwiftUI's `HStack` can
  actually offer it. Implementing `sizeThatFits(_:nsView:context:)` to
  negotiate size against the proposed width fixed both — the artwork square
  reappeared and a long title now wraps onto its 2 allotted lines
  (`maximumNumberOfLines`) instead of overflowing.
- Widened the sheet 400pt → 460pt (Tim's call, to give long titles more room
  before wrapping).

Verification: unsigned macOS build clean, zero compiler warnings; the full
Swift Testing suite passes (249 executed cases, 0 failures); SwiftLint is
clean. Live-verified 2026-08-25 against Tim's real Navidrome server, iterating
through three rounds of his feedback: click-drag selection of the title,
artist, album, and metadata values (Genre, Format) confirmed reliable and
copyable; a long title ("Sonata No. 3 in F-sharp minor, Op. 23: I.
Dramatico") wraps onto two lines with the artwork square correctly
positioned alongside it; the wider 460pt sheet and header alignment confirmed
looking right.

## Issue #73: composer track detail view (2026-08-25)
Completes E4 (#12). Replaces `ComposersView`'s placeholder detail with the
real composer track list, and covers the epic's last acceptance criterion:
a stale `.composers` sidebar selection on a server without native features.

- Added `ComposerDetailView`: a Play/Shuffle header (`trackSummary` +
  `PlayShuffleButtons`, the same shared components `AlbumDetailView` uses)
  over a `TrackTableView` showing `[.title, .album, .artist, .genre,
  .quality, .time]` — `.composer` is dropped since every row shares one, and
  `.album` stays since a composer's songs usually span several. Per-row
  "Add to Up Next" and double-click-to-play come from `TrackTableView`
  as-is; a composer with zero songs shows a "No Songs" empty state instead
  of a blank table.
- `ComposersView` now branches on `connection.nativeFeaturesState ==
  .unavailable` (deliberately not `!= .available`, since `.unknown`/
  `.checking` are the normal startup window) to show a "Composers
  Unavailable" message instead of an empty or broken screen.

Verification: the unsigned macOS build completed with zero compiler
warnings; the full Swift Testing result bundle reports **249 executed
cases, 0 failures, 0 skipped** (`ComposerDetailView`/`ComposersView` are
SwiftUI view code without unit coverage, matching #72's note); SwiftLint is
clean. Live-verified 2026-08-25 against a real Navidrome server: selecting
Alexander Glazunov listed all 51 songs correctly across albums, with
working column-sort toggling (confirmed the "Album" column sorts
alphabetically rather than grouping by track order — the same plain
per-column sort `TrackTableView` already does elsewhere, not a regression);
Play and Shuffle started playback; right-click "Add to Up Next" and
double-click-to-play both worked. A composer with zero songs is logically
unreachable with real data (composers are derived from track composer
credits), so the empty state was verified by code inspection only. The
native-unavailable fallback was verified by temporarily forcing
`ConnectionModel.probeNativeFeatures()` to `.unavailable` in a local build
(reverted before commit, never part of the diff) with a `.composers`
sidebar selection already persisted from a prior session: the sidebar row
disappeared and the "Composers Unavailable" message rendered in its place,
with the rest of the app (playback, Up Next) unaffected. A UI review also
caught the header/Play/Shuffle row rendering centered instead of flush
left against the table below it — the outer `VStack` needed explicit
`alignment: .leading` (`ArtistDetailView`'s equivalent container relies on
an outer `.frame(maxWidth: .infinity, alignment: .leading)` instead); fixed
and reverified.

Review follow-up: each composer detail now has selection-scoped SwiftUI
identity so a newly selected composer cannot temporarily inherit the prior
composer's track summary or Play/Shuffle actions; the two actions are wrapped
in an explicit horizontal row; and the 2025 `apple.classical.pages.fill`
sidebar symbol falls back to `person.2` before macOS 26. Reverified 2026-08-25
against the same Navidrome server: the macOS 26 symbol rendered, Play/Shuffle
were side-by-side, and switching from Alexander Glazunov (51 songs) to
Alexander Scriabin rebuilt the detail with the correct 27-song summary and
track table.

## Issue #72: Composers master list (2026-08-25)
Part of E4 (#12). Adds the first user-facing consumer of the native Navidrome
composer roster; track listing and playback actions remain explicitly deferred
to the next E4 sub-issue.

- Added `.composers` sidebar-selection persistence and a Composers library row
  that appears only while native Navidrome features are available.
- `LibraryModel` now loads the native composer roster once per connection,
  caches it for repeated visits, and clears the roster and loaded state on
  reset.
- Added an imageless `ComposersView` master-detail layout. The roster shows
  localized-name-sorted names and song counts, persists the selected composer,
  and shares the existing resize handle for a persisted 180–360pt list width.
  The detail pane intentionally contains only the selected name/count pending
  the follow-up track-actions issue.
- Added sidebar-selection round-trip coverage plus serialized network tests for
  composer load-once caching and reset behavior.
- Synced the UI and testing contracts in `docs/04-ui-ux.md` and
  `docs/08-testing.md`.

Verification: the unsigned macOS build completed with zero compiler warnings;
the full Swift Testing result bundle reports **246 executed cases, 0 failures,
0 skipped**; SwiftLint is clean. Live-verified 2026-08-25 in a signed Debug
build against the configured real Navidrome server: the native-only row
appeared, the sorted roster populated with numeric song counts, changing
selection updated the name/count placeholder, and selection plus a resized list
width survived quit/relaunch. A separate empty in-memory credential session
confirmed the row is absent without native capability.

## Issue #71: playable songs for a composer (2026-08-25)
E4 (#12) data foundation; no Composers UI is attached in this issue.

- Added the standard Subsonic `getSong` endpoint and golden request coverage.
- `LibraryModel.songs(forComposer:)` now resolves native composer-song ids
  into the complete `Song` values required by track tables, queues, and
  playback. The six-request concurrency cap preserves the native result order,
  silently drops individual failed fetches, and returns an empty result when
  the native lookup itself is unavailable.
- Resolved songs receive the same work/movement metadata join as every other
  song-list path. A dedicated serialized, hermetic `URLProtocol` suite covers
  playable fields and ordering, metadata joining, per-song failure, and the
  no-wasted-Subsonic-calls native-failure path.
- Synchronized the API and testing contracts; the authoritative `.xcresult`
  records 246 tests, 0 failures, and 0 skipped.

Verification: build clean (zero compiler warnings), 246 tests pass,
SwiftLint clean. Live-verified 2026-08-25 against the public Navidrome demo
server: a composer resolved to two songs with real duration, bit rate, and
suffix values; `PlayerModel.play(tracks:)` started playback, the playhead
advanced, and no playback error surfaced.

## Issue #62: resizable Artists list (2026-08-24)
E6 (#14) library/navigation UX polish; unblocks E4's eventual Composers view
(#12), which should follow the same pattern once it exists.

- `PanelResizeHandle` gained an explicit `anchoredEdge: HorizontalEdge`
  parameter (no default, forcing every call site to be explicit) so the
  same grab-strip component can drive a panel anchored to either edge of
  its container: `.trailing` (Now Playing panel — dragging left widens it,
  unchanged) or `.leading` (Artists list — dragging right widens it).
  `RootView.swift`'s call site now passes `anchoredEdge: .trailing`
  explicitly.
- `ArtistsView` gained `@AppStorage("artistsListWidth")` (default 240,
  range 180–360pt, mirroring `RootView`'s `nowPlayingPanelWidth` pattern)
  and a trailing-edge `PanelResizeHandle` overlay straddling the existing
  divider.
- `docs/04-ui-ux.md`'s Artists bullet now records the resizable list and
  the shared/generalized component.

Verification: build clean (zero warnings), tests pass, swiftlint clean.
Live-verified by Tim in a dedicated debug build: the list drags
wider/narrower and clamps at both ends of the 180–360pt range, the Now
Playing panel's own resize is unchanged, and the Artists list width
persisted across a quit/relaunch.

## Issue #61: remove artist artwork everywhere in the app (2026-08-24)
E6 (#14) sub-issue. Scope grew mid-flight from just the Artists list row to
every artist-portrait call site in the app, at Tim's request — he doesn't
want artist artwork anywhere.

- `ArtistsView.swift`: dropped `ArtworkView` from the Artists list row (no
  more leading spacing reserved for it); dropped it from `ArtistDetailView`'s
  header, which is now just the name + Artist Radio button — the name grows
  from `.title2` to `.largeTitle` to compensate for the lost visual weight
  and now sits flush against the page's leading edge instead of indented past
  where the 84pt portrait used to be.
- Similar Artists (`ArtistsView.swift`) and the search results Artists shelf
  (`SearchResultsView.swift`) both dropped their `VStack`/`.frame(width: 90)`
  tiles — built around holding a 64pt portrait above the name — for plain
  content-sized name buttons (`.buttonStyle(.bordered)`) in the same
  horizontal `Shelf` scroller. A fixed-width vertical tile made sense when it
  had an image to anchor it; with no image it was just a row of mostly-empty
  boxes.
- `docs/04-ui-ux.md`'s Global search section updated (Artists shelf was
  documented as "circular portraits").

### Live verification — 2026-08-24, against Tim's real Navidrome library
Launched the Debug build, drove it via Accessibility (`System Events` +
`cliclick`), screenshotted each spot:
- Artists list: rows show name + album count only, no thumbnails.
- Artist detail page (2Pac): large flush-left name, Artist Radio button
  underneath, no portrait.
- Similar Artists shelf on that page: "Dr. Dre" renders as a single bordered
  pill button, not an empty-image tile.
- Search results ("beethoven"): the Artists shelf shows "Ludwig van
  Beethoven" as the same style of pill button, Albums shelf below it
  unaffected.

## Issue #64: bit rate in the Now Playing quality badge for lossless files (2026-08-24)
Part of #14 (E6). The Now Playing badge showed just "FLAC" for lossless
files; it now adds the bit rate when the server reports one.

- `Song.qualityDetailLabel` (`SubsonicModels.swift`), alongside the existing
  `qualityLabel`: for a lossless suffix, appends `· N kbps` when `bitRate` is
  present and positive, else falls back to the bare format name; for
  anything else it delegates to `qualityLabel` unchanged.
- `NowPlayingPanel.swift:222` now reads `song.qualityDetailLabel` instead of
  `song.qualityLabel`. The Quality column (`MusicTrackTable.swift:290`) and
  `qualityRank`'s lossless-always-ranks-above-lossy sort are untouched, per
  the issue's explicit scope.

Four new `QualityLabelTests` cases: lossless with a bit rate ("FLAC · 1006
kbps"), lossless with no bit rate or a zero bit rate (bare "FLAC"), and
lossy/no-suffix parity with `qualityLabel`.

**Live verification (2026-08-24), Tim's configured real Navidrome server,**
via a dedicated second app instance (`open -n`) driven with `cliclick`
against the fresh Debug build, screenshots inspected at each step. A first
pass across three FLAC albums (Beethoven piano sonatas/Alfred Brendel, Arvo
Pärt's *Anima*/Alea Saxophone Quartet, Akropolis Reed Quintet's *The Space
Between Us*) only ever showed the bare "FLAC" fallback and was reported as
such — wrongly assumed to mean this library's FLACs simply carry no
`bitRate`. Tim caught the error: a follow-up check on the same Akropolis
Reed Quintet track ("The Space Between Us: III. Remembering") showed the
badge correctly reading **"FLAC · 439 kbps"**, confirming the bit-rate-present
path renders live, not just in the unit test. The Quality column kept
showing plain "FLAC" unaffected throughout.

Build clean, zero compiler warnings; full suite green (242 tests, +4 new);
SwiftLint clean (0 violations, 105 files).

## Issue #63: Favorites shelf on Home (2026-08-24)
Part of #14 (E6). Surfaces starred albums on Home so favorites are visible
without a trip to the Favorites sidebar item, matching the epic's intent —
though its text was wrong about the data already being loaded (see the
issue's "Correction to the epic text").

- `HomeView` gained a second, independent `.task { await
  library.loadStarredIfNeeded() }` beside the existing home-data task
  (`:69`) — same pattern as `ArtistsView`'s two separate `.task`/`.task(id:)`
  modifiers. Home no longer depends on Favorites having been visited first.
- A `Favorites` `AlbumShelf(albums: library.starredAlbums)` shelf, hidden
  when empty, sits between "Most Played" and "Random" (`:56-60`) —
  albums-only, matching every other Home shelf; `starredSongs` isn't pulled
  in. `scrollBinding`'s `topIDs` (still just `["greeting"]`) is untouched;
  the shelf's `.id("favorites")` only feeds `scrollTargetLayout()`.
- Review follow-up: Home's content/loading gate now counts `starredAlbums`.
  When `getStarred2` succeeds but all four `getAlbumList2` requests fail or
  return empty, the independently loaded Favorites shelf renders instead of
  remaining trapped behind the legacy Home spinner.

Build clean, zero compiler warnings; full suite green (239 tests, 0 failures,
0 skipped); SwiftLint clean (0 violations, 105 files). The review follow-up
adds a hermetic rendered-output regression in `StarringTests`: `getStarred2`
returns one album while every legacy Home request fails, and the offscreen
Home render must contain shelf content rather than only the loading spinner.

**Review-fix live verification (2026-08-25), Tim's configured real Navidrome
server,** against the exact unsigned branch build at the reviewed working tree:
confirmed Home completed loading and rendered its populated Favorites shelf in
the intended position. The server state was left unchanged. The legacy-shelf
failure edge is exercised by the hermetic regression above because reproducing
selective endpoint failures on the configured server would require changing
the server rather than the app.

**Live verification (2026-08-24), Tim's configured real Navidrome server,**
driven via AppleScript/System Events UI automation against the running
Debug build (screenshots inspected at each step). Server already had 6
starred albums: confirmed the Favorites shelf appeared on Home in the
correct position (between Most Played and Random) without ever having
opened the Favorites tab. Unstarred all 6 one at a time (each album's own
star toggle) and confirmed the shelf disappeared entirely after the last
one — not an empty header — reactively, with no relaunch needed. Re-starred
all 6 via search to restore the server's original state exactly. Separately
confirmed: Home's scroll-position restore (`ScrollMemory.swift`) only ever
covered surviving Back navigation (push an album, tap Back) — not
switching to a different sidebar section and back — and that's true for
Home, Albums, and Artist detail alike, predating this change; not a
regression from the new shelf, and out of scope per the issue's explicit
"Do NOT" on `scrollBinding`/`topIDs`.

---

## Issue #55: double-click a work header to play the whole work (2026-08-24)
E5 (#13) follow-up tweak after #47 and #48. #47 deliberately deferred header
interactivity ("the header row stays a plain, non-clickable label") to the
context-menu sub-issue; Tim has now asked for the direct interaction, so this
reverses that line.

- `TrackTableRow.header` now carries the grouping identity alongside its
  display string (`case header(String, work: String?)`), set from
  `groupedRows`' key — `nil` for a disc header, the Work name for a work
  header (folded-in disc number included). `Coordinator.work(atRow:)` reads
  it back; `trackIndex(atRow:)` is unchanged.
- `MusicTrackTable.Coordinator.doubleClicked()` now branches three ways: a
  track row plays/queues-next as before; a work-header row plays the work
  from movement 1, or (⌥) adds it to Up Next via a new `onEnqueue` closure
  threaded through from `TrackTableView` to `player.enqueue`; a disc header
  (no work identity) falls through and does nothing.
- Extracted `resolveWorkTracks(work:among:)` out of #48's `makeWorkMenuItem`
  so the header double-click and the context menu's Work submenu share one
  movement-ordering implementation (`movementNumber ?? track ?? .max`,
  original offset as tiebreak) — they can't diverge.
- Moved the four `NSTableCellView` builders (`discHeaderCell`,
  `indicatorCell`, `favoriteCell`, `textCell`) out of `Coordinator` into an
  `extension MusicTrackTable.Coordinator` in `TrackTableCells.swift` (pure
  move, no behavior change) to keep the coordinator's own body under
  SwiftLint's `type_body_length` after the new branch.
- `docs/04-ui-ux.md`'s "Album work grouping" bullet now records the
  reversal: a work header is double-click-to-play, ⌥-double-click adds it to
  Up Next; disc headers stay inert; headers stay unselectable either way.

Five new `WorkHeaderDoubleClickTests`: `resolveWorkTracks` ordering by
movement (falling back to track, tiebroken by offset) and its independence
from a reversed display sort; `Coordinator.work(atRow:)` resolving a work
header's identity, returning `nil` for a disc header, and resolving the
folded-in work on a multi-disc album. `table.clickedRow` isn't settable
outside real AppKit mouse tracking, so the actual `doubleAction` dispatch —
the "Verify first" risk the issue called out, since header rows are
unselectable — was checked live instead, not simulated.

**Live verification (2026-08-24), Tim's configured real Navidrome server,**
driven via `cliclick` mouse/keyboard automation against the running Debug
build (screenshots inspected at each step): on *Japanese Love Songs*,
double-clicking the `Two Poems By Ryokan` header played movement I and
queued II then III in Up Next, in order; ⌥-double-click on `Three Love
Songs` left movement I playing uninterrupted and appended I/II/III to Up
Next after the remaining Two Poems tracks, in order. On *Mendelssohn: Songs
Without Words* (multi-disc, every track Work-tagged), double-clicking a
`Disc 2 · Kinderstücke, Op. 72`-style header likewise played that work from
its first movement, confirming the disc-folded case; a plain track
double-click still played that single track and queued the album from
there, unchanged. A genuinely disc-only header (no Work tag) wasn't
available in the library to click by hand; that path is a pure early-return
in `doubleClicked()` (`guard let work = work(atRow:) else { return }`) on
the same dispatch mechanism already proven live, and is covered by
`discHeaderRowHasNoWorkIdentity`.

Build clean, zero compiler warnings; full suite green (226 tests, +5 new);
SwiftLint clean (0 violations, 105 files).

---

## Issue #54: Title-column movement text under a work header (2026-08-24)
Under an active work header, the Title column now shows the movement number
(roman numeral) and name instead of repeating the work name on every row.

- `WorkMovementTitle` (`UI/Components/WorkMovementTrackColumns.swift`): a
  roman-numeral converter (1–3999) plus `title(for:)`, which applies the
  issue's four fallback rules in order — `movementNumber` tagged → roman +
  name (from `movementName`, else the title with the work prefix stripped);
  no number but the title starts with `work` → the stripped remainder
  (preserving a tagger-written numeral); `movementName` alone → the bare
  name; otherwise the title is untouched. A guard skips the roman prefix
  when the name part already opens with one, so a tagged `movement` number
  never double-numbers a title that already carries its own numeral.
- `titleForRow(song:workHeaderGroupingActive:)` gates the whole thing: it
  only applies when the album's current build is actually showing work
  headers (not disc-only headers, and not withdrawn by a non-track-order
  sort) *and* the row's own track carries a `work` tag — a track with no
  work tag renders its full title unchanged even under an active header for
  its neighbors.
- `MusicTrackTable.Coordinator` tracks `workHeaderGroupingActive` alongside
  `rows` in `rebuild()` (same `activeDiscHeaders` computation that already
  gates header withdrawal on sort) and the Title cell calls
  `WorkMovementTitle.titleForRow(...)` instead of always using `song.title`.
  The Movement and Movement Name columns are untouched.

**Verification (2026-08-24):** build clean, zero warnings; full suite passes
(230 executed cases, 0 failures) including 9 new tests covering the roman
conversion, each of the four fallback rules, the double-numbering guard, and
the gating (no-work track and withdrawn headers stay untouched); `swiftlint`
0 violations. Automated GUI live-verification wasn't attempted — this Mac's
screen was shared with another concurrent Claude Code session mid-task when
this branch was ready, and automating the GUI risked stray input landing in
that other session's terminal. Instead the Debug build from this branch was
launched and handed to Tim, who live-verified it by hand against his real
Navidrome server and confirmed it working.

## Issue #53: blank row between the end of a work and the next ungrouped track (2026-08-24)
Follow-up to #47's work-grouping headers: a run of grouped tracks flowing
straight into an ungrouped track had no visual separation, since headers only
mark the *start* of a group.

- New `TrackTableRow.spacer` case (`MusicTrackTable.swift`). `groupedRows`
  emits it when the grouping key transitions from non-nil to nil — i.e.
  leaving a grouped run into ungrouped tracks — never at the top of the list,
  between two grouped runs (already separated by a header), or on albums with
  no grouping at all.
- No other plumbing changed: `trackIndex(atRow:)` already returns nil for any
  non-`.track` row, so selection, drag, and row-view handling treat a spacer
  exactly like a header; `viewFor` falls through its `case .header` check and
  returns nil, rendering an empty row at the table's uniform 24pt row height.
- Four new `DiscHeaderTests` cases: spacer emitted on work→ungrouped, absent
  on work→work, absent on ungrouped→work, absent when no grouping applies.

Build clean with zero compiler warnings; full suite **TEST SUCCEEDED** with
these four tests passing alongside the existing grouping cases; SwiftLint
clean (0 violations across 104 files).

**Live-verified by Tim (2026-08-24)** against *Japanese Love Songs* (Claude
Delangle) on his real server, confirming the blank row lands correctly.
Automated live-verification wasn't attempted this round — the desktop had
other concurrent sessions actively stealing window focus, and driving the app
blind under those conditions risked misclicking into unrelated windows.

---

## Issue #56: Space play/pause from focused lists (2026-08-24)
Focus-owning collection controls now preserve the global Space play/pause
shortcut instead of consuming it as selection input.

- `InnerTableView` intercepts hardware key code 49 and forwards a narrow
  playback callback. Return/Enter keep their existing route, while every other
  key still goes through `NSTableView`, preserving letter type-select.
- Artists, every column-browser pane, and Up Next apply the same handling at
  the `List` boundary. Up Next's row gestures and `.onMove` implementation are
  untouched; no row `.contentShape` or tap gesture was added.
- Added direct AppKit routing tests plus an offscreen hosted-`List` regression
  test. The host is retained for the test-process lifetime because asynchronous
  SwiftUI/AppKit teardown otherwise races Swift Testing's concurrent jobs.

**Live verification (2026-08-24), Tim's configured real Navidrome server:**
Space toggled playback in both directions from Songs, and toggled from
Favorites, an album track table, and a playlist track table. It also toggled
from Artists, the Artist and Composer column-browser lists, and Up Next. Letter
type-select still moved a track-table selection to the first matching title;
Space typed a literal space in Search without changing playback. The sidebar
already allowed the menu shortcut through. Album-grid buttons did not acquire
keyboard focus under the machine's current keyboard-navigation setting, so
there was no swallowed Space path to override.

Build clean with zero compiler warnings; the full suite passed **221 executed
cases, 0 failures, 0 skipped** (220 declarations, with one parameterized case
run twice); SwiftLint clean (**0 violations across 104 files**).

**PR #57 review cleanup (2026-08-24):** `/code-review medium` flagged two
findings, posted as inline PR comments.

- **Duplication (fixed):** `.playPauseOnSpace { player.togglePlayPause() }`
  plus a fresh `@Environment(PlayerModel.self)` was repeated at all three call
  sites. Added a no-argument `playPauseOnSpace()` convenience overload
  (`PlayPauseOnSpace.swift`) that reads `PlayerModel` from the environment
  internally; `ArtistsView` and `ColumnBrowserView` dropped their now-unused
  `player` properties (each had no other use of it). The closure-taking
  overload stays, since `TrackTableKeyboardTests` depends on the generic form
  to count invocations without a real `PlayerModel`.
- **Full Keyboard Access precedence (investigated, not fixed):** the concern
  is that a List's `.playPauseOnSpace` could swallow Space before a
  Tab-focused row button (e.g. Up Next's Play/Remove) gets to activate it.
  Attempted a hermetic regression test analogous to the existing
  `swiftUIListRoutesSpaceToPlayback` — host a `List { Button(...) }`
  offscreen, `makeFirstResponder` the button, send Space, assert the button
  fires and playback doesn't. Dumping the actual view hierarchy showed why
  this can't work: a plain SwiftUI `Button` inside a `List` row doesn't back
  onto a real `NSButton`; the only AppKit object present is a private
  `_FocusRingView` inside `CellHostingView`, which isn't reachable or
  drivable from public API. That's the same wall Tim's live verification hit
  — the machine's keyboard-navigation setting didn't make buttons
  Tab-focusable, so this path has never actually been exercised in either
  direction. Left the behavior unchanged rather than guess at a fix with no
  way to verify it; needs a real Full Keyboard Access pass on a live machine.

---

## Issue #47: PR #51 review cleanup (2026-08-24)
`/code-review medium` on PR #51 flagged two findings: `TrackTableRow.build`
duplicated the same "walk tracks, detect key change, emit header, append
track" loop once for Work grouping and once for disc grouping, and the Work
path ignores `headers[disc]` for multi-disc, multi-Work albums.

- Factored both loops into one `groupedRows(tracks:key:title:)` helper
  parameterized by key type and header-title closure; behavior unchanged
  (verified: all 209 tests still pass, including the five grouping cases).
- The `headers[disc]`-drop finding was **not** fixed: `DiscHeaderTests
  .multiDiscWorkHeadersFoldInDiscNumber` already asserts the disc title is
  dropped in the Work-grouping path — that's the tested, intended design
  (Work name takes priority over the disc's custom title), not an oversight.
  Left as a comment on the PR for Tim to weigh in on if the design should
  change.

Build clean, zero compiler warnings; full suite green (209 tests); SwiftLint
clean (0 violations).

After merging `origin/main` (including #48), the combined branch remained
clean: build succeeded with zero compiler warnings, all 211 tests passed,
SwiftLint reported 0 violations, and the exact signed branch build was checked
against Tim's real Navidrome server. *Japanese Love Songs* showed the
`Two Poems By Ryokan` and `Three Love Songs` Work headers; Title sort hid both,
and ascending `#` restored both. No credentials were read, logged, or copied.

---

## Issue #48: play complete works from track context menus (2026-08-24)
E5 (#13) context-menu sub-issue — complete-work playback and queueing from
movement rows.

- A single selected movement now exposes a submenu titled with its native Work
  metadata, containing **Play Work** and **Add Work to Up Next**.
- Both actions derive the complete Work from the view's underlying tracks and
  use movement-number order, falling back to track number without depending on
  the table's current display sort. **Play Work** starts at movement 1.
- Tracks without Work metadata and multi-row selections keep the existing
  context menu with no Work submenu.
- Added two AppKit target-action tests covering submenu construction, stable
  filtering and ordering, play/queue dispatch, and the no-Work case; synced the
  context-menu contract in `docs/04-ui-ux.md`.

**Live verification (2026-08-24), Tim's real Navidrome server:** in Search,
sorted results by duration and opened movement 3 of Mahler's *Symphony No. 1 in
D Major "Titan"*. The Work-titled submenu showed exactly **Play Work** and
**Add Work to Up Next**. **Play Work** started movement 1 and placed movements
2–4 in Up Next; **Add Work to Up Next** queued movements 1–4 in movement order.
The submenu was absent on an untagged Dvorak result and when movements 2–3 were
multi-selected. Real FLAC playback advanced normally.

Build clean, zero compiler warnings; full suite green (205 tests, +2 new
hermetic Work-menu tests); SwiftLint clean (0 violations across 100 files).

---

## Issue #47: work-grouping headers on album pages (2026-08-24)
E5 (#13), sub-issue 2 of 4; blocked by and built on #45.

- Album track tables now use `Song.work` to insert the existing flat,
  unselectable `TrackTableRow.header` before each consecutive Work run when an
  album contains more than one distinct non-nil Work.
- Work grouping takes priority over disc grouping. Single-disc labels are the
  Work name; multi-disc labels are `Disc N · Work Name`. Nil Work rows remain
  ordinary tracks and break a run, so a repeated Work receives a fresh header
  when it resumes.
- Headers remain limited to natural track order and ascending `#`; Title and
  every other sort withdraw them. Zero/single-Work albums retain the previous
  disc-header path byte-for-byte.
- The album-detail fetch now performs #45's native metadata join on the exact
  `Album.song` array rendered by `AlbumDetailView`. A live-gate regression
  exposed that this path had bypassed `songs(forAlbum:)`; a new hermetic test
  locks the corrected path, and the table reload signature now includes Work
  and disc identity.

**Live verification (2026-08-24), user-configured real Navidrome server:**
the final signed Debug build showed `Two Poems By Ryokan` and
`Three Love Songs` headers on the single-disc *Japanese Love Songs* album.
Sorting by Title removed both headers; selecting ascending `#` restored them.
The two-disc *Mendelssohn: Songs Without Words* album showed ten Work headers,
each folded into its disc label (for example,
`Disc 1 · Songs Without Words, Op. 19` and
`Disc 2 · Kinderstücke, Op. 72`). The single-Work
*Variations on a Melancholy Theme* remained headerless. No credentials were
read, logged, or copied.

Build clean, zero compiler warnings; full suite green (209 tests, +6 new:
five grouping cases and the album-detail join regression); SwiftLint clean.

---

## Issue #46 follow-up: Movement sort/display mismatch (2026-08-24)
Code review on PR #52 caught a bug in the fix below: the Movement column's
sort comparator ranked by `movementNumber` alone, while the cell text
requires both `movementNumber` and `movementTotal` to show anything but `—`.
A track with a movement number but no total displayed `—` yet still sorted
by its number, interleaved among fully-tagged rows instead of grouped with
the truly-untagged rows at the end.

- `workMovementColumnOrderedBefore`'s `"movement"` case now nils out
  `movementNumber` whenever `movementTotal` is missing before comparing, so
  an incomplete pair sorts exactly like a missing one — matching the display
  guard's definition of "incomplete."
- `columnsSortBothDirectionsWithMissingMovementNumbersLast` had encoded the
  bug: its `four`/`one` fixtures set `movementNumber` without
  `movementTotal`, so the old (wrong) comparator happened to satisfy the
  test. Rewrote the fixtures to give complete pairs a total, added a
  `partial` (number, no total) case, and asserted it sorts last alongside
  `missing` in both directions.
- Build clean, `swiftlint` clean, full suite green including the six
  `WorkMovementTrackColumnsTests`. Not re-verified against a live server —
  the change is confined to comparator logic already covered by the
  ascending/descending sort test above.

After merging current `origin/main` (including #47 and #48), the combined
branch built clean, all 217 tests passed, and SwiftLint reported 0 violations
across 102 files. The exact signed build reconnected to
`music.tail9575a5.ts.net`: Songs exposed Work, Movement Name, and Movement;
real Work/name values rendered; an ascending Movement header sort showed
numbered values from `1 of 3` through `15 of 24` before every `—` fallback.
The pre-test Songs/playlist columns, scroll position, and ascending Album sort
were restored.

---

## Issue #46: Work and Movement track columns (2026-08-24)
E5 (#13), sub-issue 2 of 4, built on #45's native WorkInfo-to-Song join.

- Added picker-only Work, Movement Name, and Movement columns to the shared
  AppKit track table without changing any call site's default visible columns.
  Work and Movement Name are left-aligned text; Movement is a narrow,
  right-aligned `n of total` value and falls back to `—` unless both numbers
  exist.
- Work and Movement Name sort as localized text. Movement sorts numerically
  in both directions with missing movement numbers kept last.
- The three choices are present only while
  `ConnectionModel.nativeFeaturesState == .available`. Sessions where native
  detection is still in progress, and plain Subsonic sessions, omit them from
  the menu and live table. A saved native layout remains intact and returns
  if native capability becomes available again.
- Six focused tests cover AppKit header metadata, native-feature gating,
  capability transitions (including unavailable-session layout edits),
  value/fallback rendering, and ascending/descending sort behavior.

**Live verification (2026-08-24), `music.tail9575a5.ts.net`:** the signed
Debug build loaded the real library and exposed all three choices in both a
Mahler playlist and sortable Songs. Real Work and Movement Name tags rendered;
complete records showed values including `1 of 2`, `1 of 3`, and `2 of 5`,
while incomplete records showed `—`. Direct header clicks exercised Work and
Movement Name in both ascending and descending directions. Movement ascending
put numbered rows in 1-then-2 order; descending reversed the numeric order;
both directions kept missing values after numbered rows. A second signed build
temporarily forced native features unavailable (source change reverted before
commit): the saved native columns disappeared from the live table and all
three native choices remained absent from the picker. The pre-test
Songs/playlist columns, scroll position, and ascending Album sort were
restored.

Build clean, zero compiler warnings; full suite green (209 tests, +6 focused
tests); SwiftLint clean across 101 files.

---

## Issue #45: join native WorkInfo onto Song (2026-08-24)
E5 (#13), sub-issue 1 of 4 — the foundation every other E5 sub-issue
(columns, work-grouping headers, "Play Work") builds on.

- `Song` gained four client-side-only fields — `work`, `movementName`,
  `movementNumber`, `movementTotal` — deliberately absent from `CodingKeys`
  (Subsonic never sends them) and relying on `Optional`'s own implicit `nil`
  default for synthesized `Codable` to keep compiling.
- `NavidromeClient` gained `workInfo(forSongIds:)`, a batch join backed by a
  reusable id dictionary constructed once with the cached `songIndex()`
  snapshot. Album, search, and playlist fan-outs now cost O(requested ids),
  without rebuilding an O(library size) dictionary per fetch;
  `workMetadata(songId:)` uses the same lookup.
- `LibraryModel` gained a `navidrome` reference and a `nativeFeaturesAvailable`
  closure (mirroring `PlayerModel`'s `scrobbler`/`queueStore` closure pattern —
  `AppModel` is the only place peer models actually wire together), plus a
  `joinWorkInfo(into:)` helper (`LibraryModel+WorkInfo.swift`, split out for
  the type-body-length lint) wired into all six track-table sources: album
  detail, genre/Column Browser, the Songs sample, Favorites, playlist entries,
  and search results. Its async availability gate waits for the launch-time
  connection/native probe (and coalesces with one already in flight), so an
  early library fetch cannot permanently cache unenriched songs. The join is
  still a no-op — no native network call — when native features are unavailable.

**Live verification (2026-08-24), Tim's real Navidrome server** (14,794
songs, 2,946 with `movementname`): a temporary opt-in test (reverted before
this PR, same convention as `LiveDecodeTests`) exercised the real path
end-to-end — `NavidromeClient.login()`, a real `songIndex()` walk, confirmed
real songs carrying `work`/`movementname`/`movement`/`movementtotal` tags,
`workInfo(forSongIds:)` correctly joining one, and — the actual point of this
issue — `LibraryModel.songs(forAlbum:)` returning that song with `.work`
populated end-to-end. All assertions passed (~11s per run, consistent with
#8's measured full-index-walk cost).

**Post-review live verification (2026-08-24), same real server:** a temporary
Keychain-backed test (reverted before commit; no credentials logged or copied)
started `ConnectionModel.refresh()` and a real `LibraryModel.search()` in the
startup-race order, selected a real work-tagged song from the 14,794-song native
index, and confirmed the search result carried the same Work value after the
probe completed. The single non-parallel arm64 run passed in 7.349s.

Build clean, zero compiler warnings; full suite green (203 tests, +13 new
hermetic tests: batch/cache coverage in `NavidromeComposerSongLookupTests`,
a `Song`-decode default-nil test, five `LibraryModel` join tests, and three
launch/native-availability regression tests);
SwiftLint clean across 99 files.

---

## Issue #38: column picker on every track view (2026-08-23)
E2 (#10), sub-issue 5 of 5. The header picker proven in Songs by #37 now
works on all six `TrackTableView` call sites.

- Album, Favorites, Column Browser, Playlist, and Search now opt into the
  existing `columnsCustomizable` path; Songs retains its #37 opt-in.
- Every call site's shipped `columns:` array is unchanged, so each view keeps
  its prior first-launch defaults until the user customizes it.
- Album, Favorites, Songs, Browser, Playlist, and Search use distinct
  preference keys. Playlist adds the `"playlist"` key and passes it through
  `TrackTableView` for column persistence while remaining unsortable; no new
  storage or picker mechanism was added.
- `docs/04-ui-ux.md` now records the six-view rollout and per-view persistence
  contract.

**Live verification (2026-08-23), user-configured real Navidrome server:**
drove the final Debug build through Album (2018 Concert at UCF), Favorites,
flat Songs, the Classical Column Browser, a Mahler playlist, and Search
(`Hippocrene`). On every table, right-clicking the header opened the same
15-item picker; enabling Date Added rendered real `Aug 18, 2026` values.
Quit the app completely, relaunched the same build, and revisited all six
views: each independently restored Date Added. The test-only column changes
and original Column Browser visibility were restored before finishing.

Build clean, zero compiler warnings; full suite green (190 tests, unchanged —
this is declarative call-site/AppKit UI wiring with no new hermetic test seam);
SwiftLint clean across 95 files.

---

## Issue #37: address review findings (2026-08-23)
Review of PR #42 at `3c26dfd` found four issues, all fixed on the same
branch:

- **[P1] Table-header retain cycle.** `makeNSView`'s `header.menuProvider`
  closure captured `table` strongly; `table.headerView = header` already
  retains `header`, so the pair closed `table → header → closure → table`.
  Fixed with `[weak table]` in the closure, guarding on `nil` — the
  coordinator's own `table` reference was already weak, so this was the
  only strong leg of the cycle.
- **[P2] Re-adding a hidden column lost its resized width.** `toggleColumn`'s
  add path always used `TrackColumn.widths.initial`, unlike `addColumns(to:)`,
  which already checks `TrackColumnPreferences.persistedWidth`. Now checks
  it too. Live-verified: resized Genre to 222pt (set directly via the
  Accessibility API, since the table's rendered content was wider than the
  window and made a real mouse-drag land off-screen), hid it, showed it
  again — restored at exactly 222pt, not the 100pt default.
- **[P2] Resize persistence wasn't debounced.** `columnDidResize` wrote to
  `UserDefaults` on every notification during a drag, not just once it
  settles — #37 explicitly asked for the same debounce scroll-offset
  persistence already uses. Added a `pendingColumnWidthSave: DispatchWorkItem?`
  on `Coordinator` (parallel to `pendingScrollSave`) and mirrored
  `scrollBoundsChanged(_:)`'s cancel-and-reschedule pattern exactly.
- **[P2] `docs/04-ui-ux.md` didn't mention the picker.** Only `PROGRESS.md`
  described it; the state-restoration list still said sort/scroll only, and
  the Track Table section still described a fixed column set. Both updated:
  the restoration list now notes column visibility/order/width persistence
  on `columnsCustomizable` views, and a new bullet describes the picker,
  its `.number` exclusion, and that it's opt-in per call site.

A follow-up recheck at `20d4cf0` found the new
`TrackColumn.makeTableColumn(sortable:)` helper performing AppKit work from
a nonisolated method, producing eight Swift 6 main-actor warnings. Marking the
factory `@MainActor` carries the isolation already guaranteed by both callers;
the targeted red/green build audit went from all eight warnings to none.

Build clean, zero warnings; full suite green (190 tests, unchanged — no new
hermetic coverage, matching the original entry's reasoning); SwiftLint
clean across 95 files.

**Follow-up live verification (2026-08-23), same real server:** launched the
fixed Debug build against `music.tail9575a5.ts.net`; Songs loaded 100 live
tracks and right-clicking the Title header still presented all 15 togglable
columns. The isolation-only fix caused no runtime behavior change.

## Issue #37: header context-menu column picker (2026-08-23)
E2 (#10), sub-issue 4 of 5; blocked by #35 and #36. Right-click a column
header → checkable list of every togglable column; reorder/resize (already
native `NSTableView` behavior) now persist too.

**Rolled out via an opt-in flag, not globally.** `MusicTrackTable`/
`TrackTableView` gain `columnsCustomizable: Bool = false`. Since all six
`TrackTableView` call sites share this exact implementation, shipping the
picker without a gate would have turned it on everywhere at once —
un-verified on five views the issue explicitly scoped out ("do not wire
this into more than one view for now"). Only `SongsView` opts in this
round; #38 flips the flag on the rest after confirming each view's column
set makes sense with it.

**`UI/Components/TrackColumnPicker.swift`** (new): `columnPickerMenu(for:)`
builds a checkable `NSMenu` from `TrackColumn.allCases` (minus `.number` —
see below); `toggleColumn(_:)` adds/removes the column live, refusing to
drop the last one; `observeColumnChanges(of:)` hooks
`columnDidResizeNotification`/`columnDidMoveNotification` to persist
width/order via #36's `TrackColumnPreferences`, keyed by `sortAutosaveKey`.
New columns land just before the trailing favorite column, matching
`addColumns(to:)`'s own construction order.

**`.number` is deliberately excluded from the picker.** It doubles as the
now-playing indicator column (`addColumns(to:)` only adds the fixed
`"indicator"` column when `.number` is absent from the list) — toggling it
generically would mean swapping that fixed column in or out too, a
call-site decision (`AlbumDetailView` wants `.number`, `SongsView` doesn't),
not something a one-size-fits-all picker should own. Deferred, not solved.

**`TrackColumn` gains `makeTableColumn(sortable:)`**, shared by
`addColumns(to:)` and the picker's add-column path — the single place an
`NSTableColumn` gets built from a case, instead of duplicating the
construction logic in two files.

**Bug found and fixed during live verification:** the `addColumns(to:)`
refactor (extracting a `addFixedColumn` helper for the indicator/favorite
columns) dropped the explicit `col.title = ""` the original code had.
`NSTableColumn`'s own default title isn't blank — it's a generic
placeholder ("Field") — so both fixed columns briefly showed visible
truncated header text ("F…" / "Fi…") instead of nothing. Caught from a
screenshot crop, not from the running app at a glance; fixed by restoring
the explicit empty title.

**Live verification (2026-08-23), driving the Debug build against Tim's
real Navidrome library** (`music.tail9575a5.ts.net`): no GUI-automation
tool was available this session (as in #35), so verification combined
Accessibility-API scripting, `cliclick` for drag/right-click gestures, and
`screencapture` crops for anything text-precision-sensitive. Confirmed,
each via a genuine fresh process relaunch (not just live in-session state):
- Right-click renders all 15 togglable columns, checkmarked correctly
  against the live table.
- Toggling a column on/off updates the table immediately and survives
  relaunch (`Comments` added, `Album` removed, both still correct after
  quitting and reopening).
- Dragging a column border resizes it and the new width survives relaunch
  (`Quality` 68→110pt, confirmed on two separate subsequent launches).
- Dragging a header to reorder columns persists the new order (`Genre`
  moved before `Artist`, confirmed after relaunch).
- Toggling columns off one at a time down to a single remaining column,
  then attempting to remove that last one too, correctly refuses — the
  column stays.
- One verification wrinkle worth recording: `defaults read`/`plutil`
  against the sandboxed app's own preferences file consistently failed to
  show the newly-written `trackColumns.songs`/`trackColumnWidth.*` keys —
  even immediately, even after `killall cfprefsd`, even with the app still
  running — while the app's own genuine relaunch behavior (the actual
  end-user scenario) repeatedly and consistently proved the values were
  correctly written and read back. Treated the app's own behavior as
  ground truth rather than the CLI inspection tooling, which appears
  unreliable for freshly-written sandboxed-container keys in this
  environment specifically (older keys from earlier sessions, e.g.
  `trackSort.album`, *do* show up via the same commands).
- Restored the column set to the original 7-column default (Title, Artist,
  Composer, Album, Genre, Quality, Time) before finishing, since `UserDefaults`
  is keyed by bundle id (`app.hydrophone`) — shared with any other build of
  the app Tim might run, not scoped to this Debug binary.

Build clean, zero warnings; full suite green (190 tests, unchanged — this
is AppKit header/menu interaction with no hermetic coverage per
`docs/08-testing.md`, matching #35's precedent); SwiftLint clean across 95
files.

---

## Issue #36: per-view column-visibility/order/width persistence (2026-08-23)
E2 (#10), sub-issue 3 of 5; blocked by #35. Storage only — no picker UI, no
`MusicTrackTable` wiring (both land in #37).

New `UI/Components/TrackColumnPreferences.swift`: `persistedColumns(for
viewKind:)`/`persistColumns(_:for:)` and `persistedWidth(for:in:)`/
`persistWidth(_:for:in:)`, keyed by `viewKind` — reuses `MusicTrackTable`'s
existing `sortAutosaveKey` string rather than inventing a second per-view
identifier. Same lightweight pipe-delimited-string persistence
`TrackTablePersistence.swift` already uses for sort (`"col1|col2|col3"`),
not JSON/Codable — one less thing for a future column rename to break.
Every function takes an injectable `defaults: UserDefaults = .standard` so
tests exercise a real `UserDefaults` round-trip without touching the app's
actual prefs.

Also added `TrackColumn.init?(id:)`, the inverse of the existing `id`
property, needed to resolve stored ids back to cases. Implemented via
`Self.allCases.first(where: { $0.id == id })` (new `CaseIterable`
conformance) rather than a 16-case switch — a hand-written switch here
tripped SwiftLint's cyclomatic-complexity limit (`init` bodies are checked,
unlike the existing `id`/`header`/`widths` computed-property switches,
which the complexity rule doesn't apply to) and would have duplicated the
same 16 id strings already spelled out in `id`.

Hermetic coverage in the new `HydrophoneTests/TrackColumnPreferencesTests.swift`
(7 tests): columns round-trip in order; nil when nothing stored; an unknown
id embedded in otherwise-valid stored data is dropped, not crashed; nil when
*every* stored id has become unrecognized; width round-trips; nil when a
width was never set; widths for different columns/view-kinds don't collide.
Each test uses its own `viewKind` string against a shared isolated
`UserDefaults(suiteName:)` — simpler than a teardown step, and the suite
never touches `.standard`.

No live verification to do or write down: this issue has no UI surface and
no networking — `persistedColumns`/`persistWidth` aren't called from
anywhere yet (that wiring is #37), so there's no behavior change a running
app could show. Same situation as #34's pure data-layer issue.

Build clean, zero warnings; full suite green (190 tests, up from 183 by
these 7); SwiftLint clean across 94 files.

---

## Issue #35: TrackColumn cases + cell/sort for expanded columns (2026-08-23)
E2 (#10), sub-issue 2 of 5; blocked by #34. Adds 8 `TrackColumn` cases
(`.albumArtist, .comments, .grouping, .dateAdded, .lastPlayed, .plays,
.sampleRate, .sortTitle`) with header/width/alignment, plus matching
`textCell`/`sortedTracks` branches in `MusicTrackTable`. Purely a data-
layer-to-cell wiring issue — no column picker, no persistence, not wired
into any real view yet (those are #37/#38).

Cell text + sort logic for the 8 new columns lives in a new
`UI/Components/ExpandedTrackColumns.swift` extension on
`MusicTrackTable.Coordinator`, rather than inline in `MusicTrackTable.swift`
— folding 16 more switch branches directly into `textCell`/`sortedTracks`
pushed both past SwiftLint's cyclomatic-complexity limit and pushed the
struct past its type-body-length limit. Same split `TrackTablePersistence.swift`
already uses for sort/scroll persistence. The right-alignment/font styling
also moved out to `styleAlignment(of:id:)` in the same new file, which
brought `textCell` back under the complexity limit on its own.

`Song.groupings` (from #34) is `[String]?`; the Grouping column joins it
with `", "` for display, `"—"` when empty. Missing dates/counts use explicit
optional ordering and stay last in both directions; real values follow the
selected ascending/descending direction.

**Live verification (2026-08-23), driving the app against Tim's real
Navidrome library** (`music.tail9575a5.ts.net`, 14,794 tracks): temporarily
wired all 8 new columns into `SongsView`'s flat-table `columns:` array
(reverted before commit — not part of this PR), launched the Debug build,
and drove it via macOS Accessibility API scripting + `screencapture`
screenshots (no live GUI automation tool was available for a native app
this session, so this replaced the usual click-through). Confirmed: every
column renders real data with the `"—"` fallback where absent (Comments,
Grouping); Sample Rate formats both whole (`96 kHz`) and fractional
(`44.1 kHz`, `88.2 kHz`) values correctly; clicking the Sample Rate and
Grouping headers sorts both ascending and descending correctly. One
misplaced click briefly starred a real track ("Intro") — caught immediately
from the screenshot and unstarred before moving on; no lasting change to
Tim's library.

**Review fix live verification (2026-08-23), same real server:** temporarily
re-wired the four date/numeric columns into `SongsView`, then confirmed Sample
Rate sorted ascending from `1 kHz` and descending from `96 kHz`. The random
sample had no missing sample-rate values, so the nil-last contract is covered
hermetically by `ExpandedTrackColumnsTests` for Date Added, Last Played, Plays,
and Sample Rate in both directions. Temporary view wiring was reverted.

Build clean, zero compiler warnings; full suite green (183 tests, up from 182
by the expanded-column sorting regression); SwiftLint clean across 92 files.

---

## Issue #34: decode expanded track-column Song fields (2026-08-23)
E2 (#10), sub-issue 1 of 5; spec #7. Adds 8 new optional `Song` fields —
`displayAlbumArtist`, `comment`, `groupings`, `created`, `played`,
`playCount`, `samplingRate`, `sortName` — tolerant-decoded, no UI change.
`created`/`played` ride the existing custom `Date.ISO8601FormatStyle`
decoder (`SubsonicClient.makeDecoder()`), so no new date-decoding path was
needed.

**Bug found by live verification, fixed before it shipped:** the issue
(and #7's spec) assumed `groupings` decodes as a single string, mirroring
`displayComposer`. A standalone `swiftc` harness (`SubsonicModels.swift` +
`SubsonicResponse.swift` + a throwaway `main.swift`, same pattern E3 used)
hit `demo.navidrome.org`'s real `getRandomSongs` endpoint and the decode
threw `typeMismatch` on `groupings` for every song — Navidrome actually
sends it as a JSON string array. `Song.groupings` is now `[String]?`;
formatting it for display (join vs. first-only) is left to #35, which owns
column cell rendering.

**Live verification (2026-08-23) against `demo.navidrome.org`:** the fixed
harness decoded 50/50 real songs from `getRandomSongs` with 0 throws, all
8 new fields populated (`groupings` correctly decoded as `[]` — the demo
library has no non-empty grouping tags, but the empty-array shape decodes
without error). Sample: `samplingRate=44100`, `playCount=113`, real
`created`/`played` timestamps. The scratch harness was deleted after
verification, nothing added to the repo.

Build clean, zero warnings; full suite green (182 tests, up from 180 by
these two); SwiftLint clean across 90 files.

---

## PR #32: refresh native-feature-detection branch from `main` (2026-08-23)
Merged `origin/main` at `7bcff5e24866e312d0c21f196360e97c36cc7e52`
into `issue-26-navidrome-feature-detection` after PR #33 landed issue #25.
The production and test code combined automatically; the only conflicts were
the expected additive documentation overlaps in `docs/08-testing.md` and this
file. Resolution keeps both same-day progress entries newest-first and updates
the combined suite totals to 180 tests across 90 Swift files. No rebase or
history rewrite.

**Post-merge verification:** build succeeded; all 180 tests passed with 0
failures or skips; SwiftLint reported 0 violations across 90 files. Re-ran the
actual Debug app with `HYDROPHONE_SCREENSHOT_FRESH=1` against
`demo.navidrome.org` 0.63.2: **Use Demo Server** connected and showed **Native
Navidrome features available**; **Scan Library** surfaced the demo account's
expected authorization error without a crash; after disconnecting, a
deliberately wrong password produced server error 40 and no native-feature
status line. The isolated app was then quit; the real Keychain item was never
touched.

## #26: Navidrome native-feature detection + song-index invalidation hook (2026-08-23)
`ConnectionModel` gains `nativeFeaturesState` (`.unknown`/`.checking`/
`.available`/`.unavailable`) — the on/off switch later E4/E5 classical-metadata
UI will check before using `NavidromeClient`. Detected automatically (never a
Settings toggle): after a successful Subsonic connect (`saveAndConnect()` or
`refresh()`), a real `NavidromeClient.login()` probe decides it; any failure
(network, 401, non-Navidrome server, API-key auth with no password to log in
with) settles on `.unavailable`. `testConnection()` deliberately never probes
— it verifies unsaved form credentials, while `login()` always reads the
persisted store, so probing there would check the wrong server.
`disconnect()` resets the flag to `.unknown`.

`AppModel` now constructs a `NavidromeClient` in its composition root and
hands it to `ConnectionModel`, its only consumer for now. Settings →
Connection shows a read-only status line reflecting the probe result, next to
the existing scan-trigger UI.

`ConnectionModel.startLibraryScan()` now calls `NavidromeClient.
invalidateSongIndex()` (#24) after a successful scan request, so a rescan's
adds/removes/retags aren't served stale by the in-memory song-index cache —
the next consumer (no UI yet; E4/E5) rebuilds it from scratch.

Added `ConnectionModelNativeFeaturesTests` (7 tests): probe outcomes
(available/unavailable/API-key-no-network-call), `testConnection()`'s
deliberate non-probing, `disconnect()`'s reset, and the scan → invalidation
hook. Own `ConnectionProbeMockProtocol` (not the existing
`NavidromeMockProtocol`) since this suite has to stub both `SubsonicClient`'s
`/rest/...` calls and `NavidromeClient`'s native ones in the same test, and
two `.serialized` suites sharing one mock's static state would race. Suite
count: 167 → 174.

**Live-verified (2026-08-23) against `demo.navidrome.org` 0.63.2** via a
standalone harness compiling `NavidromeClient`/`SubsonicClient` + their model
dependencies with `swiftc` and reproducing `ConnectionModel`'s exact call
sequence (works around the documented `xcodebuild test` env-forwarding gap
above `## Environment`):
- Real demo credentials → Subsonic ping OK (type `navidrome`, version
  `0.63.2`), `login()` succeeded → `nativeFeaturesState` would land on
  `.available`.
- Wrong password → Subsonic ping itself fails (`code 40, Wrong username or
  password`) before the native probe ever runs — exactly `ConnectionModel`'s
  control flow, so the flag never claims availability and nothing else is
  affected. (The API-key-with-Subsonic-still-connected branch of the probe —
  where `login()`'s local `apiKeyAuthUnsupported` guard fires without a
  network call — isn't reproducible against the demo server, since it has no
  API key configured; that exact branch is covered instead by
  `ConnectionModelNativeFeaturesTests`, which can force it deterministically.)
- Scan-invalidation hook: `songIndex()` (14,794 songs) cached at ~2×10⁻⁵s on
  repeat, then `invalidateSongIndex()` (the literal call
  `startLibraryScan()` makes) forced a full ~4.4s re-walk on the next call —
  confirms the cache is actually cleared, not just marked stale.
- The harness was deleted after verification (kept out of the repo).

**Actual-app UI verification (2026-08-23), same server, via screen automation**
(Tim granted the terminal Accessibility access mid-session so this could be
driven for real, not just through the harness above). Launched the Debug
build with `HYDROPHONE_SCREENSHOT_FRESH=1` (in-memory credentials, never
touches the real Keychain item) and drove Settings → Connection by hand:
- Filled in `demo.navidrome.org` / `demo` / `demo` and clicked **Save &
  Connect** → `Connected to navidrome 0.63.2 (be10f89c)`, and immediately
  below it, in the scan-trigger section: **✅ "Native Navidrome features
  available"** — the read-only status line, live, in green, exactly as
  designed.
- Clicked **Scan Library** on that same (unprivileged) demo account →
  `Server error 50: User is not authorized for the given operation`, surfaced
  cleanly in `scanMessage` with no crash; the native-features line stayed
  `available`, unaffected. (Confirms `startLibraryScan()`'s failure path is
  inert — `invalidateSongIndex()` only fires from the success branch, which
  the demo account can't reach; that success path is the one the harness and
  `ConnectionModelNativeFeaturesTests` already prove directly.)
- Disconnected, then retried **Save & Connect** with a deliberately wrong
  password → `Server error 40: Wrong username or password`, connection stays
  `Not Connected`, and no native-features line appears at all (state never
  reaches `.connected`, so the probe never runs — the flag never claims
  availability). Zero regressions, zero crashes.
- Quit the app afterward; no server state or Keychain item touched (fresh
  in-memory credentials only).

## Issue #25: NavidromeClient `songs(byComposerId:)` and `workMetadata(songId:)` (2026-08-23)
Two read-only lookups over #24's `songIndex()` cache, added as a `NavidromeClient`
extension alongside `composers()` in `Services/NavidromeClient.swift` — no new
network calls, since each cached `NativeSongRecord` already carries
`participants` and `tags`:
- `songs(byComposerId:)` filters the cached index by `participants.composer[].id`,
  including joint-credit songs that list several composer ids (there's no
  server-side "songs by composer" filter — confirmed by #24's testing — so this
  is the only correct approach).
- `workMetadata(songId:)` reads a new `WorkInfo` struct (`Networking/NavidromeModels.swift`)
  from a song's `tags["work"/"movementname"/"movement"/"movementtotal"]`,
  parsing `movement`/`movementtotal` as **separate** `Int`s (Navidrome tags
  them as independent plain-number strings, not a combined "n/total"), each of
  the four fields optional on its own. Returns `nil` for an unknown song id or
  one with none of the four fields.

Hermetic coverage lives in `HydrophoneTests/NavidromeComposerSongLookupTests.swift`,
an extension of `NavidromeClientNetworkTests` (same pattern
`NavidromeComposerNetworkTests.swift` already used for #23) — this keeps the
new tests inside the existing `.serialized` suite sharing `NavidromeMockProtocol`
safely, without adding a second stubbed `URLProtocol` that would race it (Swift
Testing runs distinct suites concurrently by default; `.serialized` only
serializes within one suite). Covers joint-credit filtering, a non-matching
composer id, no extra network call beyond `songIndex()`'s own, the confirmed
real-library Schubert movement fixture from the issue body, a work with no
numbered movement, and the nil cases.

**Verification:** build succeeds with zero compiler warnings; full suite green
(**TEST SUCCEEDED**, 173 tests, 0 failures — up from 167 by these 6; ran three
times back-to-back with no flakes to rule out a suite-ordering race); SwiftLint
reports 0 violations across 89 files. Live-verified 2026-08-23 against Tim's
real Navidrome server: compiled `NavidromeClient`/`NavidromeModels`/
`CredentialStore`/`AsyncLimiter` standalone with `swiftc` (the same workaround
#24/PR #31 used, since `xcodebuild test` doesn't forward `HYDROPHONE_*` into the
XCTest runner process) and ran a scratch harness — `composers()` returned 1,694
rows in 0.54s; picking Aaron Copland (reported `songCount: 12`),
`songs(byComposerId:)` returned exactly 12 songs; `workMetadata(songId:)` on a
song from the index decoded `work: "Variations on a Melancholy Theme"`,
`movementName: "Cadenza"`, `movementNumber: 13`, `movementTotal: 14` — matching
the parse-as-separate-ints contract. The scratch harness was deleted after.

## PR #31: refresh song-index branch from `main` (2026-08-23)
Merged `origin/main` at `40283cb7ddb3f0e94df30543f20518a8fa991630`
into `issue-24-navidrome-song-index` after GitHub reported PR #31 as
`DIRTY`/`CONFLICTING`; no rebase or history rewrite. The five conflicts were
additive overlaps from #30's composer-roster work and #31's song-index work:
`NavidromeModels.swift`, two Navidrome network/live test files,
`docs/08-testing.md`, and `docs/PROGRESS.md`. Resolution keeps both model and
client APIs, both test families, and both progress histories. The combined
suite count is 167 (the 164-test #31 head plus #30's three composer tests).

Combining both feature lines crossed two SwiftLint size thresholds. The
`composers()` method now lives in a same-file `NavidromeClient` extension, and
its network regression lives in `NavidromeComposerNetworkTests.swift` as an
extension of the existing serialized suite. This preserves the suite's shared
mock ordering without lint suppressions; no runtime behavior changed.

**Verification:** full build succeeded with no compiler diagnostics; the
Xcode result reports 167 passed, 0 failed, and 0 skipped; SwiftLint reports 0
violations across 88 files. Xcode also emitted its existing tool-level notices
for the ambiguous universal-Mac destination and skipped App Intents metadata
extraction. Live verification against the public demo server on 2026-08-23
returned 18 localized-name-sorted composer rows in 0.513s and 501 songs in
0.517s; the cached song-index call took 0.000048s, and two concurrent calls
after invalidation both returned all 501 songs in 0.319s total. The standalone
scratch harness was deleted after verification.

## NavidromeClient: close PR #31 re-review findings (2026-08-23)
Re-review of #31 at `fb08e4eb796287c4760260ffa1574825ba55da8f`
found that the first generation-counter fix did not retire an in-flight
song-index build when a credential change started a replacement build. If
the new-server build completed first and the old-server build completed
later, the old completion could overwrite the new cache and clear the newer
in-flight state. The build task also called the public `paginatedGet()`
entry point, which reloaded credentials instead of using the snapshot that
had been captured to label the build.

Fixed by assigning a new generation to every song-index build (not just to
explicit invalidation) and by routing both callers through a private
`paginatedGet(PageQuery, ...)` core so the full walk uses the build's captured
`ServerCredentials`. The public helper still loads credentials once, creates
its query snapshot, and delegates to that core. A
deterministic regression test starts old- and new-server builds, releases the
new one first, then the old one, and proves the final call is served from the
new cache without a third request. In its RED run, the request hosts were
`old, new, new`; after the fix, the full `NavidromeClientNetworkTests` suite
passed all 12 tests with only `old, new`.

The exact reviewed head contained 163 Swift Testing tests, not the 162 stated
in the docs (or the 159 still stated in the PR body). The new race regression
brings the current suite to 164; the testing guide and verification block are
now synchronized to that count.

**Live verification:** the same standalone-`swiftc` method used for the
earlier #31 review fixes exercised the changed path against the public demo
server on 2026-08-23. `login()` succeeded in 0.351s; the first `songIndex()`
returned 501 songs in 0.461s; a cached call returned all 501 in 0.000021s;
after invalidation, two concurrent calls both returned all 501 songs in
0.331s total. The scratch harness was deleted after verification.

Final gate: build succeeded with no compiler diagnostics; the full suite
passed 164/164 with 0 failures and 0 skips; SwiftLint found 0 violations.
Xcode also emitted its existing tool-level notices for the ambiguous
universal-Mac destination and skipped App Intents metadata extraction.

## NavidromeClient: full song index — songIndex() (2026-08-23)
Issue #24 (E3, epic #11; blocked by #22, blocks #25). Adds `NativeSongRecord`
(`Networking/NavidromeModels.swift`) — a lightweight, native-only decode of
`/api/song` entries carrying `id`/`title`, per-role `participants`
(`composer`/`artist`/`albumartist`, each `[Credit]`), and raw `tags`
(`[String: [String]]`, e.g. `work`/`movementname`/`movement`/`movementtotal`).
Deliberately separate from `Song` (`SubsonicModels.swift`), which stays the
playback pipeline's model; every field beyond `id` decodes tolerantly (a
missing key is normal, not an error) since the shape is undocumented.

`NavidromeClient` gains `songIndex()` and `invalidateSongIndex()`: the former
paginates `/api/song` via the existing `paginatedGet` helper (#22's 6-way
concurrent walk) and caches the result in an actor-private property, so
repeat calls in the same app session return the cached copy without
refetching; the latter clears the cache for a future sub-issue's rebuild
hook (e.g. after a library scan) — this issue only adds the primitive, not
a UI trigger.

Hermetic coverage: `NavidromeClientTests` decodes a representative
`/api/song` fixture with `participants`/`tags` populated, and a second
fixture with both absent (tolerant-decode path); `NavidromeClientNetworkTests`
proves `songIndex()` hits `/api/song` once across two calls (cached) and
twice after an `invalidateSongIndex()` in between, via the stubbed
`URLProtocol`. `NavidromeLiveTests` gains a `songIndex()` round trip
(opt-in, `HYDROPHONE_HOST/USER/PASS`).

**Live verification:** `xcodebuild test`'s known env-var-forwarding gap
(documented in `08-testing.md`, first hit in #22) still applies, so
verification used the same `swiftc`-standalone method — compiling
`NavidromeClient.swift`/`NavidromeModels.swift`/`CredentialStore.swift`/
`AsyncLimiter.swift` directly (inheriting the shell environment) against
the public Navidrome demo server (`demo.navidrome.org`/`demo`/`demo`, the
same credentials Settings' "Use Demo Server" button uses). Result: `login()`
succeeded; `songIndex()` returned 501 songs in 0.49s, with 217 carrying
composer participants and 436 carrying tags (spot-checked one: "Wedding
March for a Bullet" → composer "Diablo Swing Orchestra"); a second
`songIndex()` call returned instantly (0.0000s, cache hit, no refetch); a
third call after `invalidateSongIndex()` took 0.44s (confirmed refetch). The
scratch harness was deleted after verification, nothing added to the repo.

Build clean, zero warnings. Full suite green (164 tests — see the two
review-fix entries, which add four more on top of this entry's original five).
SwiftLint clean.

## NavidromeClient: address PR #31 review findings (2026-08-23)
Review of #31 (PR for #24) found a credential-binding bug matching the
`cachedTokenCredentials` pattern already fixed for the token cache in #27,
plus an actor-reentrancy race in the new `songIndex()` caching, plus a stale
test count.

**[P1] Song cache wasn't bound to the credentials it was built for.**
`songIndex()` returned `cachedSongIndex` on presence alone, without checking
`CredentialStore` first — after Settings changes server/account, the same
long-lived `NavidromeClient` would keep serving the previous server's songs.
Fixed the same way as the token cache: `cachedSongIndexCredentials:
ServerCredentials?` stored alongside the cache; a hit now requires an exact
match. New `songIndexIsInvalidatedByCredentialChange` test (mirrors
`credentialChangeInvalidatesCachedTokenAndTargetsNewHost`): saves new
credentials between two `songIndex()` calls, asserts the second call
refetches against the new host.

**[P2] Overlapping callers could each start a full paginated walk, and an
in-flight build could resurrect a cache `invalidateSongIndex()` just
cleared.** Actor isolation is reentrant across an `await`, so two concurrent
`songIndex()` calls could both observe a nil cache and each kick off their
own `/api/song` walk; separately, `invalidateSongIndex()` running while a
build was mid-flight didn't stop that build from writing its (now-stale)
result into the cache once it finally completed. Fixed with an in-flight
build (`Task<[NativeSongRecord], Error>`) that overlapping callers coalesce
onto — gated by credentials too, so a caller under new credentials can't be
handed a build's result fetched under the old ones — plus a generation
counter `invalidateSongIndex()` bumps: a build only writes the cache (and
clears the in-flight slot) if the generation is still the one it started
under, and invalidation itself clears the in-flight slot so a post-
invalidation caller starts a genuinely fresh build rather than coalescing
onto the retired one. New tests: `concurrentSongIndexCallsCoalesceIntoOneWalk`
(two concurrent calls, one `/api/song` request) and
`invalidationDuringInFlightBuildIsNotClobberedByItsCompletion` (invalidate
while a build awaits its response; the next call must refetch). Both use a
new `Gate` actor in the test file — a continuation-based hold on the mock's
response — to make "in flight" deterministic instead of racing real async
timing; this required widening `NavidromeMockProtocol`'s handler type from a
sync to an async closure (source-compatible with every existing sync handler
via Swift's normal sync-to-async function conversion).

**[P2] Stale test count.** This entry and the `## Verification status` block
said 159; `docs/08-testing.md` said 155. This review round changed them to
162, but re-review established that exact head actually contained 163 tests;
the follow-up regression brings the current suite to 164 (see the entry
above).

Re-verified against the real server after these fixes (same `swiftc`-
standalone method noted above, against the public demo server): `login()`
succeeded; `songIndex()` returned 501 songs in 0.45s; a cached second call
returned instantly (0.0000s); after `invalidateSongIndex()`, two concurrent
`songIndex()` calls both returned all 501 songs in 0.37s total — one walk's
worth of time, confirming the coalescing fix holds against a real server, not
just the mock. Build/test/swiftlint clean.
## NavidromeClient: composer roster — `composers()` (2026-08-23)
Closes #23 (E3, epic #11), built on #22's `paginatedGet` helper.

- Added `Composer` (`Networking/NavidromeModels.swift`): `id`, `name`, plus
  optional `songCount`/`albumCount` read tolerantly from the nested
  `stats.composer` object via a custom `init(from:)` — every field but
  `id`/`name` is optional since this is an internal/undocumented API.
- Added `NavidromeClient.composers()`: walks `/api/artist` via `paginatedGet`
  with `role=composer`, `sort=name`, `order=ASC`, then applies a final
  `localizedStandardCompare` sort after pagination. Live verification exposed
  a Navidrome database-collation mismatch (`André Caplet` before
  `Andre Caplet`); the final client sort now guarantees macOS-localized order.
- Roster rows are surfaced exactly as Navidrome presents them, including its
  synthetic joint-credit entities (e.g. one row named "A, B, and C" for a
  jointly-credited track, with its own id, distinct from A/B/C's individual
  rows) — matching the existing `displayComposer` show-the-server's-string
  convention. No dedup attempted; that's explicitly out of scope.
- Hermetic fixture decode test (`NavidromeClientTests.decodesComposerRoster`)
  covers a regular row, a joint-credit row, and a row missing `stats`
  entirely (tolerant decode must not throw).
- Hermetic network regression test
  (`NavidromeClientNetworkTests.composersSortsServerRosterWithLocalizedStandardOrder`)
  covers the accented/unaccented collation mismatch independently of server
  database behavior.
- Live-verified against Tim's real library (`music.tail9575a5.ts.net`,
  14,794 tracks): `composers()` returned all 1,696 composer rows,
  localized-name-sorted after the client fix, matching a direct `curl`
  cross-check of the same endpoint's complete roster
  (`X-Total-Count: 1696`); covered by a new opt-in
  `NavidromeLiveTests.composersReturnsNonEmptyNameSortedRoster`.
- No UI — `Composer` is a data-layer method only; E4 (#12) consumes it later.

---

## NavidromeClient: address PR #27 re-review findings (2026-08-23)
Re-review of #27 found the first credential-binding fix (previous entry) was
incomplete, plus a leftover stale count.

**[P2] Credential snapshot wasn't held for the whole `paginatedGet` walk.**
The previous fix made one `fetchPage()` call internally consistent, but each
page — including the concurrent pages after page zero, and a 401 retry —
still called `credentials.load()` independently. A Settings change between
page zero completing and the remaining pages firing could still mix pages
from two different servers/accounts into one result; the existing
credential-change test couldn't catch this because its mock always returned
a single-page `X-Total-Count: 1`. Fixed: `PageQuery` (already "the parts that
stay constant across every page") now also carries the `ServerCredentials`
snapshot, loaded once at the top of `paginatedGet()` and threaded through
every page — including the 401-retry recursion, which reuses the same
`query`. New `credentialChangeMidMultiPageWalkDoesNotMixServers` test: a
2-page walk (`X-Total-Count: 1000`, pageSize 500) whose mock handler saves
new credentials to the store on the *first* `/api/artist` request (simulating
Settings changing mid-walk); asserts every page still targeted the original
host.

**[P2] Stale test count survived in a second location.** `docs/08-testing.md`
was corrected to 154 in the previous round, but the older canonical
`## Verification status` block further down this file still said 67 —
two contradictory counts in one file. Fixed in place; that section is a
dated historical snapshot (2026-06-22) otherwise left as-is, not rewritten.

Re-verified against the real server after this fix: login + a full 14,794-song
`/api/song` paginated walk succeeded end to end (the multi-page path this fix
specifically targets). Build/test/swiftlint clean.

## NavidromeClient: address PR #27 review findings (2026-08-23)
Codex's review of #27 (PR for #22) found two real bugs and two contract-sync
gaps, all fixed on the same branch.

**[P1] Cached JWT wasn't bound to the credentials it was minted for.**
`ensureValidToken()` reused `cachedToken` on expiry alone; `apiRequest()`
separately reloaded the current credentials for the URL. After Settings
changes server/account mid-session, the next native request could attach the
old server's/account's bearer token while pointed at the new host. Fixed:
`cachedTokenCredentials: ServerCredentials?` (already `Equatable`) is stored
alongside the token; a cache hit now requires an exact match, not just
non-expiry. `login()`/`ensureValidToken()`/`apiRequest()` all take one
`ServerCredentials` snapshot loaded once per `fetchPage` call, rather than
loading the store independently at two points that could observe different
values mid-flight.

**[P2] Missing/malformed `X-Total-Count` silently truncated the walk.**
`total = totalCount(from: http) ?? (start + decoded.count)` treated an
unparseable header as "this page is the whole library" — exactly backwards
for a helper whose entire contract is walking a resource *fully*. Now a
missing/invalid header throws `NavidromeError.decoding` instead of returning
a falsely-complete result.

**[P2] No hermetic coverage of cache reuse / expiry / retry.** New
`NavidromeClientNetworkTests.swift`: a stubbed `URLProtocol`
(`NavidromeMockProtocol`) on a per-test `URLSessionConfiguration.ephemeral`
proves — without any network — that a valid cached token is reused across
calls (one login for two operations), an expired one triggers a fresh login
per call, a credential change invalidates the cache **and** the next request
targets the new host (the P1 fix, end to end), a 401 triggers exactly one
retry-and-relogin before failing, and a missing total-count header fails
loudly. The suite is `@Suite(.serialized)` — its tests share one static mock
state by design (standing in for one real server across a session) and would
race each other under Swift Testing's default parallel execution; that
exact race was hit and diagnosed while writing these tests (five failures,
login counts of 5–8 instead of 1–2) before adding the trait.

**[P2] Docs weren't synced.** `docs/01-architecture.md` now lists
`NavidromeClient`/`NavidromeModels` in the layer diagram, service
responsibilities, and module structure. `docs/02-opensubsonic-api.md` notes
the native `/auth/login` raw-password exception inline where the
never-send-the-password rule is stated, plus a new "Navidrome native API"
section summarizing auth/pagination/the no-server-filter finding for anyone
landing on this doc without the epic's history. `docs/08-testing.md`'s suite
list and count were stale (67 tests, predating a lot of unlisted work) —
corrected to the actual current 154, with the new suites added and the
`xcodebuild test` env-var-forwarding gap (discovered in the original #22
verification pass) documented as affecting `LiveDecodeTests` too, not just
`NavidromeLiveTests`.

Re-verified end to end against the real server after all fixes (same
`swiftc`-standalone method as the original pass, since the env-var gap above
still applies): login, a full paginated `/api/artist` walk, and a second walk
proving cache reuse (sub-second, no re-login) all succeeded.

Build/test/swiftlint clean.

## NavidromeClient foundation: auth, JWT lifecycle, pagination helper (2026-08-23)
Issue #22 (E3, epic #11; blocks #23/#24/#25/#26). New `Services/NavidromeClient.swift`
(`actor NavidromeClient`) and `Networking/NavidromeModels.swift`, standing up the
native react-admin API (`/api/...`, separate from Subsonic's `/rest/`) alongside
`SubsonicClient` — metadata only, no playback, per the E3 spike (#8).

`login()` calls `POST /auth/login`, caches the returned JWT in-actor, and decodes
its `exp` claim (no signature check — expiry-checking only, the server is the real
authority) rather than guessing a TTL; `ensureValidToken()` reuses an unexpired
cached token or re-logs-in, with a 30s leeway so a request built just before
expiry doesn't land as a 401 mid-flight. `apiKeyAuthUnsupported` is a new
`NavidromeError` case: the stored credentials can be OpenSubsonic API-key auth
(no raw password to log in with), which the original issue spec hadn't accounted
for — `login()` now fails cleanly instead of sending garbage as a password.

`paginatedGet<T>()` walks react-admin list resources (`_start`/`_end`/`_sort`/`_order`,
total via the `X-Total-Count` response header) fully, fetching pages concurrently
after the first through the existing `AsyncLimiter(limit: 6)` (`Services/AsyncLimiter.swift`)
— the same limiter and limit `ArtworkCache` already uses, and the concurrency level
measured against a real library in #8/#22 (14.2s sequential vs 5.3s at 6-way for
14,794 songs). A 401 triggers one re-login-and-retry per page; a second 401 is a
real `authenticationFailed`. `fetchPage` bundles the per-call-constant parts
(path/sort/order/extraQuery) into a private `PageQuery` to stay under SwiftLint's
parameter-count limit.

Hermetic tests (`NavidromeClientTests.swift`): JWT `exp` decoding against a real
captured token shape, expiry/leeway boundary cases, login/API request construction
(paths, headers, auth-method gating), and login-response decoding. Live tests
(`NavidromeLiveTests.swift`, gated on `HYDROPHONE_HOST`/`USER`/`PASS` like
`LiveDecodeTests`) exercise `login()` and `paginatedGet()` against a real server.

**Live verification, and a discovered tooling gap:** `xcodebuild test` on this
machine does **not** forward the invoking shell's environment into the XCTest
runner process — confirmed via a temporary diagnostic assertion (`ProcessInfo`
inside the test process saw 45 env vars, none of them `HYDROPHONE_*`, none
matching what the invoking shell had; `IDETestRunnerAdditionalEnvironmentVariables`
didn't change this). This is **not new to this issue** — `LiveDecodeTests` has the
identical silent-skip problem today (confirmed by comparing durations: both old
and new "live" tests complete in the same near-zero time whether or not the env
vars are set). Actual live verification was done by compiling the real
`NavidromeClient.swift`/`NavidromeModels.swift`/`CredentialStore.swift`/
`AsyncLimiter.swift` sources standalone with `swiftc` (inheriting the shell
environment directly, bypassing `xcodebuild`) and running them against Tim's real
server: `login()` succeeded (JWT decoded correctly, valid ~48h out); `paginatedGet`
against `/api/artist` returned 2,766 composers+artists; against `/api/song` returned
14,794 songs in ~5.2s, matching the #8 benchmark. The scratch harness was deleted
after verification, nothing added to the repo. **Follow-up worth filing:** the
`HydrophoneTests` scheme needs its Test action's environment variables wired
(scheme-level, not committed with real values) for `xcodebuild test` to actually
exercise any live test locally — affects `LiveDecodeTests` too, pre-existing.

Build clean (zero warnings introduced; three pre-existing `ScrollMemory.swift`
Sendable-capture warnings confirmed present on `main` before this branch).
Full suite green. SwiftLint clean.

## Fix: ScrollMemory Sendable-capture warnings (2026-08-23)
Unticketed. `Binding.scrollMemory(read:write:consumed:scope:topIDs:)`
(`UI/Components/ScrollMemory.swift`) triggered three Swift 6 strict-concurrency
warnings: `read`/`write`/`topIDs` (plain, non-`Sendable` closures) were captured
inside `Binding`'s `get`/`set`, which this SDK types as `@Sendable`. Marking the
three parameters `@Sendable` only relocated the problem — it surfaced that the
callers' closures (`ArtistsView`, `AlbumsView`, `HomeView`) capture
`@AppStorage`-backed, main-actor-isolated view state, which genuinely can't be
Sendable. The correct fix: mark `read`/`write`/`topIDs` **and** the
`scrollMemory` function itself `@MainActor` instead — the true isolation this
code always ran under (SwiftUI view bodies/modifiers), not `@Sendable`. A
main-actor-isolated closure is itself `Sendable` per Swift's actor-isolation
rules, so this satisfies `Binding`'s requirement without misrepresenting where
the code actually runs. Pure annotation fix — no logic changed.

Build/test/swiftlint clean (zero warnings, down from three pre-existing).
**Live verification partial:** the built app launches and connects to a real
Navidrome server without crashing (rules out a MainActor deadlock/trap from the
isolation change), but this sandbox has no Accessibility permission granted, so
scripted UI clicks (`cliclick`/`osascript`) silently no-op — couldn't
interactively confirm scroll-restore still works in Albums/Home/Artists.
Flagged for Tim to spot-check before merging.

## Composer column shown in Album, Songs, Favorites, Search (2026-08-22)
Issue #4 (part of #1, blocked by #3). Adds `.composer` to the `columns:`
array in `AlbumDetailView`, `SongsView`'s flat-table branch, `FavoritesView`,
and `SearchResultsView` — right after `.album` (`.artist` in Album View,
which has no Album column), matching the "who" cluster placement rule.
Live verification surfaced that Songs defaults to the column browser
(`showColumnBrowser = true`), which has its own separate `TrackTableView`
call the issue's scope guard explicitly excluded — so the fix was invisible
in the common case. Per direction, widened scope: `ColumnBrowserView` gains
a fourth **Composer** pane (Genre → Artist → Album → Composer, cascading the
same way Album resets on an Artist change) and `.composer` in its table too.
Composer-pane track completeness inherits an existing data-fetch limitation
(see "Known limitations" above) — flagged, not fixed, here; a real fix needs
a song-fetch rework, tracked as a separate follow-up.
Post-refresh live verification also found that the demo server returns empty
`displayComposer` strings for some songs, which created a blank Composer pane
row whose selection behaved like **All Composers**. `Song` now exposes a
shared UI accessor that treats empty or whitespace-only composer text as
missing while preserving non-empty server text verbatim; the browser, table
sorting and cells, and Get Info all use it. Regression coverage verifies both
blank-value normalization and preservation of valid composer text.
Full suite green, swiftlint clean, build clean.

## Composer row in Get Info sheet (2026-08-22)
Issue #5 (part of #1, blocked by #2). `TrackInfoView`'s `Form` gains a
Composer row next to Genre, shown only when `song.displayComposer` is
present and non-empty — no placeholder when absent, matching the Genre/Year
rows. Display-only, same as the rest of the sheet. Full suite green,
swiftlint clean; live-verified against a real server (composer column and
value confirmed present for a track with a composer).

## Composer column: `TrackColumn` + table wiring (2026-08-22)
Issue #3 (part of #1, blocked by #2). `TrackColumn` gains a `.composer` case
(id `"composer"`, header "Composer", artist widths, default-left alignment).
`MusicTrackTable.Coordinator` renders it via the shared `SecondaryTextCell`
path (`song.displayComposer ?? "—"`) and sorts it case-insensitively via
`displayComposer`. No screen shows the column yet — that's #4. While here,
split `MusicTrackTable.swift`'s `NSViewRepresentable` lifecycle
(`makeNSView`/`addColumns`/`updateNSView`) and the private `InnerTableView`
class into a new `TrackTableLifecycle.swift`, following the file's existing
`TrackTableCells.swift`/`TrackTablePersistence.swift` split pattern — the
two added lines pushed the file 2 lines past SwiftLint's 450-line
`file_length` warning threshold. Full suite green, swiftlint clean.

## Composer decoding: `Song.displayComposer` added (2026-08-22)
Data-model-only change for issue #2 (part of #1). `Song` now decodes
OpenSubsonic's `displayComposer` string field verbatim (server already
joins multiple composers into one string; no client-side splitting or
fallback to `artist`/`albumArtist`). Three new tests in
`DecodingTests.swift` cover present/multi-composer/absent cases — written
first, confirmed to fail to compile, then made to pass. Full suite green,
swiftlint clean. No UI consumes the field yet.

## Agent workflow codified: worktree → PR → stop → merge (2026-08-21)
All feature/fix work now runs in its own git worktree under `.worktrees/`
(gitignored) on an `issue-<n>-<slug>` branch cut from `origin/main`. An agent
must clear the four-part gate — build clean, tests pass, `swiftlint` clean,
live-verified against a real server — plus a PROGRESS entry on the same branch
before opening a PR, then **stops**: no CI chasing, no review-comment fixes, no
self-merging. Merges happen only on request, always `gh pr merge --merge` (true
merge commit, never squash or rebase) so each issue's fork and join stay visible
in the graph; the worktree and both branch refs are deleted afterwards. Written
up in `docs/11-agent-workflow.md` (rationale), `AGENTS.md` (enforceable short
form, also for Codex/Copilot), and the `/issue` + `/land` skills under
`.claude/skills/`. Cloud sessions can't meet the gate, so they open draft PRs.

## Navidrome client directory: submission opened (2026-08-16)
PR navidrome/website#425 adds Hydrophone to the official client apps
directory (assets/apps/hydrophone: schema-validated YAML + five WebP
shots from the rights-cleared library). Eligibility note: their rule
wants 15 stars for open-source apps; we lead with the Mac App Store
listing instead. Awaiting maintainer review.

## Mac App Store: APPROVED & RELEASED — 0.6.2 (2026-08-16)
Third submission passed App Review (window-scene fix + rights-cleared
screenshots + the round-3 evidence package: on-device screen recording
and the seven-item information reply). Version released manually from
Pending Developer Release; listing live at
<https://apps.apple.com/app/id6795956982>. Website hero and fact sheet
now link the store page alongside the direct download; README's "in
progress" note replaced with the store link. This closes M8. The review
recording stays hosted at hydrophone.app/review/ while the review thread
links to it; retire it in a future cleanup.

## App Review round 3: response sent (2026-08-14)
All seven items posted as a reply in the submission thread with the
82→76.5s screen recording attached (plus a public mirror at
hydrophone.app/review/, now hosted in `site/review/`), and items 2–7
stored in App Review Information → Notes with refreshed contact info.
ASC quirks for next time: the reply dialog's Attach File shows NO
feedback — attachments appear only after Save Draft (we accumulated five
duplicates before noticing; hover a row for its remove button), and the
recording's first frames needed re-cutting because killing the frontmost
app pre-recording un-hides the next app. Review resumes from the reply;
awaiting Apple.

## App Review round 3: 2.1 Information Needed — response prepared (2026-08-14)
Apple asked for a screen recording plus seven written items. Recording
produced on-device (82s, `drafts/appstore/review-video/`): fresh launch →
onboarding → server login → library browse → playback → Up Next panel →
column browser → Favorites → menu-bar mini player → disconnect, all
against the rights-cleared local library. Harness additions:
`HYDROPHONE_SCREENSHOT_FRESH=1` (DEBUG) starts with an empty in-memory
credential store for onboarding flows. Automation gotchas burned into the
take script: raise the Settings *window* (AXRaise), not the process —
process-frontmost lifts the full-screen main window over Settings and
swallows clicks; SecureFields drop synthetic per-char keystrokes — paste
(⌘V) instead; System Events `keystroke` needs ~1s flush before the next
click. Written answers for all seven items:
`drafts/appstore/review-notes.md` — ready to paste into ASC.

## Mac App Store: 0.6.2 resubmitted for review (2026-08-13)
The rejected version record was edited to 0.6.2 with build 12 attached,
the six rights-cleared screenshots replaced the old set (ASC quirk worth
remembering: concurrent uploads land in arbitrary order — upload one file
at a time to keep the sequence), and the submission went back to App
Review with a reply covering both fixes. Now waiting on the verdict.

## Release: v0.6.2 (build 12) — window reopen fix (2026-08-13)
Published via `publish.sh` (notarized, stapled, Gatekeeper-accepted);
hand-written notes + site changelog entry done. Sole user-facing change:
the Window-scene fix below (App Review guideline 4). README needs no sync
(no feature changes). Build 12 uploaded to ASC via `release.sh app-store`
for the resubmission alongside the rights-cleared screenshots below.

## Rights-cleared App Store screenshots produced (2026-08-13)
Answer to the 5.2.1 rejection: six art-directed 2560×1600 screenshots in
`drafts/appstore/final/` (git-ignored), showing only original content — a
generated library of 14 fictional albums (hand-written SVG covers rendered
with headless Chrome; quiet-pink-noise AAC at a realistic ~192 kbps, since
encoded silence reads "2 kbps" in the Quality column) served by a local
Navidrome and seeded with playlists/favorites/scrobbles so Home looks
lived-in. Captures were driven against a Debug build using a new
DEBUG-only env override (`HYDROPHONE_SCREENSHOT_SERVER/_USER/_PASS` →
in-memory credential store in `AppModel`), so the real Keychain item was
never touched; user defaults were snapshotted and restored around the run.
Composites reuse the site's palette/type (Bricolage Grotesque + Archivo,
#0b0b0d/#41c6f2) and its H1 as the hero line. Full regeneration kit +
notes in `drafts/appstore/README.md`. Remaining for resubmission: bump to
0.6.2 (build 12), upload build + screenshots in ASC, reply to the review.

## App Review: 0.6.1 rejected — window reopen + screenshot artwork (2026-08-12)
0.6.1 (build 11) came back with two issues. **Guideline 4:** closing the main
window left no menu item to reopen it — `CommandGroup(replacing: .newItem)`
had removed New Window (⌘N → New Playlist), and a `WindowGroup` offers no
other route back. Fixed by making the main scene a single `Window("Hydrophone",
id: "main")` — the system now lists "Hydrophone" in the Window menu, and it
matches reality anyway (one shared player, multiple windows never made
sense). Live-verified: close → 0 windows → Window ▸ Hydrophone reopens.
**Guideline 5.2.1:** the ASC screenshots (taken against the Navidrome demo
library) show third-party album covers — needs new screenshots with cleared
artwork or documentary evidence in ASC; no code change. Note the same
screenshots passed review for 0.6.0, so reviewer discretion varies — don't
count on it. Next submission needs a version bump + new screenshots.

## Release: v0.6.1 (build 11) — icon fix (2026-08-05)
Published to GitHub Releases via `publish.sh` (notarized, stapled,
Gatekeeper-accepted); hand-written notes + site changelog entry done.
Sole change: the icon transparency fix below. README needs no sync (no
feature changes). Build 11 uploaded via `release.sh app-store` and
**submitted for App Review same day**: ASC blocks adding a version while
one is Pending Developer Release, so the 0.6 release was cancelled
(status → Developer Rejected), the same version record edited to 0.6.1
with build 11 attached, and resubmitted — the store never shows the
white-tile icon. Manual release stays selected. ASC app ID: 6795956982
(store URL once live: <https://apps.apple.com/app/id6795956982> — point
site + README there on release).

## Fix: app icon shipped with opaque white corners (2026-08-05)
The 0.6.0 icon PNGs were flattened onto white at rasterization time — zero
transparent pixels, so the squircle sat on a white square tile in the Dock
and Finder. The SVG source (`docs/assets/AppIcon.svg`) was always correct
(824×824 rounded rect on a transparent 1024 canvas). Re-rasterized with
headless Chrome (`--default-background-color=00000000`) at 1024, downscaled
the smaller sizes with `sips` (Chrome renders blank below ~150 px windows),
and verified corner alpha on every PNG and on the compiled `.icns` in the
built app. Goes out as the 0.6.1 bugfix before the store release.

## Mac App Store: approved (2026-08-05)
0.6.0 (build 10) passed App Review on the first submission — the
"Use Demo Server" one-click path did its job as the reviewer entry point.
The version release is set to **manual**, so the app sits in Pending
Developer Release until the button is pressed in App Store Connect.
Remaining before M8 closes: release the version, confirm the listing is
live on the storefront, then swap the "Mac App Store in progress" wording
on the website and in README.md for the real store link (and record the
ASC app ID somewhere in the repo while at it).

## Mac App Store: first build uploaded (2026-07-29)
The MAS pipeline is live end-to-end. Portal one-timers done by hand (Apple
Distribution + Mac Installer Distribution certificates, App ID
`app.hydrophone` with **no** extra capabilities, ASC app record);
`scripts/release.sh app-store` now archives and **uploads in one step** —
`ExportOptions-app-store.plist` gained `destination: upload` (altool's
upload path is discontinued) and the export passes
`-allowProvisioningUpdates` so the provisioning profile is created on
demand. 0.6.0 (build 10) uploaded: "Upload succeeded", processing on ASC.
- `Info.plist`: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only) so every
  upload skips the export-compliance question.
- Listing prerequisites produced: privacy page at
  <https://hydrophone.app/privacy.html> (truthful "collects nothing",
  linked from the site footer) and four 2880×1800 screenshots driven live
  against the demo server (`~/Desktop/hydrophone-mas-screenshots/`, with
  `listing.md` holding drafted description/keywords/review notes).
  Screenshot gotcha: the demo server's junk playlists (one with a slur
  name) must stay out of frame — the sidebar's Playlists section was
  collapsed before capturing.
- Listing filled and **submitted for App Review the same day** (version
  0.6.0, build 10, "Data Not Collected", 4+, demo-server review notes).
  Awaiting the review outcome.

## v0.6.0 released (2026-07-29)
Build 10, notarized/stapled/Gatekeeper-accepted, hand-written notes.
First release under the **Hydrophone** name: the full rename + rebrand,
the Dusk app icon (below), queue-first Now Playing panel, album-keyed
artwork cache, one-shot scroll restore, sidebar re-select-to-root, the
honest read-ahead cap, and the elegance-pass refactors. Website changelog
entry added; README synced (queue-first panel folded into the queue
bullet). Release notes flag the bundle-id change for Sonicwave users
(fresh settings, reconnect once).

## New app icon: half-submerged play button ("Depth", Dusk palette) (2026-07-29)
Replaced the placeholder hanging-bars icon with a mark built around what the
app does: a white play triangle breaking a waterline — crisp above the
surface, refracted (offset + warm-tinted `#ffc79b`) below it — a sunset sky
(`#ffb56b→#ff7e4f`, horizon glow) over cold night water (`#123c5e→#041c33`).
Chosen from six function-focused concepts, then nine on-theme variations,
presented visually; still reads as a play button at 16 px.
- Vector master: `docs/assets/AppIcon.svg` (1024 grid, Apple margin + baked
  drop shadow via `feDropShadow`). Rasterized per size with
  `qlmanage -t -s <size>` so every PNG is rendered from vector, not
  downscaled; all seven sizes in `AppIcon.appiconset` replaced.
- Website favicon + header logo (`site/index.html`) swapped to a compact
  32-grid flat version of the same mark (goes live on next release deploy).
- ✅ Build succeeds; new icon confirmed in the built app's `AppIcon.icns`.

---

## Sidebar: re-selecting the current row returns to the section root (2026-07-29)
User-reported: with an album open, clicking "Albums" in the sidebar did
nothing — the selection binding is silent when the value doesn't change, so
the open-album overlay stayed. Implements the iOS tap-current-tab-pops
convention (Music/Photos behave the same); composes with scroll memory, so
popping back lands on the remembered grid position, same as the Back link.
- **First attempt (reverted the same day, user-caught):** a
  `simultaneousGesture` tap on each row swallowed the backing table's
  primary clicks — rows stopped *selecting* on macOS. The Up Next gotcha's
  sibling; `04` now records the general rule (no SwiftUI tap gestures on
  macOS List rows).
- **Shipped mechanism:** `ListReselectMonitor`, a local mouse-down monitor
  that hit-tests the List's `NSTableView` and passes every event through
  untouched. Local monitors run before dispatch, so clicked == selected
  identifies exactly a re-click; RootView clears `Navigator.album` on the
  signal. Table-finding walk shared with `ListSelectionHighlightDisabler`.
- Live-verified: section switching (including the switch *to* Albums the
  gesture had broken), open album → re-click Albums → grid restored at
  position; playlist rows covered by the same monitor. Suite + lint clean.

## Scroll memory: restore is one-shot, killing the mid-scroll snap (2026-07-29)
User-reported: grid scrolling would run smoothly, then skip ~50 px, then
continue. Instrumented with a scripted burst-scroll + accessibility
scroll-bar probe across a build matrix (pre-elegance-pass baseline, current,
two window widths): the skip reproduces identically on the *baseline* —
**not** a regression from the 2026-07-28 refactors; it shipped with scroll
persistence on 2026-07-18 and is window-width dependent (which is why it
surfaced now).
- Mechanism: `.scrollPosition(id:anchor:.top)` re-asserts whatever target
  its binding reports whenever the view updates, and SwiftUI writes the
  top-visible id back **every frame** while scrolling. At certain widths an
  update lands mid-scroll and the re-assertion snaps the current top tile
  flush to the anchor — the visible skip.
- Fix: the stored id is now a **one-shot restore target, not a live
  mirror** (`Binding.scrollMemory(read:write:consumed:…)`). `get` serves
  the persisted id only until the first write-back flips a per-view
  `@State` flag, then returns nil for the view's lifetime — a nil target
  re-asserts nothing, so the snap is structurally impossible; writes keep
  recording for the next restore. Adopted by the Albums grid, Home, and
  artist detail.
- Verified: probe shows zero snap spikes at the reproducing geometry (was:
  one ~80–130 px forward snap per scroll settle); launch restore and
  Back-from-album restore both land on the remembered tile (traced via
  temporary get/set logging; two earlier "restore broken" readings were
  artifacts of a mis-aimed synthetic Back click measuring the detail view's
  own table). Suite + SwiftLint clean.

## Read-ahead cap made honest: count decoded, slice jumbo chunks (2026-07-28)
The 8–15 s read-ahead cap wasn't holding (spotted during the elegance-pass
verification): followers pre-buffered *minutes* before a boundary, and a
whole decoded track (~55 MB of PCM) could pile up in the buffer stream.
Two causes, two fixes in `Playback/`:
- **Measure the truth.** The throttle compared *scheduled* frames to the
  playhead, but audio piles up earlier in the pipeline: decoded PCM queued
  in `source.buffers` that the consume task hasn't scheduled yet was
  invisible, and since pump and consume share the actor, the parser could
  race a whole track ahead while the guard read a stale low number.
  `ProgressiveAudioSource` now counts `yieldedFrames` (synchronously with
  `parse`), and `readAheadFrames(including:spanArrayIndex:)` adds the
  yielded-but-unscheduled delta. Scheduling moves frames between the two
  terms without changing the sum, so the drain signal's wake condition
  (playback progress) is unchanged.
- **Slice jumbo chunks.** URLSession can coalesce deliveries into ~4 MB
  chunks right after a suspend/resume cycle; parsing one whole blew 130+ s
  past the cap in a single step, and the resulting minutes-long transfer
  suspension outlived the demo server's idle timeout — the connection
  died, the truncated stream masqueraded as decode-complete, and the rest
  of the track was silently skipped (with an underrun at the seam). Pump
  now parses in 64 KB slices with the read-ahead check between slices,
  which also keeps suspend windows at the designed ~7 s.
- Verified: suite + lint clean; `flacDecodesFullyWhenStreamedInChunks` now
  also locks `yieldedFrames == frames delivered`. Live vs the demo server
  (throttle-engage debug log added): 4+ minutes of steady cycles all
  engaging at 15.0–17.1 s (was: one 145 s spike and unbounded runs),
  follower pre-buffer starting ≤ ~17 s before the gapless boundary (the
  logged read-ahead includes the finishing track's tail, so this is
  measured, not estimated), boundary seamless, zero underruns.
- Still fragile (pre-existing, now far less likely): a mid-track
  connection death reads as a clean early stream end and becomes
  decode-complete → the tail is skipped. A byte/duration sanity check at
  `decodeComplete` would catch it — future work.

## Elegance pass: one implementation per idea (2026-07-28)
Codebase-wide refactor removing duplicated logic (six commits, no feature
changes). The recurring smell was the same idea hand-written 2–3 times:
- **Networking**: ~15 near-identical response body structs collapsed into
  generic `ListBody<Element>`/`ObjectBody<Payload>` (outer method key
  inferred as the one non-status envelope key; the inner list key comes
  from `SubsonicListElement.listKey` because containers like `getArtists`
  carry sibling metadata). Client gains `list(_:of:)`/`object(_:as:)`; the
  `body.<method>.<element> ?? []` ritual left ~20 call sites. `Endpoint`
  query building is a small `@QueryList` result builder (nil-dropping, one
  Bool spelling); `star`/`unstar` merged into `favorite(id:kind:starred:)`.
  EndpointGoldenTests lock the exact query-item arrays; DecodingTests kept
  byte-identical fixtures across the migration.
- **Models**: `LibraryModel.load(_:into:)` owns the `.loading→.loaded/
  .failed` ritual, `fetchList`/`mutate(_:thenReload:)` the best-effort
  shapes. `PlayerModel`: gapless advance now shares `setCurrent` with
  manual starts (they had drifted), `handoff(for:)` derives decode args
  once, three Now Playing publishers became `publishNowPlaying(...)`.
- **UI**: optimistic starring centralized in `LibraryModel`
  (override-then-reconcile; views read `isStarred`, the AppKit table takes
  a `starSignature` value so closure-time reads still re-render); one
  `Binding.scrollID(scope:topIDs:)` replaces three hand-rolled scroll-
  memory bridges; `player.hasNowPlayingContent` replaces the triplicated
  panel gate; ArtworkCache's Quick Look original fetch now rides the same
  limiter+retry path as sized fetches.
- **Engine** (PlaybackService): `reapplyRoute(force:)` unifies the three
  route/config observers (the devices-changed idle path gains the guarded
  engine restart the config path had — ruled drift, not intent);
  `ensureEngineReady(for:)` extracts the graph lifecycle out of
  `schedule()`; the 80 ms read-ahead busy-poll became a drain signal
  (`CheckedContinuation` resumed from `bufferCompleted` and `hardReset` —
  the latter is what makes a cancelled-mid-throttle decode loop unable to
  hang); the four lifecycle booleans became two orthogonal enums,
  `Transport {idle, preroll(paused:), playing, paused}` and `Supply
  {decoding, awaitingNext, exhausted}`. One deliberate change: resume-
  during-preroll now waits for the preroll to fill instead of starting the
  node early (underrun-prone + duplicate event). `PlayerModel.state`'s
  two-writer arrangement documented as intent (instant space bar).
- Verified: full suite + SwiftLint clean after every phase; new tests
  (endpoint goldens, decode edge cases incl. `ignoredArticles`, starring
  rollback, manual-vs-gapless transition equivalence). Live vs the demo
  server: restore→resume, pause/resume, three consecutive gapless
  boundaries, 75 s soak with zero underruns (drain signal healthy), seek
  to 80% + resume, ⌘L star visible in Favorites, panel toggle off/on,
  quit/relaunch queue restore. Still needs by-hand checks (no hardware
  here): USB-DAC/AirPlay route switches and mixed-rate rate matching.
- Noted while verifying (pre-existing, unchanged): the decode read-ahead
  cap tolerates large overshoot — followers pre-buffer minutes before a
  boundary because read-ahead is measured at schedule time, after the
  pump/consume split. Worth a look someday; not touched in this pass.

## Artwork: album-keyed cache identity + fetch retry (2026-07-28)
Fixed redundant cover downloads and the hero's late appearance. Servers
give every *song* its own `coverArt` id even though all tracks of an album
resolve to the same image, so the cache (keyed by raw id) downloaded the
identical cover once per queue row and missed the album page's copy when
the Now Playing hero asked for it.
- `ArtworkCache` now separates **cache identity** from the fetch id:
  song/album surfaces share `artworkKey` (`album:<albumId>`, falling back
  to the song's own id when album-less) across the album grid/page, hero,
  compact strip, queue rows, LCD, menu bar and MPNowPlaying. A queue of
  one album costs a single 160px download; the hero seeds instantly from
  whatever variant the album page already loaded. Trade-off (documented
  in `05`): per-track embedded art that differs from the album cover is
  not shown — the album cover wins.
- Reliability: network fetches now get one retry on *any* failure (short
  pause), not just on 429 — a transient blip no longer leaves a gray tile
  for the whole session.
- Live-verified vs the demo server, cold cache: full Albums grid loads
  with zero gray tiles; playing a fresh 15-track album showed hero + all
  queue thumbnails instantly (screenshot at 0:02) and added no per-row
  cache files (was: one identical file per row; the same session dropped
  from 108 cached files to 72 while covering *more* albums). Build, full
  suite, SwiftLint clean; `artworkKeyCollapsesSongsOntoTheirAlbum` added.

## Hydrophone rebrand: icon, accent, site theme (2026-07-28)
New visual identity to match the name — "listening under the surface":
- **App icon**: waveform bars hanging below a water-surface line, white on
  an ocean-blue gradient (#41C6F2 → #0A4E86), standard macOS plate
  (824pt rounded rect, 1024 canvas). Rendered dependency-free by a
  CoreGraphics script (scratchpad `make_icon.swift`) at 16–1024px into
  `AppIcon.appiconset`; legible at 16px.
- **AccentColor**: red → ocean aqua (P3; light #1287CC-ish, dark
  #41C6F2-ish). MenuBarExtra symbol `waveform` → `water.waves`.
- **Site**: CSS vars renamed `--red`/`--red-deep` → `--accent`/
  `--accent-deep` with aqua values; all `rgba(255,69,58,…)` glows/shadows
  recolored; favicon + header wordmark redrawn to the new mark.
- Verified: build + SwiftLint clean, app launches; site eyeballed
  top-to-bottom in Chrome (hero, cards, spec sheet, install, changelog
  all consistently aqua).
- Marketing screenshot retaken (2026-07-28): `site/assets/app-window.png`
  now shows the aqua build against the public Navidrome demo server
  (The Butcher's Ballroom album view, quality badges, Now Playing panel
  with Up Next). Window capture via `screencapture -o -l` at 1000×760pt
  (@2x, 2000×1520); alt text updated in site + README. Demo-server
  playlists (test names) are visible in the sidebar — retake against a
  curated library if that ever grates.

## Renamed: Sonicwave → Hydrophone (2026-07-28)
The app is now **Hydrophone** (a device for listening under the surface —
fitting for a Subsonic client; the old name collided with an Android music
player and SonicWall's SonicWave hardware line). Full rename, no legacy
support (pre-rename installs are assumed not to exist — fresh container,
fresh Keychain item):
- Bundle identifier `nl.huell.sonicwave` → **`app.hydrophone`** (domain
  hydrophone.app is registered); tests bundle `app.hydrophoneTests`.
- Renamed: project/targets/scheme, `Hydrophone/` + `HydrophoneTests/`
  source dirs, `HydrophoneApp.swift`, `HydrophoneCommands.swift`,
  `Hydrophone.entitlements`. Keychain service
  `app.hydrophone.credentials`; Logger subsystems + queue labels
  `app.hydrophone*`; OpenSubsonic client name `Hydrophone`; live-test env
  vars `HYDROPHONE_HOST/USER/PASS`; notary profile name `hydrophone`.
- Website copy + URLs now point at <https://hydrophone.app/> (canonical +
  og:url added). Docs/README/scripts/CI all renamed.
- Verified: clean build, SwiftLint 0 violations, full test suite green,
  app launches as "Hydrophone" with the new bundle ID.
- ⏳ manual follow-ups: `gh repo rename hydrophone`, Pages custom-domain
  + DNS for hydrophone.app, re-create the notary keychain profile
  (`xcrun notarytool store-credentials hydrophone`), MAS app record for
  `app.hydrophone` when M8 resumes.

## Queue-first Now Playing panel: collapsible hero (2026-07-26)
The play queue can now take (nearly) the whole panel. A chevron beside the
hero title collapses the card to a compact strip (36pt art, title/artist);
clicking the strip restores it. Persisted as `nowPlayingHeroCollapsed`,
like the panel width. Max panel width bumped 480 → 560pt.
- The strip sits below the toolbar (no top safe-area ignore while
  collapsed); scrubber/transport stay reachable in the toolbar LCD.
- Hard-won: expanding swaps the hero in under the mouse and the expansion
  click is occasionally re-delivered to the artwork's tap gesture, opening
  Quick Look uninvited (~1 in 5). Fixed by disarming the Quick Look tap
  for 400ms after the card appears (`quickLookArmed`); a deliberate click
  afterwards still works. See `04`.
- Live-verified against the demo library: repeated collapse/expand cycles
  (no spurious Quick Look post-fix), queue drag-reorder in collapsed mode,
  deliberate artwork Quick Look, state persistence across relaunch.
  Build + full test suite + SwiftLint clean.

## v0.5.1 released (2026-07-18)
Build 9, notarized/stapled/Gatekeeper-accepted, hand-written notes.
Polish/reliability release: Back-navigation state restoration (artist
selection, three scroll surfaces, expanded bio), the ten-bug audit batch
(genre race, stale-empty clobbers, offline Home, star rollback, ordered
queue saves, Play Next vs shuffle-off), and the drag-order fix's siblings.
Website changelog entry added; README already current (no new features).
Note: briefly published as v0.6.0, then unwound minutes later (release +
tag deleted) and reissued as 0.5.1 — bugfix-only content warranted a
patch bump, not a minor.

## Albums grid, Home, and artist-detail scroll survive Back (2026-07-18)
All three SwiftUI scroll surfaces now persist position via
`scrollPosition(id:)` (macOS 14 API) + `scrollTargetLayout()`, stored in
`@AppStorage` — same reasoning as the artists selection: the views are
torn down while an album is open, so scroll must live outside them.
- **Albums grid** — top-visible album id (`albumsScrollID`); cleared on
  filter/sort changes; a missing id (deep pagination after relaunch)
  no-ops harmlessly.
- **Home** — section-level ids on the shelves (`homeScrollID`); the
  greeting reads as nil so the top stays the top.
- **Artist detail** — composite `artistID|albumID`
  (`artistDetailScroll`): per-artist, so switching artists starts at the
  top; the first album reads as nil (it's what tracking reports while the
  header is visible — restoring to it would scroll the header off).

## Bug-hunt batch: teardown, ordering, and async-race audit (2026-07-18)
Three-way audit prompted by the artist-selection and drag-order bugs
(same-family hunt). Ten fixes, all covered by the suite (107 green):
- **Genre browser race** — the pane's Binding-setter Task is never
  cancelled; two rapid genre clicks could leave the wrong genre's songs
  displayed. Stale results now dropped (`storedGenre` recheck after await).
- **Stale-empty clobbers** — cancelled `.task(id:)` loads resolve empty
  (LibraryModel swallows CancellationError) and blanked fresh views:
  search results mid-typing, artist detail, album detail. All three now
  guard `Task.isCancelled` before assigning.
- **Home permanently empty after an offline launch** — `homeLoaded` was
  set unconditionally; all-empty shelves now leave it false so the next
  appearance retries. In-flight guard added.
- **Star rollback** — a failed star/unstar left the optimistic override
  wrong until the view died; `setStarred` now reports success and
  `TrackTableView` rolls back on failure (+ overrides cleared when a
  fresh tracks array arrives).
- **Queue-save ordering** — rapid skips fired concurrent `savePlayQueue`
  POSTs that could land out of order (older snapshot winning server-side);
  saves are now FIFO-chained (`queueSaveTask`).
- **Play Next vs shuffle-off** — `playNext`/`insertInQueue` appended to
  `unshuffledOrder`, so turning shuffle off banished a just-queued track
  to the end. Canonical order now mirrors the queue (shuffle off) or
  slots after the current song (shuffle on). Two regression tests.
- **Duplicate fetches** — in-flight guards for artists/genres/starred
  loads; `starredLoaded` flag stops zero-favorites users refetching on
  every appearance. `shuffleLibrary` joined the `isPreparingMix` guard.
- Expanded artist bio survives Back (persisted as `artistBioExpandedID`).
- **Audited clean** (no change needed): Up Next index math incl. the
  `hi+2` move destination, disc-header row mapping, playlist
  reorder-by-replace, all three drop sites, `isPreparingMix` lifecycle,
  restore-vs-play race. **Known + accepted:** header Play uses album
  order even when the table is sorted (intended); duplicate-song queue
  restore snaps to the first copy (savePlayQueue is id-based); scrobble
  now-playing ordering under rapid skips (best-effort).
- **Tracked, deferred:** SwiftUI scroll-position persistence for
  Albums/Home/artist detail (the AppKit table autosave doesn't cover
  them); genre-songs/playlist caching to avoid refetch flash on Back.

## Fix: Back from an album reset the Artists selection (2026-07-18)
Opening an album replaces the whole section view in the detail column
(`RootView`'s `if let album` swap), so `ArtistsView`'s `@State selectedID`
died while browsing the album and Back landed on the first artist.
Selection now lives in `@AppStorage("artistsSelectedID")` — same app-wide
restoration pattern as sort/scroll (`06`) — which fixes Back and restores
the selected artist across relaunches for free.

## v0.5.0 released (2026-07-18)
Build 8, notarized/stapled/Gatekeeper-accepted, hand-written notes. Ships
M10 discovery (Start Radio, artist pages, Shuffle Albums), the macOS 14
Sonoma floor (headline), and the drag-order fix. Website: 0.5.0 changelog
entry + two new feature tiles (radio, shuffle); README synced. The
release-triggered Pages deploy stamps 0.5.0 into the version spans.

## Fix: multi-song drags dropped into Up Next / playlists lost their order (2026-07-18)
SwiftUI hands multi-item drop payloads over in no guaranteed order, and all
three drop sites (Up Next `.onInsert`, empty-queue `.dropDestination`,
sidebar-playlist `.dropDestination`) consumed them as-received. Fix: sort
decoded `DraggedTrack`s by their `index` field (the source row index the
drag already carried) before inserting — restoring the on-screen order the
user grabbed. Human-reported after dragging an album's tracks to the queue.

## M10 discovery batch: artist info, Start Radio, album shuffle (2026-07-18)
Internet radio deliberately skipped (ICY-stream spike still open — `10`).
- **API:** `getArtistInfo2`, `getSimilarSongs2`, `getTopSongs` endpoints +
  bodies (`02` inventory updated). `getTopSongs` keys off artist *name*
  (API quirk). Bio HTML flattened client-side
  (`ArtistInfo2Body.Info.plainBiography` — drops the "Read more on Last.fm"
  anchor, strips tags, decodes entities; covered by a decode test).
- **Artist page:** header with circular portrait + Artist Radio button,
  expandable 3-line bio, Similar Artists shelf (search-shelf idiom,
  `navigator.openArtist`); artist-list rows get a Start Artist Radio
  context item. Data loads concurrently with the album grid; servers
  without a metadata agent simply hide bio/shelf (best-effort idiom).
- **Start Radio:** track-table context menu (single selection) +
  artist entry points. Chain: similar-by-song → similar-by-artist →
  server top songs → shuffled own-artist tracks (≤10 albums), so radio
  always plays on agent-less servers (the demo server exposed this).
  Seed song plays first; shuffle mode is switched off so station order
  holds.
- **Busy guard:** `AppModel.isPreparingMix` — mix assembly takes a beat
  (similar-songs then per-album fetches), so all radio/album-shuffle entry
  points disable while one is in flight (Artist Radio button swaps its
  icon for a spinner) and the methods bail re-entrantly.
- **Shuffle Albums:** whole albums back-to-back in random order — Controls
  menu + Albums-grid header button. Honors the genre/decade filter (server
  `type=random` unfiltered; filters are list types with no random order,
  so a 200-album filtered page is sampled client-side).
- **Verified:** 105 tests green, zero warnings, SwiftLint clean. All three
  endpoints live-checked against demo.navidrome.org (status ok, expected
  shapes; demo has no Last.fm agent → empty payloads exercised the
  fallback design). ✅ In-app flows (artist page, radio entry points,
  album shuffle) human-verified against a real server 2026-07-18.

## Deployment target lowered to macOS 14 Sonoma (2026-07-18)
`MACOSX_DEPLOYMENT_TARGET` 15.0 → 14.0 across all targets; README, docs
(`00`/`07`/`10`), and the website updated to "macOS 14 Sonoma or later".
Verified empirically before changing: the **app target** compiles at 14.0
with zero errors/warnings — every API in use (incl. `@Observable`,
`MenuBarExtra .window`, the AppKit table) exists on Sonoma. macOS 13 is not
feasible without a rewrite: `@Observable`/Observation requires macOS 14 and
the whole state layer is built on it. Gains the Sonoma-holdout user base
plus 2018–2019 MacBook Air hardware that macOS 15 dropped.
- **Test target needed 3 small fixes:** `AVAudioFile.close()` is 15-only —
  replaced with a `do`-scope so deinit flushes the header (FlacStreaming,
  DecodeContinuity); `MPMediaItemArtwork`'s Sendable conformance is gated
  to 15 → `@preconcurrency import MediaPlayer` (NowPlayingCenterTests);
  the 14.0 SDK surface marks `AVAudioConverter`'s input block `@Sendable` →
  `nonisolated(unsafe)` on a test-local flag (block runs synchronously).
  Full suite green at 14.0; SwiftLint clean.
- **Sonoma runtime verification: consciously skipped** (2026-07-18). Dev
  machine runs macOS 15; a VM/dual-boot pass was judged not worth the
  hassle. Support for 14 is compile-verified only — accepted risk that
  SwiftUI behavior may differ subtly (menu-bar panel, split view). If a
  Sonoma user reports breakage, that's the first place to look; revisit
  with a VM then.
- Future 15-only APIs now need `#available(macOS 15, *)` guards (same
  pattern already planned for Tahoe APIs).

## Post-v1 roadmap from ecosystem gap analysis (2026-07-18)
Surveyed ~35 Subsonic/OpenSubsonic clients (Feishin, Supersonic, Symfonium,
play:Sub, Amperfy, EKO, NaviBeat, …) and mapped Hydrophone against them.
Already ahead of the field: `savePlayQueue` cross-device sync (almost
unclaimed ecosystem-wide), hardware rate matching, streaming gapless.
Added M9–M11 to `10-roadmap.md`: M9 ratings (`setRating`) + synced lyrics
(`getLyricsBySongId`) + sleep timer (all S) · M10 discovery —
`getArtistInfo2` bios, instant mix (`getSimilarSongs2`), album shuffle,
internet radio gated behind an ICY-stream spike (M) · M11 audiophile batch —
optional EQ, signal-path integrity indicator, hog mode, playbackReport (L).
Crossfade explicitly deferred (single-node gapless scheduling has no overlap
path). Offline caching flagged as the first `00` non-goal to revisit
post-MAS. Docs only — no code changes.

## v0.4.0 released (2026-07-17)
Build 7, notarized/stapled/Gatekeeper-accepted, hand-written notes. Ships
the FLAC streaming fix (headline), transcode fallback, album filters,
Shuffle Library, disc headers, artwork throttling. Website changelog
updated; release-triggered Pages deploy stamps 0.4.0.

## FLAC streaming was broken — parser corruption from in-callback buffers (2026-07-16)
Found while live-verifying the issue batch below: playing any FLAC album
decoded ~0.5s per track, then raced through the queue to the end. Weeks of
MP3-only listening had masked it — **FLAC never worked** via the
progressive pipeline.
- **Symptom:** `AudioFileStreamParseBytes` returns `'wht?'`
  (kAudioFileStreamError_UnsupportedFileType) mid-stream after ~6 FLAC
  frames; no `failureMessage` (format WAS discovered), so each track ends
  after ~24K frames → instant gapless boundary → next track → race.
- **Diagnosis:** dumped the real stream via a throwaway in-target test
  (server bytes = pristine FLAC), then bisected standalone: identical bytes
  parse cleanly with no-op callbacks; constructing **AVAudioCompressedBuffer
  inside the AudioFileStream packets callback corrupts the FLAC parser**
  (AVAudioConverter creation in the property callback is innocent; MP3
  tolerates all of it, which is why this never surfaced).
- **Fix:** the packets callback now only copies raw bytes + packet
  descriptions (`PendingPackets`); buffer construction and conversion run
  after ParseBytes returns (`drainPendingPackets` from `parse()`/`finish()`).
  Verified: the dumped 25MB track decodes 10.6M/10.6M frames, and The
  Blueprint (13 FLACs) plays normally in the app. Hermetic regression test
  (`FlacStreamingTests`) synthesizes a FLAC via AVAudioFile and streams it
  in 4KB chunks — reproduces the corruption on the old code.
- Red herrings worth remembering: server-side player transcoding (wasn't),
  ATS hints (wasn't), Retry-After chunk sizes (wasn't). The winning move
  was dumping real bytes and bisecting the callback work standalone.

## Issue batch: #4 #7 #8 #9 #10 (2026-07-15/16)
- **#7 Shuffle All** (`64c9727`): Controls → Shuffle Library + Songs header
  button; fresh 500-song `getRandomSongs` batch.
- **#4 artwork throttling** (`d72fb54`): `AsyncLimiter` (FIFO semaphore
  actor) caps fetches at 6; 429s get one retry after Retry-After (2s
  default, 30s clamp); disk hits bypass.
- **#10 transcode retry** (`29dafc6`): undecodable current track retries
  once as forced mp3 (suffix "mp3" too — the stream is mp3 whatever the
  file was); followers inherit the timeline's forceTranscode so a fully
  unsupported album doesn't race; recovery/seek preserve gain + transcode.
- **#9 album filters** (`6ccc37f`): genre/decade via byGenre/byYear list
  types; sort disabled while filtered; playlists CRUD split to
  LibraryModel+Playlists for the type-length lint.
- **#8 disc headers** (`cdfac38`): TrackTableRow maps unselectable sticky
  group rows over the AppKit table; all external contracts stay in
  track-index space; headers only in disc order; subtitles from discTitles.
- Live-verified: filters (Rap → 1 album, sort disabled), Shuffle Library
  (cross-library mix), single-disc album renders headerless with correct
  play-index mapping. Multi-disc live check pending a multi-disc album in
  the library (row math unit-tested). Suite: 89 → **102 tests**.
- Verification gotcha: computer-driven UI clicks/screenshots cost 5-18s
  each — position math must use timestamps, and a stale app instance from
  a previous day can shadow the fresh build (`ps` first, then `open`).

## v0.3.0 released (2026-07-15)
Build 6, notarized/stapled/Gatekeeper-accepted, zip on the GitHub Release
with hand-written notes. Ships the issue burn-down below (queue
persistence, ReplayGain, formPost playlists, local plain-HTTP). Website
changelog updated; the release-triggered Pages deploy stamps 0.3.0.

## Issue burn-down: #1 #2 #5 #6 (2026-07-15)
First four tracker issues closed (from the competitive research round):
- **#2 — plain-HTTP home servers** (`88eaff3`): partial `Info.plist`
  (repo root; inside `Hydrophone/` the synced group copies it as a bundle
  resource → warning) merged into the generated one with
  `NSAllowsLocalNetworking`. Non-local `http://` stays ATS-blocked but now
  maps to an actionable message (`SubsonicError.transport(from:)`).
- **#1 — large playlist mutations** (`d1f85cc`): `usesFormPost`-flagged
  endpoints go as form-encoded POST when the server advertises `formPost`
  (capability via resurrected `getOpenSubsonicExtensions`, cached per base
  URL). `+` escaped in bodies — form decoding reads it as a space.
- **#5 — play-queue persistence** (`671e565`): `savePlayQueue`/
  `getPlayQueue`; saves forced on pause/track change, 30s-throttled on
  position ticks, final best-effort on quit; restores paused via
  `PlayerModel.restoreQueue` (never clobbers an active queue; resume
  position consumed by the next stopped→play).
- **#6 — ReplayGain** (`232ea3c`): gain baked into span buffers via
  `vDSP_vsmul` (one shared gapless node → node volume can't do per-track);
  peak-clamped dB→linear math on `ReplayGainMode` (unit-tested); Settings →
  Playback picker; seek preserves the span's gain. Gotcha: `Song` has
  explicit `CodingKeys` — new decoded fields must be added there or they
  silently decode as nil.
- Suite: 67 → **89 tests**.
- **Live-verified vs Navidrome 0.63.2** (same day): queue restore across
  quit/relaunch is exact — track, paused position (1:02, then 3:01) and Up
  Next order all reappear, no auto-play; resume plays on from the restored
  position at 1× (timestamp-correlated — beware: computer-driven UI clicks/
  screenshots cost 5–18s each, which first masqueraded as a "+12s position
  jump"). savePlayQueue→getPlayQueue round-trips through the formPost path
  (Navidrome advertises it). Settings picker persists across relaunches.
  A `replaygain <gain> for <songId>` info log (app.hydrophone/playback)
  makes gain application observable; the library's files carry no RG tags,
  so non-unity gain (and audibility) still needs a tagged album — the
  unity no-op path ran clean. NB: zsh shadows `/usr/bin/log` with a
  builtin — use the full path.

## v0.2.0 released; repo public, website live (2026-07-15)
- **Released v0.2.0 (build 5)** via `scripts/publish.sh` — notarized,
  Gatekeeper-accepted ("Notarized Developer ID"), tagged, zip attached to
  the GitHub Release with generated notes. First release carrying the
  post-M7 feature batch (Home, scrobbling, AirPlay Tier 1, demo onboarding,
  scan, Quick Look art, decode-failure alerts, resizable panel).
- **Repository made public** (2026-07-15) after a full git-history audit:
  no credentials/hosts ever committed (live tests are env-var-gated); the
  Apple Team ID and author email are the only identifying values and are
  public by design. Claude-design share links stripped from `09`.
- **Landing page** (`site/`, dark hi-fi look, animated LCD hero) deployed to
  GitHub Pages: <https://hydrophone.app/>. `pages.yml` deploys
  on `site/` pushes **and on every published release**, stamping the latest
  release tag into the page's `app-version` spans — the download front door
  stays current with zero manual steps.
- Gotcha found on the first release-triggered deploy: the `github-pages`
  environment only allowed `main`, and release events run on the **tag
  ref** — the run failed in 3s with no job logs. Fixed permanently with a
  `v*` **tag** deployment-branch policy on the environment; rerun deployed
  and the live page shows 0.2.0.
- Docs synced with the shipped app (scrobbling no longer a non-goal — the
  server relays; CI marked done; AirPlay/Quick Look/scan coverage added)
  and a root `CLAUDE.md` added as the session entry point.

## Polish batch: scan, Quick Look art, show-album (2026-07-08)
Player quality-of-life features, all live-verified:
- **Server library scan**: `startScan` endpoint; Settings → Connection
  "Scan Library" (shows "Scanning — N items" feedback) + File → Update
  Server Library. Verified against Navidrome.
- **Seek precision log-verified sample-exact** while validating seek entry
  points (temporary tick logging: position ran 30.0 → 31.4 dead-on after a
  seek to 0:30). An apparent "+10s offset" during UI testing turned out to
  be measurement latency, not a bug. (A "Go to Time…" prompt was built on
  this and removed the same day as not useful enough.)
- **Quick Look artwork**: clicking the panel's hero art opens the
  full-resolution cover (`ArtworkCache.originalImageFileURL` stages a
  properly-named file, extension sniffed from magic bytes so QL renders it).
- **Show Album in Library**: the panel's album line is clickable, plus
  Controls → Show Album in Library (⇧⌘L). Resolves `albumId` via
  `getAlbum`. Learned: SwiftUI `.contextMenu` on toolbar items never fires —
  NSToolbar intercepts right-clicks for its own customize menu — so the LCD
  hosts no context menu.
- RootView's Controls-menu handlers live in a `CurrentTrackCommands`
  modifier (inlining them broke the type-checker's time budget).
- Known cosmetic nit: the fixed-height Settings window scrolls its
  Connection form now that the scan section is added.

## Home shelves, scrobbling, demo server (2026-07-08)
- **Home** sidebar section (`HomeView`): a distinct landing page —
  time-of-day greeting, "Jump Back In" hero card (blurred-artwork backdrop,
  inline Play verified to win over the card's open-album tap), then
  varied-size shelves (Keep Listening / Recently Added at 150pt / Most
  Played / Random with re-roll) from `getAlbumList2` types. Shared
  `Shelf`/`AlbumShelf` gained title, tile-size and header-accessory
  parameters. Verified live against Navidrome (first flat four-shelf cut
  was rejected as indistinct and redesigned).
- **Scrobbling** (`PlayerModel+Scrobbling`, injected closure → `scrobble`):
  "now playing" at track start, submission at half-track-or-4-minutes
  (≥ 30s tracks). Settings → Playback toggle, default on. **Verified
  end-to-end**: played a 2Pac track past its midpoint → after relaunch the
  album led the server-fed Recently Played shelf (it was absent before —
  plays predating this feature were never counted).
- **Demo server**: Settings → Connection shows a one-click "Use Demo
  Server" (public Navidrome demo, `demo`/`demo`) — only while no server is
  configured, so it can't clobber a real setup. Doubles as the App Review
  reviewer path (`07` checklist item closed). Demo server reachability
  probe-verified; the button reuses the tested saveAndConnect path.

## CI, decode-failure UX, panel resize (2026-07-08)
- **CI test job** (`.github/workflows/tests.yml`): build + full unit suite on
  every push/PR, macOS 15 runner, newest installed Xcode selected at run
  time, `CODE_SIGNING_ALLOWED=NO` (LiveDecodeTests self-skip without env).
  Closes the last self-serve M8 item.
- **AAC/ALAC-in-MP4 graceful error**: `ProgressiveAudioSource` now refuses
  cookie-dependent containers at format discovery (`AVAudioConverter` has no
  magic-cookie API — decoding emitted loud static) and reports a
  `failureMessage`; a stream ending with no decodable format gets a generic
  one. `PlaybackService` stops the transfer and emits `.failed`. Found along
  the way: `PlayerModel.lastError` was **write-only** — playback failures
  were never shown. RootView now presents a "Can't Play Track" alert with
  the actionable message (enable server transcoding). Unit-tested against a
  real AVAudioFile-encoded `.m4a` (`aacInMP4SurfacesGracefulError`).
- **Now Playing panel resize**: grab strip on the panel's leading edge
  (`PanelResizeHandle`), 300–480pt clamp, persisted
  (`nowPlayingPanelWidth`). Lives inside the detail column so it cannot
  re-trigger the split-view/toolbar instability the panel design avoids;
  open/close animation is keyed on visibility only, so dragging is live.

## AirPlay Tier 1 (2026-07-08)
Status: **code complete, build/lint clean, UI verified; live end-to-end
deferred** (needs a real AirPlay 2 receiver — none available at the time).
- Scope (Tier 1): treat AirPlay endpoints as regular Core Audio output
  devices — no private sender API, no in-app discovery. `AudioDevice` gained
  `isAirPlay` (via `kAudioDevicePropertyTransportType ==
  kAudioDeviceTransportTypeAirPlay`); the Settings picker groups AirPlay
  routes after regular devices with an `airplay.audio` label;
  `matchDeviceRateIfEnabled` skips AirPlay transports (fixed network clock —
  nominal-rate pokes are useless-to-glitchy; macOS resamples instead).
- **Empirical constraint (probed, not assumed):** an AirPlay receiver only
  exists as a Core Audio device *while the system is connected to it* —
  Control Center owns discovery/connection. A shairport-sync fake receiver
  ("Hydrophone Test Speaker") advertised fine on Bonjour (`_raop._tcp`) but
  never appeared in the device list, and *also never appeared in Control
  Center*: the Homebrew build is **AirPlay 1 only**, and macOS's system
  output list shows **AirPlay 2 receivers only** (AirPlay 1 shows in
  Music.app's private picker alone). An AirPlay 2 shairport-sync needs a
  from-source build + root nqptp daemon — not attempted.
- Verified so far: build + SwiftLint clean; Settings → Playback picker
  correct pre-connection (regular devices, remembered-disconnected entry, no
  phantom AirPlay section).
- **⏳ Pending live test** (any AirPlay 2 receiver, e.g. another Mac with
  AirPlay Receiver enabled, HomePod, Apple TV): connect via Control Center →
  device appears with AirPlay transport → shows under the picker's AirPlay
  group → pin in-app → audio arrives → log shows no rate-match attempt.

## Toolbar/panel stability fixes (2026-07-08)
Status: **done & frame-verified** (screen recordings analyzed per frame;
note: computer-use synthetic input does NOT deliver while `screencapture -V`
records — drive the app via `osascript` keystrokes when filming).
- **Sidebar shove on panel toggle (the real one):** presenting the Now
  Playing panel via `.inspector` inserts its column into the window's split
  view at full width *before* the detail column yields space — the whole
  content pane slides left, pushing the sidebar off the window edge and
  snapping it back (~9 frames at 60 fps, caught on camera). Fixed by hosting
  the panel as a width-animated trailing pane **inside the detail column,
  below the toolbar** (`HStack` + `.transition(.move(edge: .trailing))`);
  the outer split view never re-lays-out and the toolbar never needs to
  reflow (NSToolbar item re-layout snaps, never animates — every attempt at
  a header that tracks the panel, animated padding / merged full-width item
  / split-view holding priorities, either snapped or landed in the overflow
  menu). Motion-analysis verified: the pane slides over ~10 frames; the
  sidebar and the toolbar strip show **zero** moved frames across both
  toggle directions. Trade-offs: no inspector drag-to-resize (fixed 344pt),
  and the hero artwork tops out at the toolbar's bottom edge rather than
  the window top.
- Along the way: panel toggles (LCD, toolbar button, ⌘U, dismiss binding)
  wrapped in `withAnimation`; `columnVisibility` pinned to `.constant(.all)`
  (the sidebar is permanently visible by design); the toolbar volume slider
  is hosted in an `NSHostingView` that refuses `mouseDownCanMoveWindow` —
  dragging it no longer moves the window (custom SwiftUI drag gestures don't
  opt out of toolbar window-dragging the way native controls do).

## M8 — release signing pipeline (2026-07-07)
Status: **Developer ID pipeline working end-to-end; MAS path configured and
blocked on portal artifacts.**
- Release build settings: Manual signing, **Developer ID Application (Huell
  B.V., 4HNWJ993V9)**, **Hardened Runtime ON** (was `Automatic` with no team).
  Debug unchanged (Developer ID, hardened runtime off — Keychain DR
  stability).
- `scripts/release.sh [developer-id|app-store]`:
  archive → export (`scripts/ExportOptions-*.plist`) → `codesign
  --verify --strict` + authority/`runtime`-flag assertion → notarize + staple
  + `spctl` assess (auto-skipped with instructions until a `hydrophone`
  notarytool keychain profile is stored) → versioned zip. `build/` is
  git-ignored.
- **Verified:** pipeline run produced `build/Hydrophone-0.1.0.zip`; signature
  valid (`Authority=Developer ID Application: Huell B.V.`,
  `flags=0x10000(runtime)`); entitlements on the artifact are exactly
  app-sandbox + network.client; `spctl` reports "Unnotarized Developer ID"
  (expected pre-notarization); the exported app **runs, connects via
  Keychain creds, and plays audio** under the hardened runtime — no runtime
  exceptions needed.
- ✅ **Notarization round-trip verified (2026-07-07):** with the `hydrophone`
  keychain profile stored, the pipeline notarized (status **Accepted**),
  stapled, and passed Gatekeeper (`accepted, source=Notarized Developer ID`).
  `build/Hydrophone-0.1.0.zip` is a fully distributable direct-download build.
- Remaining for M8: Apple Distribution + Mac Installer certs and an ASC app
  record for the MAS build, final app icon, App Privacy details, reviewer
  notes/demo server, CI test job.

## M7 close-out — accessibility + scroll restoration (2026-07-07)
Status: **M7 complete** (Tahoe/Liquid Glass verification pending a macOS 26
machine). The `08-testing.md` manual checklist is annotated with per-item
status.
- **`SlimSlider` accessibility**: the custom gesture-driven slider now
  exposes a spoken value (percent for volume; "elapsed of total" for the
  panel/menu-bar scrubbers via `accessibilityValueText`) and
  increment/decrement adjustable actions — which also make it operable via
  Full Keyboard Access and VoiceOver (VO-↑/↓). Verified by walking the AX
  tree: `label=Volume valueDesc=100 percent actions=[AXIncrement,
  AXDecrement]`.
- **Track-table favorite buttons** expose state-aware labels ("Add to /
  Remove from Favorites") + `AXPress` — all rows verified via the AX API.
- **Scroll-position restoration** (`trackScroll.<key>`): the stable library
  views (Songs/Favorites/browser) persist their scroll offset (debounced
  saves via a selector-based clip-view observer; saving starts only after
  the one-shot restore so churn can't clobber the stored value; restore is
  clamped to loaded content). Content-specific views (album detail, search)
  and playlists deliberately don't persist scroll. Live-verified: offset 932
  survived a relaunch (a +5-tick scroll then saved 1052).
- **Light mode verified** without touching system settings (per-app
  `NSRequiresAquaSystemAppearance` override, removed afterwards): clean
  light rendering, readable text, correct accent. No hardcoded colors exist
  in the codebase.
- `MusicTrackTable` was reorganized to keep lint clean: view lifecycle in a
  same-file extension, sort+scroll persistence in
  `TrackTablePersistence.swift`.
- Remaining strictly-by-hand items: a full VoiceOver listening pass,
  increased-contrast / reduce-transparency spot checks, AirPods route
  change (same recovery path as the verified USB-DAC vanish), and the
  macOS 26 Liquid Glass look.

## Memory-leak audit (2026-07-07)
Status: **app code verified leak-free** (static review + `leaks` runs against
the live app under load).
- **Static review:** all long-lived closures use `[weak self]`
  (NowPlayingCenter remote commands, engine callbacks, event loops);
  `DataStreamLoader` invalidates its URLSession (which retains its delegate)
  on both completion and stream termination; `AudioDeviceListObserver`
  removes its Core Audio listener in `deinit`; `NSMenuItem.target` is weak so
  `ClosureMenuItem`'s self-target doesn't cycle; the one `takeRetainedValue`
  balances Core Audio's +1; artwork `NSCache` is count-bounded (400) with
  self-removing in-flight tasks.
- **Runtime (leaks tool):** after 12 track skips (full decode pipeline
  teardown/rebuild each), seeks, panel toggles, view switching, and repeated
  context menus: **zero leaks attributable to Hydrophone code**. Footprint is
  stable and *declines* during playback (47 MB idle → ~118 MB peak → 83 MB
  while still playing) — the bounded read-ahead behaves as designed.
- **Known framework-internal leak (accepted):** AudioToolbox's
  `ListenerMap::InsertEvent` leaks ~50–100-byte AU parameter-listener
  bindings each time the player node is (re)connected to the mixer — first
  play, rate-change hard starts (rate matching), route recoveries. ~1.2 KB
  per reconnect, all inside `AVAudioEngine`/`AudioToolboxCore` via the
  documented `engine.connect` API; not fixable app-side (we already reconnect
  only when the timeline rate actually changes). Heisenbug note: full
  `MallocStackLogging=1` masks it; reproduce with `=lite` or none.

## M7 quick wins — shortcuts + restoration (2026-07-07)
Status: **done & live-verified by driving the app (computer-use).**
- **File → New Playlist… (⌘N)** replaces New Window (like Music); routed to
  the sidebar's existing New Playlist prompt via an observable request
  counter on `AppModel`. Disabled when disconnected.
- **Controls gains** Increase/Decrease Volume (⌘↑/⌘↓, ±0.1) and a current-track
  favorite toggle (⌘L) whose title tracks the starred state ("Add to/Remove
  from Favorites"); it loads the starred list first so the toggle is truthful.
- **Table-sort persistence**: `MusicTrackTable` takes a `sortAutosaveKey`
  (one slot per view kind: songs/favorites/browser/album/search); the sort
  key + direction persist to UserDefaults (`trackSort.<key>`) and are restored
  on creation — only for columns that still exist. Playlists are exempt
  (stored order is the reorder surface).
- **Column-browser selections persist** (`browser.genre/artist/album` via
  `@AppStorage`); the reset cascade moved into the binding setters so a
  restore doesn't clear the restored artist/album, and the genre's songs are
  reloaded on appearance.
- Verified live: ⌘N opened the prompt; ⌘↓/⌘↑ moved the toolbar volume
  slider; ⌘L unstarred the playing track (row left Favorites) and re-starred
  it; Rock → Jimi Hendrix + Title-sort survived a full quit/relaunch
  (defaults inspected: `trackSort.browser = "title|asc"`, flips to desc on
  re-click); playlist view stayed in stored order with no sort applied.

## Tooling — SwiftLint (2026-07-06)
Status: **done; lint clean, build warnings unchanged, all 66 tests green.**
- SwiftLint 0.65 installed (Homebrew) with a near-default `.swiftlint.yml`
  (only idiomatic short names `id/i/x/y/lo/hi` excluded from
  `identifier_name`). 125 violations fixed to zero.
- Along the way: `MusicTrackTable`'s cell/row views moved to
  `TrackTableCells.swift`; `PlaybackState`/`RepeatMode` moved to
  `Models/PlaybackTypes.swift`; oversized functions split
  (`viewFor` cell builders, `handlePackets` input helpers, context-menu
  sections); `PlaybackService`'s 7-param decode functions bundled into a
  `DecodeRequest`; `PlaybackService`/`PlayerModel` reorganized into same-file
  extensions per functional area. One justified `file_length` disable stays in
  `PlaybackService.swift` (splitting the actor would expose its private
  state). No behavior changes.

## Hardware sample-rate matching (2026-07-05)
Status: **done & human-verified against a USB DAC (CXA81, 44.1k–705.6k).**
Audirvana/Roon-style bit-perfect-style output, on by default (Settings →
Playback → "Match hardware sample rate"); full design in
`03-playback-engine.md`:
- Each hard start re-derives the timeline format from the track's **native
  sample rate** (`ProgressiveAudioSource.chooseOutput` picks the output format
  at source discovery — no software resample for native-rate tracks), and the
  node is reconnected when the rate differs from the current connection.
- The output device's **nominal hardware rate** is set to the closest
  supported match (`AudioOutputDevices.bestSupportedRate/setNominalSampleRate`),
  so nothing resamples between file and DAC. Gapless followers join the
  running timeline's format (resampled only if they differ).
- Deliberate rate switches fire config-change notifications — swallowed as
  echoes via the recovery guard. With matching off, timelines return to the
  fixed 44.1 kHz base format and the device's rate is never touched.
- Verified live: a 48 kHz pre-set device snapped to 44.1 kHz on play; with the
  toggle off an external 48 kHz set was left untouched. Remaining ideal-world
  gaps: bit depth stays float32 through the mixer (lossless for ≤24-bit
  sources); exclusive/hog-mode access not implemented.
- Same pass: the menu-bar icon now matches the app icon's waveform glyph, and
  `ArtworkView` gained a `placeholderSymbol` (menu-bar panel shows the
  waveform, glyph scales with view size).

## UI overhaul — Cadence design pass (2026-07-02/03)
Status: **done & live-verified (computer-use driving the real app).** The
visual direction moved from the old bottom-bar layout to the Cadence design
project (see `09-design-system.md` for the source). Highlights, with pointers
for anything the older sections below describe differently:
- **Now-playing toolbar** — transport (prev / accent play circle / next)
  leading, a centered "LCD" (artwork, title, artist — album, elapsed/total,
  accent progress hairline; click toggles the panel), volume + panel toggle
  trailing. `NowPlayingBar` (bottom bar) is gone; see `NowPlayingToolbar.swift`.
- **Now Playing panel** — `UpNextView` → `NowPlayingPanel.swift`: headerless
  inspector, full-bleed hero artwork to the window top, slim scrubber,
  transport with shuffle/repeat, aligned Up Next queue (drag-to-reorder,
  hover play/remove). Only presentable while something plays or is queued.
- **Search** — field pinned at the top of the sidebar
  (`.searchable(placement: .sidebar)`, ⌘F focuses); results are artist/album
  shelves over the shared track table.
- **No NavigationStack** — in-place navigation via `Navigator` (opened album
  overlays the section with an inline Back link; Artists is a master-detail
  split). `GenresView` was folded into the column browser.
- **Consistency fixes** — shared `AlbumGridCell` (covers fill adaptive grid
  cells), column-browser panes match the table header style, content no
  longer scrolls under the transparent toolbar (pinned hairline).
- **Menu-bar panel** — restyled to the same design language (slim scrubber +
  times, accent play, shuffle/repeat).
- Gotchas discovered (recorded in `04-ui-ux.md`): custom toolbar items can't
  live above the sidebar; row tap gestures kill List drag-reordering;
  `.toolbarBackground(.visible)` is a no-op under `.hiddenTitleBar`.
- **Stability: gapless events vs. queue edits.** The engine echoes the queue
  position a track had at hand-off; queue edits after hand-off shift
  positions, so `PlayerModel` now translates every `.trackChanged`/`.wantNext`
  through a `spanPositions` map (hand-off echo → current position), adjusted
  positionally by move/remove/insert alongside `currentIndex`. Unknown echoes
  (stale across a hard restart) are ignored rather than advanced into.
  `handle(_:)` is internal so tests drive engine events directly (3 tests).

## M6 — MenuBarExtra, search, output device ✅
Status: **complete — multi-device switching + route changes human-verified
2026-07-05 (USB DAC); see the bullets below.**
- **MenuBarExtra `.window` panel** — `MenuBarPanel` shares the same `PlayerModel`
  as the main window (artwork, scrubber, prev/play-pause/next). Verified live: the
  menu-bar popover reflects and controls the current track independently of the
  main window.
- **Global search** — `search3` via `.searchable`, with a 250 ms debounce and
  per-keystroke cancellation (`.task(id:)` in `SearchResultsView`). Already in
  place from M2; confirmed it meets the M6 bar.
- **Output-device selection** (new):
  - `Playback/AudioOutputDevices.swift` — Core Audio enumeration of
    output-capable devices (`AudioDevice` = id/uid/name), default-device lookup,
    and UID→id resolution (UID is the stable, persisted identifier).
  - `PlaybackService` — `setOutputDevice(uid:)` persists the choice and applies it
    to the engine's output unit (`kAudioOutputUnitProperty_CurrentDevice`),
    applied at engine connect and re-applied on every
    `.AVAudioEngineConfigurationChange` (route change / default-device change /
    format change) so playback follows the new route; falls back to the system
    default when the chosen device is gone.
  - Settings → Playback gains an **Output Device** picker (System Default +
    devices), persisted via `@AppStorage("outputDeviceUID")`.
  - Verified live (computer-use): picker enumerates real devices (System Default +
    MacBook Pro Speakers), selecting an explicit device persists and plays with
    no engine errors / 0 IO overloads.
  - ✅ **Multi-device switching + route changes human-verified (2026-07-05)**
    against a USB DAC (Cambridge Audio CXA81) alongside MacBook/Studio Display
    speakers: mid-track switches amp → speakers → amp all audible; yanking the
    amp's USB mid-track fell back to the system default and kept playing from
    the playhead; replugging re-pinned to the amp automatically. Findings
    fixed along the way (see `PlaybackService`/`AudioOutputDevices`):
    - A **live device swap wedges the render graph silently when hardware
      formats differ** (USB DAC at 44.1 kHz vs speakers) — audio gone until a
      rebuild, unrecoverable by switching back. All route changes (manual
      switch, vanish, return) now rebuild the engine and hard-restart the
      stream at the playhead (`recoverPlayback`, reusing the seek path) — a
      sub-second gap, reliable on any hardware.
    - `AVAudioEngineConfigurationChange` does **not** fire when a *pinned*
      device vanishes: a `kAudioHardwarePropertyDevices` listener
      (`AudioDeviceListObserver`) drives vanish-fallback / return-re-pin.
    - Settings device picker refreshes live on connect/disconnect, shows a
      "(disconnected)" row (persisted device name) while the choice is absent,
      and filters Core Audio's transient private aggregates.
    - Hydrophone never touches the system default — other apps' routing is
      fully independent (macOS's own Bluetooth default auto-switch is not
      ours to control).

## M5 — Playlists CRUD/reorder + Favorites ✅
Status: **complete — reorder-by-replace + add/remove verified against
Navidrome 0.62 (2026-07-03; see "Remaining for M5" below).**
- **Endpoint** — `createPlaylist` extended with an optional `playlistId` so it
  can *replace* a playlist's contents (the canonical Subsonic reorder
  mechanism, since `updatePlaylist` can only append).
- **LibraryModel** — added playlist editing: `createPlaylist(name:songIds:)`
  (returns the created playlist to auto-select it), `deletePlaylist`,
  `renamePlaylist`, `addToPlaylist`, `removeFromPlaylist(indexes:)`, and
  `reorderPlaylist(name:songIds:)` (full-replace). Each refreshes the sidebar
  list. Favorites: batched `setStarred(_:songIds:)` (one reload for many) plus
  `setAlbumStarred`.
- **TrackTableView** — now the single place for track actions everywhere
  (Songs, album/playlist/genre detail, favorites, search):
  - **Favorites star column** with optimistic local state (taps reflect
    immediately; server reconciles on the next `getStarred2`).
  - Context menu: Play / Play Next / Add to Up Next · **Add to Playlist ▸**
    (existing playlists + **New Playlist…** via a name alert) · Add/Remove
    Favorites (multi-select aware).
  - **Playlist-edit mode** (opt-in via handlers): reorder (Move to Top/Up/
    Down/Bottom) + **Remove from Playlist**, operating on stored indices;
    `sortable: false` keeps the displayed order == stored order so reorder is
    coherent.
- **SidebarView** — Playlists section header gains a **+** (New Playlist alert,
  auto-selects the new playlist); per-row context menu **Rename… / Delete**
  (with confirmation; resets selection if the open playlist is deleted).
- **PlaylistDetailView** — rewritten: artwork + song-count/duration header,
  **Play** + **Shuffle**, toolbar **⋯ → Rename…**, and an editable
  `TrackTableView` (drag-free reorder + remove via context menu) with optimistic
  updates that re-fetch after each server edit.
- **AlbumDetailView** — header **favorite (star) toggle** for whole albums.
- **Row identity** — `TrackTableView` wraps each track in a positional `Row`
  (id = stored index) so **duplicate songs are distinct** (select / remove /
  reorder act on one entry, not every copy). Title is now the first column.
- **Drag & drop** — track-table rows are `.draggable` (`DraggedTrack` = song id
  + source index, JSON-encoded); **dropping onto a sidebar playlist** adds the
  song(s), with a drop-target highlight.
- **Playlist appearance (Music-faithful, AppKit table)** — `PlaylistDetailView`
  uses `MusicTrackTable`, an `NSViewRepresentable` wrapping `NSTableView`
  (`UI/Components/MusicTrackTable.swift`). SwiftUI can't combine edge-to-edge
  stripes + double-click + reliable selection (`Table` is inset-only; `List`
  can't double-click without breaking selection), so the playlist uses AppKit:
  - `.fullWidth` style + alternating row colors → **true edge-to-edge stripes**
    (incl. empty filler rows below, like Music).
  - **Double-click-to-play** (`doubleAction`), **Return-to-play** (keyDown),
    native single/multi **selection**, full-width **red** selection via a
    custom `NSTableRowView.drawSelection`.
  - **Now-playing speaker** column (`speaker.wave.2.fill` in the accent red),
    shown independently of selection.
  - Favorite star column (clickable `NSButton`); right-click menu built with a
    `ClosureMenuItem` helper (Play / Play Next / Add to Up Next / Add to
    Playlist▸ / Favorite / Move to Top·Up·Down·Bottom / Remove).
  - Verified by driving the app (computer-use): double-click started playback +
    speaker appeared on the playing row while selection moved elsewhere; stripes
    edge-to-edge; favorites/menu/selection all work.
- **Unified table everywhere** — `MusicTrackTable` is now the single track list
  used across the whole app. `TrackTableView` was reworked into a thin SwiftUI
  wrapper over it (same public API, so all call sites — Songs, album/genre
  detail, Favorites, Search, ColumnBrowser, Playlist — were untouched). Added to
  the AppKit table so the browse views didn't regress:
  - **Click-to-sort headers** (`sortDescriptorPrototype` + a coordinator-owned
    sorted `displayed` order). Playlist mode passes `sortable: false` (keeps
    stored order for reorder).
  - **Drag-to-playlist** via `tableView(_:pasteboardWriterForRow:)` writing a
    `DraggedTrack` as `public.json`, which the sidebar's SwiftUI
    `.dropDestination(for: DraggedTrack.self)` accepts.
  - Callbacks are order-independent: `onPlay([Song], Int)` /
    `onToggleFavorite(Song)` / `makeMenu([Song], IndexSet)` use the *displayed*
    (sorted) order.
  - Verified live (computer-use): edge-to-edge stripes, double-click-to-play, the
    now-playing speaker (which correctly tracks the song across a re-sort),
    selection, and header sorting all work in Favorites/Songs/Playlist.
  - The old `PlaylistTracksView` was deleted (folded into `TrackTableView`).
  - Note: dropped the standalone album `#` (track-number) column for a single
    consistent column set (Title/Artist/Album/Genre/Time + speaker + favorite).
  - **Header/stripe polish:** the `Time` header is right-aligned to match its
    right-aligned values; `columnAutoresizingStyle = .uniformColumnAutoresizing`
    makes the flexible columns fill the table width so rows/stripes/selection
    run truly edge-to-edge (previously ~20px short on the right). Verified.
  - ⚠️ **Open:** post-relaunch order didn't reflect earlier menu reorders, so
    **server-side persistence of reorder-by-replace on Navidrome is unconfirmed**
    (favorites persist fine). Native drag-to-reorder also postponed.
  - Other track views (Songs/Albums/Genres/Favorites/Search) still use the
    sortable `Table` (`.inset(alternatesRowBackgrounds:)`) — inset, not
    edge-to-edge. Converting them would mean dropping click-to-sort headers
    (only `Table` sorts). Open question whether to unify.
- **Accent color** — app `AccentColor` set to the iTunes red (`#CF172C` light /
  brighter in dark), sampled from the user's iTunes 12.6.3 reference screenshot
  (the selected-row red is `#CC132C`). Drives row selection, buttons, etc.
- **Sidebar (iTunes-style)** — section icons are colored red (loaded via
  `Color("AccentColor")` so they stay red regardless of list tint); selection is
  the standard macOS pill, which renders the accent red while the sidebar is the
  focused pane and neutral gray when another pane is focused (matching the
  reference, which was captured with the track list focused). Forcing
  always-gray would need custom row drawing — not done (SwiftUI's sidebar
  selection ignores `.tint`).
- Tests: `PlaylistEndpointTests` (8) — create (with/without songs), replace-for-
  reorder ordering, rename/add/remove via `updatePlaylist`, delete, star/unstar.

### Remaining for M5 / to verify
- ✅ **Reorder-by-replace + add/remove verified against Navidrome 0.62
  (2026-07-03),** driving the real app: Move to Top persisted across a full
  relaunch (fresh `getPlaylist` fetch); Move Up/Down round-trips; Remove took
  out only the targeted entry with a duplicated song present; Add to
  Playlist ▸ appended; a final relaunch fetched the exact restored order —
  duplicates intact throughout. (The earlier "post-relaunch order didn't
  reflect reorders" observation did not reproduce.)
  Note: replace and bulk add/remove use **GET** query params, so very large
  playlists could hit URL-length limits — fine for typical sizes; a POST path is
  a future hardening item if needed.

## M0 — Foundation ✅
Status: **complete, builds clean.**
- `Hydrophone.xcodeproj` (app + unit-test targets), synchronized file groups.
- App Sandbox + `network.client` entitlement (`Hydrophone/Hydrophone.entitlements`),
  Hardened Runtime, generated Info.plist (min macOS 15, music category,
  `app.hydrophone`).
- Scenes wired in `App/HydrophoneApp.swift`: `WindowGroup`, `Settings`,
  `MenuBarExtra(.window)`; shared `@Observable` models injected via environment.
- `App/AppModel.swift` composition root owning services + models.
- Asset catalog with `AppIcon` (placeholder) + `AccentColor`.

## M1 — Connectivity & auth ✅
Status: **complete, builds clean, 18 unit tests passing.**
- `Services/SubsonicClient.swift` — actor; request builder
  (`/rest/<method>.view`, common params `v/c/f=json`), envelope decode, typed
  `SubsonicError` mapping, capability fields surfaced via `ServerInfo`.
- Auth: token+salt (`md5(secret+salt)` via CryptoKit, random salt per request)
  and OpenSubsonic `apiKey`. Secret never appears in the URL; token never
  persisted.
- `Services/CredentialStore.swift` — Keychain-backed store (+ in-memory store
  for tests/previews).
- `Models/ConnectionModel.swift` — connection state machine, Test Connection
  (`ping`), Save & Connect (persists to Keychain), refresh at launch,
  transcoding prefs (UserDefaults).
- `UI/Settings/SettingsView.swift` — Connection + Playback tabs (server,
  auth method, Test/Save/Disconnect, transcoding format/bitrate).
- Tests: `AuthTests`, `DecodingTests`, `RequestBuildingTests`,
  `PlayerQueueTests` — md5 vectors, salt randomness, URL/auth construction for
  both methods, transcoding params, envelope/model/date decoding, failed-status
  → error, queue/transport logic.

## M4 — Gapless + queue + column browser ✅
Status: **complete — gapless human-confirmed seamless 2026-07-03** (see
"Remaining for M4" below for the verification details).
- **Gapless engine** — `PlaybackService` reworked to decode **every track to one
  canonical format** (44.1 kHz/stereo float) and schedule consecutive tracks
  back-to-back on a single `AVAudioPlayerNode` (no stop between tracks), so
  transitions are seamless and **sample-rate changes are handled by resampling**.
  Pre-buffering uses a **pull model**: when a track finishes decoding the service
  emits `.wantNext(afterIndex:)`, `PlayerModel` replies `enqueueNext`/
  `enqueueNoMore`. Track boundaries detected via sample-time **spans** →
  `.trackChanged(index)`; `.ended` only when the last track finishes.
  `ProgressiveAudioSource` now decodes to the supplied canonical format.
- **PlayerModel** — gapless coordination (`gaplessAdvance`, `provideNext`,
  auto vs manual successor incl. repeat-one loop / repeat-all wrap). Manual
  skip/seek hard-restart (a brief gap is expected, by design).
- **Up Next UI** — `UI/NowPlaying/UpNextView.swift` shown as an `.inspector`
  (⌘U / toolbar / View menu): now-playing + upcoming, **drag reorder**, remove,
  **play-from-here**, clear. Backed by tested `PlayerModel` queue editing
  (`moveQueue`, `removeFromQueue`, `clearUpNext`, `playFromQueue`).
- **Column browser** — `UI/Library/ColumnBrowserView.swift`: Genre → Artist →
  Album panes above a filtered `TrackTableView`; selections narrow panes to the
  right + the tracks below. Toggle via View menu (⌥⌘B) / `SongsView`.
- Tests: `QueueEditingTests` (7) added; full suite green.

### Remaining for M4 / to verify
- ✅ **Gapless seam instrumentally verified (2026-07-03):** three consecutive
  Abbey Road medley boundaries (Golden Slumbers → Carry That Weight → The End
  → Her Majesty) crossed on-device with **zero underruns** (the starvation
  detector never fired) and **zero HAL overloads/skipped IO cycles** in the
  unified log; the album played to completion. Found & fixed along the way:
  pre-buffer streams suspended by the read-ahead throttle were hitting
  URLSession's default 60 s request timeout (-1001) — the loader now uses a
  600 s request timeout since long idle is by design. Remaining known log
  noise: one benign `AudioConverter … packet descriptions (0)` complaint per
  track at the end-of-stream flush (decode continuity is test-verified).
  **Human-confirmed seamless by ear (2026-07-03)** — the M4 gapless-seam exit
  criterion is met. Still open from that checklist: a cross-sample-rate
  (44.1↔48 k) transition, untestable until the library has mixed-rate tracks.
- 🔬 Sample-rate change across tracks (44.1↔48 k) audibly clean — device-only.
- 🔬 Magic-cookie formats (AAC-in-MP4) — `AVAudioConverter` has no cookie API;
  ADTS/MP3/FLAC are fine; documented limitation in `03-playback-engine.md`.

## M3 — Single-track playback + system integration ✅
Status: **complete — playback verified end-to-end on device** (audio plays
from Navidrome, seek verified, media keys hardened during M7 work; see
"Audible playback" below for the crackle/seek forensics).
- **Decision:** Option A (progressive decode) is the committed streaming source
  (see `03-playback-engine.md`). Option B kept as fallback.
- `Playback/PlaybackService.swift` — actor owning `AVAudioEngine` + one
  `AVAudioPlayerNode`. Drives loader → decoder → buffer scheduling. Play / pause
  / resume / seek / stop / volume; sample-time position throttled to ~5 Hz via an
  `AsyncStream<PlaybackEvent>`; App Nap / idle-sleep prevented via
  `ProcessInfo.beginActivity` while playing; lazy engine connect at the decoded
  format; teardown releases per-track resources.
- `Playback/DataStreamLoader.swift` — `URLSession` data-delegate → chunked
  `AsyncThrowingStream<Data>` (audio starts before full download).
- `Playback/ProgressiveAudioSource.swift` — Audio File Stream Services parser +
  `AVAudioConverter` producing `AVAudioPCMBuffer`s; format auto-detect + suffix
  hint; `SendablePCMBuffer` ownership transfer.
- `Playback/AudioStreamSource.swift` — protocol seam so Option B is droppable-in.
- `Services/NowPlayingCenter.swift` — `MPNowPlayingInfoCenter` metadata/artwork/
  elapsed + `MPRemoteCommandCenter` (play/pause/toggle/next/prev/seek) → **media
  keys**. Single writer to the system center.
- `Models/PlayerModel.swift` — rewritten to forward intent to `PlaybackService`
  and drive `state`/`position` from its events, while keeping queue/transport
  bookkeeping synchronous (so unit tests need no engine). Wires remote-command
  callbacks; pushes Now Playing metadata + async artwork.
- `App/AppModel.swift` — constructs and injects `PlaybackService` +
  `NowPlayingCenter`.
- Seek re-opens the stream with `timeOffset` (Option A has no random access);
  scrubbers in `NowPlayingBar`/`MenuBarPanel` seek once on release, not per drag.
- Tests added: `PlaybackConfigTests` (transcode prefs, `timeOffset` URL, file
  type hint) + existing `PlayerQueueTests` still green after the refactor.

### Remaining for M3 / to verify
- 🔬 Runtime: play/pause/seek a real track; confirm Now Playing widget + media
  keys; artwork + elapsed time. Needs live server.
- 🔬 Magic-cookie handling (AAC/ALAC) and seek accuracy are flagged for the M4
  spike (see `03-playback-engine.md`).

## M2 — Library browse 🚧
Status: **UI + data flow working in-memory; SwiftData cache not yet wired.**
- `Networking/SubsonicModels.swift` value types (Song/Album/Artist/Genre/Playlist);
  `Networking/Endpoint.swift` endpoint map; `Networking/SubsonicResponse.swift`
  envelope + per-endpoint bodies.
- `Models/LibraryModel.swift` — albums (paginated via `getAlbumList2`), artists
  (`getArtists`), genres, songs (random sample — see limitation), favorites
  (`getStarred2`), playlists, search (`search3`), album/artist/genre detail,
  star/unstar.
- UI: `RootView` (NavigationSplitView + bottom now-playing bar + not-connected
  overlay + global search), `SidebarView` (Library + Playlists sections),
  `AlbumsView` (grid + infinite scroll), `AlbumDetailView`, `ArtistsView`
  (+ detail), `SongsView`, `GenresView` (+ detail), `FavoritesView`,
  `PlaylistDetailView`, `SearchResultsView`, `TrackTableView` (sortable, context
  menu, play/enqueue), `ArtworkView` + `Services/ArtworkCache.swift` (NSCache,
  server-resized, in-flight dedup).
- `UI/NowPlaying/NowPlayingBar.swift`, `UI/MenuBar/MenuBarPanel.swift`,
  `App/HydrophoneCommands.swift` (Controls menu + shortcuts).

### M2 notes
- ❌ SwiftData persistence layer — **dropped.** The app is network-required by
  design (no offline playback), so library metadata stays in-memory per
  `LibraryModel`. Artwork is cached persistently on disk instead
  (`Services/ArtworkCache.swift`); see `05-data-and-caching.md`.
- ✅ Column browser (Genre → Artist → Album) — delivered in M4; a fourth
  Composer pane added 2026-08-22 (see below and the known limitation it
  inherits).

## Known limitations / deferrals
- ✅ **Songs and the unfiltered column browser use the complete library.**
  Empty-query `search3` now supplies the eager all-songs walk; incompatible
  servers retain the bounded `getRandomSongs` fallback (#81).
- ✅ ~~Playback is stubbed~~ — superseded: the real `AVAudioEngine` streaming +
  gapless engine landed in M3/M4 (`03-playback-engine.md`).
- ⏳ Accessibility pass, state restoration, MAS packaging — per roadmap M7–M8.
  (SwiftData cache dropped; output-device selection delivered in M6; playlist
  editing/reorder + favorites in M5; Now Playing center / media keys in M3.)

## Verification status
- ✅ Issue #114 (2026-09-05): per-item album/artist detail caching. **417 tests
  / 440 executions, 0 failures**, unsigned build zero warnings, SwiftLint 0
  violations. Live on Tim's configured Navidrome 0.63.2: revisiting Alfred
  Brendel and the *Schwanengesang* album both hit cache with no repeat
  network call; a mid-session background reconciliation correctly forced one
  fresh re-fetch afterward.
- ✅ PR #153 review repair (2026-09-05): **413 tests / 436 executions, no
  failures/skips**, unsigned build zero warnings, lint/diff checks clean.
  Confirmed the failed unsaved form test retains the populated live library;
  bounded retry and stale/canceled-load regressions pass. Whole-table small-write
  cost remains a documented performance follow-up.
- ✅ Epic #128 / #146–151 (2026-09-05): all implementation and acceptance work
  complete, pending joint review/landing. Unsigned app build zero warnings;
  **407 tests / 428 executions, 0 failures/skips**; SwiftLint 0 violations;
  diff check clean. Real process restarts on Navidrome 0.63.2 verified Home
  seed-to-live behavior and saved-playlist launch (10 songs / 59:21); disk
  snapshot holds 14,231 songs and 1,152 albums. See the newest entry for exact
  executable/PIDs and the corrected earlier verification claim.
- ✅ Issue #146 (2026-09-04): unsigned app build zero warnings; **375 tests /
  396 executions, 0 failures/skips**; SwiftLint 0 violations (152 files).
  In-memory and disk persistence regressions pass, including canonical
  identity reuse across overlapping unsaved graphs. Live on Tim's configured
  Navidrome server: 14,231 songs loaded, *After Bach* rendered 12 tracks with
  composer metadata, *Before Bach: Benediction* streamed to 0:09 with the
  ALAC 16/44.1k badge; playback paused afterward. Ad-hoc test-build signing
  only; production persistence wiring remains #147–151.
- ✅ Issue #124 (2026-09-04): unsigned build has zero compiler warnings; full
  suite passes; SwiftLint clean. Live on Tim's configured Navidrome server:
  a 10-song playlist rendered instantly on a cold native-index cache; the
  added Work column populated a few seconds later once the non-blocking
  join resolved, with no re-render delay or missing-track flash.
- ✅ Issue #118 (2026-09-04): unsigned build has zero compiler warnings; full
  suite passes; SwiftLint clean. Live on Tim's configured Navidrome server:
  launching directly on Artists (never visiting Songs) still showed the
  toolbar's songs-loaded pill climb to the full 14,231-song count within
  seconds, confirming the walk now starts eagerly at launch.
- ✅ Issue #102 (2026-09-03): unsigned build has zero compiler warnings; full
  suite (343-344 executions across runs, 0 failures/skips); SwiftLint clean.
  Live on the configured Navidrome server: the status renders attached
  inside the LCD capsule, tracked the full-library walk, stayed visible
  after navigating to Artists mid-load, and vanished on completion; no
  bottom-of-Songs-page overlay appeared.
- ✅ Issue #108 (2026-08-30): unsigned build has zero compiler warnings; full
  suite **324 cases / 344 executions, 0 failures/skips**; SwiftLint and
  `git diff --check` pass. Rendered regressions cover complete displayed-row
  fitting from too-narrow and too-wide widths, exact text/badge/font metrics,
  headers, bounds, empty tables, offscreen-view exclusion, and persistence.
  Live on the configured Navidrome server: the exact Debug build rendered
  14,327 songs and fit Title from deliberately narrow to the full-library
  widest value in about 0.6 seconds, with playback and Up Next unchanged.
- ✅ Composers/Artists list spacing polish (2026-08-28): unsigned build has
  zero compiler warnings; full suite **330 test cases/executions, 0
  failures/skips**; SwiftLint clean. Live against Tim's connected library
  across several iterations; final row spacing, separator, and count color
  confirmed.
- ✅ Column divider resize cursor (2026-08-28): unsigned build has zero
  compiler warnings; full suite **313 cases / 333 executions, 0
  failures/skips**; SwiftLint and `git diff --check` pass. Rendered regressions
  cover picker removal and detach/reattach observer ownership. Live on the
  configured private Navidrome server: Test Connection succeeded, 14,117 songs
  rendered, picker removal reflowed the headers immediately, and a remaining
  divider resized normally. Earlier live iterations also confirmed smooth
  resize tracking and no reorder-drag conflict.
- ✅ Issue #84 (2026-08-28): unsigned build has zero compiler warnings; full
  suite **311 cases / 331 executions, 0 failures/skips**; SwiftLint and
  `git diff --check` pass. Rendered regressions cover complete panes, hundreds
  of composer tracks, cascades/restoration, and stale genre requests. Live on
  the configured private Navidrome server: 14,117 songs loaded, responsive
  filters and genre roundtrip, saved pane selections restored after relaunch.
  Browser dependency isolation and artwork-test teardown blockers are resolved.
- ✅ Issue #82 local (2026-08-28): unsigned build has zero compiler warnings
  (only the non-compiler AppIntents extraction notice); full suite
  **303 cases / 323 executions, 0 failures/skips**; SwiftLint and
  `git diff --check` pass. Incremental loading, large-table/scroll behavior,
  and All-row reset clicks have automated coverage.
- ✅ Issue #82 earlier live (2026-08-26): incremental rows/count and 14,128-song completion observed;
  Tim confirmed column-browser reset and deep-scroll/relaunch restoration with
  no snap-back, responsive Title/Artist/Album sorting, and fresh Shuffle All
  mixes without altering the visible Songs list.
- ✅ Issue #82 final live recheck (2026-08-28): server recovered from HTTP 502;
  fresh isolated build incrementally loaded 500 → 14,117 songs and finished
  metadata enrichment. Selection/Get Info identity, scrolling without
  snap-back, and composer-filter reset verified; no queue changes.
- ✅ Issue #81 (2026-08-26): unsigned build has zero compiler warnings; full
  suite **291 cases / 307 executions, 0 failures/skips**;
  SwiftLint and `git diff --check` pass. Paging, cache, invalidation, fallback,
  stale-completion, and no-progress regressions have red/green evidence.
- ✅ Issue #81 live (2026-08-26): private Navidrome 0.63.2; isolated signed
  branch app loaded **14,082 songs / 14,082 unique ids**, rendered real rows,
  and completed the all-songs walk plus WorkInfo join in **50.1 seconds**.
- ✅ Issue #83 (2026-08-26): unsigned build has zero compiler warnings; full
  suite **275 cases / 291 executions, 0 failures/skips**; SwiftLint and
  `git diff --check` pass. The 1,003-song and short-page request regressions
  have red/green evidence.
- ✅ Issue #83 live (2026-08-26): private Navidrome 0.63.2; Classical loaded
  exactly **7,384 tracks** and scrolled through the table's final rows in an
  isolated signed Debug app. Temporary instrumentation and app copy removed.
- ✅ Issue #85 (2026-08-26): unsigned build has zero warnings; full suite
  **273 cases / 289 executions, 0 failures/skips**; SwiftLint and
  `git diff --check` pass. Request/metadata regressions have red/green evidence.
- ✅ Issue #85 live (2026-08-26): private Navidrome 0.63.2; Bach **596** and
  Beethoven **514**, zero resolution `getSong` calls, reference metadata and
  artwork-byte parity, and cached repeat loads around **11–12 ms**. Signed
  UI playback, Info, and favorite restoration pass. The cold-index timeout
  and initial intermittent engine abort are recorded in the entry above.
- ✅ Issue #86 (2026-08-26): unsigned build has zero warnings; full suite
  passes **264 cases / 273 executions, 0 failures/skips**; strict SwiftLint
  and `git diff --check` pass. The regression was verified failing before
  the `missing=false` fix and passing afterward.
- ✅ Issue #86 live (2026-08-26): demo Navidrome 0.63.2 index **501**, equal
  to filtered `X-Total-Count`; cache retains 501. Focused index and composer
  live tests pass. Signed-app composer tracks load and “Outro” plays with
  an advancing timer. The broader probe-suite HTTP 429 is recorded above.
- ✅ PR #87 local review fixes (2026-08-26): standard unsigned build succeeds
  with zero compiler warnings; SwiftLint and `git diff --check` pass with
  zero violations. Focused artwork tests pass (**12 cases, 0 failures/skips**).
- ✅ PR #87 full suite (2026-08-26): **263 test cases, 272 executions
  including parameters, 0 failures, 0 skipped**. Explicit Sendable task
  closures in two mock URLProtocol types resolve the compilation blockers.
  The test build emits the AppIntents metadata-extraction tool notice
  (no AppIntents framework); no compiler warnings.
- ✅ PR #87 local signed build and strict signature verification pass using
  the available user Developer ID identity via command-line overrides;
  project signing settings are unchanged.
- ✅ PR #87 live artwork check (2026-08-26): signed PR build against the
  user-authorized private Navidrome 0.63.2 server; scrolling, pagination,
  resizing, album detail and Back retain artwork. Credentials unchanged;
  existing caches retained. The earlier public demo attempt timed out and
  is not counted as successful verification.
- Previous full-suite verification after #29: **255 test cases, 264
  executions including parameters, 0 failures/skips**, 2026-08-25. This is
  historical evidence, not verification of the PR #87 changes.
- ✅ Artists master-list scroll restoration — live demo-server Back/relaunch,
  top-of-list, keyboard selection, and focused Space checks passed 2026-08-25
  (details in the #29 entry above).

### Live verification — 2026-06-22, against Navidrome 0.62.0 (real server)
Validated the networking + decode path end-to-end (opt-in `LiveDecodeTests`,
skipped unless `HYDROPHONE_HOST/USER/PASS` env vars are set — no secrets committed):
- ✅ **Auth** (token+salt) — `ping` returns ok; password never in the URL.
- ✅ **Capabilities** — `openSubsonic: true`; extensions include `transcodeOffset`
  (confirms the `timeOffset` seek approach is supported) + `transcoding`.
- ✅ **Endpoints decode** — `getAlbumList2`, `getArtists`, `getGenres`,
  `getRandomSongs`, `getPlaylists`, `getStarred2` all parse (extra
  Navidrome/OpenSubsonic keys ignored by `Codable`).
- ✅ **Artwork** — `getCoverArt` returns `image/webp` (NSImage decodes natively
  on macOS 15).
- ✅ **Stream** — `audio/mpeg` (MP3) with HTTP range support.
- ✅ **Transcode + seek** — `format=mp3&maxBitRate=192&timeOffset=30` returns
  valid MP3.
- ✅ **Decode pipeline (the spike!)** — a real downloaded MP3 fed through
  `ProgressiveAudioSource` (AudioFileStream + AVAudioConverter) produced
  > 1 s of 44.1 kHz canonical PCM. The Option A pipeline works on real data.
- **Bug found & fixed:** Navidrome 0.62 sends `genres` (array), not the legacy
  `genre` string → added `GenreRef`/`displayGenre` so the Genre column populates.
- **Connection robustness:** pasting the browser URL (`…/app`) caused a 404
  (`/app/rest/ping.view`). `ConnectionModel.normalizedBaseURL` now strips the
  `/app` SPA suffix + trailing slash/query/fragment and assumes `https://` when
  the scheme is omitted (a legit reverse-proxy subpath like `/navidrome` is
  preserved). Covered by `ConnectionTests`.

### Audible playback (on device)
- ✅ Audio plays end-to-end from Navidrome.
- 🔬 **Crackle investigation (evidence-based).** Rather than enlarge buffers:
  - **Decode/convert exonerated.** A self-contained test (`DecodeContinuityTests`)
    encodes a pure sine → AAC/ADTS → decodes it through the *real*
    `ProgressiveAudioSource` and measures sample-to-sample steps: the max interior
    step (~0.0324) equals the sine's natural slope (~0.0313) → **no glitches /
    sample corruption** in the per-batch conversion. (The synthetic ADTS stream
    under-decodes — an AudioFileStream/ADTS harness quirk — so real-file
    completeness + boundary continuity is covered by the extended `LiveDecodeTests`
    instead.)
  - **Found & fixed a real bug:** the converter's tail was never flushed —
    `ProgressiveAudioSource.finish()` now runs a final `.endOfStream` conversion
    (`flushDecoder()`) so the end of each track isn't dropped (clipped endings /
    gapless-seam clicks).
  - **Runtime underrun detector:** `PlaybackService` logs (os.Logger, category
    `playback`) when the player node starves. In a captured Console log it
    **never fired** → the crackle was *not* underrun.
  - 🐛→✅ **ROOT CAUSE FOUND (from the Console log):** repeated
    `AVAudioCompressedBuffer initWithFormat … required condition is false:
    (!(fmt.IsLinearPCM()…))`. `ProgressiveAudioSource` always wrapped packets in
    an `AVAudioCompressedBuffer`, but for **uncompressed (linear-PCM) sources —
    WAV/AIFF —** that buffer is invalid, so those tracks decoded to garbage →
    crackle. Matches the symptom exactly (only *some* songs cracked). **Fix:**
    when the source format is linear PCM, wrap the frames in an `AVAudioPCMBuffer`
    instead (compressed path unchanged). Verified clean build + tests.
  - Earlier mitigation (~2 s pre-roll + `engine.prepare()`) remains.
- 🐛→✅ **ROOT CAUSE of the remaining single click (~1 s into PCM tracks).** After
  the PCM fix, AIFF still produced one reproducible click. Traced with a render
  tap (output data was clean — `maxStep 0.157`, no discontinuity) + unified-log
  correlation: a single `HALC_ProxyIOContext … skipping cycle due to overload`
  fired ~1 s into playback. The audio **device dropped one IO cycle** (the glitch
  is after the engine, so not in the rendered samples). Cause: a track decodes
  *far* faster than real time, so its buffers are scheduled in one big burst —
  and **linear-PCM (AIFF/WAV) yields ~2× as many buffers** (~2800 for a 3:49
  track) as compressed, flooding `scheduleBuffer` and starving the IO thread
  (hence PCM-only). **Fix:** `ProgressiveAudioSource` now **consolidates** the
  many small per-batch decoder outputs into ~1-second buffers before yielding,
  cutting `scheduleBuffer` calls ~12×. Verified: the overload no longer appears
  in the log when playing the AIFF.
- **Bounded read-ahead (paced scheduling).** Following the standard streaming
  model (cf. AudioStreaming / SwiftAudioPlayer / the AVAudioEngine streaming
  writeup), decoding/scheduling no longer runs unbounded ahead of playback.
  `PlaybackService.throttleReadAhead` keeps the buffered look-ahead between ~8 s
  and ~15 s (both well above the 2 s pre-roll): once 15 s ahead it **suspends the
  URLSession transfer and pauses decoding**, resuming when playback drains to
  8 s. Bounds memory (a whole track is no longer held decoded in RAM) and smooths
  scheduling. `DataStreamLoader` gained `pause()`/`resume()`
  (`URLSessionDataTask.suspend/resume` → TCP back-pressure). Verified: the AIFF
  stays at 0 overloads and decode is paced (no early burst to completion).
- 🐛→✅ **Seek restarted the track from 0.** The Subsonic `timeOffset` parameter
  only seeks *transcoded* streams (the OpenSubsonic `transcodeOffset` extension);
  on an original-file stream (the default, transcoding off) the server ignores it
  and plays from the start. **Fix:** when not transcoding, `runDecode` streams from
  0 and `ProgressiveAudioSource` **discards decoded output up to the seek point**
  (`skipFrames`, sample-precise, works for every format); when transcoding it
  still uses the efficient server-side `timeOffset`. Verified by driving the app:
  scrubbing to ~2:00 resumes playback from 2:00 (0 overloads). Note: the
  non-transcoded path re-reads from the start up to the seek point (fine on a fast
  connection; a future byte-range/`AudioFileStreamSeek` optimization could avoid
  the re-read for self-syncing formats).

### Still requires a human (audio output / listening)
- ✅ Actual sound through an output device — verified (see "Audible playback").
- ✅ Audible gapless seam — human-confirmed 2026-07-03 (Abbey Road medley).
- ⏳ Cross-sample-rate transition (44.1↔48 k) — untestable until the library
  has mixed-rate tracks.
- ✅ Now Playing widget + media keys — hardened & verified during the M7 pass.
- App is launchable: `open` the Debug build, then Settings → Connection.
