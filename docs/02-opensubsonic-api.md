# 02 — Server & API Layer (OpenSubsonic)

Target the **OpenSubsonic** API (a backward-compatible superset of Subsonic),
with **Navidrome** as the reference server. Single server connection, no
multi-server profiles.

References to consult during implementation:
- Subsonic API: <http://www.subsonic.org/pages/api.jsp>
- OpenSubsonic spec: <https://opensubsonic.netlify.app/>

## Authentication ✅

Two modes; the user picks the method in Settings (a Method picker —
capability-based auto-selection was not needed):

1. **Standard Subsonic token+salt** (always available)
   - Generate a random `salt` per request (or per session) and
     `t = md5(password + salt)` using `Insecure.MD5` (CryptoKit).
   - Send `u` (username), `t` (token), `s` (salt). **Never** send the raw
     password over this endpoint; never persist the token — persist only the
     password in Keychain. (Exception: `NavidromeClient`'s *separate* native
     `/auth/login` call does send the raw password — that's how Navidrome's
     own native API works, not a Subsonic endpoint. See the Navidrome native
     API section below.)

2. **OpenSubsonic API-key auth** (where supported)
   - Send the pre-issued API key per the OpenSubsonic auth extension instead of
     `u/t/s`. Server support varies — gate on capability detection (below).

Common params on every request: `v` (protocol version we target, e.g.
`1.16.1`), `c=Hydrophone` (client name), `f=json` (JSON responses).

Credentials live in the **Keychain** (`CredentialStore`; an in-memory variant
backs tests/previews): server base URL, username, and either password or API
key. The connection is configured in the native Settings window with a
**Test Connection** button that calls `ping`. `ConnectionModel` normalizes
pasted addresses (strips the `/app` SPA suffix, trailing slash/query/fragment;
assumes `https://` when the scheme is omitted).

## Capability detection ✅ (as implemented)

`ping` surfaces the capability fields (`openSubsonic`, `serverVersion`,
`type`) via `ServerInfo`, which `ConnectionModel` keeps on the connected
state. The app doesn't branch on extensions at runtime — the auth method is
user-chosen and `timeOffset` seeking is handled by the transcode-aware seek
path in `03`. (`getOpenSubsonicExtensions` was removed as dead code
2026-07-08; see the endpoint map.)

## Networking client ✅

`actor SubsonicClient` over `URLSession`:

- `func send<Body: Decodable & Sendable>(_ endpoint: Endpoint, as: Body.Type)
  async throws(SubsonicError) -> Body` — performs the call and unwraps the
  decoded body.
- The client composes base URL + endpoint path (`/rest/<method>.view`) +
  common params + auth params + endpoint params. URL-encode everything.
- `streamURL(songId:format:maxBitRate:timeOffset:)` and
  `coverArtURL(id:size:)` build authed media URLs for the player/artwork
  cache.
- One configured `URLSession`; decoding off the main actor; `Sendable` value
  types returned.
- Respect cancellation (`Task` cancellation → cancels the data task) for
  search-as-you-type and view teardown.

### Response envelope

All Subsonic JSON is wrapped: `{ "subsonic-response": { status, version, … } }`.
A generic `SubsonicResponse<T>` decodes the envelope; on
`status == "failed"` decode the `error` object and throw.

## Endpoint map (v1)

Grouped by feature. `GET` on `/rest/<method>` — except endpoints flagged
`usesFormPost` (unbounded id lists: playlist mutations, `savePlayQueue`),
which go as a form-encoded POST when the server advertises the OpenSubsonic
`formPost` extension (URL limits bite around ~1,500 song ids; GET fallback
otherwise; see `SubsonicClient.formPostRequest`).

### Connection
- `ping` — connection/auth test.
- `getOpenSubsonicExtensions` — capability discovery for the GET-vs-POST
  decision (resolved lazily, cached per base URL). Removed as dead code
  2026-07-08, resurrected 2026-07-15 for `formPost`.
- ~~`getMusicFolders`~~ — not needed; the app queries the whole library.
- `startScan` — kick off a server-side library rescan (Settings →
  Connection "Scan Library", File → Update Server Library). The persistent
  metadata path polls `getScanStatus` once per second until completion (up to
  five minutes), then invalidates the session and awaits a full metadata refresh.
  Requests stay pinned to the starting credentials and retire on session change.
