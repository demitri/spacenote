import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // becomes .accessory (LSUIElement) with bundling in Phase 4
let delegate = AppDelegate()
app.delegate = delegate
app.run()
