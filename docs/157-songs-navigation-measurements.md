# Songs navigation measurements — 2026-09-06

Issue #157 is implemented and accepted for PR review, pending merge. The
candidate does **not** meet the original median <=100 ms / maximum <=150 ms
target. On 2026-09-06, Tim explicitly accepted the measured 167 ms maximum
and confirmed the app feels "MUCH better than before." This is acceptance
of the observed result, not a claim that the original target passed.

## Method

- MacBook Pro, macOS 26.6.2 (25G83), Xcode 26.6, Debug, arm64.
- Baseline: `e5fc1f46af8463f60e76846de7a4b5f8adee306e` (`origin/main`).
- Candidate: `issue-157-songs-navigation-latency`.
- Tim's configured Navidrome library, **14,231 songs**, browser visible,
  All Genres/Artists/Albums/Composers, saved Title ascending browser sort.
- Repeated **Songs -> Favorites -> Songs**. Favorites is an intervening
  sorted table, so the sequence exercises the old one-slot-cache weakness.
- A temporary identical probe began at the sidebar selection binding and
  ended after the first populated track table's `draw(_:)`. Values measure
  selection-to-first-table-draw, not physical input-device latency or final
  display scanout. The probe was removed from the final source.
- Instruments Time Profiler captured the navigation intervals and CPU stacks.
  Separate timing log records cover all ten repeats; recording startup meant
  that not every repeat was present in the CPU traces.
- Startup and first-use samples are reported separately. The initial
  exploratory trace contained reconciliation and network work and was not
  used as the warm baseline. The native-pane series had a 700.716 ms first
  return before the ten subsequent steady-state repeats below. Its precise
  cause was not isolated; it is reported separately as warm-up, not silently
  discarded. First-use/changed-content latency remains a limitation.

## Results (milliseconds)

| Repeat | Main baseline | Cached presentation | Cached presentation + native panes |
| --- | ---: | ---: | ---: |
| 1 | 1558.592 | 210.725 | 161.384 |
| 2 | 1527.991 | 220.479 | 154.688 |
| 3 | 1529.448 | 212.484 | 155.273 |
| 4 | 1507.436 | 213.547 | 166.423 |
| 5 | 1540.535 | 218.340 | 157.335 |
| 6 | 1533.580 | 216.733 | 159.610 |
| 7 | 1523.772 | 186.270 | 155.072 |
| 8 | 1518.498 | 216.315 | 166.686 |
| 9 | 1511.561 | 210.680 | 161.469 |
| 10 | 1519.153 | 208.679 | 159.754 |
| Median | **1525.882** | **213.016** | **159.682** |
| Slowest | **1558.592** | **220.479** | **166.686** |

The final median is **89.5% lower** than main. The native pane renderer saves
another 25.0% relative to the presentation-cache-only candidate.

This is not a guarantee for every navigation path. One additional Albums ->
flat Songs return with the user's saved flat-view preferences measured
197.807 ms. Initial population and content replacement still prepare new
results and can be appreciably slower than unchanged revisits.

## Trace findings and resulting changes

1. The baseline restored the saved sort through the table delegate, then
   unconditionally rebuilt again in `makeNSView`. The initial update could
   also rebuild. Creation now initializes the signature and loads once.
2. Sorting and browser projections now belong to immutable song snapshots
   retained by `LibraryModel`. Unchanged publication keeps the same snapshot;
   changed values replace it. Cache validation uses reference identity instead
   of whole-song hashes. Each snapshot retains up to four sort variants, and
   another collection cannot evict its results.
3. Warm snapshot updates bypass the old per-song ID/group/favorite signature.
   Selection-order arrays are built only during incremental loading, where
   identity preservation actually needs them.
4. The next trace showed browser List construction/layout costs. The four
   pane lists now use small, fixed-height AppKit cell-based tables, preserving
   the plain appearance, labels, selection bindings, cascades, and native
   keyboard controls. This does not change the filtering UX tracked by #159.
5. In the final trace's six measured warm intervals, about 734 ms of 941 ms
   sampled main-thread time was under window/view layout, including 353 ms
   under default key-view-loop setup and 292 ms under visible table-row
   preparation (inclusive, overlapping totals). Warm sorting and browser
   projection computation no longer dominated. These measurements do not
   establish a hard platform limit; further work would need to investigate
   view lifetime and native layout rather than add more song caches.

## Evidence and acceptance

Local traces are under `/private/tmp/hydrophone-157-*-timed.trace`; extracted
CPU samples and signposts have matching XML filenames. These are local
diagnostic artifacts and are not committed or uploaded. Only these aggregate
measurements are suitable for the public issue.

Live verification also exercised composer filtering, arrow-key
selection, artist filtering, cascading All resets, and flat Songs
revisits. Browser visibility was restored afterward. Hermetic tests cover
same-ID metadata publication, unchanged publication, reset, intervening tables,
sort variants, native pane clicks/keyboard/Space/type-select data, pagination,
stale genre requests, and saved selections.

Tim accepted the observed steady-state result and confirmed perceived
responsiveness on 2026-09-06, authorizing the replacement PR. The original
numerical target remains unmet; the first-use and other-navigation limitations
above still apply. PRs #160 and #162 remain closed, unmerged; this replacement
requires review and separate merge authorization.

Final source verification after removing the probes: unsigned app build with
zero compiler warnings; **428 tests / 451 executions, zero failures or skips**;
SwiftLint and diff checks clean. The test compilation retains the pre-existing
`ArtworkCacheTests` weak-variable warning; the app build emits only Xcode's
App Intents metadata-extraction notice (the target has no App Intents).
