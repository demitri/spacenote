# Experiment spec: App Store go/no-go — Strategy B (system window restoration)

**Status:** proposed, not yet run. Intended to be executed in a fresh session.
**Owner question this answers:** Can SpaceNote have an App Store–legal version of
its core feature (per-Space note persistence) at all?

---

## Background (why this experiment exists)

SpaceNote's entire reason to exist is **per-Mission-Control-Space note
persistence**: each note reopens on the desktop (Space) it lived on, across
relaunch and reboot. The shipping app achieves this with **private SkyLight/CGS
APIs** — Strategy A′, `CGSMoveWindowsToManagedSpace`, confirmed working on macOS
26.5.1 (PLAN.md §7c). Private API means **automatic App Store rejection**.

The only App-Store-legal route to the same behavior is **Strategy B**: let
macOS's own window-restoration machinery (Resume / `NSWindowRestoration`) put
windows back on their Spaces, using **zero private API**. PLAN.md §1 describes B;
§7d shelved it *untested* ("MOOT given A′ works"). The premise that B even works
on this OS was never verified — that is the gap this experiment closes.

This is explicitly a **go/no-go feasibility probe**, not a feature build. Budget
~30 minutes of build + a structured test protocol.

## The one question

> On macOS 26.5.1, does a correctly-written **restorable, non-private-API**
> AppKit app get its windows restored to **their original Spaces** across a
> **system restart / logout-login** cycle?

