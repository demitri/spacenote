import AppKit

let app = NSApplication.shared
// Menu-bar-only app (matches LSUIElement in the bundled Info.plist; explicit
// so unbundled `swift run` behaves identically). Key equivalents from
// NSApp.mainMenu work without a visible menu bar.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
