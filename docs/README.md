# Hydrophone — Design & Planning Docs

Hydrophone is a native macOS music player for **OpenSubsonic** servers
(Navidrome as the reference server), written in modern SwiftUI for
macOS 15 "Sequoia" and later, built with Xcode 26 / Swift 6.2.

This directory is the **design and planning source of truth**, kept in sync
with the implementation as it lands. Each document is self-contained and
detailed enough to implement (or understand) the subsystem it covers;
`PROGRESS.md` is the running record of what's actually built and verified.

## How to read this set

Read `00-fork-divergence.md` first. This repo is a fork, and much of this
directory was inherited from the upstream project rather than written for
this one. Then read `00-overview.md` for product scope and the requirements
traceability matrix, and `01-architecture.md` for the shape of the app.
After that, the numbered docs can be read in any order; the roadmap
(`10-roadmap.md`) sequences the actual build.

## Index

| Doc | Purpose |
| --- | --- |
| [00-fork-divergence.md](00-fork-divergence.md) | **Read first.** Fork point, which inherited docs are non-binding, where goals diverge |
| [00-overview.md](00-overview.md) | Product vision, scope, non-goals, glossary, requirements traceability |
| [01-architecture.md](01-architecture.md) | Layers, state model, concurrency, module structure, dependency policy |
| [02-opensubsonic-api.md](02-opensubsonic-api.md) | Auth, networking client, endpoint map, models, errors, pagination |
| [03-playback-engine.md](03-playback-engine.md) | `AVAudioEngine` graph, streaming decode, gapless, device/route handling |
| [04-ui-ux.md](04-ui-ux.md) | Navigation, sidebar, track table, column browser, queue, MenuBarExtra, a11y |
| [05-data-and-caching.md](05-data-and-caching.md) | SwiftData schema, artwork cache, pagination, memory tactics |
| [06-system-integration.md](06-system-integration.md) | Now Playing, remote commands, media keys, drag-and-drop, restoration |
| [07-distribution.md](07-distribution.md) | App Sandbox, entitlements, Mac App Store, signing/notarization |
| [08-testing.md](08-testing.md) | Swift Testing units, mocking, UI tests, manual verification checklist |
| [09-design-system.md](09-design-system.md) | `claude_design` import workflow, mapping cues to native SwiftUI |
| [10-roadmap.md](10-roadmap.md) | Milestones M0–M8, exit criteria, risks, spikes |
| [11-agent-workflow.md](11-agent-workflow.md) | Branch/worktree workflow, done gate, PR-then-stop, merge & cleanup policy |
| [PROGRESS.md](PROGRESS.md) | Running build log — what's implemented, verified, deferred |

## Status legend

Used inside docs to flag maturity of a section:

- ✅ **Decided** — committed; implement as written.
- 🔶 **Default** — a reasonable default chosen; revisit if it bites.
- 🔬 **Spike** — needs a prototype before committing (highest risk).
- ⏳ **Deferred** — out of scope for v1, captured for later.

## Key decisions at a glance

- **Platform:** SwiftUI, macOS 15+ deployment, Xcode 26 SDK, Swift 6 strict
  concurrency. Liquid Glass adopted automatically on macOS 26 "Tahoe" via
  standard controls/materials; Tahoe-only APIs availability-guarded. ✅
- **Playback:** `AVAudioEngine`, Option A progressive decode, one canonical
  timeline format on a **single** player node for gapless (the dual-node plan
  proved unnecessary — see `03`). Hardware sample-rate matching on by
  default. ✅
- **Persistence:** none for metadata — the app is network-required by design;
  library metadata is in-memory per session. Artwork is cached on disk
  (the SwiftData metadata cache was dropped — see `05`). ✅
- **State:** Observation (`@Observable`) with one central `PlayerModel`. ✅
- **Distribution:** Mac App Store, App Sandbox, minimal entitlements. ✅
- **Dependencies:** First-party Apple frameworks only. ✅
