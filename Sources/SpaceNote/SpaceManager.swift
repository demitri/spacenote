import AppKit

/// Orchestrates space behavior (PLAN.md §1): launch placement via A′ writes,
/// derived re-stamping on space/window events, explicit bring-here moves.
final class SpaceManager {
    let tracker = SpaceTracker()
    private let controllersProvider: () -> [NoteWindowController]
    /// Gates re-stamping while launch placement is mid-flight: the moves echo
    /// activeSpaceDidChange, and stamping from that half-moved reality would
    /// corrupt the layout.
    private var placementInFlight = false

    init(controllersProvider: @escaping () -> [NoteWindowController]) {
        self.controllersProvider = controllersProvider

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restampAll() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restampAll() }

        // Display topology changes invalidate display identifiers, current
        // spaces, and ordinal resolution.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restampAll() }

        // Catches drags between desktops (incl. inside Mission Control, which
        // can end with no space-change notification at all — PLAN.md §1).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  let controller = self.controller(for: window) else { return }
            self.restamp(controller)
        }
    }

    private func controller(for window: NSWindow) -> NoteWindowController? {
        controllersProvider().first { $0.window === window }
    }

    // MARK: - Launch placement (Strategy A′)

    /// Orders all note windows front (never key — moving the key window of the
    /// active app drags the user's desktop along, Phase 0 fact) and moves each
    /// stamped note to its resolved space, readback-verified. Foreign-space
    /// notes are placed at alpha 0 to avoid a flash on the launch space.
    func performLaunchPlacement() {
        tracker.refresh()
        let controllers = controllersProvider()

        guard tracker.readsAvailable else {        // degraded: stock Stickies behavior
            controllers.forEach { $0.window?.orderFront(nil) }
            return
        }

        placementInFlight = true
        var pendingMoves: [(NoteWindowController, SpaceInfo)] = []

        for controller in controllers {
            let note = controller.note
            let target = tracker.snapshot.resolve(spaceUUID: note.spaceUUID,
                                                  displayIdentifier: note.displayIdentifier,
                                                  desktopOrdinal: note.desktopOrdinal)
            if let target,
               !tracker.snapshot.currentSpaceIDs.contains(target.id64),
               tracker.writesAvailable {
                controller.window?.alphaValue = 0
                // A .floating-level window can't be moved across Spaces by CGS —
                // the move silently no-ops (observed: a floating note "wanted 4"
                // but stayed on 5). Drop to .normal for the move; float is
                // restored after verification. Without this the move "fails" and
                // (pre-fix) froze the whole write tier.
                if note.isFloating { controller.window?.level = .normal }
                pendingMoves.append((controller, target))
            } else if note.spaceUUID != nil, target == nil {
                NSLog("SpaceNote: note \(note.id) was on a desktop that no longer exists — re-homing to the current space")
                // Stamp refreshes from readback below: explicit, logged re-home.
            }
            controller.window?.orderFront(nil)
        }

        // Windows have no space until the WindowServer commits (Phase 0 fact):
        // move on the next runloop turn, verify with retry.
        DispatchQueue.main.async { [self] in
            guard !pendingMoves.isEmpty else {
                placementInFlight = false
                restampAll()   // stamps unstamped and re-homed notes
                return
            }
            for (controller, target) in pendingMoves {
                tracker.moveWindow(controller.window?.windowNumber ?? -1, to: target)
            }
            var remaining = pendingMoves.count
            var failures = 0
            for (controller, target) in pendingMoves {
                verifyMove(of: controller, to: target, attemptsLeft: 2) { [self] success in
                    if !success {
                        NSLog("SpaceNote: placement of note \(controller.note.id) FAILED (wanted \(target.id64))")
                        failures += 1
                    }
                    // Restore float level regardless of move outcome — a floating
                    // window, once on its space, stays there.
                    if controller.note.isFloating { controller.window?.level = .floating }
                    controller.window?.alphaValue = 1   // unconditionally — never leave a window invisible
                    remaining -= 1
                    if remaining == 0 {
                        // Conclude the write TIER is broken only if EVERY move
                        // failed — one note failing must never freeze placement and
                        // restamping for all the others (the cascade bug).
                        if failures == pendingMoves.count {
                            tracker.reportWriteFailure()
                        }
                        placementInFlight = false
                        restampAll()   // also stamps unstamped and re-homed notes
                    }
                }
            }
        }
    }

    /// Readback verification with one retry — a slow WindowServer commit must
    /// not masquerade as a permanently broken write tier.
    private func verifyMove(of controller: NoteWindowController, to target: SpaceInfo,
                            attemptsLeft: Int, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let actual = self.tracker.spaceIDs(forWindow: controller.window?.windowNumber ?? -1)
            if actual == [target.id64] {
                completion(true)
            } else if attemptsLeft > 1 {
                self.verifyMove(of: controller, to: target,
                                attemptsLeft: attemptsLeft - 1, completion: completion)
            } else {
                completion(false)
            }
        }
    }

    // MARK: - Derived stamping (never event-trusted; PLAN.md §1)

    /// Re-derive every live note window's space from CGS readback. Stamps are
    /// only ever written from observed reality, and only while writes work —
    /// in fallback mode reality can't honor stamps, so they stay frozen.
    func restampAll() {
        guard !placementInFlight, tracker.readsAvailable, tracker.writesAvailable else { return }
        tracker.refresh()
        controllersProvider().forEach { restamp($0) }
    }

    private func restamp(_ controller: NoteWindowController) {
        guard !placementInFlight, tracker.writesAvailable else { return }
        // Float-on-top notes are pinned by their stamp + launch placement, not by
        // drag-readback. A floating (.floating-level) window can't be dragged
        // across Spaces — macOS snaps it back — and that fight emits a storm of
        // move/space-change notifications. Restamping from that half-moved reality
        // both flickers and corrupts the saved desktop (ord 4→3→4 churn observed).
        // Their stamp only changes via an explicit toggle-off → drag → toggle-on,
        // when the note is momentarily non-floating and restamps normally.
        guard !controller.note.isFloating else { return }
        guard let windowNumber = controller.window?.windowNumber, windowNumber > 0 else { return }
        let ids = tracker.spaceIDs(forWindow: windowNumber)
        guard ids.count == 1 else {
            // Empty: not yet committed. Multiple: transient mid-transition
            // state. Either way: no basis for changing the persisted stamp.
            if ids.count > 1 {
                NSLog("SpaceNote: window of note \(controller.note.id) on \(ids.count) spaces — stamp unchanged")
            }
            return
        }
        guard let info = tracker.snapshot.space(withID: ids[0]) else {
            // e.g. dragged onto a fullscreen-app space: not note territory.
            NSLog("SpaceNote: note \(controller.note.id) on unmanaged/unknown space \(ids[0]) — stamp unchanged")
            return
        }
        controller.updateStamp(info)
    }

    /// Stamp a just-created note once its window has a committed space.
    func stampNewNote(_ controller: NoteWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.restamp(controller)
        }
    }

    // MARK: - Status-menu support

    /// Refresh the snapshot before menu classification (it may be stale if no
    /// space/screen event fired since the last refresh).
    func refreshSnapshot() {
        tracker.refresh()
    }

    /// Is this note's window on a currently visible space? Empty readback is
    /// treated as local: it only occurs pre-commit, i.e. for windows just
    /// created on the current space.
    func isOnVisibleSpace(_ controller: NoteWindowController) -> Bool {
        guard tracker.readsAvailable else { return true }   // degraded: everything is local
        guard let windowNumber = controller.window?.windowNumber, windowNumber > 0 else { return true }
        let ids = tracker.spaceIDs(forWindow: windowNumber)
        guard !ids.isEmpty else { return true }
        return !tracker.snapshot.currentSpaceIDs.isDisjoint(with: ids)
    }

    /// Desktop ordinal for menu labels ("Desktop 3"), from live readback.
    func desktopOrdinal(of controller: NoteWindowController) -> Int? {
        guard let windowNumber = controller.window?.windowNumber, windowNumber > 0 else { return nil }
        let ids = tracker.spaceIDs(forWindow: windowNumber)
        guard ids.count == 1, let info = tracker.snapshot.space(withID: ids[0]) else { return nil }
        return info.ordinal
    }

    /// Explicit, user-initiated relocation to the current space (the status
    /// menu's "bring here" — never an implicit side effect of focusing).
    ///
    /// Order matters: move first, focus only after readback settles. Focusing
    /// a foreign-space window makes it key, and macOS follows the key window's
    /// space — focus-then-move can teleport the user to the note's OLD desktop
    /// while the note departs it (the Phase 0 sharp edge, PLAN.md §7).
    func bringToCurrentSpace(_ controller: NoteWindowController) {
        guard tracker.readsAvailable, tracker.writesAvailable,
              let windowNumber = controller.window?.windowNumber, windowNumber > 0 else {
            controller.focus()   // degraded mode: the note is on the current space anyway
            return
        }
        tracker.refresh()
        // The note keeps its display: prefer the current space whose display
        // matches; otherwise the first current space.
        let currentSpaces = tracker.snapshot.userSpaces.filter {
            tracker.snapshot.currentSpaceIDs.contains($0.id64)
        }
        guard let target = currentSpaces.first(where: {
            $0.displayIdentifier == controller.note.displayIdentifier
        }) ?? currentSpaces.first else {
            NSLog("SpaceNote: bring-here found no current user space — focusing in place")
            controller.focus()
            return
        }
        if tracker.spaceIDs(forWindow: windowNumber) == [target.id64] {
            controller.focus()   // already here
            return
        }
        placementInFlight = true   // gate restamps against the move's notification echoes
        // Floating windows can't be CGS-moved; drop to .normal for the move and
        // restore after (same as launch placement).
        let wasFloating = controller.note.isFloating
        if wasFloating { controller.window?.level = .normal }
        tracker.moveWindow(windowNumber, to: target)
        verifyMove(of: controller, to: target, attemptsLeft: 2) { [weak self] success in
            guard let self else { return }
            self.placementInFlight = false
            if wasFloating { controller.window?.level = .floating }
            if success {
                // Stamp directly from the known target: this is an explicit CGS
                // move (works even for floating notes, which restamp() skips).
                controller.updateStamp(target)
            } else {
                NSLog("SpaceNote: bring-here of note \(controller.note.id) FAILED")
                self.tracker.reportWriteFailure()
            }
            controller.focus()
        }
    }
}
