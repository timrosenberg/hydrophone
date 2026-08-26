# 04 — Interface & UX

Model the **interaction design** on iTunes 12.6.3's genuinely-good patterns;
render everything in **modern, fully native** SwiftUI that follows the HIG and
adopts Liquid Glass automatically on macOS 26. SF Symbols and system typography
throughout. (See `00` for the philosophy and `09` for the design-import
workflow.)

## Window & scene structure ✅

- **Main window** — a single `Window` scene (not `WindowGroup`; the player is
  one shared engine/queue, so multiple windows make no sense) containing a
  `NavigationSplitView` shell. The `Window` scene makes the system list
  "Hydrophone" in the Window menu, so the window can be reopened after
  closing — an App Review guideline-4 requirement (0.6.1 rejection).
- **Settings** — a `Settings` scene (native Preferences window; ⌘,). See `02`
  for server/auth/transcoding contents.
- **MenuBarExtra** — Now Playing panel scene (below).
- Support resizing, full-screen, Stage Manager, and
  **state restoration**. Implemented: selected sidebar section, Now Playing
  panel visibility, column-browser visibility, column-browser **selections**
  (genre/artist/album), and per-view-kind table **sort** (key + direction,
  `trackSort.*`) persist via `@AppStorage`/UserDefaults (deliberately
  app-wide, so they restore regardless of the system's window-restoration
  setting). Scroll position persists too for the stable library views
  (Songs/Favorites/browser; content-specific views like album detail
  deliberately don't). All six `TrackTableView` contexts opt into
  `columnsCustomizable` (#38), so column **visibility, order, and width** persist
  the same way (`TrackColumnPreferences`, `trackColumns.*`/
  `trackColumnWidth.*`) — see the Track table section below. See `06`.

## Layout ✅

```
┌──────────────────────────────────────────────────────────┐
│ Toolbar: transport ·· [LCD now-playing] ·· volume · panel │
├──────────┬───────────────────────────────┬───────────────┤
│ 🔍 Search│ [ Genre ][ Artist ][ Album ]  │ NOW PLAYING ✕ │
│ Sidebar  ├───────────────────────────────┤  hero artwork │
│ (Library │                               │  title/artist │
│  /Play-  │  Track Table (dense,          │  scrubber ·   │
│  lists)  │  sortable)                    │  transport    │
│          │                               │  UP NEXT list │
└──────────┴───────────────────────────────┴───────────────┘
```

The now-playing experience lives in the window's unified toolbar: transport
leading, a centered "LCD" display (artwork, title, artist — album,
elapsed/total, a hairline progress bar), volume + panel toggle trailing. The
search field is pinned at the top of the sidebar (Music-style,
`.searchable(placement: .sidebar)`) so it never collapses or migrates when the
toolbar gets tight. Clicking the LCD toggles the **Now Playing panel** — a
trailing inspector with a hero card for the current track above the Up Next
queue.

> Toolbar gotcha: SwiftUI on macOS cannot host custom toolbar items in the
> strip above the sidebar — attaching them to the sidebar column breaks the
> NSToolbar layout (items dumped into overflow), and `.automatic` placement
> there silently drops the whole toolbar. Keep all items on the split view.

## Sidebar (`NavigationSplitView`) ✅

Grouped like iTunes, using `Section`s and SF Symbols:

- **Library**
  - Home · Albums · Artists · Songs · Favorites (starred). Genre browsing
    lives in the column browser (no separate sidebar item).
  - Composers appears only when Navidrome native features are available. It
    opens an imageless master-detail view: a localized-name-sorted composer
    roster with song counts, a 180–360pt resizable list whose width and
    selection persist, and a detail pane with a Play/Shuffle header (name,
    song count/duration) over that composer's tracks (`[.title, .album,
    .artist, .genre, .quality, .time]` — spans albums, so `.album` stays
    while `.composer` is redundant here), reusing `TrackTableView`'s
    per-row queueing and double-click-to-play as-is. A composer with no
    songs shows a "No Songs" empty state. Reaching Composers with a stale
    sidebar selection on a server without native features (e.g. after
    switching to a plain Subsonic server) shows a "Composers Unavailable"
    message instead of an empty or broken screen.
  - **Home** is a distinct landing page, not just re-sorted album lists: a
    time-of-day greeting, a full-width "Jump Back In" hero card for the most
    recently played album (cover on a blurred blow-up of itself + scrim,
    inline Play; clicking the card opens the album), then shelves at varied
    sizes — Keep Listening (continues past the hero), Recently Added
    (larger 150pt tiles), Most Played, Favorites (starred albums; loaded by
    Home itself, not dependent on visiting the Favorites tab), Random
    (re-roll button). The starred load is independent: a non-empty Favorites
    shelf keeps Home renderable even if all four `getAlbumList2` shelf requests
    fail or return empty. Shelves the server can't fill stay hidden; the
    played-based shelves are fed by the app's own scrobbling (see `02`).
- **Playlists**
  - The user's server playlists (live from `getPlaylists`), each selectable;
    context menu for rename/delete; "+" to create.

Selection drives the detail area. `LibraryModel` backs the content.
Selection appearances are **custom-drawn** (the backing tables' system
highlight is suppressed via `ListSelectionHighlightDisabler`; selection
state and keyboard navigation are untouched) because the system pill blends
with the list material and never matches the app accent:
- **Sidebar**: Music-style neutral-gray pill with standard side insets, red
  icons on top (the iTunes reference look).
- **Artist list & track tables**: the accent red, white content.
Note: the `AccentColor` asset is tagged **Display P3** — the red was sampled
on a wide-gamut screen and lies outside the sRGB gamut; tagged sRGB it
rendered visibly washed out.

## Track table ✅

- AppKit-backed **`MusicTrackTable`** (via the `TrackTableView` wrapper — see
  the M5 notes in `PROGRESS.md`) with click-to-sort columns: Title, Artist,
  Album, Genre, Quality, Time, plus the now-playing speaker and ★ columns.
  Per-view column sets, expandable to 8 more (Album Artist, Comments,
  Grouping, Date Added, Last Played, Plays, Sample Rate, Sort Title — E2),
  plus native-only Work, Movement Name, and Movement columns. Work and
  Movement Name show `—` for missing text; Movement shows `n of total` only
  when both values exist and otherwise shows `—`.
- **Column picker**: right-click a column header for a checkable list of
  every column the view could show (all of `TrackColumn` except `.number`,
  which doubles as the now-playing indicator and stays a per-call-site
  choice). Toggling shows/hides live; reordering (drag) and resizing (drag
  the border) already work natively. All three — visible set, order, and
  width — persist per view kind via `TrackColumnPreferences`. All six table
  contexts (album, favorites, songs, column browser, playlist, and search)
  opt in while retaining their call-site defaults until customized — see
  `TrackColumnPicker.swift`. Work, Movement Name, and Movement are offered
  only after `ConnectionModel.nativeFeaturesState` reaches `.available`;
  plain Subsonic or unavailable-native sessions omit those menu items rather
  than showing disabled choices. A saved native-column layout is filtered
  from the live table while unavailable, then restored if native capability
  returns. Visible-column edits made during an unavailable session merge into
  that preference without discarding its hidden native entries.
- **Quality column**: a small outline badge per song — format name for
  lossless files ("FLAC", "AIFF"), bit rate for lossy ("320 kbps") — via
  `Song.qualityLabel`; sorting ranks lossless above any lossy bit rate. The
  Now Playing hero card uses the same outline styling with
  `Song.qualityDetailLabel`, which adds `· N kbps` for lossless files when the
  server reports a positive bit rate while preserving `qualityLabel` behavior
  for lossy files and lossless files without one.
- **Album work grouping**: when an album contains more than one distinct
  tagged Work, flat, unselectable headers mark each consecutive run. Work
  grouping takes priority over disc grouping; a multi-disc album folds the
  disc into each label (`Disc 2 · Work Name`). A blank spacer row marks the
  opposite boundary — where a grouped run ends and an ungrouped run begins —
  since no header exists there to separate them; it does not appear at the
  top of the list, between two grouped runs, or on albums with no grouping.
  Headers appear only in natural track order or ascending `#`, and withdraw
  (spacer included) under every other sort. Albums with zero or one Work
  retain the existing disc-header behavior unchanged.
  A work header is double-click-to-play (#55, reversing #47's "no new
  interactivity" deferral): starts the whole Work from its first movement;
  ⌥-double-click adds it to Up Next instead. Disc headers stay inert — only
  a header carrying a Work identity is actionable — and headers remain
  unselectable either way. Movement ordering/track resolution is shared with
  the context menu's Work submenu (`resolveWorkTracks`, #48) so the two can
  never disagree.
- Dense row height; right-aligned monospaced-digit time; edge-to-edge stripes.
- Double-click (or ⏎) plays the row and sets the queue from the current view;
  **⌥-double-click queues it next**.
- Context menu: Play, Play Next, Add to Up Next, Add to Playlist ▸ (incl. New
  Playlist…), Add/Remove Favorites, Get Info (read-only sheet — tag editing is
  post-v1; also ⌘I, table-focus-scoped like ⏎/Space rather than a menu-bar
  command, with Caps Lock ignored and only with exactly one row selected —
  #77), Go to Album / Go to Artist (single selection); playlist mode adds
  Move to Top/Up/Down/Bottom + Remove from Playlist. A single selected track
  with native Work metadata also gets a submenu titled with the Work: **Play
  Work** starts at movement 1 and **Add Work to Up Next** queues the complete
  Work. Both actions use the view's underlying tracks ordered by movement
  number (falling back to track number), never the table's current display
  sort; the submenu is absent for multi-selection and tracks without Work.
- Multi-select; drag selected rows to a playlist in the sidebar, or into the
  Up Next queue (position-aware insert; the payload carries the full song).

## Column browser ✅

Above the track table, a horizontal multi-pane browser filtering
**Genre → Artist → Album → Composer** (iTunes pattern, extended with a
Composer pane). Selecting in a left pane narrows the panes to its right and
the track table below. Implemented as adjacent selectable lists; selections
are part of restorable view state. Toggleable (View menu / shortcut) so users
who prefer a plain table can hide it.

## Now Playing panel (Up Next / play queue) ✅

- A trailing pane (`NowPlayingPanel`, 344pt default) hosted **inside the
  detail column, below the toolbar**, as a width-animated `HStack` member —
  deliberately NOT SwiftUI's `.inspector`: the system inspector inserts its
  column into the window's split view at full width before the detail yields
  space, shoving the whole content pane left and briefly pushing the sidebar
  off-screen on every toggle (verified frame-by-frame). Opening below the
  toolbar means the toolbar's layout is never touched by the toggle either —
  NSToolbar item re-layout snaps rather than animates, so any design that
  required the header to reflow looked janky. Motion-analysis verified: the
  pane slides over ~10 frames while the sidebar and toolbar show zero moved
  frames. User-resizable via a grab strip on its leading edge
  (`PanelResizeHandle`, 300–560pt, persisted) — the resize lives entirely
  inside the detail column, so it can't re-trigger the split-view/toolbar
  instability. Remaining trade-off: the hero artwork tops out at the
  toolbar's bottom edge rather than the window top.
  Headerless (closed via the toolbar toggle, the LCD, or ⌘U). Only presentable while something is playing
  or queued — otherwise it stays hidden (no empty state) and its toggles are
  disabled; the stored preference survives, so it reappears when playback
  starts. Contents: a full-bleed square hero artwork flush with
  the panel edges and extending to the window's very top (the panel ignores
  the top safe area — its slice of the toolbar has no items), then
  title/artist/album, a slim scrubber with elapsed/total times, and a
  prominent transport cluster (accent-filled play) flanked by shuffle + repeat
  toggles (accent when active) — all on a 16pt inset shared with the Up Next
  rows. Clicking the hero artwork **Quick Looks** the full-resolution cover
  (staged via `ArtworkCache.originalImageFileURL`, see `05`); the album line
  doubles as a **Show Album in Library** button (⇧⌘L, also in Controls).
- **Queue-first mode (collapsible hero)**: the chevron beside the title
  collapses the hero card to a compact strip — 36pt artwork, title/artist,
  chevron — so Up Next gets nearly the panel's full height (~85% vs ~40%);
  clicking anywhere on the strip restores the full card. The strip lives
  outside the queue `List`, so its tap gesture is safe (the no-tap-gesture
  rule below applies to queue *rows*). Persisted as
  `nowPlayingHeroCollapsed` (`@AppStorage`), like the panel width. While
  collapsed the panel does NOT ignore the top safe area (the strip sits
  below the toolbar, matching the queue-only state); scrubber and transport
  remain reachable in the toolbar LCD.
  Gotcha: expanding swaps the hero in under the mouse, and the click that
  triggered the expansion is *occasionally* re-delivered to the artwork's
  tap gesture, popping Quick Look uninvited (reproduced ~1 in 5 by hand).
  The artwork's Quick Look tap therefore stays disarmed for the first
  400ms after the card appears (`quickLookArmed`).
- Below, the **Up Next** queue: **reorderable** by drag (`.onMove`),
  hover-to-remove, "play from here" via a hover play button on the artwork
  (and the context menu), clear upcoming. Edits mutate `PlayerModel.queue`;
  gapless pre-buffer target updates accordingly (see `03`).
  Gotcha: rows must NOT carry `.contentShape`/tap gestures — they claim the
  mouse-down and silently disable the List's row-drag reordering.

## Now-playing toolbar ✅

- Transport (prev / accent play circle / next) at the leading edge; a centered
  "LCD" capsule with cached artwork (see `05`), centered title and
  artist — album, elapsed/total time, and a hairline accent progress bar along
  its bottom edge; volume + panel toggle trailing. Clicking the LCD (or the
  trailing toolbar button, or ⌘U) toggles the Now Playing panel.

## MenuBarExtra Now Playing panel ✅

- `MenuBarExtra` with **`.menuBarExtraStyle(.window)`** dropping a compact
  panel modeled on the modern macOS Music / Control Center Now Playing dropdown
  (this replaces the old iTunes MiniPlayer):
  - Large artwork, title/artist, the inspector's slim accent scrubber with
    elapsed/total times, and its transport row (accent play circle flanked by
    shuffle + repeat toggles).
  - ⏳ Pending: volume + output-device quick-switch (output device lives in
    Settings → Playback for now).
- Observes the same `PlayerModel` instance as the main window (shared via the
  environment) so it never drifts. Works while the main window is closed.

## Global search ✅

- A search field pinned at the top of the sidebar (`.searchable(placement:
  .sidebar)`), calling `search3` with debounce + task cancellation (see `02`).
  Previous results stay visible while the next query runs (no spinner flash).
- Results: an Artists shelf (name buttons, no artwork — #61) and an Albums
  shelf (covers, same cell as Favorites) that open the regular artist/album
  screens in place, above the songs in the shared `TrackTableView` (stripes,
  double-click-to-play, context menu, favorites, now-playing indicator).

## Navigation (no stack) ✅

- The app deliberately has **no `NavigationStack`** — no push/pop and no
  toolbar back/forward chrome. `Navigator` (environment observable) holds the
  in-place state: an opened album renders over the current section with an
  inline accent "‹ Back" link; switching sections or editing the search query
  closes it.
- **Re-selecting the current sidebar row also closes it** (the iOS
  tap-current-tab-pops convention; Music/Photos behave the same). The
  selection binding is silent when the value doesn't change, and row-level
  tap gestures swallow the backing table's primary clicks (the Up Next
  gotcha's sibling — clicking rows stopped selecting them), so the sidebar
  detects re-clicks with `ListReselectMonitor`: a local mouse-down monitor
  that hit-tests the List's `NSTableView` and passes every event through
  untouched.
- Artists is a master-detail split (artist list left, albums right); search
  hands an artist off via `Navigator.pendingArtist` (selects it in the Artists
  section and clears the query). The list is user-resizable via a grab strip
  on its trailing edge (`PanelResizeHandle`, 180–360pt, persisted) — the same
  component the Now Playing panel uses, generalized with an `anchoredEdge`
  parameter since this list is anchored to the leading edge of the window
  (grows on a rightward drag) rather than the trailing edge (grows on a
  leftward drag).
  The artist list remembers its top-visible artist ID independently of the
  selected artist and the right-hand album grid. Back and relaunch restore
  it once after rows load; the first row stays at the top and a removed ID
  is ignored. `ListScrollMemory` bridges the native List's backing table to
  `Binding.scrollMemory` because `scrollPosition(id:)` does not track this
  macOS List. Native selection, keyboard handling, and resizing are unchanged.
- ⌘F focuses search.

## Menus & keyboard shortcuts ✅ (as implemented)

Menu bar via `Commands` (`HydrophoneCommands`):

- **File:** New Playlist… (⌘N, replaces New Window — like Music), routed to
  the sidebar's New Playlist prompt via `AppModel.requestNewPlaylist()`;
  Update Server Library (triggers a server-side `startScan`).
- **Controls:** Play/Pause (Space), Next (⌘→), Previous (⌘←),
  Increase/Decrease Volume (⌘↑/⌘↓), Add/Remove Favorites for the current
  track (⌘L, title reflects its starred state), Show Album in Library (⇧⌘L),
  Repeat (Off/All/One picker), Shuffle toggle — playback items disabled when
  nothing is loaded.
- **Focus routing:** the shared AppKit track table forwards Space explicitly
  while preserving native letter type-select. SwiftUI Lists that otherwise
  consume Space (Artists, every column-browser pane, and Up Next) handle it at
  the List boundary; search/text fields still type literal spaces. Up Next row
  gestures remain forbidden so drag reorder continues to own mouse-down.
- **View:** Show Now Playing (⌘U, disabled when nothing plays/queued), Show
  Column Browser (⌥⌘B), plus the standard sidebar toggle.
- **Find:** ⌘F focuses the sidebar search field (a hidden button —
  `.searchable` has no command-level focus hook).
- **Edit / Window / Help:** system defaults; the Window menu additionally
  lists "Hydrophone" (from the `Window` scene) to reopen the closed main
  window.

## Liquid Glass & appearance ✅

- Use **standard SwiftUI controls and materials** (`.background(.regularMaterial)`,
  system control styles, `NavigationSplitView`, `Table`, toolbars) so the UI
  **automatically adopts Liquid Glass on macOS 26** while staying clean and
  native on Sequoia.
- **Do not hard-depend on Tahoe-only APIs.** Guard any with
  `if #available(macOS 26, *)` and provide a Sequoia fallback.
- Respect Light/Dark automatically; no hardcoded colors — use semantic/system
  colors and materials.

## Accessibility ✅ (semantics verified via the AX API)

- **VoiceOver** labels on icon-only controls are in place; the custom
  `SlimSlider` exposes a spoken value ("1:23 of 4:05" for scrubbers, percent
  for volume) and increment/decrement adjustable actions; the track table's
  favorite buttons expose state-aware labels ("Add to/Remove from
  Favorites"). Verified by walking the app's AX tree.
- Remaining by hand: a full VoiceOver listening pass, increased-contrast and
  reduce-transparency spot checks (no hardcoded colors anywhere, so risk is
  low).
- **Dynamic Type**: use text styles, avoid fixed font sizes; verify table/
  header reflow.
- **Increased contrast** and **reduce transparency/motion** honored (don't
  fight `accessibilityReduceTransparency`).
- **Full keyboard navigation**: every action reachable without the mouse;
  logical focus order; visible focus ring.

## Drag-and-drop ✅

- Drag rows → playlists / Up Next (internal).
- Accept audio files dropped on the window/dock to **enqueue** — but note v1 is
  streaming-only/server-backed, so local-file drops are matched to server items
  where possible or flagged as unsupported (decide in M? ; see `06`). ⏳ for
  full local-file playback.
