import AppKit

/// First click on an inactive note places the caret immediately.
final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Content view of a note window: strip on top, text body below, colored
/// (optionally translucent) background.
final class NoteRootView: NSView {
    /// Default note font. Falls back loudly, not silently, if Gill Sans ever
    /// disappears from the system.
    static let defaultFont: NSFont = {
        if let font = NSFont(name: "GillSans-SemiBold", size: 18) { return font }
        NSLog("SpaceNote: font GillSans-SemiBold not found — falling back to system font")
        return NSFont.systemFont(ofSize: 18, weight: .semibold)
    }()

    let strip = StripView()
    let scroll = NSScrollView()
    let textView: NoteTextView

    var bodyColor: NSColor = NoteColor.yellow.body { didSet { needsDisplay = true } }
    var bodyAlpha: CGFloat = 1.0 {
        didSet {
            strip.alpha = bodyAlpha
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }   // strip at y=0, body below

    override init(frame frameRect: NSRect) {
        textView = NoteTextView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)

        textView.isRichText = true
        textView.importsGraphics = false   // v1 is RTF: no image attachments (PLAN.md §2)
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.font = NoteRootView.defaultFont
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        addSubview(scroll)
        addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: StripView.height)
        scroll.frame = NSRect(x: 0, y: StripView.height,
                              width: bounds.width,
                              height: max(0, bounds.height - StripView.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fill only below the strip — the strip fills its own band with the
        // same alpha; overlapping translucent fills would compound.
        bodyColor.withAlphaComponent(bodyAlpha).setFill()
        NSRect(x: 0, y: StripView.height,
               width: bounds.width, height: max(0, bounds.height - StripView.height)).fill()
    }
}
