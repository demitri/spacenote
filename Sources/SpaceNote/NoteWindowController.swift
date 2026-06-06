import AppKit

/// One controller per note: owns the StickyWindow + views and the note's
/// presentation state. (Model/persistence arrives in Phase 2; for now state
/// lives here.)
final class NoteWindowController: NSWindowController {
    private let root: NoteRootView

    private(set) var color: NoteColor {
        didSet { applyAppearance() }
    }
    var isTranslucent: Bool = false {
        didSet { applyAppearance() }
    }
    var isFloating: Bool = false {
        didSet { window?.level = isFloating ? .floating : .normal }
    }
    private(set) var isCollapsed = false
    private var expandedHeight: CGFloat = 0

    var textView: NSTextView { root.textView }

    init(frame: NSRect, color: NoteColor) {
        self.color = color
        root = NoteRootView(frame: NSRect(origin: .zero, size: frame.size))
        let window = StickyWindow(contentRect: frame)
        super.init(window: window)

        window.contentView = root
        root.strip.onClose = { [weak self] in self?.requestClose() }
        root.strip.onToggleCollapse = { [weak self] in self?.toggleCollapse() }
        root.strip.menu = buildContextMenu()
        window.initialFirstResponder = root.textView
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyAppearance() {
        root.bodyColor = color.body
        root.strip.color = color.strip
        root.bodyAlpha = isTranslucent ? 0.80 : 1.0
        // Translucent windows shouldn't cast a full opaque-rect shadow.
        window?.invalidateShadow()
    }

    // MARK: - Actions

    func requestClose() {
        // Phase 2 will route this through the store (delete + confirm-if-nonempty).
        window?.close()
    }

    func toggleCollapse() {
        guard let window else { return }
        var frame = window.frame
        if isCollapsed {
            frame.origin.y -= expandedHeight - StripView.height
            frame.size.height = expandedHeight
        } else {
            expandedHeight = frame.height
            frame.origin.y += frame.height - StripView.height
            frame.size.height = StripView.height
        }
        isCollapsed.toggle()
        root.scroll.isHidden = isCollapsed
        window.setFrame(frame, display: true)
    }

    // MARK: - Context menu (right-click on the strip)

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        for noteColor in NoteColor.allCases {
            let item = NSMenuItem(title: noteColor.displayName,
                                  action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = noteColor.rawValue
            item.image = NoteWindowController.swatch(noteColor.body)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Translucent", #selector(toggleTranslucent(_:))))
        menu.addItem(makeItem("Float on Top", #selector(toggleFloat(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Collapse", #selector(toggleCollapseItem(_:))))
        menu.delegate = self
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).stroke()
            return true
        }
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let picked = NoteColor(rawValue: raw) else { return }
        color = picked
    }

    @objc private func toggleTranslucent(_ sender: NSMenuItem) { isTranslucent.toggle() }
    @objc private func toggleFloat(_ sender: NSMenuItem) { isFloating.toggle() }
    @objc private func toggleCollapseItem(_ sender: NSMenuItem) { toggleCollapse() }
}

extension NoteWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(toggleTranslucent(_:)): item.state = isTranslucent ? .on : .off
            case #selector(toggleFloat(_:)): item.state = isFloating ? .on : .off
            case #selector(toggleCollapseItem(_:)): item.title = isCollapsed ? "Expand" : "Collapse"
            case #selector(pickColor(_:)):
                item.state = (item.representedObject as? String) == color.rawValue ? .on : .off
            default: break
            }
        }
    }
}
