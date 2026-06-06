import AppKit

/// Menu-bar presence: New Note, the note list, Quit. The menu is rebuilt on
/// each open via NSMenuDelegate so titles/swatches stay current.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "note.text",
                                           accessibilityDescription: "SpaceNote")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let newNote = NSMenuItem(title: "New Note",
                                 action: #selector(AppDelegate.newNote(_:)), keyEquivalent: "n")
        newNote.target = appDelegate
        menu.addItem(newNote)

        // Local notes focus; notes on other desktops get an EXPLICIT bring-here
        // section — we can't switch desktops via public API, and focusing a
        // foreign note must never silently relocate it (PLAN.md §4).
        let manager = appDelegate.spaceManager
        let (local, foreign) = appDelegate.controllers.reduce(into: ([NoteWindowController](), [NoteWindowController]())) {
            if manager.isOnVisibleSpace($1) { $0.0.append($1) } else { $0.1.append($1) }
        }

        if !local.isEmpty {
            menu.addItem(.separator())
            for controller in local {
                menu.addItem(noteItem(controller, action: #selector(AppDelegate.focusNote(_:))))
            }
        }
        if !foreign.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Bring to this desktop:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for controller in foreign {
                let item = noteItem(controller, action: #selector(AppDelegate.bringNote(_:)))
                if let ordinal = manager.desktopOrdinal(of: controller) {
                    item.title += "  —  Desktop \(ordinal)"
                }
                item.toolTip = "Moves this note to the current desktop"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SpaceNote",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func noteItem(_ controller: NoteWindowController, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: controller.menuTitle, action: action, keyEquivalent: "")
        item.target = appDelegate
        item.representedObject = controller.noteID
        item.image = NoteWindowController.swatch(controller.note.color.body)
        return item
    }
}
