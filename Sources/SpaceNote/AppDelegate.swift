import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()
    private(set) var controllers: [NoteWindowController] = []
    private var statusItemController: StatusItemController?
    private(set) lazy var spaceManager = SpaceManager { [unowned self] in self.controllers }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        statusItemController = StatusItemController(appDelegate: self)

        let loaded = store.loadAll()
        if loaded.isEmpty {
            newNote(nil)   // first launch: seed one note (current space, focused)
        } else {
            for (note, text) in loaded {
                addController(note: note, text: text)
            }
            // No NSApp.activate, no makeKey: placement must happen on non-key
            // windows or it drags the user's desktop along (Phase 0 fact).
            spaceManager.performLaunchPlacement()
        }
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
        controllers.append(controller)
        return controller
    }

    @objc func newNote(_ sender: Any?) {
        let note = store.create(frame: nextNoteFrame(), color: .yellow)
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

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
