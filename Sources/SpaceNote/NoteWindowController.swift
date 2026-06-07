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

    /// App-level owner of the shared `NSColorPanel` fill session (PLAN.md §9):
    /// the single source of truth for which note a color-panel change targets.
    /// A panel action is a no-op unless its controller IS this token, so a stale
    /// target can never recolor the wrong note.
    static weak var fillSessionOwner: NoteWindowController?
    private var activePopover: NSPopover?

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
        root.strip.onToggleToolbar = { [weak self] in
            guard let self else { return }
            setToolbarShown(!note.showsToolbar)
        }
        root.strip.menu = buildContextMenu()
        root.toolbar.delegate = self

        if let text {
            root.textView.textStorage?.setAttributedString(text)
        }
        root.textView.delegate = self

        applyAppearance()
        root.showsToolbar = note.showsToolbar
        window.level = note.isFloating ? .floating : .normal
        if note.isCollapsed { setCollapsed(true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyAppearance() {
        root.bodyColor = note.color.body
        root.stripColor = note.color.strip
        root.ink = note.color.chromeInk
        root.bodyAlpha = note.effectiveAlpha
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
        root.collapsed = collapsed   // hides scroll + toolbar
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
        // Custom… duplicates the toolbar popover deliberately: the toolbar can be
        // hidden, and Stickies likewise offers colors in two places (PLAN.md §9).
        menu.addItem(makeItem("Custom…", #selector(pickCustomColor(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Show Toolbar", #selector(toggleToolbarItem(_:))))
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
        setFill(.preset(picked))
    }

    @objc private func pickCustomColor(_ sender: Any?) {
        beginFillColorSession()
    }

    @objc private func toggleToolbarItem(_ sender: NSMenuItem) { setToolbarShown(!note.showsToolbar) }

    /// Set the note's background fill (preset or custom) and persist.
    func setFill(_ fill: NoteFill) {
        note.color = fill
        applyAppearance()
        store.update(note)
    }

    func setToolbarShown(_ shown: Bool) {
        guard shown != note.showsToolbar else { return }
        note.showsToolbar = shown
        root.setToolbarShown(shown)
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

    /// Another note becoming key ends any fill session this isn't the owner of
    /// (PLAN.md §9). The color panel itself becoming key is NOT a note window,
    /// so it never fires this — the session survives panel interaction.
    func windowDidBecomeKey(_ notification: Notification) {
        if let owner = NoteWindowController.fillSessionOwner, owner !== self {
            NoteWindowController.fillSessionOwner = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        if NoteWindowController.fillSessionOwner === self {
            NoteWindowController.fillSessionOwner = nil
        }
        activePopover?.close()
    }
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
            case #selector(toggleToolbarItem(_:)): item.title = note.showsToolbar ? "Hide Toolbar" : "Show Toolbar"
            case #selector(toggleCollapseItem(_:)): item.title = isCollapsed ? "Expand" : "Collapse"
            case #selector(pickColor(_:)):
                // Checkmark only when the fill IS this preset; a custom fill checks none.
                let presetRaw = item.representedObject as? String
                item.state = note.color == presetRaw.flatMap(NoteColor.init).map(NoteFill.preset) ? .on : .off
            default: break
            }
        }
    }
}

// MARK: - Toolbar (formatting) — PLAN.md §9
// Same-file extension so it can reach the controller's private `root`/`note`/`store`.

extension NoteWindowController: ToolbarViewDelegate {

    /// All formatting routes through here: make *this note's* text view first
    /// responder, never rely on the ambient responder chain (which would no-op
    /// when the text view isn't focused, or hit the wrong note when another is
    /// key — PLAN.md §9).
    private func focusTextView() {
        if window?.firstResponder !== root.textView {
            window?.makeFirstResponder(root.textView)
        }
    }

    private var representativeFont: NSFont {
        let tv = root.textView
        if let storage = tv.textStorage, storage.length > 0 {
            let loc = min(tv.selectedRange().location, storage.length - 1)
            if let font = storage.attribute(.font, at: loc, effectiveRange: nil) as? NSFont {
                return font
            }
        }
        return (tv.typingAttributes[.font] as? NSFont) ?? NoteRootView.defaultFont
    }

    /// Transform every font in the selection (or the typing attributes when the
    /// selection is empty — native behavior). Persists via `didChangeText()`.
    private func transformFonts(_ transform: (NSFont) -> NSFont) {
        focusTextView()
        let tv = root.textView
        guard let storage = tv.textStorage else { return }
        let ranges = tv.selectedRanges.map(\.rangeValue)
        let base = NoteRootView.defaultFont

        if ranges.allSatisfy({ $0.length == 0 }) {
            let current = (tv.typingAttributes[.font] as? NSFont) ?? base
            tv.typingAttributes[.font] = transform(current)
            return
        }
        storage.beginEditing()
        for range in ranges where range.length > 0 {
            storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                let current = (value as? NSFont) ?? base
                storage.addAttribute(.font, value: transform(current), range: sub)
            }
        }
        storage.endEditing()
        tv.didChangeText()
    }

    private func currentAttributeIsOn(_ key: NSAttributedString.Key) -> Bool {
        let tv = root.textView
        if let storage = tv.textStorage, storage.length > 0 {
            let loc = min(tv.selectedRange().location, storage.length - 1)
            return attributeIsOn(storage.attribute(key, at: loc, effectiveRange: nil))
        }
        return attributeIsOn(tv.typingAttributes[key])
    }

    private func attributeIsOn(_ value: Any?) -> Bool {
        if let n = value as? Int { return n != 0 }
        if let d = value as? Double { return d != 0 }
        if let n = value as? NSNumber { return n.doubleValue != 0 }
        return false
    }

    /// Toggle a numeric attribute (underline/strikethrough style, stroke width).
    private func toggleAttribute(_ key: NSAttributedString.Key, on onValue: Any) {
        focusTextView()
        let tv = root.textView
        guard let storage = tv.textStorage else { return }
        let turnOn = !currentAttributeIsOn(key)
        let offValue = 0
        let ranges = tv.selectedRanges.map(\.rangeValue)

        if ranges.allSatisfy({ $0.length == 0 }) {
            tv.typingAttributes[key] = turnOn ? onValue : offValue
            return
        }
        storage.beginEditing()
        for range in ranges where range.length > 0 {
            if turnOn { storage.addAttribute(key, value: onValue, range: range) }
            else { storage.removeAttribute(key, range: range) }
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: Delegate: menus

    func toolbarFontMenu() -> NSMenu {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Fonts…", action: #selector(showFontPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let currentFamily = representativeFont.familyName
        // Built lazily on open. Every family gets an item; if its face can't load
        // or render its own name, the item falls back to the menu font FOR DISPLAY
        // only — never skipped (PLAN.md §9 / no-silent-skip).
        for family in NSFontManager.shared.availableFontFamilies {
            let item = NSMenuItem(title: family, action: #selector(pickFontFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            if let face = NSFont(name: family, size: 14) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: face])
            }
            if family == currentFamily { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }

    func toolbarStyleMenu() -> NSMenu {
        let menu = NSMenu()
        let traits = symbolicTraits(representativeFont)

        func add(_ title: String, _ action: Selector, key: String, on: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("Bold", #selector(toggleBold), key: "b", on: traits.contains(.bold))
        add("Italic", #selector(toggleItalic), key: "i", on: traits.contains(.italic))
        add("Underline", #selector(toggleUnderline), key: "u", on: currentAttributeIsOn(.underlineStyle))
        add("Strikethrough", #selector(toggleStrikethrough), key: "", on: currentAttributeIsOn(.strikethroughStyle))
        add("Outline", #selector(toggleOutline), key: "", on: currentAttributeIsOn(.strokeWidth))
        return menu
    }

    func toolbarColorMenu() -> NSMenu {
        let menu = NSMenu()
        for noteColor in NoteColor.allCases {
            let item = NSMenuItem(title: noteColor.displayName,
                                  action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = noteColor.rawValue
            item.image = NoteWindowController.swatch(noteColor.body)
            if note.color == .preset(noteColor) { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(pickCustomColor(_:)), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        return menu
    }

    func toolbarCurrentAlignment() -> NSTextAlignment? {
        let tv = root.textView
        if let storage = tv.textStorage, storage.length > 0 {
            let loc = min(tv.selectedRange().location, storage.length - 1)
            if let ps = storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle {
                return ps.alignment
            }
        }
        return (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left
    }

    // MARK: Delegate: direct actions

    func toolbarAlign(_ alignment: NSTextAlignment) {
        focusTextView()
        let tv = root.textView
        switch alignment {
        case .center: tv.alignCenter(nil)
        case .right:  tv.alignRight(nil)
        default:      tv.alignLeft(nil)
        }
        tv.didChangeText()
    }

    func toolbarShowColorPopover(from view: NSView) {
        let picker = FillPickerView(current: note.color,
                                    onPreset: { [weak self] in self?.setFill(.preset($0)) },
                                    onCustom: { [weak self] in self?.beginFillColorSession() })
        showPopover(picker, from: view, size: FillPickerView.preferredSize)
    }

    func toolbarShowOpacityPopover(from view: NSView) {
        let content = OpacityPopoverView(value: Double(note.effectiveAlpha)) { [weak self] value in
            guard let self else { return }
            note.applyOpacitySlider(value)
            applyAppearance()
            store.update(note)
        }
        showPopover(content, from: view, size: NSSize(width: 180, height: 28))
    }

    private func showPopover(_ view: NSView, from anchor: NSView, size: NSSize) {
        activePopover?.close()
        let popover = NSPopover()
        let vc = NSViewController()
        view.frame = NSRect(origin: .zero, size: size)
        vc.view = view
        popover.contentViewController = vc
        popover.contentSize = size
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        activePopover = popover
    }

    // MARK: Style/font action targets

    @objc private func showFontPanel() {
        focusTextView()
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    @objc private func pickFontFamily(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        let fm = NSFontManager.shared
        transformFonts { fm.convert($0, toFamily: family) }
    }

    @objc private func toggleBold() {
        let fm = NSFontManager.shared
        transformFonts { [self] font in
            symbolicTraits(font).contains(.bold)
                ? fm.convert(font, toNotHaveTrait: .boldFontMask)
                : fm.convert(font, toHaveTrait: .boldFontMask)
        }
    }

    @objc private func toggleItalic() {
        let fm = NSFontManager.shared
        transformFonts { [self] font in
            symbolicTraits(font).contains(.italic)
                ? fm.convert(font, toNotHaveTrait: .italicFontMask)
                : fm.convert(font, toHaveTrait: .italicFontMask)
        }
    }

    @objc private func toggleUnderline() {
        toggleAttribute(.underlineStyle, on: NSUnderlineStyle.single.rawValue)
    }

    @objc private func toggleStrikethrough() {
        toggleAttribute(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue)
    }

    @objc private func toggleOutline() {
        toggleAttribute(.strokeWidth, on: 3.0)
    }

    // MARK: Shared color-panel fill session

    private func beginFillColorSession() {
        NoteWindowController.fillSessionOwner = self
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(fillColorChanged(_:)))
        panel.showsAlpha = false
        panel.color = note.color.body
        panel.orderFront(nil)
    }

    @objc private func fillColorChanged(_ sender: NSColorPanel) {
        // Ownership guard: ignore unless this controller still owns the session.
        guard NoteWindowController.fillSessionOwner === self else { return }
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let rgb = (UInt32(round(c.redComponent * 255)) << 16)
                | (UInt32(round(c.greenComponent * 255)) << 8)
                | UInt32(round(c.blueComponent * 255))
        setFill(.custom(rgb: rgb))
    }

    private func symbolicTraits(_ font: NSFont) -> NSFontDescriptor.SymbolicTraits {
        font.fontDescriptor.symbolicTraits
    }
}
