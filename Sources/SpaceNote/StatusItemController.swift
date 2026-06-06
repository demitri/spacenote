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

        let controllers = appDelegate.controllers
        if !controllers.isEmpty {
            menu.addItem(.separator())
            for controller in controllers {
                let item = NSMenuItem(title: controller.menuTitle,
                                      action: #selector(AppDelegate.focusNote(_:)),
                                      keyEquivalent: "")
                item.target = appDelegate
                item.representedObject = controller.noteID
                item.image = NoteWindowController.swatch(controller.note.color.body)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SpaceNote",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }
}
