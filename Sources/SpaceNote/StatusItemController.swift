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

        let newNote = NSMenuItem(title: "New Note",
                                 action: #selector(AppDelegate.newNote(_:)), keyEquivalent: "n")
        newNote.target = appDelegate
        menu.addItem(newNote)

        // Local notes focus; notes on other desktops get an EXPLICIT bring-here
        // section — we can't switch desktops via public API, and focusing a
        // foreign note must never silently relocate it (PLAN.md §4).
        let manager = appDelegate.spaceManager
        manager.refreshSnapshot()
        // Label notes live in the "Go to Desktop" section below, not the regular
        // focus/bring-here lists — otherwise a label shows twice.
        let (local, foreign) = appDelegate.controllers
            .filter { !$0.note.isDesktopLabel }
            .reduce(into: ([NoteWindowController](), [NoteWindowController]())) {
                if manager.isOnVisibleSpace($1) { $0.0.append($1) } else { $0.1.append($1) }
            }

        // Desktop-label switcher (PLAN.md §10): jump to a named desktop by
        // focusing its label note (macOS follows the key window to its Space).
        let labels = appDelegate.controllers
            .filter { $0.note.isDesktopLabel }
            .sorted { ($0.note.desktopOrdinal ?? .max) < ($1.note.desktopOrdinal ?? .max) }
        if !labels.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Go to Desktop", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for controller in labels {
                let item = noteItem(controller, action: #selector(AppDelegate.goToDesktop(_:)))
                if let ord = controller.note.desktopOrdinal { item.title += "  —  Desktop \(ord)" }
                menu.addItem(item)
            }
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

    private func noteItem(_ controller: NoteWindowController, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: controller.menuTitle, action: action, keyEquivalent: "")
        item.target = appDelegate
        item.representedObject = controller.noteID
        item.image = NoteWindowController.swatch(controller.note.color.body)
        // NoteFill.body unifies preset + custom — no preset-vs-custom branch.
        return item
    }
}
