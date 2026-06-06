import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NoteWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()

        // Phase 1: one hardcoded note. Phase 2 replaces this with NoteStore.
        let controller = NoteWindowController(
            frame: NSRect(x: 400, y: 400, width: 280, height: 220),
            color: .yellow)
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true   // Phase 1 only; the real app is a status-item app and keeps running
    }

    // MARK: - Menu
    // The final app is LSUIElement; the main menu still provides the standard
    // Edit key equivalents, which work regardless of menu-bar visibility.

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SpaceNote",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "SpaceNote"))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Note",
                         action: #selector(closeKeyNote(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, title: "File"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu, title: "Edit"))

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func closeKeyNote(_ sender: Any?) {
        // Borderless windows lack .closable, so performClose(_:) would beep.
        NSApp.keyWindow?.close()
    }
}
