# SpaceNote

A minimal Stickies-style notes app for macOS whose distinguishing feature is
**per-desktop persistence**: every note remembers which Mission Control Space
it lives on and reappears there after relaunch or reboot — the thing Apple's
Stickies famously doesn't do.

- Stickies-faithful chrome: thin drag strip, hover close/collapse widgets,
  double-click collapse, resize to tiny, the six classic colors, per-note
  translucency and float-on-top (right-click the strip)
- Menu-bar app (no Dock icon): note list with explicit "Bring to this desktop"
  for notes living elsewhere, ⌘N new note, Start-at-Login toggle
- Rich text (RTF), Gill Sans SemiBold 18 by default, ⌘T font panel
- Storage: `~/Library/Application Support/SpaceNote/` (JSON manifest + RTF per
  note), atomic writes, ≤1 s autosave debounce

## Build & install

```sh
make app      # builds dist/SpaceNote.app (SwiftPM + ad-hoc codesign, no Xcode project)
make install  # copies to ~/Applications (stable path matters for the login item)
```

## How the Space feature works

macOS has no public API for per-window Space placement. SpaceNote uses the
read tier of the private SkyLight (CGS) interface to identify desktops, and
`CGSMoveWindowsToManagedSpace` — which works unprivileged for a process's
*own* windows (verified on macOS 26.5.1) — to place each note at launch,
readback-verified. Notes are stamped with a `(uuid, display, ordinal)` tuple
derived from observed reality, never from trusted events. If the private API
ever breaks, the app degrades loudly to stock-Stickies behavior and freezes
stamps so no layout data is lost. Design history and verified facts: PLAN.md.

`SPACENOTE_FORCE_DEGRADED=1` runs without any private API (for testing).
