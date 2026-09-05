# 00 — Fork Divergence

> **Read this before treating any other doc as binding.**

This repository is a fork of [`thijsw/hydrophone`](https://github.com/thijsw/hydrophone),
taken at commit `627ffcc` on 2026-08-16. As of 2026-09-05 it has 242 commits of
its own on top of that point. It is maintained for its owner's use and its goals
have diverged from the upstream project's.

## The standing rule

Every doc in this directory except `11-agent-workflow.md` was originally written
by the upstream maintainer, before the fork. Where an inherited doc conflicts
with what is actually built here, **this repository wins and the inherited text
is historical context.**

A scope decision or non-goal recorded before `627ffcc` is a record of the
upstream maintainer's product judgment about their app. It is not a constraint
on this one, and it does not need to be argued around. Before citing a doc as
authority, check whether the passage predates the fork:

```sh
git log $(git merge-base HEAD upstream/main)..HEAD -- docs/<file>
```

Docs with no commits since the fork point are inherited wholesale. `00-overview.md`
is currently the clearest example. `05-data-and-caching.md` has been substantially
rewritten here and reflects this fork's decisions.

Review findings and design objections must stand on observed behavior. "This
contradicts a documented non-goal" is not on its own a valid objection when the
document is inherited.

## Where the goals diverge

**Classical music is a first-class browsing axis.** Composers, works, movements,
and performer/conductor credits are built out here (`ComposersView`,
`LibraryModel+WorkInfo`, the Work and Movement track columns and grouping headers).
`00-overview.md`'s in-scope library list names only Albums, Artists, Songs, Genres
and Favorites.

**Smart playlists and playlist folders are being built** (epic E8, #16, with
sub-issues #88 through #93). `00-overview.md` lists smart playlists as an explicit
non-goal. These are local-only: rules are evaluated on this machine and the server
never sees them.

**Library metadata is persisted to disk** (epic #128). Upstream dropped the planned
SwiftData store and kept library metadata in memory for the session. This fork
reverses that as a launch-speed optimization. It stores metadata only. No audio is
ever written to disk, and the store is a warm-start index rather than a source of
truth.

**Distribution is direct, not the App Store.** Releases are notarized Developer ID
builds published through `scripts/publish.sh` to GitHub Releases, with a GitHub
Pages site. `07-distribution.md` still describes the Mac App Store as the primary
channel and designs the sandbox around it.

**Changes are not contributed upstream.** The `upstream` remote is fetch-only and
push is disabled. This fork may eventually ship independently under its own name
(working title Cadenza).

## What has not changed

These hold, and the inherited docs remain accurate on them:

- Streaming-only playback. No offline audio, no downloads.
- Zero third-party dependencies. Apple frameworks only.
- Single-server connection, with credentials in the Keychain.
- Native macOS app, SwiftUI with an AppKit track table, Swift 6 strict concurrency.
