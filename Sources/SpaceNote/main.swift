import AppKit

let app = NSApplication.shared
// Activation policy follows the user's "Show in Dock" setting (default
// accessory = menu-bar-only, matching Info.plist LSUIElement). Set here, before
// the delegate, so there's no launch flicker. Key equivalents from
// NSApp.mainMenu work in either mode.
app.setActivationPolicy(AppSettings.showInDock ? .regular : .accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
