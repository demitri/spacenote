# SpaceNote — Implementation Plan

A minimal Stickies-style notes app for macOS whose distinguishing feature is **per-Space
persistence**: each note remembers which Mission Control Space (desktop) it lives on and
reappears there after app relaunch / reboot, instead of piling up on the current Space
the way Apple's Stickies does.

Target: macOS 26.5 (Tahoe), Apple Silicon, personal use (not App Store, not sandboxed).
Language: Swift 6, AppKit (programmatic, no storyboards/xibs).

---

## 1. The core problem: Spaces

macOS has **no public API** to (a) identify the current Space, (b) enumerate Spaces, or
(c) place a window on a non-current Space. The Dock's "Assign To Desktop" is per-app
only. So:

### Strategy A (primary): lazy materialization with read-only private API

Never *move* a window to another Space — only ever **show windows on the current Space**,
which requires no special privileges. Concretely:

1. Each note persists a `spaceUUID` (see "Space identity" below).
2. A `SpaceTracker` component subscribes to
   `NSWorkspace.shared.notificationCenter` → `NSWorkspace.activeSpaceDidChangeNotification`
   (plus `NSApplication.didChangeScreenParametersNotification` for display changes).
3. On launch and on every space-change event, it computes the set of **currently visible
   Space UUIDs** (one per display) and the `NoteStore` orders in exactly the note windows
   whose `spaceUUID` is in that set; all others are ordered out (`orderOut(_:)`, windows
   kept alive, never released).
4. **Stamping is derived, not event-trusted.** On every space-change event, on
   `orderFront`/`didBecomeKey`, app (re)activation, and at the end of any window drag,
   the tracker re-derives the actual space of **every live note window that has a valid
   window number — not just visibly on-screen ones** — via `CGSCopySpacesForWindows`
   (queried one window at a time — the call returns a flat array, so multi-window calls
   can't be attributed; empty result for an ordered-out window → keep the persisted
   stamp) and re-stamps notes whose space changed. This catches the cases drag events
   miss: dragging a note between desktops **inside Mission Control**, edge-drag
   transitions, and restoration races. Note the nastiest case: an MC drag that ends back
   on the *same* space fires **no** `activeSpaceDidChange` at all — hence the
   app-activation trigger plus a structural guard:
5. **Verify before evict.** The tracker never orders out a window whose CGS readback
   says it is currently on a visible space, regardless of what its persisted stamp
   claims. Stale stamps can therefore cause at worst a missed hide, never the
   note-vanishes-from-where-the-user-put-it failure.

Space queries use **private SkyLight (CGS) functions**, read-only tier only:

```c
typedef int      CGSConnectionID;
typedef uint64_t CGSSpaceID;        // 64-bit; matches the dicts' id64
CGSConnectionID CGSMainConnectionID(void);
CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);     // per-display dicts
// Returns a FLAT array of space IDs for the given windows (no per-window attribution
// when multiple windows are passed) — always call with a single window number.
CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef windowIDs);
```

Symbols resolved at runtime via `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", ...)`
+ `dlsym` (primary path, not fallback — avoids SwiftPM private-framework link friction
and degrades cleanly if a symbol vanishes in a future macOS).

- `CGSCopyManagedDisplaySpaces` returns, per display: `"Display Identifier"`,
  `"Current Space"` (dict with `id64`, `uuid`, `type`), and `"Spaces"` (array of same).
  This is the same call WhichSpace-style menu-bar indicators use; it works unprivileged,
  no SIP changes, no Dock injection.
- `CGSCopySpacesForWindows` maps one of our window numbers → its space ID, used for the
  derived stamping above (more reliable than assuming "active space" when multiple
  displays are involved).

**Space identity across reboots:** the numeric `CGSSpaceID` (`id64`) is *not* guaranteed
stable across logout/reboot. The space dictionaries also carry a `uuid` string which is
persisted by the system in `com.apple.spaces` and is stable for user-created desktop
spaces in practice — but treat this as a **heuristic, not a contract**. Persist a
resolution tuple per note: `(uuid, displayIdentifier, desktopOrdinal)` where
`desktopOrdinal` is the space's index among user desktop spaces on its display. Resolve
at runtime in that priority order; `id64` is logged for diagnostics only. Known caveats:
the primary/default desktop on each display may report an **empty uuid** (the ordinal
covers it), and `"Display Identifier"` can be the literal `"Main"` or change with
display topology — the ordinal is the tiebreaker, and mismatches resolve to "current
space + re-stamp + log", never to a hidden note. Fullscreen-app spaces (`type != 0`)
are ignored — notes don't belong on those.

**Failure mode:** if the CGS calls ever break in a future macOS, degrade explicitly:
log loudly, show all notes on the current space (stock Stickies behavior), never
silently drop notes. A note whose persisted `spaceUUID` no longer exists (user deleted
the desktop) is surfaced on the current space and re-stamped, not hidden forever.

