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
                pendingMoves.append((controller, target))
            } else if note.spaceUUID != nil, target == nil {
                NSLog("SpaceNote: note \(note.id) was on a desktop that no longer exists — re-homing to the current space")
                // Stamp refreshes from readback below: explicit, logged re-home.
            }
            controller.window?.orderFront(nil)
        }

        // Windows have no space until the WindowServer commits (Phase 0 fact):
        // move on the next runloop turn, verify a beat later.
        DispatchQueue.main.async { [self] in
            for (controller, target) in pendingMoves {
                tracker.moveWindow(controller.window?.windowNumber ?? -1, to: target)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                for (controller, target) in pendingMoves {
                    let actual = tracker.spaceIDs(forWindow: controller.window?.windowNumber ?? -1)
                    if actual != [target.id64] {
                        NSLog("SpaceNote: placement of note \(controller.note.id) FAILED (wanted \(target.id64), got \(actual))")
                        tracker.reportWriteFailure()
                    }
                    controller.window?.alphaValue = 1   // unconditionally — never leave a window invisible
                }
                placementInFlight = false
                restampAll()   // also stamps unstamped and re-homed notes
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

    /// Is this note's window on a currently visible space?
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
    func bringToCurrentSpace(_ controller: NoteWindowController) {
        defer { controller.focus() }
        guard tracker.readsAvailable, tracker.writesAvailable,
              let windowNumber = controller.window?.windowNumber, windowNumber > 0 else { return }
        tracker.refresh()
        // The note keeps its display: prefer the current space whose display
        // matches; otherwise the first current space.
        let currentSpaces = tracker.snapshot.userSpaces.filter {
            tracker.snapshot.currentSpaceIDs.contains($0.id64)
        }
        guard let target = currentSpaces.first(where: {
            $0.displayIdentifier == controller.note.displayIdentifier
        }) ?? currentSpaces.first else { return }
        tracker.moveWindow(windowNumber, to: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let actual = self.tracker.spaceIDs(forWindow: windowNumber)
            if actual != [target.id64] {
                NSLog("SpaceNote: bring-here of note \(controller.note.id) FAILED (got \(actual))")
                self.tracker.reportWriteFailure()
            }
            self.restamp(controller)
        }
    }
}
