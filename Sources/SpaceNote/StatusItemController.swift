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

        // New Note + Go to Desktop switcher + focus/bring-here lists (shared with
        // the Dock menu). The status menu adds app-control items below.
        appDelegate.populateNavigationMenu(menu)

        menu.addItem(.separator())
        let dock = NSMenuItem(title: "Show in Dock",
                              action: #selector(AppDelegate.toggleDockVisibility(_:)),
                              keyEquivalent: "")
        dock.target = appDelegate
        dock.state = AppSettings.showInDock ? .on : .off
        menu.addItem(dock)

        let quit = NSMenuItem(title: "Quit SpaceNote",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }
}