### Strategy B (Phase-0 experiment, could replace A): system window restoration

The WindowServer restores Space assignments for windows that participate in **Resume /
`NSWindowRestoration`** across logout-with-"reopen-windows" (this is why Terminal windows
sometimes land back on their Spaces). Apple's Stickies bypasses Resume with its own
persistence, which is plausibly *why* it has this bug. Before committing to Strategy A,
run a 30-minute experiment: a minimal app with the **full** restoration checklist —
unique `window.identifier`, `restorationClass` conforming to `NSWindowRestoration`,
`window.isRestorable = true`, `setFrameAutosaveName`, and
`applicationSupportsSecureRestorableState(_:) -> true` — across a logout/login and a
reboot.

- If Spaces come back reliably → adopt B for *placement*, but the SpaceTracker does not
  vanish: restoration only runs on system-initiated relaunch. Manual launches, login-item
  launches via `SMAppService`, and the user's "close windows when quitting" setting all
  bypass or race AppKit restoration, and NoteStore must not pre-create windows before
  restoration has had its chance. B reduces A's job; it doesn't eliminate it.
- Expectation: ~50/50. Resume-across-reboot space fidelity has varied across macOS
  releases and is undocumented; must be tested on this exact build (26.5.1).
- Decision rule: B must survive **2 consecutive reboots with 3 spaces** to be adopted;
  otherwise A.

### Strategy A′ (Phase-0 experiment): write-tier placement of our OWN windows

The hard "requires yabai-style Dock injection with SIP disabled" restriction is firmly
established for moving *other apps'* windows. Whether `CGSAddWindowsToSpaces` /
`CGSRemoveWindowsFromSpaces` / `CGSMoveWindowsToManagedSpace` still work unprivileged
for a process's **own** windows on Tahoe is unsettled — reports conflict across recent
macOS versions. Phase 0 tests this empirically. If own-window writes work, prefer A′
over A's show/hide: notes get *real* placement (visible in Mission Control on their
spaces, no materialize-on-visit quirk), and lazy materialization remains the documented
fallback. If they fail (likely silently — verify via `CGSCopySpacesForWindows` readback,
never assume), A stands.

Signatures to test in the spike (treat as hypotheses — verifying/correcting them against
the live SkyLight symbol table via `dlsym` + behavior is itself a spike task, so a wrong
guess reads as "signature wrong", not "API restricted"):

```c
void CGSAddWindowsToSpaces(CGSConnectionID cid, CFArrayRef windowIDs, CFArrayRef spaceIDs);
void CGSRemoveWindowsFromSpaces(CGSConnectionID cid, CFArrayRef windowIDs, CFArrayRef spaceIDs);
void CGSMoveWindowsToManagedSpace(CGSConnectionID cid, CFArrayRef windowIDs, CGSSpaceID spaceID);
```

### Strategy C (rejected): moving other applications' windows

Genuinely requires scripting-addition injection + SIP changes. Not our use case.

---

## 2. Note windows (the chrome)

`StickyWindow: NSWindow` (plain `NSWindow`, **not** `NSPanel` — once non-activating
behavior is off the table, panel semantics (deactivation hiding, Esc/cancel handling,
floating-by-default) are all things to counteract, not features):

- `styleMask: [.borderless, .resizable]` — borderless windows still get live
  edge-resizing with cursors when `.resizable` is set.
- **Must override `canBecomeKey` (and `canBecomeMain`) → `true`** — borderless windows
  refuse key status by default, which would make the text view uneditable.
- Normal app activation on click. LSUIElement sharp edge: when showing/focusing a note
  programmatically (status menu, new-note shortcut), call
  `NSApp.activate(ignoringOtherApps: true)` explicitly, and implement
  `acceptsFirstMouse(for:) -> true` on the strip and body so the first click on an
  inactive note both activates and acts — otherwise controls feel intermittently dead.
- `contentMinSize ≈ 60×30` — resizable down to nearly nothing, like Stickies.
- `isOpaque = false`, `hasShadow = true`, `backgroundColor = .clear`; the content view
  draws the note.
