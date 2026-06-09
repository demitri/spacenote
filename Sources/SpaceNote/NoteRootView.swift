import AppKit

/// First click on an inactive note places the caret immediately.
final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Content view of a note window: strip on top, optional format toolbar, text
/// body below, colored (optionally translucent) background.
final class NoteRootView: NSView {
    /// Default note font. Falls back loudly, not silently, if Gill Sans ever
    /// disappears from the system.
    static let defaultFont: NSFont = {
        if let font = NSFont(name: "GillSans-SemiBold", size: 18) { return font }
        NSLog("SpaceNote: font GillSans-SemiBold not found — falling back to system font")
        return NSFont.systemFont(ofSize: 18, weight: .semibold)
    }()

    let strip = StripView()
    let toolbar = ToolbarView()
    let scroll = NSScrollView()
    let textView: NoteTextView

    var bodyColor: NSColor = NoteColor.yellow.body { didSet { needsDisplay = true } }

    /// Strip + toolbar tint. Body uses `bodyColor`; chrome uses this.
    var stripColor: NSColor = NoteColor.yellow.strip {
        didSet { strip.color = stripColor; toolbar.color = stripColor }
    }

    /// Contrast-aware glyph ink, shared by strip widgets and toolbar symbols.
    var ink: NSColor = NSColor.black.withAlphaComponent(0.45) {
        didSet { strip.ink = ink; toolbar.ink = ink }
    }

    /// Body alpha (full 0.25–1.0 range). The strip and toolbar never drop below
    /// 0.70 so a ghosted note stays findable and draggable (PLAN.md §9).
    var bodyAlpha: CGFloat = 1.0 {
        didSet {
            let chrome = max(bodyAlpha, 0.70)
            strip.alpha = chrome
            toolbar.alpha = chrome
            // Fade the text with the paper. The background fill honors bodyAlpha
            // in draw(), but the text view is an opaque subview drawn on top —
            // without this its glyphs stay solid while the note ghosts (the bug).
            scroll.alphaValue = bodyAlpha
            needsDisplay = true
        }
    }

    var showsToolbar = false { didSet { needsLayout(); needsDisplay = true } }
    /// Collapsed notes hide both the scroll view and the toolbar.
    var collapsed = false { didSet { needsLayout() } }

    private var toolbarVisible: Bool { showsToolbar && !collapsed }

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
        addSubview(toolbar)
        addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func needsLayout() { needsLayout = true }

    /// Show/hide the toolbar without resizing or moving the window — the text
    /// area grows/shrinks by the band (PLAN.md §9).
    func setToolbarShown(_ shown: Bool) { showsToolbar = shown }

    override func layout() {
        super.layout()
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: StripView.height)

        let contentTop: CGFloat
        if toolbarVisible {
            toolbar.isHidden = false
            toolbar.frame = NSRect(x: 0, y: StripView.height,
                                   width: bounds.width, height: ToolbarView.height)
            contentTop = StripView.height + ToolbarView.height
        } else {
            toolbar.isHidden = true
            contentTop = StripView.height
        }

        scroll.isHidden = collapsed
        scroll.frame = NSRect(x: 0, y: contentTop,
                              width: bounds.width,
                              height: max(0, bounds.height - contentTop))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fill only below the chrome — strip and toolbar fill their own bands with
        // their own (floored) alpha; overlapping translucent fills would compound.
        let top = toolbarVisible ? StripView.height + ToolbarView.height : StripView.height
        bodyColor.withAlphaComponent(bodyAlpha).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top)).fill()
    }
}
