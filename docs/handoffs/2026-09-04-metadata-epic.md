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

## Acceptance evidence (2026-09-05)

| Issue | Implementation and verification |
|---|---|
| #146 | Versioned v1 schema and migration plan; rich/sparse mappings, ordered repeated playlist entries, disk reopen and actor-boundary tests in #152. |
| #147 | Account-scoped actor containers and session tokens; A/B/A, disconnect retention, API-key separation and unavailable/corrupt store tests. |
| #148 | Verified seed precedes held live rows, then replaces without duplicates; rejected connection never opens the store; unavailable store keeps live loading. Section and playlist tasks follow session/readiness changes. |
| #149 | Real disk writes from fetch completions; held and failed backend tests prove live publication completes independently; concurrent upsert, authoritative favorites and stale playlist-detail tests. |
| #150 | Complete-walk validation and one session refresh; atomic pruning, failed mapping rollback, cancellation, incomplete pagination rejection, accepted-write replay, native-field clearing and 14k-to-7k tests. A later successful full sync also recovers an initial collection fetch failure. |
| #151 | A held server scan leaves current rows intact; completing it awaits a second full metadata commit with new rows. Cache inventory in docs/05 records distinct retained responsibilities and no redundant-cache removal follow-up. |

The earlier 0.88-second relaunch claim was invalid and is withdrawn. It observed
an existing process. The final live verification uses a confirmed process exit
and new PID; it is a functional restart check, not a launch-speed benchmark.
The post-review final gate is **413 tests / 436 executions**, zero failures/skips,
an unsigned app build with zero warnings, SwiftLint zero violations and a clean
diff check. Live verification on Navidrome 0.63.2 includes Home seed-to-live,
direct saved-playlist restart, and a manual scan followed by an updated disk
sync timestamp/generation and restored playlist Work metadata. See PROGRESS
for the exact executable, PIDs, result bundle and observations.

## Review/landing order

Review #152 plus the final continuation together. Land the foundation before
the continuation using true merge commits only, after Tim explicitly approves
landing. Do not rewrite the foundation or merge it during implementation.
