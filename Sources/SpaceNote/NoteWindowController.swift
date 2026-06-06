import AppKit

/// One controller per note: owns the StickyWindow + views, mirrors edits and
/// geometry into the store.
final class NoteWindowController: NSWindowController {
    private let root: NoteRootView
    private unowned let store: NoteStore
    private(set) var note: Note
    /// Called after the note is deleted and its window closed (manager removes us).
    var onDeleted: ((UUID) -> Void)?

    private(set) var isCollapsed = false
    private var expandedHeight: CGFloat

    var noteID: UUID { note.id }
    var textView: NSTextView { root.textView }

    /// First line of the note's text, for the status menu.
    var menuTitle: String {
        let firstLine = root.textView.string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if firstLine.isEmpty { return "Untitled" }
        return firstLine.count > 40 ? firstLine.prefix(40) + "…" : firstLine
    }

    init(note: Note, text: NSAttributedString?, store: NoteStore) {
        self.note = note
        self.store = store
        self.expandedHeight = note.frame.height
        // Presentation-only clamp: the persisted frame is kept verbatim until
        // the user actually moves/resizes the note.
        let displayFrame = NoteWindowController.clampedToScreens(note.frame)
        root = NoteRootView(frame: NSRect(origin: .zero, size: displayFrame.size))
        let window = StickyWindow(contentRect: displayFrame)
        super.init(window: window)

        window.delegate = self
        window.contentView = root
        window.initialFirstResponder = root.textView
        root.strip.onClose = { [weak self] in self?.requestClose() }
        root.strip.onToggleCollapse = { [weak self] in self?.toggleCollapse() }
        root.strip.menu = buildContextMenu()

        if let text {
            root.textView.textStorage?.setAttributedString(text)
        }
        root.textView.delegate = self

        applyAppearance()
        window.level = note.isFloating ? .floating : .normal
        if note.isCollapsed { setCollapsed(true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyAppearance() {
        root.bodyColor = note.color.body
        root.strip.color = note.color.strip
        root.bodyAlpha = note.isTranslucent ? 0.80 : 1.0
        window?.invalidateShadow()
    }

    // MARK: - Geometry

    /// A note restored from an unplugged display must not be stranded
    /// offscreen (PLAN.md §3). "On screen enough" = its strip is grabbable.
    static func clampedToScreens(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        let strip = NSRect(x: frame.minX, y: frame.maxY - StripView.height,
                           width: frame.width, height: StripView.height)
        if screens.contains(where: { $0.visibleFrame.intersection(strip).width >= 60 }) {
            return frame
        }
        let target = (NSScreen.main ?? screens[0]).visibleFrame
        var clamped = frame
        clamped.size.width = min(clamped.width, target.width)
        clamped.size.height = min(clamped.height, target.height)
        clamped.origin.x = min(max(clamped.minX, target.minX), target.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.minY, target.minY), target.maxY - clamped.height)
        return clamped
    }

    // MARK: - Geometry → model

    /// The persisted frame is always the *expanded* geometry (PLAN.md §3).
    private func pushFrame() {
        guard let window else { return }
        if isCollapsed {
            note.frame = NSRect(x: window.frame.minX,
                                y: window.frame.maxY - expandedHeight,
                                width: window.frame.width,
                                height: expandedHeight)
        } else {
            expandedHeight = window.frame.height
            note.frame = window.frame
        }
        store.update(note)
    }

    // MARK: - Close / delete

    func requestClose() {
        guard let window else { return }
        let hasText = (root.textView.textStorage?.length ?? 0) > 0
        guard hasText else {
            deleteNote()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "Closing a note deletes it; its text will be lost."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.deleteNote() }
        }
    }

    private func deleteNote() {
        store.delete(id: note.id)
        window?.close()
        onDeleted?(note.id)
    }

    // MARK: - Collapse

    func toggleCollapse() { setCollapsed(!isCollapsed) }

    private func setCollapsed(_ collapsed: Bool) {
        guard let window, collapsed != isCollapsed else { return }
        var frame = window.frame
        if collapsed {
            expandedHeight = frame.height
            frame.origin.y += frame.height - StripView.height
            frame.size.height = StripView.height
        } else {
            frame.origin.y -= expandedHeight - StripView.height
            frame.size.height = expandedHeight
        }
        isCollapsed = collapsed
        root.scroll.isHidden = collapsed
        window.setFrame(frame, display: true)
        note.isCollapsed = collapsed
        pushFrame()
    }

    // MARK: - Space stamp (written only by SpaceManager, from CGS readback)

    func updateStamp(_ info: SpaceInfo) {
        guard note.spaceUUID != info.uuid
                || note.displayIdentifier != info.displayIdentifier
                || note.desktopOrdinal != info.ordinal else { return }
        note.spaceUUID = info.uuid
        note.displayIdentifier = info.displayIdentifier
        note.desktopOrdinal = info.ordinal
        store.update(note)
    }

    // MARK: - Focus

    func focus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    static func swatch(_ color: NSColor) -> NSImage {
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
        note.color = picked
        applyAppearance()
        store.update(note)
    }

    @objc private func toggleTranslucent(_ sender: NSMenuItem) {
        note.isTranslucent.toggle()
        applyAppearance()
        store.update(note)
    }

    @objc private func toggleFloat(_ sender: NSMenuItem) {
        note.isFloating.toggle()
        window?.level = note.isFloating ? .floating : .normal
        store.update(note)
    }

    @objc private func toggleCollapseItem(_ sender: NSMenuItem) { toggleCollapse() }
}

// MARK: - Window/text delegates

extension NoteWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { pushFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { pushFrame() }
}

extension NoteWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let storage = root.textView.textStorage else { return }
        guard let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length)) else {
            NSLog("SpaceNote: RTF serialization failed for note \(note.id) — edit NOT saved")
            return
        }
        store.textChanged(id: note.id, rtf: rtf)
    }
}

extension NoteWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(toggleTranslucent(_:)): item.state = note.isTranslucent ? .on : .off
            case #selector(toggleFloat(_:)): item.state = note.isFloating ? .on : .off
            case #selector(toggleCollapseItem(_:)): item.title = isCollapsed ? "Expand" : "Collapse"
            case #selector(pickColor(_:)):
                item.state = (item.representedObject as? String) == note.color.rawValue ? .on : .off
            default: break
            }
        }
    }
}