- `hidesOnDeactivate = false`; `collectionBehavior` default (notes must NOT join all
  spaces; that's the antithesis of the app).
- `animationBehavior = .none` (snappy), `isReleasedWhenClosed = false` (we own lifetime).

Content layout (all custom-drawn, no system titlebar):

- **Title strip**: ~14 pt tall band across the top, note color darkened ~8%. Hover
  reveals: close box (left), collapse triangle (right). Drag anywhere on the strip →
  `window.performDrag(with:)`. Double-click → collapse (window shrinks to strip height,
  previous frame remembered). This mirrors Stickies exactly.
- **Body**: `NSTextView` in a borderless `NSScrollView` (scroller `.overlay`, hidden
  until needed). Rich text on — fonts, styled runs, link *storage* come free; link
  detection, font-panel wiring, and list editing each need explicit (small) AppKit
  hookup and land in Phase 4. v1 is text-only: RTF does not carry image attachments
  (that's RTFD/file-wrapper territory — explicitly out of scope, documented here, not
  silently dropped at paste time: pasted images are rejected with a beep).
- **Translucency** (per-note toggle): body alpha ~0.85 via layer opacity on the colored
  background view. v1 uses plain alpha-translucency (true Stickies look); an
  `NSVisualEffectView` blur variant is a possible later option, not in v1.
- **Float on top** (per-note toggle): `window.level = .floating` vs `.normal`.
- **Colors**: classic six as an enum:

```swift
enum NoteColor: String, Codable, CaseIterable { case yellow, blue, green, pink, purple, gray }
```

Each maps to (background, strip, selection) `NSColor` triples tuned for both light and
dark appearance.

---

## 3. Data model & persistence

```swift
struct Note: Identifiable, Codable {
    let id: UUID
    var rtfFilename: String        // content stored as sibling .rtf
    var color: NoteColor
    var frame: CGRect              // also keep collapsed state + expanded height
    var isCollapsed: Bool
    var isTranslucent: Bool
    var isFloating: Bool
    var spaceUUID: String?         // nil = unstamped (shown on current space)
    var displayIdentifier: String? // resolution tuple, part 2
    var desktopOrdinal: Int?       // resolution tuple, part 3: index among user
                                   // desktop spaces on that display (see §1)
}
```

- Store: `~/Library/Application Support/SpaceNote/` → `manifest.json` (array of `Note`)
  plus one `.rtf` per note. Atomic writes (`Data.write(.atomic)`), debounced autosave
  (~1 s after last text change; immediate on move/resize-end, color change, close,
  app termination).
- RTF via `NSAttributedString` ↔ `NSTextStorage`; no document architecture, no NSDocument.
- Schema versioned (`"version": 1` in manifest) so later migrations are explicit.
- Frame restoration uses `frame` directly but clamps to the current screen arrangement
  (`NSScreen` visible frames) so a note from an unplugged display isn't stranded offscreen.

## 4. App structure

```
SpaceNoteApp (NSApplicationDelegate, LSUIElement=true)
├── StatusItemController      — menu bar icon: New Note, list of notes, per-note flags, Quit
├── NoteStore                 — owns [Note] + [NoteWindowController]; persistence; CRUD
├── SpaceTracker              — CGS wrapper; publishes visibleSpaceUUIDs; stamps notes
└── NoteWindowController      — one per note; StickyWindow + text view; pushes edits to store
```

- **Status-menu note list semantics**: we cannot switch Spaces via public API, so a
  naive "jump to note" would `orderFront` the window onto the *current* space — silently
  relocating it. Rule: notes on a currently visible space get "Focus"; notes on another
  space get an explicit **"Bring to this desktop"** item (which shows + re-stamps —
  intentional relocation), with the menu listing each note's space ordinal for
  orientation. No implicit moves, ever.
- Menu-bar-only app (`LSUIElement`), no Dock icon. Standard Edit-menu key equivalents
  (⌘C/V/X/A/Z…) provided programmatically so text editing shortcuts work in an
  LSUIElement app. ⌘N new note on current space; ⌘W closes (= deletes, with the same
  confirm-if-nonempty sheet Stickies uses).
- Deleting vs. hiding: closing a note deletes it (Stickies semantics). "Hidden because
  on another space" is purely window ordering, invisible to the user model.
- Login item via `SMAppService.mainApp` toggle in the status menu. Requires running as
  the assembled, signed `.app` bundle with stable identity (never the raw SwiftPM
  binary); handle `register()` errors and the `.requiresApproval` status explicitly in
  the menu UI rather than pretending it's on.

## 5. Build & tooling

- **SwiftPM executable target** + `Makefile`/script assembling `SpaceNote.app`
  (copy binary, `Info.plist` with `LSUIElement`, `CFBundleIdentifier`,
  ad-hoc `codesign --force --sign -`). No Xcode project; fully CLI-drivable.
- `Info.plist` kept in repo; bundle id `net.bistromath.spacenote` (stable bundle id +
  signature matters if Strategy B is adopted, since Resume keys off identity).
- Private CGS access via `dlopen`/`dlsym` wrapper (`SpaceTracker` internals); function
  pointer types declared in Swift. No private-framework link flags needed; a missing
  symbol is detected at startup and triggers the loud degraded mode.
- No tests for AppKit chrome (manual); unit tests for: manifest round-trip,
  space-dict parsing (fixture plists captured from the real
  `CGSCopyManagedDisplaySpaces` output), frame-clamping logic.

## 6. Phases

| # | Deliverable | Exit criteria |
|---|-------------|---------------|
| 0 | `spike-spaces` mini-tool: prints per-display space dicts on every space change; logs uuid/id64; survives reboot comparison; tests **own-window** space-write APIs (A′) with readback verification. Also the Strategy-B restoration test app. | Confirmed on 26.5.1: (a) CGS read calls work + dict shape pinned; (b) uuid/ordinal stability across reboot; (c) A′ own-window write verdict; (d) Resume verdict per decision rule |
| 1 | One hardcoded note window with full chrome: strip, drag, resize-to-tiny, collapse, colors, translucency, float | Visual parity with Stickies side-by-side |
| 2 | NoteStore + persistence + status item; multi-note CRUD surviving relaunch | Kill -9 loses ≤1 s of typing; relaunch restores all notes/frames |
| 3 | SpaceTracker + placement (A′ real placement, lazy materialization, or Resume wiring — per Phase 0 verdicts) | 6–8 notes across 4 spaces + reboot → every note on its own space; Mission-Control drag of a note to another space sticks |
| 4 | Polish: login item, Edit menu, fonts panel, screen-arrangement clamping, dark mode pass | Daily-drivable |

## 7. Phase 0 results (2026-06-06, macOS 26.5.1 / 25F80)

Spike: `swift run SpikeSpaces [--dump | --automove]`; log: `spike-spaces.log`.

- **(a) CGS reads: CONFIRMED.** All seven symbols resolve via dlsym. Dict shape as
  planned: per-display `"Display Identifier"` / `"Current Space"` / `"Spaces"`, spaces
  carry `id64`, `uuid`, `type`, `ManagedSpaceID` (== id64 in all observations). Primary
  desktop's `uuid` is the empty string, as predicted — ordinal tuple required.
- **(c) Strategy A′: CONFIRMED WORKING.** Both `CGSMoveWindowsToManagedSpace` and
  `CGSAddWindowsToSpaces`+`CGSRemoveWindowsFromSpaces` move our own window between
  user spaces unprivileged, verified by `CGSCopySpacesForWindows` readback.
  **A′ is the placement strategy.** Lazy materialization (A) remains the coded
  fallback path behind the same `SpacePlacer` interface (readback-verified per move;
  if a write ever no-ops, log loudly and fall back).
- **(d) Strategy B (Resume): MOOT** given (c). The restoration spike will not be built.
- **(b) uuid stability across reboot: PENDING** — baseline dump captured in
  `spike-spaces.log`; re-run `--dump` after next reboot and compare.
- **New facts for the implementation:**
  - A window's space readback is **empty immediately after `orderFront`** — it gets a
    space only after the runloop/WindowServer commits. Always re-query a turn later;
    treat empty readback as "not yet placed", not an error.
  - `activeSpaceDidChangeNotification` fired during A′ moves of the app's own key
    window — moving the key window of the active app can drag the user's desktop along.
    The app must perform launch-time placement while its windows are not key (place
    *before* `makeKey`, or explicitly avoid activating), and must expect/ignore the
    resulting notification echo.

## 8. Risks & open questions

1. **CGS dict shape on Tahoe** — key names (`uuid`, `id64`, `type`, `Current Space`)
   verified only up to recent releases; Phase 0 exists to pin this down. Parser must
   fail loudly on unexpected shape, not skip.
2. **Empty uuid for primary spaces** — handled via the (uuid, displayIdentifier,
   desktopOrdinal) resolution tuple; needs Phase-0 confirmation of what 26.5.1
   actually reports.
3. **"Displays have Separate Spaces" OFF** — changes the managed-display topology;
   v1 assumes ON (default). Detect and warn otherwise rather than misbehave.
4. **Space deletion / reordering by user** — orphaned notes surface on current space
   and re-stamp (explicit, logged). Never invisible.
5. **activeSpaceDidChange timing** — notification can fire before the transition
   animation completes; ordering windows in mid-transition may flash on the old space.
   Mitigation: stamp/show on the *next* runloop turn; verify visually in Phase 3.
6. **Borderless + resizable quirks** — AppKit's edge-resize hit target on borderless
   windows can be tiny/inconsistent, and overlaps the strip-drag zone at corners. Test
   in Phase 1; the named fallback is custom resize tracking (mouse-down zones on a
   transparent border view), which is well-trodden but ~150 lines we'd rather not write.
7. **Mission Control window pickup** (Strategy A only) — ordered-out windows don't
   appear in Mission Control / Exposé for other spaces, and a note "arrives" on first
   visit to its space post-launch. Acceptable quirk; A′, if Phase 0 confirms it, removes
   it entirely.