- `scrobble` — play reporting: `submission=false` ("now playing") at each
  track start, `submission=true` once playback passes half the track or
  4 minutes (tracks ≥ 30s; the Last.fm rules Navidrome mirrors). Drives the
  server's play counts / recently-played (and the Home shelves). Toggleable
  (Settings → Playback, default on); best-effort, failures never surface.
- `savePlayQueue` / `getPlayQueue` — the queue, current song and playhead
  persist server-side (forced on pause/track change, 30s-throttled on
  position ticks, best-effort like scrobbles) and restore **paused** on
  launch — cross-device resume for free. Tolerant decode: `current` is a
  string id on Navidrome, a number on classic Subsonic.

### Library browse
- `getAlbumList2` — albums, with `type` (`alphabeticalByName`, `newest`,
  `recent`, `frequent`, `byGenre`, …), `size`, `offset` → **pagination**.
- `getArtists` — full artist index (grouped alphabetically).
- `getArtist` — one artist's albums.
- `getAlbum` — one album's songs.
- `getGenres` — genre list (with counts).
- `getSongsByGenre` — songs in a genre. The column browser walks 500-song
  `count`/`offset` pages until the first short page, then performs one WorkInfo
  join over the assembled result.
- `search3` with an empty query, `artistCount=0`, and `albumCount=0` — the
  ecosystem's de-facto all-songs primitive. `SubsonicClient.allSongs()` probes
  one 500-song page, then walks later pages with bounded six-request
  concurrency until the first short page. The ordered result is cached for the
  exact credential snapshot; credential changes, disconnects, and successful
  library scans retire both client and visible-library snapshots. Each
  assembled offset-ordered batch is also published as a visible partial
  snapshot; the one-time native WorkInfo join still runs only after the walk
  completes.
- `getRandomSongs` — compatibility fallback when empty-query `search3` fails,
  returns no songs on a nonempty server, or fails to advance; it remains the
  fresh source for Shuffle Library.
