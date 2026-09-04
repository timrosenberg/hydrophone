# 05 — Local Metadata & Artwork Caching

> **Decision (updated):** The **SwiftData metadata cache was dropped.** The app
> is network-required by design — you can't stream music with the server down,
> so caching library *metadata* for offline browsing adds complexity for little
> value. Library metadata stays **in-memory**, fetched per session, spread
> across `SubsonicClient`, `NavidromeClient`, and `LibraryModel` rather than
> held in one place — see "In-memory metadata caches (inventory)" for the full
> lifecycle breakdown. The one thing we *do* cache **persistently** (disk,
> across launches) is **artwork** (immutable) — see "Artwork cache". The
> SwiftData section below is retained as historical context and is **not
> implemented**.

**Persistent** (disk, survives relaunch) caching here is **artwork only** —
there is **no audio/offline caching**. Library **metadata** does have a real
in-memory caching layer, session-scoped only; it is inventoried below rather
than persisted (streaming-only, network-required).

## In-memory metadata caches (inventory)

This section audits every in-memory cache and cache-like load/session state in
the client and model layer, against `main` as of #139. It complements, but
does not replace, "Pagination & lazy loading" below (which covers `LibraryModel`
paging mechanics) — this section is about **what's held and for how long**,
not how a page is fetched. It's a factual inventory (#125 → #139); no
consolidation or warm-up-behavior decisions are made here — those are #140
(design) and #141 (implementation).

### Lifecycle matrix

