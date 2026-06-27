import AppKit
import ServiceManagement

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

        // SMAppService needs a real bundle with stable identity (PLAN.md §4);
        // hidden when running as a bare SwiftPM binary.
        if Bundle.main.bundleURL.pathExtension == "app" {
            let login = NSMenuItem(title: "Start at Login",
                                   action: #selector(AppDelegate.toggleLoginItem(_:)),
                                   keyEquivalent: "")
            login.target = appDelegate
            switch SMAppService.mainApp.status {
            case .enabled:
                login.state = .on
            case .requiresApproval:
                login.title = "Start at Login (approve in System Settings)"
                login.state = .mixed
            default:
                login.state = .off
            }
            menu.addItem(login)
        }
        let quit = NSMenuItem(title: "Quit SpaceNote",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }
}
