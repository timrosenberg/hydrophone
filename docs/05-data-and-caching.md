# 05 — Local Metadata & Artwork Caching

> **Decision (updated):** The **SwiftData metadata cache was dropped.** The app
> is network-required by design — you can't stream music with the server down,
> so caching library *metadata* for offline browsing adds complexity for little
> value. Library metadata stays **in-memory** in `LibraryModel`, fetched per
> session. The one thing we *do* cache aggressively is **artwork** (immutable),
> on disk — see "Artwork cache". The SwiftData section below is retained as
> historical context and is **not implemented**.

Caching here is **artwork only** — there is **no audio/offline caching** and no
metadata persistence (streaming-only, network-required).

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