- `getSong` — single-song endpoint, retained for independent metadata checks.
  Composer resolution no longer calls it: cached native rows map directly
  into `Song` values (#85), preserving source order and the work/movement join.

### Discovery (added 2026-07-18, M10)
- `getArtistInfo2` — artist bio + similar artists (server metadata agent,
  e.g. Navidrome's Last.fm bridge) for the artist page. Bio HTML is
  flattened client-side (`ArtistInfo2Body.Info.plainBiography`).
- `getSimilarSongs2` — the Start Radio mix; `id` may be a song or artist.
  On Navidrome 0.62+ with the `sonicSimilarity` extension the server backs
  this with audio analysis transparently — nothing to negotiate client-side.
- `getTopSongs` — radio fallback for artists without similarity data.
  Keys off the artist **name**, not id (Subsonic API quirk).

### Favorites / starred
- `getStarred2` — starred artists/albums/songs.
- `star` / `unstar` — toggle favorite by `id` (song/album/artist).

### Search
- `search3` — unified search with `query`, and per-type
  `artistCount/albumCount/songCount` + `*Offset` → pagination. The empty-query,
  songs-only form also supplies the complete Songs/column-browser library.

### Playlists
- `getPlaylists` — the user's playlists.
- `getPlaylist` — one playlist's entries (ordered).
- `createPlaylist` — name + songId list; also takes a `playlistId` to
  **replace** an existing playlist's contents — the canonical Subsonic
  reorder mechanism (`updatePlaylist` can only append).
- `updatePlaylist` — rename, add songs (`songIdToAdd`), remove by index
  (`songIndexToRemove`), comment, public flag.
- `deletePlaylist` — by `id`.

### Streaming & artwork
- `stream` — audio stream by `id`. Transcoding params:
  - default: omit `format`/`maxBitRate` → original file.
  - when transcoding enabled in Settings: `format` (e.g. `mp3`, `opus`) +
    `maxBitRate` (kbps). Optional `timeOffset` for resume/seek-on-server
    fallback (we primarily seek locally — see `03`).
- `getCoverArt` — artwork by `id`, with `size` to request a server-resized
  thumbnail (used by `ArtworkCache`).

## Models (Codable, value types) ✅

`Sendable struct`s mirroring the JSON, e.g. `Song`, `Album`, `AlbumID3`,
`ArtistID3`, `Genre`, `Playlist`, `SearchResult3`, `Starred2`. Keep DTOs close
to the wire, then map to UI value types where the wire shape is awkward. Notable
fields: `id`, `title`/`name`, `artist`/`artistId`, `album`/`albumId`,
`coverArt`, `duration`, `track`, `discNumber`, `year`, `genre`, `bitRate`,
`suffix`, `contentType`, `starred` (date → `isStarred`), plus the expanded
track-column metadata: `displayAlbumArtist`, `comment`, `groupings` (`[String]`),
`created`/`played` (dates), `playCount`, `samplingRate`, and `sortName`.

Decoding notes: Subsonic returns single-vs-array inconsistencies and
string-encoded numbers in places; write tolerant decoders + fixtures (see `08`).

## Errors ✅

```
enum SubsonicError: Error, Sendable {
  case transport(URLError)
  case http(status: Int)
  case decoding(String)
  case api(code: Int, message: String)   // Subsonic error codes:
                                          // 0 generic, 10 missing param,
                                          // 20 client too old, 30 server too old,
                                          // 40 wrong credentials, 41 token auth
                                          // unsupported, 50 not authorized,
                                          // 60 trial over, 70 not found
  case notConfigured
}
```

Map code `40/41/50` to a re-authenticate / open-Settings flow; `70` to
empty-state UI; transport errors to a retry affordance.

## Pagination strategy ✅

- `getSongsByGenre` is eager: the column browser needs the complete selected
  genre for its Artist/Composer/Album panes, so `LibraryModel` walks 500-song
  pages to the first short page before joining native WorkInfo metadata.
- Empty-query `search3` is eager for the same reason. One probe determines
  support; subsequent 500-song pages run with a six-request limiter, are
  restored to offset order, and stop at the first short page. Duplicate ids or
  a repeated full page are treated as lack of progress and trigger the bounded
  random-sample fallback instead of looping indefinitely. The first page and
  each ordered batch render incrementally while the eager walk continues.
- Page size constants remain explicit for `getAlbumList2` and `search3`.
- Library views request the next page when the user scrolls near the end
  (`onAppear` of a trailing sentinel row).
- Fetched pages accumulate **in-memory** in `LibraryModel`, which owns the
  offset bookkeeping (the SwiftData store was dropped — see `05`).

## Transcoding setting → `stream` params ✅

Settings exposes: **Stream original** (default) or **Transcode** with a format
picker (`mp3`/`opus`/`aac`) and a max bitrate. `PlaybackService` asks
`SubsonicClient` for the stream URL with the appropriate params. Document that
transcoding shifts CPU to the server and can affect gapless (re-encoded
boundaries) — note for the `03` spike.

## Navidrome native API (metadata-only) 🔬

A **separate, undocumented** API Navidrome itself is built on
(`<host>/api/...`, distinct from Subsonic's `<host>/rest/...`), used by
`NavidromeClient` (actor, `Services/NavidromeClient.swift`) for classical-
metadata features Subsonic has no endpoints for: composer enumeration, a full
song index, work/movement tags. Never used for streaming/playback — those stay
on `SubsonicClient`; `NavidromeClient` only resolves song ids that the
existing playback pipeline then handles. Full design rationale and the
confirmed-by-live-capture API facts live in the E3 epic (#11) and its spike
(#8); summary:

- **Auth:** `POST /auth/login` with `{"username", "password"}` (real password,
  see the exception noted above) → a JWT (`token`) plus, in the same response,
  the Subsonic `salt`/`token` (unused by `NavidromeClient`, but means one
  login could seed both clients). Every subsequent request carries
  `X-Nd-Authorization: Bearer <token>`. Only available for `.tokenSalt`-auth
  credentials — API-key auth has no raw password to log in with, so
  `NavidromeClient` fails cleanly (`NavidromeError.apiKeyAuthUnsupported`)
  rather than attempting it.
- **Pagination:** react-admin conventions — `_start`/`_end`/`_sort`/`_order`
  query params, total via the **`X-Total-Count` response header** (not the
  JSON body). `NavidromeClient.paginatedGet<T>` walks a resource fully,
  fetching pages concurrently after the first (bounded by the same
  `AsyncLimiter(limit: 6)` `ArtworkCache` uses).
- **Composer roster:** `GET /api/artist?role=composer` genuinely filters
  server-side (unlike the song-level filter below) — `NavidromeClient.composers()`
  walks it via `paginatedGet`. The server's `_sort=name` keeps page boundaries
  stable; after all pages arrive, the client applies `localizedStandardCompare`
  so database collation differences do not leak into the macOS-visible order.
  Rows include Navidrome's own
  synthetic joint-credit entities (e.g. one row named "A, B, and C" for a
  jointly-credited track, with its own id, distinct from A/B/C's individual
  rows) — surfaced as-is, not deduplicated, matching `displayComposer`'s
  show-the-server's-string convention (#23).
- **No server-side "songs by composer" filter exists** — confirmed by testing
  every plausible query param combination live; they're silently ignored.
  Composer/work-movement lookups are client-side filters over one fully
  paginated `/api/song` walk (`participants.composer[].id` per song), not
  per-selection server round-trips.
- **Every field is tolerant-decoded** (all optional) — this API is internal
  and can change between Navidrome releases without notice. A failed login or
  unexpected response degrades to Subsonic-only; nothing else breaks.
- **Feature detection:** whether native features are usable at all is exposed
  as `ConnectionModel.nativeFeaturesState` (`.unknown`/`.checking`/`.available`/
  `.unavailable`) — auto-detected, never a user toggle. `ConnectionModel`
  probes it once per successful Subsonic connect (`saveAndConnect`/`refresh`)
  by attempting a real `NavidromeClient.login()`; any failure (network, 401,
  non-Navidrome server, API-key auth) settles on `.unavailable`, and
  `disconnect()` resets it to `.unknown`. `testConnection()` (the Settings
  "Test Connection" button) deliberately never probes — it verifies unsaved
  form credentials, while `login()` always reads the persisted credential
  store, so probing there would check the wrong server. Settings → Connection
  shows the result as a read-only status line. A form test does not interrupt an
  active persisted connect/probe; failed or superseded connection attempts settle
  native waiters so metadata loading cannot remain stranded in `.checking`.
  See #26.
- **Song-index invalidation on scan:** `ConnectionModel.startLibraryScan()`
  calls the composition-root invalidation hook after server scan completion.
  `LibraryModel.reset()` retires all collections and both `LibrarySongIndex`
  caches. The same verified seed/live/full-sync path then refreshes the UI and
  persistent metadata, including Work/movement tags, without waiting for another
  view appearance. Failed/incomplete walks cannot authorize disk pruning.
- **Song index (#24, #86):** `NavidromeClient.songIndex()` walks
  `/api/song?missing=false` fully via `paginatedGet`, excluding records whose
  files are missing/deleted. The filter is sent on every page and 401 retry;
  pagination uses the filtered `X-Total-Count`. It caches the result
  (`[NativeSongRecord]`) in-actor for
  the app session — no disk persistence, matching the M2 decision to drop the
  SwiftData cache. Cache hits and coalesced in-flight builds are scoped to an
  exact `ServerCredentials` snapshot; each build uses that snapshot for its
  entire paginated walk, and a replacement build gets a new identity so an
  older completion cannot overwrite or clear newer state.
  `invalidateSongIndex()` clears the cache and retires any in-flight build for
  a future rebuild (e.g. after a library scan; the trigger itself isn't wired
  up yet).
  `NativeSongRecord` carries optional row metadata as well as `id`/`title`,
  `participants` (`composer`/`artist`/`albumartist`/`performer`/`conductor`,
  each `[Credit]`), and raw `tags` (`[String: [String]]`). It stays separate
  from `Song` (`SubsonicModels.swift`), the playback pipeline's model.
- **Performer/Conductor (#103):** unlike composer, Navidrome sends no
  pre-joined `displayPerformer`/`displayConductor` string. Both roles ride the
  standard OpenSubsonic `contributors` array instead (`role` + optional
  `subRole`, e.g. an instrument for `performer`), present on every regular
  `getAlbum`/`getSong` response — no native `/api/song` walk needed the way
  work/movement requires. `Song.contributors` decodes it directly;
  `nonEmptyDisplayPerformer`/`nonEmptyDisplayConductor` filter+join client
  side. `NativeSongRecord.asSong()` synthesizes the same shape from
  `participants.performer`/`.conductor` so Songs built via the Composers
  native path get the same rows. Confirmed against Navidrome's own
  `model/participants.go` (role enum) and the OpenSubsonic `Contributor`
  spec — no `ensemble` role exists anywhere in Navidrome (not in the role
  enum, not in `resources/mappings.yaml`), so there is no data source for an
  Ensemble row; it was dropped from #103's scope for that reason.
- **Playable composer rows (#85):** `LibraryModel.songs(forComposer:)` maps
  the existing cached composer-filtered records directly to `Song`; there is
  no per-track `getSong` request or second library cache. Native fractional
  duration is truncated to seconds, `trackNumber`/`sampleRate` map to
  `track`/`samplingRate`, and composer credits retain Navidrome's bullet join
  and optional subroles. The mapping preserves album artist, genre(s),
  comment/groupings, sort title, dates/play count, and all four ReplayGain
  values. Zero/empty fields omitted by Subsonic remain nil, preserving Info
  labels and nil-last column sorting; sample rate retains its wire zero value.
  Optional invalid timestamps become nil without losing the index.
  `coverArt` uses the song id accepted by `getCoverArt`, while `artworkKey`
  still shares the cache by album id. Native favorite annotations seed the
  row; loaded favorites and optimistic overrides take precedence, including
  Get Info's direct `Song.starred` read. MIME labels follow Navidrome's
  [default format map](https://github.com/navidrome/navidrome/blob/v0.63.2/resources/mime_types.yaml),
  not macOS aliases; unknown/custom formats retain the suffix without an
  inferred MIME label. Streaming, cache invalidation, and the existing
  `missing=false` filter are unchanged.
- **Work/movement join onto `Song` (#45, epic #13):** `NavidromeClient`
  exposes `workMetadata(songId:)` (#25, one song) and
  `workInfo(forSongIds:)` (#45, many songs at once) against the same reusable
  id dictionary, constructed once with each cached song-index snapshot.
  `LibraryModel.joinWorkInfo(into:)`
  calls the batch form and copies `work`/`movementName`/`movementNumber`/
  `movementTotal` onto the matching `Song` values, gated on
  an async `ConnectionModel.nativeFeaturesAvailable()` gate that waits for the
  launch-time probe or starts it when necessary — a no-op, with no native
  network call at all, when unavailable. Wired into all six track-table
  sources: album, genre/Column Browser, Songs, Favorites, playlist, and search.
  The playlist source is the one exception to "inline in the fetch": since a
  cold native song-index cache means a full `/api/song` walk,
  `PlaylistDetailView.reload()` renders the playlist's own tracks from
  `LibraryModel.playlist(id:)` (unjoined) first, then applies
  `LibraryModel.joinWorkInfo(intoPlaylist:)` as a non-blocking follow-up pass
  — mirrors `allSongs()`'s partial-publish pattern (#124). A per-view load
  generation prevents a superseded fetch or enrichment pass from overwriting
  a newer playlist load or an optimistic reorder/removal.
- **Bit depth join onto `Song` (#106):** `/api/song` carries a `bitDepth`
  field (confirmed live 2026-09-03 against demo.navidrome.org: present on
  FLAC and ALAC-in-`.m4a` records, absent on lossy suffixes) that plain
  Subsonic never exposes. `NavidromeClient.bitDepths(forSongIds:)` mirrors
  `workInfo(forSongIds:)`'s batch/cache-reuse shape; `LibraryModel.joinWorkInfo(into:)`
  calls it alongside the work/movement join (same gate, same six sources) and
  sets `Song.bitDepth`. `Song.qualityDetailLabel` uses it for the Now Playing
  badge — format name + bit depth/sample rate ("FLAC 24/96k") above the
  320 kbps hi-res threshold when both fields are reported, otherwise format
  name + bit rate ("AAC 256 kbps", "MP3 192 kbps"). 320 kbps is the ceiling of
  legitimate lossy encoding, and it doubles as a lossless detector in place of
  a suffix list. `.m4a`/`.m4b` alone can't distinguish lossless ALAC from lossy
  AAC (Navidrome reports the same suffix and MIME type for both), so those two
  suffixes are named from the hi-res branch instead of the suffix directly:
  "ALAC" when a bit depth backs the high bit rate, "AAC" otherwise.
