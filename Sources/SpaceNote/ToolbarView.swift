import AppKit

enum ToolID {
    case font, styles, alignLeft, alignCenter, alignRight, color, opacity
}

/// Supplies menus, actions, and current state to the toolbar. The controller
/// implements it; the toolbar never reaches into the text view directly
/// (explicit routing — PLAN.md §9).
protocol ToolbarViewDelegate: AnyObject {
    func toolbarFontMenu() -> NSMenu
    func toolbarStyleMenu() -> NSMenu
    func toolbarColorMenu() -> NSMenu          // swatches + Custom…, for the overflow submenu
    func toolbarAlign(_ alignment: NSTextAlignment)
    func toolbarShowColorPopover(from view: NSView)
    func toolbarShowOpacityPopover(from view: NSView)
    func toolbarCurrentAlignment() -> NSTextAlignment?
}

/// The tiny per-note format bar: a 20 pt band below the strip (PLAN.md §9).
/// Lays its controls left→right; whatever doesn't fit at the current note width
/// collapses into a trailing » overflow menu, so it works at any width with no
/// min-width clamp and no detached windows.
final class ToolbarView: NSView {
    static let height: CGFloat = 20

    weak var delegate: ToolbarViewDelegate?

    var color: NSColor = NoteColor.yellow.strip { didSet { needsDisplay = true } }
    var alpha: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var ink: NSColor = NSColor.black.withAlphaComponent(0.45) {
        didSet { applyInk(); needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private struct Tool {
        let id: ToolID
        let button: NSButton
        let symbol: String
        let tooltip: String
    }
    private var tools: [Tool] = []
    private let overflowButton = NSButton()
    private var hiddenTools: [Tool] = []

    private let inset: CGFloat = 4
    private let spacing: CGFloat = 1
    private let buttonWidth: CGFloat = 22
    private let overflowWidth: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildTools()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildTools() {
        let specs: [(ToolID, String, String, Selector)] = [
            (.font,        "textformat",      "Font",         #selector(fontTapped)),
            (.styles,      "bold",            "Style",        #selector(stylesTapped)),
            (.alignLeft,   "text.alignleft",  "Align Left",   #selector(alignLeftTapped)),
            (.alignCenter, "text.aligncenter","Align Center", #selector(alignCenterTapped)),
            (.alignRight,  "text.alignright", "Align Right",  #selector(alignRightTapped)),
            (.color,       "paintpalette",    "Note Color",   #selector(colorTapped)),
            (.opacity,     "circle.lefthalf.filled", "Opacity", #selector(opacityTapped)),
        ]
        for (id, symbol, tip, action) in specs {
            let button = makeButton(symbol: symbol, tooltip: tip, action: action)
            tools.append(Tool(id: id, button: button, symbol: symbol, tooltip: tip))
            addSubview(button)
        }
        overflowButton.title = "»"
        overflowButton.bezelStyle = .regularSquare
        overflowButton.isBordered = false
        overflowButton.font = .systemFont(ofSize: 14, weight: .semibold)
        overflowButton.contentTintColor = ink
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped)
        overflowButton.toolTip = "More formatting"
        overflowButton.refusesFirstResponder = true   // never steal the text view's focus
        addSubview(overflowButton)
        applyInk()
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.refusesFirstResponder = true   // PLAN.md §9: clicking never moves first responder
        button.wantsLayer = true
        button.layer?.cornerRadius = 3
        return button
    }

    private func applyInk() {
        for tool in tools { tool.button.contentTintColor = ink }
        overflowButton.contentTintColor = ink
    }

    // MARK: - Layout (inline until full, then overflow »)

    override func layout() {
        super.layout()
        let width = bounds.width
        let symbolPointSize: CGFloat = 11
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        for tool in tools { tool.button.image = tool.button.image?.withSymbolConfiguration(config) }

        // Does everything fit inline?
        let allInline = inset + CGFloat(tools.count) * buttonWidth
            + CGFloat(max(0, tools.count - 1)) * spacing + inset
        let y: CGFloat = (Self.height - 18) / 2

        if allInline <= width {
            var x = inset
            for tool in tools {
                tool.button.isHidden = false
                tool.button.frame = NSRect(x: x, y: y, width: buttonWidth, height: 18)
                x += buttonWidth + spacing
            }
            overflowButton.isHidden = true
            hiddenTools = []
        } else {
            // Reserve the » button at the right edge; fill the rest from the left.
            let overflowX = width - inset - overflowWidth
            let leftRegion = overflowX - spacing - inset
            var fit = 0
            var used: CGFloat = 0
            for _ in tools.indices {
                let next = (fit == 0 ? 0 : spacing) + buttonWidth
                if used + next <= leftRegion { used += next; fit += 1 } else { break }
            }
            var x = inset
            for (i, tool) in tools.enumerated() {
                if i < fit {
                    tool.button.isHidden = false
                    tool.button.frame = NSRect(x: x, y: y, width: buttonWidth, height: 18)
                    x += buttonWidth + spacing
                } else {
                    tool.button.isHidden = true
                }
            }
            hiddenTools = Array(tools[fit...])
            overflowButton.isHidden = false
            overflowButton.frame = NSRect(x: overflowX, y: y, width: overflowWidth, height: 18)
        }
        updateAlignmentHighlight()
    }

    /// Subtle highlight on the active paragraph-alignment button.
    func updateAlignmentHighlight() {
        let current = delegate?.toolbarCurrentAlignment()
        for tool in tools {
            let active: Bool
            switch tool.id {
            // Untouched text reports `.natural`, which renders left for LTR — light
            // the Left button so a fresh note isn't shown with no alignment active.
            case .alignLeft:   active = current == .left || current == .natural
            case .alignCenter: active = current == .center
            case .alignRight:  active = current == .right
            default:           active = false
            }
            tool.button.layer?.backgroundColor = active
                ? ink.withAlphaComponent(0.18).cgColor : nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(alpha).setFill()
        bounds.fill()
    }

    // MARK: - Inline actions

    @objc private func fontTapped(_ sender: NSButton) { popUp(delegate?.toolbarFontMenu(), from: sender) }
    @objc private func stylesTapped(_ sender: NSButton) { popUp(delegate?.toolbarStyleMenu(), from: sender) }
    @objc private func alignLeftTapped() { delegate?.toolbarAlign(.left); updateAlignmentHighlight() }
    @objc private func alignCenterTapped() { delegate?.toolbarAlign(.center); updateAlignmentHighlight() }
    @objc private func alignRightTapped() { delegate?.toolbarAlign(.right); updateAlignmentHighlight() }
    @objc private func colorTapped(_ sender: NSButton) { delegate?.toolbarShowColorPopover(from: sender) }
    @objc private func opacityTapped(_ sender: NSButton) { delegate?.toolbarShowOpacityPopover(from: sender) }

    private func popUp(_ menu: NSMenu?, from button: NSButton) {
        guard let menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 2),
                   in: button)
    }

    // MARK: - Overflow »

    @objc private func overflowTapped(_ sender: NSButton) {
        guard let delegate else { return }
        let menu = NSMenu()
        for tool in hiddenTools {
            switch tool.id {
            case .font:
                addSubmenu(to: menu, title: "Font", submenu: delegate.toolbarFontMenu())
            case .styles:
                addSubmenu(to: menu, title: "Style", submenu: delegate.toolbarStyleMenu())
            case .color:
                addSubmenu(to: menu, title: "Note Color", submenu: delegate.toolbarColorMenu())
            case .alignLeft:
                menu.addItem(overflowItem("Align Left", #selector(alignLeftTapped)))
            case .alignCenter:
                menu.addItem(overflowItem("Align Center", #selector(alignCenterTapped)))
            case .alignRight:
                menu.addItem(overflowItem("Align Right", #selector(alignRightTapped)))
            case .opacity:
                menu.addItem(overflowItem("Opacity…", #selector(opacityFromOverflow)))
            }
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.maxY + 2),
                   in: sender)
    }

    private func addSubmenu(to menu: NSMenu, title: String, submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func overflowItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func opacityFromOverflow() {
        // Anchor the opacity popover at the » button (it owns the hidden tool).
        delegate?.toolbarShowOpacityPopover(from: overflowButton)
    }
}
