import AppKit

/// Borderless, resizable, translucency-capable note window (PLAN.md §2).
final class StickyWindow: NSWindow {
    // Borderless windows refuse key/main by default, which would make the
    // text view uneditable.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false   // controllers own window lifetime
        animationBehavior = .none
        hidesOnDeactivate = false
        contentMinSize = NSSize(width: 60, height: 40)
        // Notes are paper-light in dark mode too (matches Stickies); pinning
        // appearance keeps text/insertion-point colors correct on light fills.
        appearance = NSAppearance(named: .aqua)
    }
}
