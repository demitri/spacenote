import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()
    private(set) var controllers: [NoteWindowController] = []
    private var statusItemController: StatusItemController?
    private(set) lazy var spaceManager = SpaceManager { [unowned self] in self.controllers }

    func applicationDidFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
        NSApp.mainMenu = buildMainMenu()
        statusItemController = StatusItemController(appDelegate: self)

        let loaded = store.loadAll()
        if loaded.isEmpty {
            newNote(nil)   // first launch: seed one note (current space, focused)
        } else {
            for (note, text) in loaded {
                addController(note: note, text: text)
            }
            normalizeDesktopLabels()   // clear any pre-existing duplicate labels
            // No NSApp.activate, no makeKey: placement must happen on non-key
            // windows or it drags the user's desktop along (Phase 0 fact).
            spaceManager.performLaunchPlacement()
        }
    }

    /// Two instances (e.g. dist/ copy + installed copy — Launch Services only
    /// dedupes per bundle *path*, not per bundle id) would fight over one data
    /// directory and double every note window. Defer to the older instance.
    private func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }   // bare `swift run`
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return }
        NSLog("SpaceNote: another instance is already running (pid \(existing.processIdentifier), \(existing.bundleURL?.path ?? "?")) — quitting this one")
        existing.activate()
        NSApp.terminate(nil)   // store untouched: nothing loaded or dirty yet
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // status-item app: closing the last note keeps us running
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Note management

    @discardableResult
    private func addController(note: Note, text: NSAttributedString?) -> NoteWindowController {
        let controller = NoteWindowController(note: note, text: text, store: store)
        controller.onDeleted = { [weak self] id in
            self?.controllers.removeAll { $0.noteID == id }
        }
        controller.onToggleDesktopLabel = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.toggleDesktopLabel(controller)
        }
        controller.onDesktopChangedWhileLabel = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.enforceUniqueLabel(for: controller)
        }
        controllers.append(controller)
        return controller
    }

    /// Toggle the note's desktop-label flag, enforcing one label per desktop.
    private func toggleDesktopLabel(_ controller: NoteWindowController) {
        let turnOn = !controller.note.isDesktopLabel
        controller.applyDesktopLabel(turnOn)
        if turnOn { enforceUniqueLabel(for: controller) }
    }

    /// Clear the desktop-label flag on every OTHER note sharing this controller's
    /// desktop — the given controller wins. Called on explicit toggle-on AND
    /// whenever a label note's desktop changes (moved via Mission Control, or
    /// stamped after being labeled while unstamped), so uniqueness can't silently
    /// break after the fact (codex review).
    private func enforceUniqueLabel(for controller: NoteWindowController) {
        guard controller.note.isDesktopLabel else { return }
        let key = desktopKey(controller.note)
        for other in controllers where other !== controller
            && other.note.isDesktopLabel && desktopKey(other.note) == key {
            other.applyDesktopLabel(false)
        }
    }

    /// One-shot cleanup of pre-existing duplicate labels (e.g. older data): per
    /// desktop keep the first label note, clear the rest. Runs at launch.
    private func normalizeDesktopLabels() {
        var seen = Set<String>()
        for controller in controllers where controller.note.isDesktopLabel {
            let key = desktopKey(controller.note)
            if seen.contains(key) {
                NSLog("SpaceNote: duplicate desktop label on \(key) — clearing extra \(controller.noteID)")
                controller.applyDesktopLabel(false)
            } else {
                seen.insert(key)
            }
        }
    }

    /// Identity of a note's desktop, for the one-label-per-desktop rule. Prefers
    /// the stable uuid; falls back to (display, ordinal) when uuid is empty (the
    /// primary desktop reports an empty uuid). nil-stamped notes group together.
    private func desktopKey(_ note: Note) -> String {
        if let uuid = note.spaceUUID, !uuid.isEmpty { return "uuid:\(uuid)" }
        return "disp:\(note.displayIdentifier ?? "?"):ord:\(note.desktopOrdinal ?? -1)"
    }

    /// Jump to a labeled desktop by focusing its label note — macOS follows the
    /// key window to its Space (verified independent of the Mission Control
    /// "switch to a Space with open windows" setting). Switches silently.
    @objc func goToDesktop(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let controller = controllers.first(where: { $0.noteID == id }) else { return }
        controller.focus()
    }

    @objc func newNote(_ sender: Any?) {
        let note = store.create(frame: nextNoteFrame(), color: .preset(.yellow))
        let controller = addController(note: note, text: nil)
        controller.focus()
        spaceManager.stampNewNote(controller)
    }

    @objc func focusNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let controller = controllers.first(where: { $0.noteID == id }) else { return }
        controller.focus()
    }

    @objc func bringNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let controller = controllers.first(where: { $0.noteID == id }) else { return }
        spaceManager.bringToCurrentSpace(controller)
    }

    /// Login item toggle (PLAN.md §4). Only offered when running as a bundle;
    /// errors and the requires-approval state surface in the UI, never
    /// pretended away.
    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func closeKeyNote(_ sender: Any?) {
        guard let key = NSApp.keyWindow,
              let controller = controllers.first(where: { $0.window === key }) else { return }
        controller.requestClose()   // routes through delete-confirmation
    }

    /// Cascade new notes from the top-left of the screen with the key window
    /// (or the main screen), like Stickies.
    private func nextNoteFrame() -> CGRect {
        let size = NSSize(width: 280, height: 220)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(controllers.count % 10) * 24
        return NSRect(x: visible.minX + 40 + offset,
                      y: visible.maxY - 40 - size.height - offset,
                      width: size.width, height: size.height)
    }

    // MARK: - Main menu
    // The app will be LSUIElement once bundled (Phase 4); the main menu still
    // provides the standard key equivalents, which work without a visible menu bar.

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SpaceNote",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "SpaceNote"))

        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New Note",
                                 action: #selector(newNote(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        let closeItem = NSMenuItem(title: "Close Note",
                                   action: #selector(closeKeyNote(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)
        main.addItem(submenu(fileMenu, title: "File"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let fonts = NSMenuItem(title: "Show Fonts…",
                               action: #selector(NSFontManager.orderFrontFontPanel(_:)),
                               keyEquivalent: "t")
        fonts.target = NSFontManager.shared
        editMenu.addItem(fonts)
        main.addItem(submenu(editMenu, title: "Edit"))

        // Format menu: the toolbar toggle lives here so its ⌘⇧T shortcut is
        // discoverable (PLAN.md §9). Title swaps Show/Hide for the key note.
        let formatMenu = NSMenu(title: "Format")
        formatMenu.delegate = self
        let toolbarItem = NSMenuItem(title: "Show Toolbar",
                                     action: #selector(toggleKeyNoteToolbar(_:)), keyEquivalent: "t")
        toolbarItem.keyEquivalentModifierMask = [.command, .shift]
        toolbarItem.target = self
        formatMenu.addItem(toolbarItem)
        main.addItem(submenu(formatMenu, title: "Format"))

        return main
    }

    private func keyNoteController() -> NoteWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return controllers.first { $0.window === key }
    }

    @objc private func toggleKeyNoteToolbar(_ sender: Any?) {
        guard let controller = keyNoteController() else { return }
        controller.setToolbarShown(!controller.note.showsToolbar)
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Keeps the Format-menu toolbar item's title in sync with the key note, and
    /// disables it when no note is key.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.action == #selector(toggleKeyNoteToolbar(_:)) }) else { return }
        if let controller = keyNoteController() {
            item.title = controller.note.showsToolbar ? "Hide Toolbar" : "Show Toolbar"
            item.isEnabled = true
        } else {
            item.title = "Show Toolbar"
            item.isEnabled = false
        }
    }
}
