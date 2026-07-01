import AppKit

// macOS Tahoe (26) auto-decorates standard menu items (Quit, Cut/Copy/Paste,
// Undo…) with system icons via the NSMenuEnableActionImages default. We opt out
// app-wide so our menus stay text-only; images we set explicitly (note-color
// swatches, toolbar SF Symbols) are unaffected — this key governs only the
// automatic action images. Registered (not persisted) before any menu is built.
// The sanctioned per-item API (NSMenuItem.preferredImageVisibility) is absent
// from the 26.5 SDK we build against — confirmed by grepping the SDK header:
//   grep preferredImageVisibility "$(xcrun --show-sdk-path)"/System/Library/\
//     Frameworks/AppKit.framework/Headers/NSMenuItem.h
// The exact SDK that introduces it is unverified (docs point at 27.0 for a
// related NSMenu default change, but that's not the same thing). When the grep
// above starts matching after an Xcode update, check its API_AVAILABLE line and
// consider switching to per-item control instead of this app-wide default.
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
