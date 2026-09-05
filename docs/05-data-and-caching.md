# 05 — Local Metadata & Artwork Caching

> **Decision (#128 / #146):** Persistent library metadata is a warm-start
> speed optimization. The server remains authoritative and a verified
> connection is still required. #146 supplies the versioned SwiftData schema;
> #147–151 add the actor-owned store lifecycle, seed, write-behind, and full
> reconciliation path.

**Persisted by the running app:** artwork and server-scoped library metadata.
Metadata never bypasses connection verification, and a failed or incomplete
refresh cannot prune the last complete disk snapshot. No audio is cached or
downloaded by this feature; every play continues to stream from the server.

## Persistent metadata store

`LibraryMetadataStore` is an actor over the versioned SwiftData schema in
`Models/MetadataStore`. Its root is under the app Caches directory, with a
hashed scope for normalized server URL, username, and API-key identity. It
never stores passwords or API-key material. `open(for:)` is called only after
the connection ping succeeds; a session token gates every read, write, and
sync completion. `close()` retires the session but leaves the disk snapshot
available for the next verified connection.

The connection hook reads the snapshot before starting live library loads.
Seeded rows are marked separately from completed live collections, so a
nonempty seed never suppresses the server refresh. Live fetches publish to the
observable model first and enqueue serialized, best-effort writes. Summary
values preserve richer detail when fields are omitted, while explicit empty
relationships clear prior detail. Full refresh uses an exhausted, credential-
bound song walk plus all collection roots; only a successful complete graph is
reconciled in one transaction. Writes accepted during that walk replay over
the fetched snapshot before commit. Manual library rescan waits for
`getScanStatus` to report completion and then runs the same refresh once.

## In-memory metadata caches

This section audits every in-memory cache and cache-like load/session state in
the client and model layer, as implemented after #139 (inventory) → #140
(design) → #141 (implementation). It complements, but does not replace,
"Pagination & lazy loading" below (which covers `LibraryModel` paging
mechanics) — this section is about **what's held and for how long**, not how
a page is fetched.

### Lifecycle matrix

| Owner · state | Scope/key | Source endpoint(s) | Consumers | Warm trigger | Coalescing / stale guard | Invalidation | Retry/failure | Class |
|---|---|---|---|---|---|---|---|---|
| `LibrarySongIndex`'s Subsonic cache (`CredentialScopedCache<[Song]>`) | exact `ServerCredentials` | `search3` (empty query, paginated) | `LibraryModel.loadSongsIfNeeded()` (Songs tab, Shuffle All fallback paths) | `LibraryModel.loadSongsIfNeeded()`, driven eager by `ConnectionModel`'s `songsLoadHandler` on connect (#118) | `CredentialScopedCache`'s generation counter + in-flight coalescing; a completion whose generation is stale is dropped, never written back | Explicit: `LibrarySongIndex.invalidate()`, called by `LibraryModel.invalidateSongs()` (awaited directly, not fire-and-forget) from `reset()` | Only a walk that reaches exhaustion is cached (`resolve`'s cacheable-tuple form); a mid-walk failure after partial progress propagates the error uncached (never silently swapped for a random sample) | Authoritative fetched data |
| `SubsonicClient.formPostSupport` | base URL only (not full credentials) | `getOpenSubsonicExtensions` | internal `perform(_:using:)` (routes flagged endpoints to POST) | Lazily, first flagged endpoint call per base URL | None (single cached tuple); a probe failure resolves `false` for that call *without* caching it, so one hiccup can't wedge POST off for the session | None explicit — reconnecting to the same base URL under different credentials keeps the old flag; correct today because form-post support is a server capability, not an account one | Failure (network, non-OpenSubsonic server, missing payload) resolves to `false`, uncached | Capability/auth state |
| `NavidromeClient.tokenCache` (`CredentialScopedCache<NavidromeToken>`) | exact `ServerCredentials` | `POST /auth/login` | `ensureValidToken(using:)`, used by every native `/api/*` page fetch | First native call needing a token (composer load, song-index build, `probeNativeFeatures()`) | `peek(matching:)` checks expiry first (the primitive's own cache-hit check is credentials-only, not expiry-aware) and explicitly invalidates an expired entry before `resolve`; concurrent callers under a genuinely cold token now coalesce onto one `login()` instead of each starting their own | Explicit `invalidate()` on a `401` during `fetchPage`; `login()` (the forced-fresh entry point, e.g. `probeNativeFeatures()`) seeds the cache via `store(_:for:)` after its own unconditional network call, so a later `ensureValidToken` reuses it without a second login | One transparent retry on `401` (invalidate token, relogin, retry once) | Capability/auth state |
| `LibrarySongIndex`'s native cache (`CredentialScopedCache<NativeSongIndexSnapshot>`) | exact `ServerCredentials` | `/api/song?missing=false` (paginated, via `NavidromeClient`'s pinned `paginatedGet(...using:as:)`) | `songIndex()`, `songs(byComposerId:)`, `workMetadata(songId:)`, `workInfo(forSongIds:)`, `bitDepths(forSongIds:)`, `join(into:)` | First caller needing native song data (Composers tab, `join(into:)`, playlist detail's non-blocking join pass — #124) | Same `CredentialScopedCache` shape as the Subsonic cache above | Explicit: `LibrarySongIndex.invalidate()` clears **both** caches together — called from `ConnectionModel.startLibraryScan()` and (via `LibraryModel.invalidateSongs()`) from `reset()`, so disconnect now invalidates it too (fixes the asymmetry #139 flagged) | Errors propagate to the caller uncached; no fallback sample (unlike the Subsonic cache) since there's no meaningful partial substitute for native data | Authoritative fetched data |
| `LibraryModel.albums` / `albumOffset` / `albumsExhausted` / `albumFilter` / `albumsState` | shares `librarySessionGeneration` (see below) | `getAlbumList2` | Albums grid | `loadAlbumsIfNeeded()`, first Albums-tab appearance | `albumsState == .loading` guard against duplicate concurrent loads; retried when `albums.isEmpty`; a generation captured before the fetch guards the eventual write | `reloadAlbums()` (sort/filter change); `reset()` clears the array directly and bumps `librarySessionGeneration` so an in-flight page fetch from before the reset can't append to the now-cleared array | Failed page load leaves `albumsState = .failed`; next appearance (if still empty) retries | View/model state (session cache) |
| `LibraryModel.artists` / `artistsState` | shares `librarySessionGeneration` | `getArtists` | Artists master list | `loadArtistsIfNeeded()` | `.loading` guard, retried while empty; generation-guarded write | `reset()` | Failed load retried on next empty-state appearance | View/model state |
| `LibraryModel.composers` / `composersState` | shares `librarySessionGeneration` (gated by `nativeFeaturesAvailable()`) | `NavidromeClient.composers()` (itself unpaged-cache, walks `/api/artist?role=composer` fresh each call) | Composers master list | `loadComposersIfNeeded()` | `.loading` guard, retried while empty; generation-guarded write | `reset()` | Failed load retried on next empty-state appearance | View/model state, derived from native capability state |
| `LibraryModel.genres` / `genresLoadingGeneration` | shares `librarySessionGeneration` | `getGenres` | Genre column browser, Albums genre filter | `loadGenresIfNeeded()` | Generation-owned in-flight identity prevents duplicate same-session fetches without letting a retired session block the current one; generation-guarded write | `reset()` | Failure clears to `[]` silently (no `.failed` state surfaced) | View/model state |
| `LibraryModel.starredSongs` / `starredAlbums` / `starredSongIDs` / `starOverrides` / `albumStarOverrides` / `starredLoaded` / `starredLoadingGeneration` | shares `librarySessionGeneration` | `getStarred2`, `star`/`unstar` | Favorites view, `isStarred(_:)` everywhere a star glyph renders | `loadStarredIfNeeded()`, first favorite check or Favorites-tab visit | Generation-owned in-flight identity; optimistic per-id overrides shown until the write + reconciling `reloadStarred()` round-trip; generation-guarded write | `reset()`; overrides are also cleared per-id after each mutation's reload | A refused optimistic write rolls its override back; a failed reload keeps accepted overrides rather than reverting them | Mix: authoritative fetched data (`starredSongs`/`starredAlbums`) + view state (overrides) |
| `LibraryModel.homeNewest/Recent/Frequent/Random` / `homeLoaded` / `homeLoadingGeneration` | shares `librarySessionGeneration` | `getAlbumList2` ×4 (newest/recent/frequent/random), concurrent | Home shelves | `loadHomeIfNeeded()` | Generation-owned in-flight identity; `homeLoaded` only set true if at least one shelf came back non-empty, so an all-offline launch retries next appearance; all writes, including `rerollRandomAlbums()`, are generation guarded | `reset()` | All-empty result is treated as "didn't really load" and retried, not cached as a true empty state | View/model state |
| `LibraryModel.playlists` / `playlistsLoadingGeneration` | shares `librarySessionGeneration` | `getPlaylists`, playlist create/update/delete endpoints | Sidebar playlist list, Add to Playlist menu, playlist CRUD reconciliation | `loadPlaylistsIfNeeded()` | Generation-owned in-flight identity coalesces same-session list loads; both lazy and forced reloads guard writes against a retired session | `reset()`; successful CRUD reloads the list | A failed list load keeps the existing list; an empty list retries on next appearance | View/model state |
| `LibraryModel.songs` / `songsState` / `songsGeneration` | unscoped *view* of `LibrarySongIndex`'s Subsonic cache | (derives from `songIndex.allSongs()`, which now performs the native join itself before returning) | Songs tab, toolbar loading indicator (`songsAreLoading`) | `loadSongsIfNeeded()`, made eager at connect (#118) | Own generation counter (`songsGeneration`, separate from `librarySessionGeneration`): a superseded `loadSongsIfNeeded()` (invalidated mid-flight) can't overwrite `songs`/`songsState` with a stale result; partial pages publish incrementally via `onProgress` | Explicit: `invalidateSongs()`, awaited directly (not fire-and-forget) so `songIndex`'s cache is verifiably clear before the caller proceeds — wired through `ConnectionModel`'s `libraryInvalidationHandler` on `disconnect()`, credential change in `saveAndConnect()`, and (via `reset()`) `startLibraryScan()` | A failed load keeps existing (possibly partial) rows and surfaces `.failed`; next visit retries | Derived/view state layered over the Subsonic cache's authoritative data |

**Why the six `LibraryModel` collections share a plain `Int` generation
(`librarySessionGeneration`) instead of each wrapping a `CredentialScopedCache`
as originally decided in #140.2:** implementing it surfaced a real problem
with that plan. These properties are `@MainActor`/`@Observable` UI state read
directly by SwiftUI; routing every `loadXIfNeeded()` call through an actor
(even on a cache *hit*) reintroduces a `.loading` → `.loaded` flicker on every
revisit, and the credential-keyed *value* cache adds nothing a plain
generation guard doesn't already give here — the actual #139 fix is
`reset()` being wired into `ConnectionModel`'s hook at all (see below), not
which primitive guards a stale write. `librarySessionGeneration` is `reset()`
bumping one counter, exactly mirroring the `songsGeneration` pattern that
already existed for Songs specifically — now shared across the other six
collections since one disconnect/credential-change/scan event invalidates
all of them together. `CredentialScopedCache` stayed exactly where it earns
its keep: the two actor-resident, already-async-network-bound walks in
`LibrarySongIndex`, plus `NavidromeClient`'s token.

Not a cache (fetched fresh every call, listed for completeness/contrast):
`LibraryModel.search(_:)`, `songs(forGenre:)`, `songs(forAlbum:)`,
`albums(forArtist:)`, `artistInfo(id:)`, `similarSongs(id:)`,
`topSongs(artist:)`, `randomAlbums()`, `randomBatch()`, and individual playlist
entry loads (`playlist(id:)`). Playlist listing is session-cached as inventoried
above; playlist CRUD always reaches the server and then reconciles that list.
`songs(forComposer:)`
(`LibraryModel+Composers.swift`) has no cache of its own either, but reads
through `NavidromeClient`'s cached song index. Adjacent but out of scope for
this layer: `ConnectionModel.nativeFeaturesState` (capability state gating
whether native calls happen at all) and `ArtworkCache` (its own section,
disk-persisted, already documented).

### Overlaps and gaps → resolved by #140's design decision and #141's implementation

- **The Subsonic and native full-library walks are two views onto largely the
  same library**, one via `search3` and one via `/api/song` — #125's original
  observation. Resolved by consolidating both under `LibrarySongIndex` (see
  "Design decision (#140)" below) rather than collapsing them into one walk;
  the underlying data genuinely differs (native-only fields, universal-vs-
  Navidrome-only availability), so both walks remain, just unified.
- **The "cached value + credentials guard + generation counter + in-flight
  coalescing" shape was hand-rolled three times.** Resolved: `CredentialScopedCache`
  now backs `LibrarySongIndex`'s two caches and `NavidromeClient`'s token cache.
- **Invalidation was inconsistent across the credential-scoped caches** —
  resolved. Every row in the matrix above now invalidates on disconnect,
  credential change, *and* a successful library scan, all through one path:
  `ConnectionModel.invalidateLibrary()` → `libraryInvalidationHandler` →
  `LibraryModel.reset()`, which itself awaits `invalidateSongs()` (which
  awaits `LibrarySongIndex.invalidate()`) and bumps `librarySessionGeneration`
  for the other six collections. A library scan previously left
  albums/artists/composers/genres/starred/home/playlists untouched (only the song
  caches were invalidated) — it now clears everything, matching disconnect.
- **`LibraryModel.reset()` was effectively dead code in the running app** —
  the direct cause of switching servers leaving stale
  Albums/Artists/Composers/Genres/Favorites/Home/Playlists data visible. Resolved:
  `AppModel`'s composition-root wiring now calls `connection.setLibraryInvalidationHandler
  { [weak library] in await library?.reset() }` instead of the narrower
  `invalidateSongs()` it called before — the crux of the fix, since `reset()`
  already cleared every collection correctly; it just needed to be reachable
  from the event that should trigger it.
- **`formPostSupport`'s scope (base URL only) is deliberately coarser** than
  every other cache here (full `ServerCredentials`) — intentional, not an
  inconsistency, since form-post support is a server-wide protocol capability
  rather than an account-specific fact. Left as-is, per #140's decision.

### Relationship to #128 (persistent metadata cache)

Everything above is **session-only, in-memory, and non-authoritative** — it
exists purely so a view doesn't re-walk the network on every appearance; the
server remains the source of truth every time a cache misses. #128 adds a
disk-backed, cross-session persistent layer (the #146 schema and actor store
described above). It survives relaunch, while this layer resets with the
connection session. The two layers remain separate: the observable model is
the session projection, and the actor store is its warm-start and
reconciliation backing store.

## Design decision (#140), implemented in #141: song-index consolidation & cache abstraction

Resolves the gaps §139 flagged above. #140 recorded the architectural decision
(field/API evidence + trade-offs); #141 implemented it — the text below is
kept as the decision record, with each sub-section noting where the shipped
code followed it exactly and the one place (140.2's `LibraryModel` collections)
it didn't, and why. Evidence behind each call:

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

Instead: one new type, **`LibrarySongIndex`**
(`Hydrophone/Services/LibrarySongIndex.swift`), becomes the single owner of
"the library's songs" (the issue's "combined behind one repository/index
interface" option). Despite unifying two walks, it's a plain `Sendable`
class, not an actor — see the shipped note below for why:

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

**Shipped as designed, with one correction found during live verification.**
`LibrarySongIndex` exists with exactly this shape, but **is not an actor** —
it's a plain `final class: Sendable`. The first implementation made it an
actor (holding the two `CredentialScopedCache`s as stored properties), which
compiled and passed every hermetic test, but live-verifying against a real
~14,000-track library surfaced a real bug: opening a playlist while the
Songs tab's eager Subsonic walk was still running made the playlist's
non-blocking native join (`join(into:)`) wait behind the walk instead of
running concurrently with it — reintroducing the exact blocking #124 fixed,
because *entering `LibrarySongIndex`'s own actor* now serialized both walks
against each other, even though their two caches were independently isolated.
`LibrarySongIndex` holds no mutable state of its own (every stored property
is a `let`), so nothing requires it to be an actor at all; making it a plain
`Sendable` class removed that serialization point entirely while the two
`CredentialScopedCache` actors continue to guard their own state correctly.
No hermetic test caught this — actor-isolation contention needs real
concurrent load (a live server, a large library) to surface, which is why
this is exactly the kind of thing the live-verification gate exists to catch.
Separately, `SubsonicClient`/`NavidromeClient` reverted to pure transport (the
latter also gained a pinned `paginatedGet(...using:as:)` overload so
`LibrarySongIndex`'s native walk can pin one credential snapshot across its
whole walk, mirroring `SubsonicClient.perform(_:using:)`). `LibraryModel`
never got a new constructor parameter for this — it builds its own
`songIndex: LibrarySongIndex` internally from the `client`/`navidrome`/
`nativeFeaturesAvailable` it already receives, so no test's `LibraryModel(...)`
call site needed to change.

**Also confirmed live, not a regression:** the native `/api/song` walk itself
took roughly 30–40s against a real ~14,000-track library during testing —
unrelated to this change (the walk logic is untouched, just relocated) and
consistent with what #124 already documented as a known, accepted cold-cache
cost. Concurrent callers (three playlists opened during the same walk, plus
the Songs tab's own join) were confirmed — via temporary timing
instrumentation, since removed — to correctly coalesce onto the one walk
rather than each starting their own; a follow-up (pre-warming, or #128's
persistent cache) remains the legitimate way to actually shorten that cost,
same conclusion #124 already reached.

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
- ~~`LibraryModel`'s single-shot collections (`artists`, `composers`, `genres`,
  starred, home)~~ — **not shipped this way; see the "Why" note in the
  lifecycle matrix above.** Implementing this surfaced that wrapping
  `@MainActor`/`@Observable` UI-bound properties in an actor-based cache
  reintroduces a `.loading` flicker on every revisit (routing every
  `loadXIfNeeded()` call through an actor hop even on a cache *hit*), for no
  correctness benefit the plain generation guard below doesn't already give.
  What actually fixes §139's finding is `reset()` being wired into
  `ConnectionModel`'s hook at all — that alone clears every collection
  immediately on disconnect/credential-change/scan. The six collections
  instead share one `librarySessionGeneration: Int` (bumped by `reset()`),
  the same generation-guard shape `songsGeneration` already used for Songs,
  protecting against a fetch already in flight when `reset()` fires. This is
  a narrower mechanism than the generic primitive, deliberately: #140's own
  principle — "prefer explicit implementations if policies differ enough
  that a generic type would obscure behavior" — turned out to apply here too,
  discovered only once the flicker became visible in implementation.

**Does not adopt it:**
- `SubsonicClient.formPostSupport` — scoped by base URL, not full credentials;
  failure resolves to an uncached `false` rather than propagating an error.
  Forcing it into `CredentialScopedCache` would obscure that real difference
  for no benefit.
- `LibraryModel.albums` — incremental/paginated with independent
  offset/exhaustion bookkeeping *per sort-or-filter selection*, not a single
  walk-to-exhaustion result (multiple live variants, not one cached blob).
  Genuinely different shape. Shipped with the same `librarySessionGeneration`
  guard the other six collections use (not the full primitive): `reset()`
  clears its pagination state directly, and a page fetch already in flight
  when that happens can't append to the now-cleared array.

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
  starred/home/playlists): **stay demand-driven** (loaded on first view appearance),
  unchanged from today — #140 fixes their invalidation gap (140.2), not their
  loading trigger.
- Demand joining an in-flight warm-up is already correct by construction:
  `CredentialScopedCache.resolve` *is* "join the in-flight task if one's
  running, else start one," so a Composers-tab visit landing mid-connect
  warm-up naturally coalesces rather than double-fetching.

This ratifies existing, already-justified behavior rather than inventing new
sequencing. **Shipped as designed** — no warm-up timing changed.

### 140.4 — Relationship to #128, restated for the new interface

`LibrarySongIndex` and the `librarySessionGeneration`-guarded `LibraryModel`
collections all stay session-only/non-authoritative, same as every cache in
§139's inventory. #128's persistent layer would sit *behind* `LibrarySongIndex` (an alternate
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

### Migration surface (#141, shipped)

- **New files**: `Services/LibrarySongIndex.swift`,
  `Services/CredentialScopedCache.swift`.
- **`SubsonicClient`**: `cachedAllSongs`/`inFlightAllSongs`/`allSongsGeneration`/
  `invalidateAllSongs()` removed; `SubsonicClient+AllSongs.swift` deleted, its
  walk logic moved into `LibrarySongIndex` (calling `client.object(...)`/
  `client.list(...)` instead of `self.object(...)`). `SubsonicClient` gained
  one small addition: `var currentCredentials: ServerCredentials? { credentials.load() }`,
  so `LibraryModel` can get a snapshot for the `librarySessionGeneration`-guarded
  collections without a new constructor parameter.
- **`NavidromeClient`**: `cachedSongIndex`/`cachedSongIndexCredentials`/
  `songIndexGeneration`/`inFlightSongIndexBuild`/`songIndex()`/
  `songIndexSnapshot()`/`invalidateSongIndex()` removed;
  `NavidromeClient+SongLookup.swift` now holds only `composers()` (never
  cached at this layer, unaffected) — its other methods moved to
  `LibrarySongIndex`. `cachedToken`/`cachedTokenCredentials` replaced by a
  `CredentialScopedCache<NavidromeToken>`; `login(using:)`'s body became
  `performLogin(using:)` (the raw network call), with `login()` (the
  forced-fresh entry point) seeding the cache via `store(_:for:)` and
  `ensureValidToken(using:)` peeking expiry before deciding whether to
  invalidate-then-`resolve`. Gained a pinned
  `paginatedGet(path:sort:order:extraQuery:pageSize:using:as:)` overload for
  `LibrarySongIndex`'s native walk (mirrors `SubsonicClient.perform(_:using:)`).
- **`LibraryModel`**: gained `let songIndex: LibrarySongIndex` (constructed
  internally in `init` — no new external parameter) and
  `var librarySessionGeneration = 0`. `loadSongsIfNeeded()`/`invalidateSongs()`
  call through `songIndex`; `joinWorkInfo(into:)` is now a thin forwarder to
  `songIndex.join(into:)` (the 5 other call sites — album/genre/search/
  favorites/playlist — unchanged); `songs(forComposer:)` calls
  `songIndex.songs(byComposerId:)`. `loadMoreAlbums()`/`loadArtistsIfNeeded()`/
  `loadComposersIfNeeded()`/`loadGenresIfNeeded()`/`reloadStarred()`/
  `reloadHome()`/`reloadPlaylists()`/`rerollRandomAlbums()` each capture
  `librarySessionGeneration` before their fetch
  and check it's unchanged before writing the result. `reset()` bumps
  `librarySessionGeneration` (one added line) and `invalidateSongs()` now
  awaits `songIndex.invalidate()` directly (not fire-and-forget — see the
  race note below). Genres, Favorites, Home, and playlist listing keep a
  generation-owned in-flight identity: it coalesces concurrent callers in the
  same session without letting a retired request block a new session. Two new
  extension files, `LibraryModel+Favorites.swift` and `LibraryModel+Home.swift`,
  split out of the main file for the type/file-length lint (their stored
  properties widened from `private`/`private(set)` to internal `var`,
  matching the existing `songs`/`songsState` precedent).
- **`ConnectionModel`**: `songsInvalidationHandler`/`setSongsInvalidationHandler`/
  private `invalidateSongs()` renamed to `libraryInvalidationHandler`/
  `setLibraryInvalidationHandler`/`invalidateLibrary()` (broadened scope, same
  shape). **The handler and `invalidateLibrary()`/`disconnect()` all became
  `async`** — not in the original plan, but required for correctness: `reset()`
  must `await` its actor-cache invalidation rather than fire-and-forget it, or
  a `disconnect()` → immediate `songIndex.allSongs()` call (exactly what
  `startLibraryScan`'s own test does) could race the invalidation and read
  stale actor state. `disconnect()`'s one call site
  (`SettingsView`'s Disconnect button) wraps it in `Task { await ... }`,
  matching the button's siblings. `startLibraryScan()` now calls
  `invalidateLibrary()` alone (replacing the separate `navidrome.invalidateSongIndex()`
  + `invalidateSongs()` calls) — this also means a scan now invalidates
  albums/artists/composers/genres/starred/home/playlists too, which it didn't
  before.
  `AppModel`'s one wiring line changed to
  `connection.setLibraryInvalidationHandler { [weak library] in await library?.reset() }`.

### Test contract (#141, shipped)

- `SubsonicAllSongsTests`/`SubsonicAllSongsProgressTests` construct a
  `LibrarySongIndex` (via a `makeIndex()` helper) instead of calling
  `SubsonicClient.allSongs()` directly; same `AllSongsMockProtocol` double,
  same assertions. `NavidromeClientNetworkTests`'s song-index-specific cases
  and `NavidromeSongIndexNetworkTests`/`NavidromeComposerSongLookupTests`
  (both already-established "shares this suite without growing its main
  file" extensions) migrated the same way; token-reuse cases stayed on
  `NavidromeClient` unchanged. `ConnectionModelNativeFeaturesTests`'s scan
  test was rewritten as `startLibraryScanFiresLibraryInvalidationHandlerOnce`
  — `ConnectionModel` no longer touches a song cache directly, so it now
  just proves the handler fires; `LibrarySongIndex`'s own tests cover that
  `invalidate()` actually clears state.
- New `CredentialScopedCacheTests.swift`: hermetic, endpoint-agnostic,
  trivial mock `build` closure — cache-hit reuse, credential-mismatch
  rebuild, concurrent-caller coalescing, explicit invalidate, a superseded
  build's stale completion cannot repopulate the cache, and an uncacheable
  (`cacheable: false`) result is returned but not cached.
- New `LibraryModelResetTests.swift`: `reset()` clears Favorites and Home
  (populated by direct property assignment, since their stored properties are
  legitimately internal-settable for the extension-file split above) and
  bumps `librarySessionGeneration` — Composers' equivalent was already
  covered by `NavidromeComposerLibraryModelTests`; Artists/Genres share that
  exact shape closely enough that a third near-duplicate test wouldn't add
  coverage `reset()`'s visible body doesn't already make obvious.
- New `LibrarySessionInvalidationTests.swift`: six held-response regressions
  prove `reset()` clears playlist listing, retired playlist/random-shelf
  completions cannot repopulate the new session, and retired Home/Genres/
  Favorites loads cannot block the current session's first load.
- One pre-existing timing-sensitive test,
  `SubsonicAllSongsTests.fetchesPagesAfterTheProbeConcurrently`, needed its
  artificial response delay raised from 40ms to 80ms: the walk now hops from
  `LibrarySongIndex` to `SubsonicClient` per page instead of a same-actor
  call, and under heavy full-suite scheduling load the tighter margin
  occasionally read as non-concurrent. Not a functional regression — the
  6-way concurrent fan-out via `AsyncLimiter` is unchanged — just a test
  margin that needed to account for one more actor hop.

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

## Persistence: SwiftData foundation (#146)

The former offline-browsing proposal was dropped. #128 introduces metadata
persistence for faster connected launches instead. #146 implements only the
schema/mapping foundation in `Hydrophone/Models/MetadataStore/`; no production
container or application read/write path is wired yet.

### Schema and migration boundary

`MetadataSchemaV1` declares version **1.0.0** and all six model types.
`MetadataMigrationPlan` lists v1 and has no migration stages because no older
metadata store exists. Tests create an on-disk v1 store, save every entity
family, release the writer, and reopen through the plan. This proves v1
compatibility, not a migration to an invented v2. Once released, preserve v1's
persisted shape; structural evolution gets another version and explicit stages.

- `CachedSong`: every stored field in the current `Song` value, including
  composer/contributors, ReplayGain, multi-genre/grouping tags, sort and play
  metadata, work/movement, and bit depth. Native fields are explicit columns:
  encoding `Song` directly would omit them through its wire `CodingKeys`.
- `CachedAlbum`: all current album fields, genre/disc-title metadata, and a
  nullifying relationship to canonical songs.
- `CachedArtist`: all current artist fields and a nullifying relationship to
  canonical albums. The API value has no artist sort-key field to persist.
- `CachedPlaylist`: all current playlist fields and a nullifying relationship
  to canonical songs, plus explicit ordered entry IDs. Duplicate songs retain
  their positions without duplicating song records.
- `CachedGenre`: exact server genre name as the unique key (the API provides
  no separate ID), with optional song/album counts.
- `LibrarySyncState`: one unique collection key, offset, generation, and
  optional `lastSyncedAt`, mapped to `LibrarySyncSnapshot`. Completion policy
  belongs to #150; a stored offset alone never establishes a completed sync.

Artists, albums, songs, and playlists use unique **server IDs**; no random
client IDs are assigned. Relationship ID arrays record server ordering for
artist albums, album tracks, and playlist entries. `nil` means detail has not
been fetched; `[]` means a fetched empty list. Neither becomes the other on a
round-trip. Deleting a collection nullifies its links and does not delete
shared songs/albums; pruning belongs to the later full-sync transaction.

Nested contributor, ReplayGain, genre, and disc-title values use explicit JSON
`Data` attributes. Scalar fields stay queryable. Decoding malformed nested
metadata or resolving a missing related ID throws, allowing the future seed
reader to discard an unusable seed instead of silently omitting rows/credits.

### Value mapping and context ownership

Use `MetadataRecords.upsert(value, in: context)` for `Song`, `Album`, `Artist`,
`Playlist`, `Genre`, and `LibrarySyncSnapshot`. It resolves existing records by
identity before assigning relationships, including records inserted earlier in
the same unsaved batch. Relying on implicit unique-constraint merging of fresh
object graphs failed a real disk test when a playlist reused an album's song;
canonical context-owned references avoid that collision.

These are context-confined schema mapping helpers, not the write-behind
service: they do not create containers, save, schedule work, or fetch network
data. The caller owns the transaction and must roll back on mapping/save
failure. Inputs replace the represented snapshot, including optional fields
and unfetched relationship state; combining partial endpoint results with
already-enriched metadata is a caller policy for #149, not inferred here.
`@Attribute(.unique)` additionally enforces identity at the store boundary.

Call each record's `value()` inside its owning context to obtain the existing
`Sendable` API value (or `LibrarySyncSnapshot`) before crossing actors.
SwiftData records are context-confined, **not inherently MainActor-bound**;
the future store may use a `ModelActor`. A hermetic test exercises that boundary
by fetching in a separate model actor and returning only `[Song]`.

### Persistent metadata epic boundaries

Issues #147–151 are implemented together on the continuation branch: store
location and isolation, verified seed, write-behind, complete transactional
reconciliation, and manual-rescan integration. Review and landing remain
deferred until the epic is complete.

The existing `LibrarySongIndex` join point and session invalidation remain in
place. #146 adds no UI behavior, network request, audio persistence, or launch
speed improvement by itself.

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
