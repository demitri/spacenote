import AppKit

/// The minimal Stickies-style "title bar": a thin colored band that drags the
/// window, shows close/collapse widgets on hover, and collapses on double-click.
final class StripView: NSView {
    static let height: CGFloat = 14

    var color: NSColor = NoteColor.yellow.strip { didSet { needsDisplay = true } }
    var alpha: CGFloat = 1.0 { didSet { needsDisplay = true } }
    /// Contrast-aware glyph ink (PLAN.md §9): black on light fills, light on dark.
    var ink: NSColor = NSColor.black.withAlphaComponent(0.45) { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    var onToggleCollapse: (() -> Void)?

    private var hovered = false

    override var isOpaque: Bool { false }
    // First click on an inactive note must act, not just activate (PLAN.md §2).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    private var glyphSize: CGFloat { 7 }
    private var closeRect: NSRect {
        NSRect(x: 5, y: (bounds.height - glyphSize) / 2, width: glyphSize, height: glyphSize)
    }
    private var collapseRect: NSRect {
        NSRect(x: bounds.width - glyphSize - 5, y: (bounds.height - glyphSize) / 2,
               width: glyphSize, height: glyphSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(alpha).setFill()
        bounds.fill()
        guard hovered else { return }

        ink.setStroke()
        // Close: ×
        let x = NSBezierPath()
        x.lineWidth = 1.2
        x.move(to: NSPoint(x: closeRect.minX, y: closeRect.minY))
        x.line(to: NSPoint(x: closeRect.maxX, y: closeRect.maxY))
        x.move(to: NSPoint(x: closeRect.minX, y: closeRect.maxY))
        x.line(to: NSPoint(x: closeRect.maxX, y: closeRect.minY))
        x.stroke()
        // Collapse: chevron
        let c = NSBezierPath()
        c.lineWidth = 1.2
        c.move(to: NSPoint(x: collapseRect.minX, y: collapseRect.maxY - 1.5))
        c.line(to: NSPoint(x: collapseRect.midX, y: collapseRect.minY + 1))
        c.line(to: NSPoint(x: collapseRect.maxX, y: collapseRect.maxY - 1.5))
        c.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -3, dy: -3).contains(p) {
            onClose?()
            return
        }
        if collapseRect.insetBy(dx: -3, dy: -3).contains(p) {
            onToggleCollapse?()
            return
        }
        if event.clickCount == 2 {
            onToggleCollapse?()
            return
        }
        window?.performDrag(with: event)
    }
}