**Critical framing (do not skip).** `NSWindowRestoration` is documented to
restore window *identity, frame, and encoded UI state* — it does **not** document
Mission Control **Space** placement as part of that contract. Observed real-world
behavior (Chromium's macOS code documents this explicitly) splits the two cases:

- **User ⌘Q + manual relaunch** → restored windows typically land on the
  **current/primary Space**, NOT their original one. This is expected and does
  **not** indicate failure of the feature.
- **System restart / logout-login with "reopen windows"** → the OS may restore
  windows to their **prior Spaces**.

Therefore the **reboot/logout test is the sole arbiter** of the go/no-go
question. The quit/relaunch test answers only the prerequisite "does this app
restore window *identity and frame* correctly at all" — a NO there means the
spike is broken; a (Space-wise) NO there is **not** evidence against Strategy B
and must not be reported as such. Designing the experiment so that quit/relaunch
Space behavior could yield a verdict would produce a **false NO-GO**.

A YES on the reboot test makes an App Store version feasible; a NO means the core
feature is private-API-only and the App Store version must be a reduced product
(spell out what's left).

## Constraints (what keeps the experiment honest)

1. **The spike contains NO private API.** No SkyLight, no CGS, nothing dlopen'd
   from PrivateFrameworks *in the app itself*. The whole point is to test what a
   sandboxed, App-Review-passing binary gets for free. A spike that cheats with
   CGS proves nothing.
2. **Observation may use read-only CGS, outside the app.** Measuring *which Space
   a window ended up on* is allowed via the existing read-only helper
   `tools/winspaces.swift` (it only reads window→space mapping; it never writes).
   Reading is not the App Store problem — only writing/placement is. Keep this
   measurement tooling strictly separate from the spike target.
3. **Do not touch the production `SpaceNote` target or its data** (`~/Library/
   Application Support/SpaceNote/`). New SwiftPM target only
   (e.g. `Sources/ResumeSpike/`). Commit the spike on its own.
4. **Must run as a real signed `.app` bundle.** Window restoration keys off
   stable bundle identity; a bare `swift run` binary won't restore. Reuse the
   Makefile bundling + ad-hoc codesign pattern; give it its own bundle id
   (e.g. `net.bistromath.resumespike`) so it can't collide with SpaceNote.
5. **Run the decisive pass SANDBOXED.** Mac App Store apps are *required* to be
   sandboxed (`com.apple.security.app-sandbox`), and sandboxing can itself change
   restoration/container behavior. An ad-hoc, non-sandboxed bundle is fine for a
   first smoke test, but the reboot arbiter must be run at least once with the
   sandbox entitlement enabled and a clean container — otherwise the go/no-go is
   not actually an *App Store* go/no-go. Note: ad-hoc signing (not Developer ID)
   is acceptable for local restoration testing; signing identity is not the
   variable under test, the sandbox is.

## The spike

A minimal standalone app with the **full restoration checklist** (PLAN.md §1
Strategy B), and nothing more:

- A handful (say 3) of plain `NSWindow`s — ordinary titled windows are fine here;
  the borderless note chrome is irrelevant to whether Resume restores Spaces.
  **Give each a distinct, externally visible `title`** (e.g. "Spike-1"…) — the
  measurement tool reads window *titles* to match identity across relaunch (see
  measurement note below); window *numbers* change and cannot be used.
- Each window: unique `window.identifier`, `window.isRestorable = true`,
  `window.restorationClass` conforming to `NSWindowRestoration`,
  `setFrameAutosaveName(<unique>)`.
- App delegate: `applicationSupportsSecureRestorableState(_:) -> true`.
- **Implement the actual restoration path, not just the flags:** the restoration
  class must implement
  `restoreWindow(withIdentifier:state:completionHandler:)` and recreate/return
  the matching window; the window's controller must be **strongly retained** so a
  restored window isn't deallocated. Use `encodeRestorableState(with:)` /
  `restoreState(with:)` to round-trip each window's identity + color.
- **Do NOT pre-create the windows unconditionally at launch.** If the app always
  spawns its 3 windows in `applicationDidFinishLaunching`, AppKit restoration has
  nothing to restore (and you may get duplicates). Let restoration recreate them;
  only spawn fresh windows when there is no saved state (first run). This is the
  same "NoteStore must not pre-create windows before restoration runs" caveat from
  PLAN.md §1, and getting it wrong is the most likely way to get a false NO.
- A regular (Dock) app is the safe default; `LSUIElement` apps have historically
  been less reliable with Resume. Note the choice; if testing the menu-bar variant
  matters, test it *after* the regular one passes.
- Also verify the relevant defaults aren't suppressing persistence
  (`NSQuitAlwaysKeepsWindows`, `ApplePersistenceIgnoreState`) — if a prior
  experiment or dotfile set `ApplePersistenceIgnoreState = YES`, restoration is
  globally disabled and every result is a false NO.

## Test protocol

**Preconditions — verify and record BOTH:**
1. System Settings ▸ Desktop & Dock ▸ "Close windows when quitting an
   application" must be **OFF** — governs app-reopen-after-⌘Q (Test 1).
2. The **logout/restart** "Reopen windows when logging back in" checkbox (shown in
   the restart/shut-down/log-out confirmation dialog) must be **CHECKED** —
   governs window reopening after a restart/login (Test 2, the arbiter). If this
   is unchecked at restart time, nothing reopens and a NO is meaningless.
Record both states with the results.

**Measurement note (must fix the tool first):** `tools/winspaces.swift` currently
prints `window number + space id64 + size` only. That is insufficient here:
window numbers change across relaunch (can't match identity), and `id64` is not
stable across reboot (PLAN.md §1). Before testing, extend the observer (a *copy*,
keep it out of the spike target) to emit **window title → (Space uuid, Space
ordinal, display id)**, keyed on title for cross-relaunch/cross-reboot matching.

**Test 1 — quit/relaunch (agent runs this now; prerequisite check ONLY):**
1. Launch the bundled spike. Drag its 3 titled windows onto **2–3 different
   desktops/Spaces** (create Spaces first if needed).
2. Snapshot title → Space via the extended observer.
3. ⌘Q, then relaunch the bundle.
4. Snapshot again. **What this proves:** that windows restore with correct
   *identity, frame, and encoded state*. **Space placement on manual relaunch is
   EXPECTED to be the current/primary Space, not the original** — do not score
   that as a feature failure (see "The one question"). If identity/frame don't
   restore, the spike is broken — fix before proceeding to Test 2.

**Test 2 — logout/reboot (THE arbiter; staged for the user):**
- The agent cannot reboot. Stage tooling so the user drives it:
  (i) confirm the 3 windows are scattered across Spaces; (ii) capture a "before"
  snapshot (title → Space uuid/ordinal/display) to a log file; (iii) ensure the
  restart dialog's "Reopen windows" box is checked; (iv) **restart** (not just
  re-login of the app — a full system restart is the case that restores Spaces);
  (v) on return, **relaunch nothing manually** — observe what the OS reopened,
  then run the diff command.
- **Pass = each titled window reopens on the Space (by uuid, or ordinal if uuid
  churned) it was on before restart.**
- PLAN.md's adoption rule is **2 consecutive reboots with 3 Spaces** — so a single
  passing reboot is "promising, not adopted." Stage the tooling to be re-runnable
  across two restarts.

## Decision output

A GO/NO-GO verdict **requires the Test 2 (reboot) result** — Test 1 alone can
never produce GO (it doesn't test Space restoration; see "The one question").
Until the user has run the reboot, the honest status is **"PENDING reboot —
prerequisite (identity/frame restoration) confirmed, sandbox pass built."**

When the reboot result is in:

- **GO** — Resume restores Spaces across restart (≥1 reboot passed sandboxed;
  full adoption per PLAN.md still wants 2 consecutive). Then: what adopting B
  *for the App Store build* costs — per PLAN.md §1 the SpaceTracker does **not**
  vanish (manual launch, login-item launch via `SMAppService`, and the
  "close windows when quitting" setting all bypass or race restoration), so
  enumerate exactly what an App-Store SpaceNote would need and what behavior gaps
  remain vs. the A′ build. Also confirm no *other* App Store blocker survives:
  sandbox entitlements the feature needs, login-item consent, no background/
  auto-launch behavior without consent.
- **NO-GO** — Resume does not reliably restore Spaces across restart. Then: the
  core feature is fundamentally private-API-only; describe the **reduced** App
  Store product (e.g. notes that persist content + per-display frame but NOT
  Space, with a manual "this note belongs to the current desktop" affordance that
  can only show/hide, never place) and whether that's worth shipping.

**App Store legality footnotes (so the executing session doesn't over/under-claim):**
- Private API = rejection (App Review 2.5.1), but it is **not the only** gate:
  Mac App Store also mandates the sandbox (2.4.5), login-item consent, and no
  unconsented background launch. A "Resume works" GO is necessary, not sufficient.
- The read-only CGS measurement tool is irrelevant to App Review **only because it
  is never bundled, linked, or shipped** in the submitted app. If any private
  read call lived inside the app, it would violate 2.5.1 just like the writes.
  Keep the observer strictly external.

## Workflow for the executing session

1. Read `PLAN.md` (§1 Strategies, §7 Phase 0 results) first.
2. **Propose** the spike + exact test protocol and wait for confirmation before
   building (don't burn the budget on a misaimed spike).
3. Extend a *copy* of the winspaces observer to emit title → Space uuid/ordinal.
4. Build the spike as its own target + bundle (regular app, real restoration path,
   no unconditional window pre-creation); smoke-test, then rebuild **sandboxed**.
5. Run Test 1 — confirm identity/frame restoration only (NOT a Space verdict).
6. Stage Test 2 tooling + the user's restart steps (incl. both preconditions).
7. After the user's reboot(s): give the GO/NO-GO with cost/fallback spelled out.
   Before then, the verdict is **PENDING reboot** — never GO from Test 1 alone.