| Owner · state | Scope/key | Source endpoint(s) | Consumers | Warm trigger | Coalescing / stale guard | Invalidation | Retry/failure | Class |
|---|---|---|---|---|---|---|---|---|
| `SubsonicClient.cachedAllSongs` (+ `inFlightAllSongs`, `allSongsGeneration`) | exact `ServerCredentials` | `search3` (empty query, paginated) | `LibraryModel.loadSongsIfNeeded()` (Songs tab, Shuffle All fallback paths) | `LibraryModel.loadSongsIfNeeded()`, driven eager by `ConnectionModel`'s `songsLoadHandler` on connect (#118) | Generation counter + in-flight task reused for matching credentials; a completion whose generation is stale is dropped, never written back | Explicit: `invalidateAllSongs()` from `ConnectionModel.disconnect()` and `saveAndConnect()` (credentials changed) | Only a walk that reaches exhaustion is cached; a mid-walk failure after partial progress propagates the error uncached (never silently swapped for a random sample) — see `SubsonicClient+AllSongs.swift` | Authoritative fetched data |
| `SubsonicClient.formPostSupport` | base URL only (not full credentials) | `getOpenSubsonicExtensions` | internal `perform(_:using:)` (routes flagged endpoints to POST) | Lazily, first flagged endpoint call per base URL | None (single cached tuple); a probe failure resolves `false` for that call *without* caching it, so one hiccup can't wedge POST off for the session | None explicit — reconnecting to the same base URL under different credentials keeps the old flag; correct today because form-post support is a server capability, not an account one | Failure (network, non-OpenSubsonic server, missing payload) resolves to `false`, uncached | Capability/auth state |
| `NavidromeClient.cachedToken` / `cachedTokenCredentials` | exact `ServerCredentials` | `POST /auth/login` | `ensureValidToken(using:)`, used by every native `/api/*` page fetch | First native call needing a token (composer load, song-index build, `probeNativeFeatures()`) | None beyond the credentials-match + expiry check; no generation counter, no in-flight coalescing — concurrent callers under a cold token each `login()` independently | **No explicit invalidation path.** Relies entirely on (a) `cachedTokenCredentials == creds` failing after a Settings change, and (b) `invalidateCachedToken()`, called only internally on a `401` during `fetchPage` | One transparent retry on `401` (invalidate token, relogin, retry once) | Capability/auth state |
| `NavidromeClient.cachedSongIndex` / `cachedSongIndexCredentials` (+ `songIndexGeneration`, `inFlightSongIndexBuild`) | exact `ServerCredentials` | `/api/song?missing=false` (paginated) | `songIndex()`, `songIndexSnapshot()`, composer roster/song lookup, `workInfo`/`bitDepths` batch joins (`NavidromeClient+SongLookup.swift`) | First caller needing native song data (Composers tab, `joinWorkInfo`, playlist detail's non-blocking join pass — #124) | Same shape as `cachedAllSongs`: generation counter + in-flight task reused per matching credentials, stale completions dropped | Explicit: `invalidateSongIndex()` from `ConnectionModel.startLibraryScan()` only. **Not called from `disconnect()`** — falls through to the credentials-mismatch check instead, same as the token cache | Errors propagate to the caller uncached; no fallback sample (unlike `cachedAllSongs`) since there's no meaningful partial substitute for native data | Authoritative fetched data |
| `LibraryModel.albums` / `albumOffset` / `albumsExhausted` / `albumFilter` / `albumsState` | unscoped (no credential guard) | `getAlbumList2` | Albums grid | `loadAlbumsIfNeeded()`, first Albums-tab appearance | `albumsState == .loading` guard against duplicate concurrent loads; retried when `albums.isEmpty` | **None on disconnect or credential change** — only `reloadAlbums()` (sort/filter change) or the (unwired, see below) `reset()` clears it | Failed page load leaves `albumsState = .failed`; next appearance (if still empty) retries | View/model state (session cache) |
| `LibraryModel.artists` / `artistsState` | unscoped | `getArtists` | Artists master list | `loadArtistsIfNeeded()` | `.loading` guard, retried while empty | Same gap as albums — no wired invalidation path | Failed load retried on next empty-state appearance | View/model state |
| `LibraryModel.composers` / `composersState` | unscoped (gated by `nativeFeaturesAvailable()`) | `NavidromeClient.composers()` (itself unpaged-cache, walks `/api/artist?role=composer` fresh each call) | Composers master list | `loadComposersIfNeeded()` | `.loading` guard, retried while empty | Same gap — no wired invalidation | Failed load retried on next empty-state appearance | View/model state, derived from native capability state |
| `LibraryModel.genres` / `genresLoading` | unscoped | `getGenres` | Genre column browser, Albums genre filter | `loadGenresIfNeeded()` | `genresLoading` flag prevents duplicate concurrent fetches from Albums + column browser | Same gap — no wired invalidation | Failure clears to `[]` silently (no `.failed` state surfaced) | View/model state |
| `LibraryModel.starredSongs` / `starredAlbums` / `starredSongIDs` / `starOverrides` / `albumStarOverrides` / `starredLoaded` | unscoped | `getStarred2`, `star`/`unstar` | Favorites view, `isStarred(_:)` everywhere a star glyph renders | `loadStarredIfNeeded()`, first favorite check or Favorites-tab visit | `starredLoading` flag; optimistic per-id overrides shown until the write + reconciling `reloadStarred()` round-trip | Same gap — no wired invalidation on disconnect/credential change; overrides are cleared per-id after each mutation's reload | A refused optimistic write rolls its override back; a failed reload keeps accepted overrides rather than reverting them | Mix: authoritative fetched data (`starredSongs`/`starredAlbums`) + view state (overrides) |
| `LibraryModel.homeNewest/Recent/Frequent/Random` / `homeLoaded` / `homeLoading` | unscoped | `getAlbumList2` ×4 (newest/recent/frequent/random), concurrent | Home shelves | `loadHomeIfNeeded()` | `homeLoading` flag; `homeLoaded` only set true if at least one shelf came back non-empty, so an all-offline launch retries next appearance | Same gap — no wired invalidation | All-empty result is treated as "didn't really load" and retried, not cached as a true empty state | View/model state |
| `LibraryModel.songs` / `songsState` / `songsGeneration` | unscoped *view* of `SubsonicClient.cachedAllSongs` | (derives from `client.allSongs()`, plus the native work-info join) | Songs tab, toolbar loading indicator (`songsAreLoading`) | `loadSongsIfNeeded()`, made eager at connect (#118) | Per-load generation counter: a superseded `loadSongsIfNeeded()` (invalidated mid-flight) can't overwrite `songs`/`songsState` with a stale result; partial pages publish incrementally via `onProgress` | Explicit: `invalidateSongs()`, wired through `ConnectionModel`'s `songsInvalidationHandler` on both `disconnect()` and credential change in `saveAndConnect()` | A failed load keeps existing (possibly partial) rows and surfaces `.failed`; next visit retries | Derived/view state layered over `cachedAllSongs`'s authoritative data |

Not a cache (fetched fresh every call, listed for completeness/contrast):
`LibraryModel.search(_:)`, `songs(forGenre:)`, `songs(forAlbum:)`,
`albums(forArtist:)`, `artistInfo(id:)`, `similarSongs(id:)`,
`topSongs(artist:)`, `randomAlbums()`, `randomBatch()`, playlist CRUD/listing
(`LibraryModel+Playlists.swift`). `songs(forComposer:)`
(`LibraryModel+Composers.swift`) has no cache of its own either, but reads
through `NavidromeClient`'s cached song index. Adjacent but out of scope for
this layer: `ConnectionModel.nativeFeaturesState` (capability state gating
whether native calls happen at all) and `ArtworkCache` (its own section,
disk-persisted, already documented).

### Overlaps and gaps → resolved by #140's design decision

- **`cachedAllSongs` vs. `cachedSongIndex` are two walks over largely the same
  library**, one via `search3` (Subsonic) and one via `/api/song` (native), as
  #125 already called out. Nothing here changes that; it's restated so the
  matrix above is the reference #140 designs against.
- **The same "cached value + credentials guard + generation counter + in-flight
  coalescing" shape is hand-rolled three times**: `cachedAllSongs`,
  `cachedSongIndex`, and (a simpler variant, no generation counter or
  coalescing) `cachedToken`. A shared generic primitive is exactly #125's
  "reusable cache abstraction" question for #140.
- **Invalidation is inconsistent across the four credential-scoped caches**:

  | Cache | On disconnect | On credential change (`saveAndConnect`) | On library scan |
  |---|---|---|---|
  | `cachedAllSongs` | ✅ explicit | ✅ explicit (if creds actually differ) | ✅ explicit |
  | `cachedSongIndex` | ❌ (falls through to credential mismatch) | ❌ (same) | ✅ explicit |
  | `cachedToken` | ❌ (same) | ❌ (same) | n/a (not library data) |
  | `LibraryModel` collections (albums/artists/composers/genres/starred/home) | ❌ | ❌ | ❌ |

  The credential-mismatch fallback (a stale cache simply won't match the new
  `ServerCredentials` and gets rebuilt on next use) makes the missing
  `cachedSongIndex`/`cachedToken` invalidations *harmless in practice*, not
  merely unwired — but it's an inconsistency worth a deliberate call in #140:
  either lean fully on the credential-guard pattern everywhere (and stop
  explicitly invalidating `cachedAllSongs`/`cachedSongIndex` at all), or wire
  every cache through one explicit invalidation path for the sake of a single
  legible lifecycle.
- **`LibraryModel.reset()` is effectively dead code in the running app.** It
  clears `albums`, `artists`, `composers`, `genres`, all starred/override
  state, and the home shelves — exactly the "unscoped, no wired invalidation"
  row group in the matrix above — but nothing in `ConnectionModel` or
  `AppModel` calls it; only `songsInvalidationHandler` (→ `invalidateSongs()`)
  is wired to `disconnect()`/credential change. It's currently called only
  from test teardown (`SubsonicAllSongsTests`, `NavidromeComposerLibraryModelTests`).
  Concretely: today, switching to a different server without relaunching the
  app leaves the Albums/Artists/Composers/Genres/Favorites/Home surfaces
  showing the *previous* server's data until each collection happens to be
  reloaded some other way (most never are, since their loaders all guard on
  "already non-empty, skip"). This has no fallback like the credential-guard
  caches above — it is a genuine, unscoped gap, and #140/#141 need to decide
  whether the fix is wiring `reset()` in, or moving these collections onto the
  same credential-scoped-cache pattern as `cachedAllSongs`/`cachedSongIndex`.
- **`formPostSupport`'s scope (base URL only) is deliberately coarser** than
  every other cache here (full `ServerCredentials`) — flagged in the matrix
  as intentional, not an inconsistency, since form-post support is a
  server-wide protocol capability rather than an account-specific fact.

### Relationship to #128 (persistent metadata cache)

Everything above is **session-only, in-memory, and non-authoritative** — it
exists purely so a view doesn't re-walk the network on every appearance; the
server remains the source of truth every time a cache misses. #128 proposes a
disk-backed, cross-session persistent layer (the dropped-SwiftData shape
further down this file was its predecessor idea) and is a different problem:
it needs to survive relaunch, this layer explicitly must not (network-required
by design). The two layers are not expected to merge; §140.4 below states how
#128 should plug into the design decided here instead of rediscovering it.

## Design decision (#140): song-index consolidation & cache abstraction

Resolves the gaps §139 flagged above. This is an **architectural decision**
(field/API evidence + trade-offs recorded), not an implementation — #141 does
the code. Evidence behind each call:

- **Native-only fields are genuinely native-only** (`docs/02`): work/movement
  tags and `bitDepth` are exposed *only* via `/api/song`; plain Subsonic
  (`search3`/`getAlbum`/`getSong`) never carries them. Composer credit **ids**
  (needed for `songs(byComposerId:)`) are likewise only in
  `participants.composer[].id` — Subsonic only gets the server-joined
  `displayComposer` *string*, no ids. The native walk's data cannot be folded
  into the Subsonic walk's, in either direction.
- **The native walk is not universally available**: it requires Navidrome +
  password auth and degrades to `.unavailable` for any non-Navidrome server,
  network failure, or API-key auth (`docs/02`). `cachedAllSongs` (Subsonic) is
  the only walk that works on every configuration, so it can never be dropped.
- **`NativeSongRecord.asSong()`** (`NativeSongRecord+Song.swift`) already
  proves a native record can stand in for a playable `Song` — used today by
  `songs(forComposer:)` — but two of its fields are *derived*, not
  server-truth: `coverArt = id` (relies on legacy Subsonic id-acceptance) and
  `contentType` (guessed from a hardcoded suffix→MIME table, not the server's
  own value). Making this the *primary* source for the whole Songs tab, not
  just the smaller Composers-tab subset it serves today, would be a
  correctness risk on the app's central, always-available list, for a
  walk-count savings that only helps Navidrome-password-auth users.
- **Prior art already answered a piece of this**: #118 made the Subsonic walk
  eager at connect. #124 explicitly declined to also make the native walk
  eager at connect ("doesn't add a second concurrent full-library walk to
  every app launch… Pre-warming the native index remains a legitimate
  follow-up, not folded in here" — `docs/PROGRESS.md`). Nothing new here
  changes that trade-off.

### 140.1 — Keep two walks; unify behind one interface

Rejects collapsing to a single walk (the issue's option "supplied by one
authoritative full-library walk with derived projections") — it isn't the
same data, and forcing Navidrome-native-available users onto native-only
playback metadata risks the one surface (Songs tab) that must behave
identically across every server type, for a savings that doesn't apply to
non-Navidrome/API-key users anyway.

Instead: one new actor, **`LibrarySongIndex`**
(`Hydrophone/Services/LibrarySongIndex.swift`), becomes the single owner of
"the library's songs" (the issue's "combined behind one repository/index
interface" option):

- Holds what's currently split across `SubsonicClient.cachedAllSongs` /
  `inFlightAllSongs` / `allSongsGeneration` (moves out of `SubsonicClient`,
  which reverts to a pure transport actor) and
  `NavidromeClient.cachedSongIndex` / `cachedSongIndexCredentials` /
  `songIndexGeneration` / `inFlightSongIndexBuild` (moves out of
  `NavidromeClient` likewise).
- One entry point, `allSongs(onProgress:)`: walks Subsonic (always) and joins
  native work/movement/bitDepth (when available) — replacing today's two-step
  "`LibraryModel.loadSongsIfNeeded()` calls `client.allSongs()`, then
  separately calls `joinWorkInfo(into:)`" with one call whose join logic
  lives in one place.
- `songs(byComposerId:)`, `workInfo(forSongIds:)`, `bitDepths(forSongIds:)`
  relocate here unchanged in behavior from `NavidromeClient+SongLookup.swift`
  — these stay native-only by necessity (composer ids only exist natively),
  just discoverable under the same interface.
- `LibraryModel` keeps its `songs`/`songsState`/`songsGeneration` — genuine
  view state, not a second copy of the walk — but calls through
  `LibrarySongIndex` instead of `client` + `navidrome` directly.

This turns "two walks over largely the same library" into "two walks, one
interface, one join point": the duplication that was actually a problem
(three copies of cache-lifecycle code, ad hoc join call sites) goes away; the
duplication that isn't a problem (two genuinely different endpoints) stays,
because it has to.

### 140.2 — One generic cache primitive, adopted broadly but not everywhere

Build **`CredentialScopedCache<Value: Sendable>`**
(`Hydrophone/Services/CredentialScopedCache.swift`): the credentials-guard +
generation-counter + in-flight-task-coalescing + explicit-`invalidate()` shape
`cachedAllSongs` and `cachedSongIndex` already hand-roll identically. Its
`resolve(using:build:)` takes a credentials snapshot and an async build
closure, returning the cached value, an in-flight result, or a fresh build —
today's `allSongs()`/`songIndexSnapshot()` logic, generalized.

**Adopts it:**
- `LibrarySongIndex`'s two internal caches (replacing the hand-rolled
  versions).
- `NavidromeClient.cachedToken` — today the *only* credential-scoped cache
  with no generation counter or in-flight coalescing, so a concurrent burst of
  callers under a cold/expired token each independently call `login()`. Same
  shape; fixes that thundering-herd case as a side effect.
- **`LibraryModel`'s single-shot collections**: `artists`, `composers`,
  `genres`, `starredSongs`/`starredAlbums` (as one `StarredSnapshot` value),
  and the four home shelves (as one `HomeShelves` value). Each is "fetch
  once, cache until invalidated" — `cachedAllSongs`'s shape, minus
  partial-publish. This is the direct fix for §139's finding that
  `LibraryModel.reset()` is wired nowhere in the running app: once each
  collection adopts `CredentialScopedCache`, invalidation is automatic on any
  credential mismatch — the same mechanism `cachedAllSongs` already relies on
  — and the missing `reset()` wiring stops being load-bearing. This *is* a
  behavior change versus today, but it's the correctness fix §139 flagged,
  not scope creep: deciding which caches use the primitive is exactly what
  #140 asks for, and this gap has no other proposed fix on the table.

**Does not adopt it:**
- `SubsonicClient.formPostSupport` — scoped by base URL, not full credentials;
  failure resolves to an uncached `false` rather than propagating an error.
  Forcing it into `CredentialScopedCache` would obscure that real difference
  for no benefit.
- `LibraryModel.albums` — incremental/paginated with independent
  offset/exhaustion bookkeeping *per sort-or-filter selection*, not a single
  walk-to-exhaustion result (multiple live variants, not one cached blob).
  Genuinely different shape. It should still gain an explicit credential-scope
  check before #141 lands, so switching servers doesn't leave a stale grid
  either — a small bespoke guard, left as a concrete, scoped requirement for
  #141 rather than designed further here.

### 140.3 — Warm-up ownership: no change to what warms eagerly

`ConnectionModel` stays the sole owner of "what starts automatically after a
verified connection" (already true today via `songsLoadHandler`/
`probeNativeFeatures()`):

- Subsonic full-library walk (via `LibrarySongIndex`): **stays eager**,
  unchanged from #118.
- Native song-index walk: **stays lazy/on-demand**, unchanged from #124.
  #124 already weighed and explicitly declined eager native warm-up for a
  narrower symptom; nothing new here (no measured latency complaint, no
  user-facing regression) changes that trade-off, and reversing it would
  reintroduce a second concurrent full-library walk on every launch for a
  feature (classical metadata) most sessions may never touch.
- `LibraryModel`'s other collections (albums/artists/composers/genres/
  starred/home): **stay demand-driven** (loaded on first view appearance),
  unchanged from today — #140 fixes their invalidation gap (140.2), not their
  loading trigger.
- Demand joining an in-flight warm-up is already correct by construction:
  `CredentialScopedCache.resolve` *is* "join the in-flight task if one's
  running, else start one," so a Composers-tab visit landing mid-connect
  warm-up naturally coalesces rather than double-fetching.

This ratifies existing, already-justified behavior rather than inventing new
sequencing, and gives #141 nothing to guess at.

### 140.4 — Relationship to #128, restated for the new interface

`LibrarySongIndex` and the `CredentialScopedCache`-backed collections stay
session-only/non-authoritative, same as every cache in §139's inventory.
#128's persistent layer would sit *behind* `LibrarySongIndex` (an alternate
`build` source consulted before the network) or *beside* it (seeding on
launch, network still authoritative) — either way #128 reuses
`LibrarySongIndex`'s single join point and `CredentialScopedCache`'s
invalidation hooks rather than inventing its own, which is the point of
consolidating now.

### Rejected alternatives

- **Single native-only walk for the whole library.** Data loss for
  non-Navidrome/API-key-auth servers (no native walk exists there at all);
  correctness risk for Navidrome users too, since `asSong()`'s `coverArt`/
  `contentType` are derived approximations never exercised at Songs-tab scale
  today.
- **Eager native warm-up at every connect.** Reverses #124's explicit,
  reasoned decision with no new evidence; doubles concurrent full-library
  walks at launch for a feature many sessions never touch.
- **A fully generic cache primitive for every cache in §139's inventory
  (including `formPostSupport` and `LibraryModel.albums`).** Their policies
  (scope key, failure handling, multi-variant state) differ enough that
  forcing the shared shape would obscure behavior rather than clarify it —
  the issue itself allows preferring explicit implementations in that case.

### Migration surface for #141

- **New files**: `Services/LibrarySongIndex.swift`,
  `Services/CredentialScopedCache.swift`.
- **`SubsonicClient`**: remove `cachedAllSongs`/`inFlightAllSongs`/
  `allSongsGeneration`/`invalidateAllSongs()`; `SubsonicClient+AllSongs.swift`'s
  walk logic moves to `LibrarySongIndex`, leaving `SubsonicClient` with only
  the raw page-fetching.
- **`NavidromeClient`**: remove `cachedSongIndex`/`cachedSongIndexCredentials`/
  `songIndexGeneration`/`inFlightSongIndexBuild`/`invalidateSongIndex()`;
  `NavidromeClient+SongLookup.swift`'s cache-reading methods move to
  `LibrarySongIndex`; `NavidromeClient` keeps `paginatedGet`/auth/token
  (itself migrated onto `CredentialScopedCache`).
- **`LibraryModel`**: `loadSongsIfNeeded()`/`invalidateSongs()` call through
  `LibrarySongIndex` instead of `client`+`navidrome` directly;
  `artists`/`composers`/`genres`/`starredSongs`+`starredAlbums`/home shelves
  each wrap a `CredentialScopedCache` instance; `reset()` becomes redundant
  for those (#141 decides whether to delete it once nothing — production or
  tests — still calls it).
- **`ConnectionModel`**: `songsInvalidationHandler`/`songsLoadHandler`
  retarget `LibrarySongIndex` instead of `client`; `startLibraryScan()` calls
  `LibrarySongIndex.invalidate()` instead of `navidrome.invalidateSongIndex()`.

### Test contract for #141

- Every existing `SubsonicAllSongsTests` case and the
  `NavidromeClientNetworkTests` song-index/token-reuse cases move to target
  `LibrarySongIndex`/`CredentialScopedCache` instead of the clients directly;
  the same assertions (reuse-across-calls, credential-change invalidates,
  concurrent coalescing, stale-generation guard, explicit-invalidate-forces-
  refetch, scan-triggers-invalidate) must still pass in spirit.
- New hermetic tests for `CredentialScopedCache` itself, decoupled from any
  specific endpoint (a trivial mock `build` closure): guard/generation/
  coalescing/invalidate behavior in isolation.
- New regression test: switching `ServerCredentials` (simulating a
  disconnect/reconnect to a different server) invalidates
  `artists`/`composers`/`genres`/starred/home without any explicit `reset()`
  call — the test that proves §139's gap is actually fixed.

## Artwork cache (implemented)

`Services/ArtworkCache.swift` is a two-tier cache keyed by `cache identity +
pixel size`:
- **Identity ≠ fetch id.** Servers give every *song* its own `coverArt` id
  even though all tracks of an album resolve to the album's image, so keying
  by raw id would download the identical cover once per queue row and miss
  the album page's copy when the hero shows it. Song and album surfaces
  therefore share an album-scoped identity (`Song.artworkKey` /
  `Album.artworkKey`, i.e. `album:<albumId>`; songs without an album fall
  back to their own id) while the fetch URL still uses the raw `coverArt`
  id. One trade-off: per-track embedded art that differs from the album
  cover is not shown (the album cover wins) — never fetch a cover that the
  album identity already has. Artist/playlist ids are their own identity.
- **In-memory** `NSCache` bounded by a byte budget (`totalCostLimit`, ~200 MB
  of decoded pixels — a full-res hero and a grid thumbnail don't count the
  same against it — plus a looser 1,000-entry `countLimit` backstop) for the
  hot path, plus a per-identity size index so a different-size request can
  show an already-loaded variant instantly (no placeholder flash).
- **Viewport-ahead prefetch.** `prefetch(_:)` replaces a window of up to 24
  `PrefetchRequest` values, sharing `image`'s cache/in-flight de-dup. One
  worker submits at most one speculative load to the existing six-slot
  network limiter, leaving capacity for visible artwork. Replacing the
  window discards obsolete pending work; passing an empty window (leaving
  Albums) or switching servers clears it. One active load may finish so a
  visible view sharing that request is not cancelled.
  `AlbumsView` derives the window after the furthest appearing cell and
  refreshes it when visible IDs, the album list, or the measured tile size
  change. It waits for a positive measurement and recomputes the shared
  `ArtworkView.fetchPixels(forSize:)` quantum after layout/resizing, so a
  transient initial size cannot leave the final window stale. See #15.
- **On-disk** store under `Caches/<bundleId>/Artwork`, filenames are the SHA-256
  of the key; the original downloaded bytes (webp/jpeg) are written as-is.
  Because cover art is immutable, a disk hit is authoritative and kept
  indefinitely — artwork loads instantly across launches and survives network
  blips. Disk + network I/O run off the main actor. Network fetches get one
  retry: after `Retry-After` on a 429, or a short pause on any other failure,
  so a transient blip doesn't leave a gray tile for the session.
- **Scoped per server.** Both tiers are namespaced by a hash of the server's
  base URL (disk: a per-server subdirectory; memory: a key prefix). A different
  Navidrome server can reuse the same coverArt id for a different album, so
  without scoping the cache would serve the wrong image. Set via
  `setServer(baseURL:)` at launch, on connect, and on disconnect; switching
  servers drops the in-memory tier and each server keeps its own disk store.
- **Quick Look originals.** Clicking the Now Playing panel's hero art opens
  the full-resolution cover: `stageOriginal` fetches the original bytes
  (cached as the "size 0" variant), then writes a human-named copy into a
  per-server `previews/` subdirectory — extension sniffed from the image's
  magic bytes — so Quick Look's title shows the album name rather than a
  hash. (`previews/` filenames are the one exception to the SHA-256 naming
  above.) Consumed by `NowPlayingPanel` via `.quickLookPreview`.

## Persistence: SwiftData 🔶 (dropped — historical)

*(Not implemented. Kept for context.)* Originally we planned **SwiftData** for a
metadata cache:
- Modern, value-/macro-based, pairs cleanly with `@Observable` and SwiftUI.
- macOS 15 deployment supported it; schema small and read-mostly.
- Core Data was the escape hatch if a hard limitation surfaced.

### Model schema (cached server metadata)

`@Model` classes mirroring the API value types, keyed by the server `id`:

- `CachedArtist` — id, name, albumCount, starred, sort key.
- `CachedAlbum` — id, name, artist(+id), year, genre, coverArtId, songCount,
  duration, starred; relationship → songs.
- `CachedSong` — id, title, artist(+id), album(+id), track, disc, year, genre,
  duration, bitRate, suffix, contentType, coverArtId, starred.
- `CachedGenre` — name, songCount, albumCount.
- `CachedPlaylist` — id, name, owner, public, songCount, duration, changed;
  ordered relationship → entries (song ids).
- `LibrarySyncState` — per-list offsets/timestamps for pagination + staleness.

Notes:
- Store the server `id` as the unique key; upsert on fetch.
- Keep these as a **cache, not the source of truth** — the server is
  authoritative. Refresh on connect and on demand; treat entries as
  invalidatable.
- Map `@Model` objects to `Sendable` value types before crossing actor
  boundaries (`@Model` types are `@MainActor`-bound).

## Pagination & lazy loading ✅

- Library lists (`getAlbumList2`, `getSongsByGenre`, `search3`) fetch in pages
  and accumulate **in-memory** in `LibraryModel`.
- Album grids trigger the next page near the scroll end (trailing sentinel
  row). Genre and all-songs walks fetch eagerly to exhaustion because their
  column-browser facets require the complete set; the all-songs walk publishes
  ordered partial snapshots after its first page and each later batch.
  A failed partial load keeps its usable rows but may retry on the next visit;
  nonempty partial data is not treated as a completed load.
- `LibraryModel` owns the offset bookkeeping and exhaustion detection; state
  is refetched per session (network-required by design).

## Artwork cache — original design notes ✅

`ArtworkCache` (an actor or `@MainActor` cache) — decode once, reuse resized
variants:

- Key by `coverArtId` **+ target pixel size** (so a list thumbnail and the
  header hero are separate entries).
- Fetch via `getCoverArt` requesting a server-resized `size` close to the
  needed points × screen scale (avoids pulling full-res for a 40 pt thumbnail).
- Two tiers:
  - **In-memory** `NSCache<NSString, NSImage>` (or a custom LRU) — bounded by
    total cost; evicts under memory pressure.
  - Optionally a small **on-disk** thumbnail cache in
    `Caches/` (system-purgeable) to avoid re-downloading across launches.
    Mark as cache so the OS can reclaim it; this is *artwork*, not audio, so it
    doesn't violate "no offline caching."
- Never reload full-resolution artwork on selection; the now-playing header
  uses a single moderate hero size, list rows use thumbnails.
- Respond to `NSCache` automatic eviction + explicit purge on memory warnings.

## Memory-footprint tactics (consolidated) ✅

- **Stream, don't load:** audio is streamed and decoded incrementally; only the
  next track is pre-buffered (see `03`).
- **Release aggressively:** completed PCM buffers and finished-track temp files
  are freed immediately; artwork is bounded and purgeable.
- **Paginate:** never fetch an entire large library up front; rely on table
  virtualization + paged fetches.
- **Right-size images:** request server-resized artwork; cache by exact target
  size; downscale on decode.
- **Bounded caches:** count-bounded `NSCache` for artwork; paged library
  fetches.

## Threading ✅

- Models are `@MainActor`; network fetches and decoding run off-main and hand
  `Sendable` values back.
- Artwork fetch/decode off the main thread; publish the finished `NSImage` to
  the main actor.
