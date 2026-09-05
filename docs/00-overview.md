# 00 — Product Overview & Scope

> **Inherited from upstream.** This file predates the fork and has not been
> revised for this repository. Its scope list and non-goals record the upstream
> maintainer's decisions, several of which this fork has deliberately reversed
> (classical browsing, smart playlists, persistent metadata, distribution).
> Read [`00-fork-divergence.md`](00-fork-divergence.md) first; it supersedes
> this document wherever the two disagree.

## Vision

Hydrophone is a **restrained, fully native macOS music player** for self-hosted
**OpenSubsonic** libraries. It brings back the genuinely good *interaction
design* of **iTunes 12.6.3** — a dense sortable track list, a column browser,
an Up Next queue, a persistent now-playing header, fast global search — but
renders all of it in **modern, native styling** that follows the Apple Human
Interface Guidelines and automatically adopts Liquid Glass on macOS 26.

It is streaming-only, single-server, and built for people who run Navidrome
(or another OpenSubsonic server) and want a Mac client that feels like it
shipped with the OS.

### Design philosophy: iTunes patterns, not iTunes chrome

We replicate the *patterns* iTunes 12.6.3 got right, **not** its visual
appearance:

- ✅ Keep: column browser (Genre → Artist → Album), dense sortable track
  table, Up Next, persistent playback header, fast type-to-search.
- ❌ Drop: skeuomorphic chrome, brushed metal, Cover Flow (no longer a native
  macOS pattern), the old MiniPlayer window (replaced by a `MenuBarExtra`
  Now Playing panel modeled on the modern macOS Music / Control Center
  dropdown).

## Target user

A technical music listener running their own OpenSubsonic/Navidrome server,
on macOS 14+, who wants a native, keyboard-friendly, low-footprint desktop
client rather than a web UI or an Electron app.

## In scope (v1)

- Single OpenSubsonic server connection, configured in a native Settings
  window; credentials in Keychain.
- Standard Subsonic **token+salt** auth and OpenSubsonic **API-key** auth
  where the server supports it.
- Library browsing: **Albums, Artists, Songs, Genres, Favorites (starred)**,
  plus a **Home** landing page (Jump Back In, Keep Listening, Recently Added,
  Most Played, Random shelves).
- The user's **server playlists** with full create / edit / delete / reorder.
- **Streaming-only** playback with **gapless** album transitions.
- Optional **server-side transcoding** (format + bitrate) setting; otherwise
  stream the original file.
- Full system integration: **Now Playing** in Control Center, **media keys**,
  `MPRemoteCommandCenter` transport, live metadata + artwork.
- A **`MenuBarExtra`** Now Playing panel (window style).
- **Global search**, dense sortable **track table**, **column browser**,
  **Up Next** queue, persistent **now-playing header**.
- Output device selection (AirPlay routes included).
- **Server scrobbling** ("now playing" + play submissions, Last.fm rules) and
  a **server library scan** trigger.
- **Quick Look** full-resolution artwork and **Show Album in Library**.
- Full macOS citizenship: menu bar + standard shortcuts, multi-window,
  full-screen, Stage Manager, state restoration, Light/Dark, accessibility.

## Non-goals (explicitly out of scope for v1)

- ❌ Offline caching / downloads (streaming only). ⏳
- ❌ Direct Last.fm / ListenBrainz clients. (Server scrobbling **shipped**
  2026-07-11 — the server relays to any connected scrobbler; a direct
  client remains out of scope.)
- ❌ Smart playlists.
- ❌ Multiple server profiles / multi-server.
- ❌ Cover Flow.
- ❌ Library *editing* on the server beyond playlists and starring (no tag
  editing, no uploads).
- ❌ Third-party dependencies unless a permissive-licensed library is the only
  alternative to reinventing the wheel.

## Glossary

- **OpenSubsonic** — a backward-compatible, community-extended superset of the
  Subsonic API. Adds capability discovery and newer auth options on top of the
  classic Subsonic REST endpoints.
- **Navidrome** — the primary reference OpenSubsonic server for this project.
- **token+salt auth** — classic Subsonic auth: send `t = md5(password + salt)`
  plus the random `salt`, never the raw password.
- **API-key auth** — an OpenSubsonic extension allowing a pre-issued API key
  instead of password-derived tokens (server support varies).
- **Gapless playback** — no audible silence between consecutive tracks,
  achieved by pre-buffering/scheduling track N+1 before track N ends.
- **Liquid Glass** — the macOS 26 "Tahoe" material/design language; standard
  SwiftUI controls adopt it automatically on Tahoe while staying native on
  Sequoia.

## Requirements traceability

Every `PROMPT.md` requirement maps to at least one design doc. Use this as the
acceptance checklist.

| PROMPT.md area | Requirement | Covered in |
| --- | --- | --- |
| Platform & language | SwiftUI, macOS 14 min, Xcode 26 SDK, Liquid Glass auto-adopt, availability guards | 01, 04 |
| Platform & language | First-party frameworks (NavigationSplitView, Table, MenuBarExtra, AVAudioEngine, MediaPlayer, Keychain, URLSession, SwiftData) | 01–06 |
| Platform & language | External deps only if permissive + unavoidable | 01 |
| Distribution | Mac App Store, App Sandbox, minimal entitlements | 07 |
| Server & API | OpenSubsonic / Navidrome, single server | 02 |
| Server & API | token+salt + API-key auth, Keychain | 02 |
| Server & API | Settings window for server config | 02, 04 |
| Server & API | Server-side transcoding setting | 02, 04 |
| Playback | Streaming-only | 02, 03 |
| Playback | Gapless (pre-buffer next track) | 03 |
| Playback | Now Playing / media keys / remote commands / artwork | 06 |
| Playback | Server scrobbling (shipped post-M7; direct Last.fm client stays a non-goal) | 00, 02 |
| Interface & UX | iTunes 12.6.3 interaction model, modern native styling, HIG, SF Symbols | 00, 04 |
| Interface & UX | Sidebar groups (Library / Playlists) | 04 |
| Interface & UX | MenuBarExtra Now Playing panel | 04 |
| Interface & UX | Track table, column browser, Up Next, now-playing header, global search | 04 |
| Playlists | Full CRUD + reorder, no smart playlists | 04, 02 |
| Performance | Lazy-load, paginate, stream, release buffers/artwork | 03, 05 |
| macOS dev | HIG, menu bar + shortcuts, window model, appearance/a11y, sandbox, signing, file access | 04, 06, 07 |
| Swift tips | Concurrency/actors, Swift 6, value types, Observation, Swift Testing, idiomatic | 01, 08 |
| Audio engine | AVAudioEngine, gapless, route changes, output device, off-main I/O | 03 |
| System integration | Now Playing center, remote command center, media keys, App Nap, drag-and-drop | 06 |
| Library/metadata | Artwork caching | 05 |
| Architecture tips | Central @Observable player, decoupled engine, throttled position | 01, 03 |
| Design | claude_design import for inspiration | 09 |
