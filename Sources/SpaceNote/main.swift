import AppKit

// macOS Tahoe (26) auto-decorates standard menu items (Quit, Cut/Copy/Paste,
// Undo…) with system icons via the NSMenuEnableActionImages default. We opt out
// app-wide so our menus stay text-only; images we set explicitly (note-color
// swatches, toolbar SF Symbols) are unaffected — this key governs only the
// automatic action images. Registered (not persisted) before any menu is built.
// The sanctioned per-item API (NSMenuItem.preferredImageVisibility) is a
// later-SDK addition and absent from the 26.5 SDK we build against.
UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])

let app = NSApplication.shared
// Activation policy follows the user's "Show in Dock" setting (default
// accessory = menu-bar-only, matching Info.plist LSUIElement). Set here, before
// the delegate, so there's no launch flicker. Key equivalents from
// NSApp.mainMenu work in either mode.
app.setActivationPolicy(AppSettings.showInDock ? .regular : .accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
