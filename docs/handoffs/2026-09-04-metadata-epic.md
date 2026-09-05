# Persistent metadata epic continuation

Tim authorized continuation of #128 on a branch based on #146, with review
and landing deferred until the epic is complete. This overrides the normal
origin/main branch base and per-issue PR stop for this batch. No merge is
authorized by the continuation request.

Foundation: `issue-146-metadata-schema`, PR #152, `d66668c`.
Continuation: `issue-128-metadata-warm-start`, based on that foundation.

| Issue | Deliverable | Primary files | Dependency |
| --- | --- | --- | --- |
| #146 | Versioned schema, value mappings | Models/MetadataStore | Complete in #152 |
| #147 | Persistent store lifecycle and isolation | Services/LibraryMetadataStore*, ConnectionModel, AppModel | #146 |
| #148 | Seed before live loads, preserve rows during refresh | LibraryModel+Metadata, LibraryModel collections | #147 |
| #149 | Best-effort write-behind at successful fetches | LibraryModel extensions, metadata store | #147–148 |
| #150 | Complete background walk and atomic reconciliation | Services/LibraryMetadataSync, LibrarySongIndex, metadata store | #148–149 |
| #151 | Manual rescan and updated cache inventory | ConnectionModel, LibraryModel+Metadata, docs/01, docs/05, docs/10, PROGRESS | #150 |

## Ownership and integration

- Controller: connection/composition/library wiring, shared persistence value
  contract, strict complete song-index API, sync fetch coordinator, integration
  tests and documentation.
- Disk-store subtask: new `Services/LibraryMetadataStore*.swift` files and
  `HydrophoneTests/LibraryMetadataStore*` tests. No existing library or connection
  files, schema edits, or documentation edits.
- Read-only review follows implementation. Commits preserve issue boundaries
  where practical; the continuation is reviewed as an integrated result.
- Existing #113 worktree remains untouched. Its album-detail scope overlaps
  library code conceptually; integration here is limited to metadata persistence.

## Implementation decisions and acceptance

1. Disk work lives on an actor. Stores are separate by normalized server and
   account identity; secrets are never persisted or logged. A new session token
   retires reads/writes/syncs from earlier connections. Disconnect retains disk.
2. A successful connection opens and reads the store before exposing a connected
   library and starting normal live loads. Persisted values never bypass ping.
   The UI shows seed values immediately; first live pages replace seed data
   without appending duplicates or temporarily emptying complete seeded rows.
3. Successful live fetches publish UI state first and enqueue writes afterward.
   Nil detail fields from summary endpoints preserve existing fetched detail
   where valid; explicit empty detail clears it. Favorites/playlist mutations
   are persisted only through accepted server responses.
4. Full sync reuses existing transport and song pagination. A random fallback,
   repeated page, cancellation, or failed page is never sufficient to prune.
   Fetch all collections before one transactional reconciliation; failed walks
   leave the previous disk snapshot intact. Writes accepted during the walk are
   replayed over the older snapshot at commit so favorites/playlists do not regress.
5. One pass per verified connection; manual rescan waits for server scan completion,
   then forces the same complete sync path. No periodic timer or new network API.
6. Verify warm relaunch, failed connection, A/B/A and account switches, stale async
   completions, partial/failing stores, deletion pruning, concurrent writes, manual
   rescan, and server-observed cold versus warm launch behavior.

## Review/landing order

Review #152 plus the final continuation together. Land the foundation before
the continuation using true merge commits only, after Tim explicitly approves
landing. Do not rewrite the foundation or merge it during implementation.
