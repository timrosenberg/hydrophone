<div align="center">

# Hydrophone

**A native macOS music player for your own OpenSubsonic server.**

The interaction design iTunes got right — a dense sortable track list, a
column browser, Up Next, fast search — rebuilt as a modern, restrained
Mac app. Streaming-only, audiophile-grade playback, no Electron in sight.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)
![Frameworks](https://img.shields.io/badge/dependencies-Apple%20frameworks%20only-green)
![Server](https://img.shields.io/badge/server-OpenSubsonic%20%2F%20Navidrome-8A2BE2)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

**[Website](https://hydrophone.app/)** · **[Latest release](https://github.com/thijsw/hydrophone/releases/latest)**

![Hydrophone playing Meridian by Ada Lark — track table, quality badges and Now Playing panel with Up Next](site/assets/app-window.png)

</div>

---

Hydrophone connects to a self-hosted [OpenSubsonic](https://opensubsonic.netlify.app/)
library ([Navidrome](https://www.navidrome.org/) is the reference server).
It's for people who run their own music server and want a real Mac app —
keyboard-friendly, low-footprint, native — instead of a browser tab.

## Features

- True gapless playback; streaming decode of FLAC, MP3, AAC, WAV, AIFF —
  with automatic server-transcode fallback for anything else
- Hardware sample-rate matching (on by default) — your DAC runs at each
  track's native rate
- ReplayGain volume normalization (track/album) with peak protection
- Output-device picker incl. AirPlay routes; USB-DAC unplug/replug recovery
- Dense sortable track table, column browser (Genre → Artist → Album),
  global search, quality badges with lossless-first sorting
- Home page shelves; artist pages with an instant album grid
- Start Radio from any song or artist (server similarity, with fallbacks)
- Shuffle Library (500-song mix) and Shuffle Albums (whole albums,
  filter-aware); album grid filters by genre/decade
- Server playlists with full round-trip editing; favorites everywhere
- Scrobbling; trigger a server library scan from the app
- Queue-first Now Playing panel — the artwork hero collapses to a compact
  strip so Up Next gets the full height; queue saved server-side with the
  playhead — survives relaunches, resumable from other clients
- Menu-bar player, media keys, Control Center widget, iTunes-style LCD
- Light/Dark, keyboard-first, VoiceOver, state restoration; sandboxed with
  a single (network) entitlement
- One-click demo server to try it without a server of your own

## Requirements

- **macOS 14 Sonoma** or later
- An **OpenSubsonic-compatible server** (Navidrome, Gonic, LMS, Astiga, …)

## Status

Actively developed — see the
[changelog](https://hydrophone.app/#changelog) for what's new.
Also available on the
[Mac App Store](https://apps.apple.com/app/id6795956982). Deliberately out
of scope for v1: offline downloads, smart playlists, multi-server
profiles, tag editing.

## For developers

Swift 6 (strict concurrency), SwiftUI with an AppKit core for the track
table, and **zero third-party dependencies**. Build with Xcode 26, or:

```sh
git clone https://github.com/thijsw/hydrophone.git && cd hydrophone
xcodebuild -project Hydrophone.xcodeproj -scheme Hydrophone \
  -destination 'platform=macOS' build   # or: test
```

The [`docs/`](docs/) directory holds the full design docs — architecture,
the playback-engine deep-dive (gapless + crackle forensics), API layer,
UI/UX rationale — and the running build log
([`docs/PROGRESS.md`](docs/PROGRESS.md)). The test suite runs hermetically —
in CI on every push ([`tests.yml`](.github/workflows/tests.yml)) — and an
opt-in live suite exercises a real server via `HYDROPHONE_HOST/USER/PASS`
env vars. Releases ship through [`scripts/release.sh`](scripts/release.sh)
(archive → notarize → staple) and [`scripts/publish.sh`](scripts/publish.sh);
the [website](https://hydrophone.app/) redeploys itself from
[`site/`](site/) on every release.

## License

[MIT](LICENSE)

---

<div align="center">
<sub>Built for people who miss iTunes 12.6 — the patterns, not the chrome.</sub>
</div>
