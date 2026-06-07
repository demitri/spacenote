import AppKit

/// Note-fill picker shown from the toolbar swatch (PLAN.md §9): the six classic
/// presets plus "Custom…" which opens the shared `NSColorPanel`.
final class FillPickerView: NSView {
    static let preferredSize = NSSize(width: 196, height: 78)

    private let current: NoteFill
    private let onPreset: (NoteColor) -> Void
    private let onCustom: () -> Void

    init(current: NoteFill, onPreset: @escaping (NoteColor) -> Void, onCustom: @escaping () -> Void) {
        self.current = current
        self.onPreset = onPreset
        self.onCustom = onCustom
        super.init(frame: NSRect(origin: .zero, size: FillPickerView.preferredSize))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var fittingSizeOverride: NSSize { FillPickerView.preferredSize }

    private func build() {
        let pad: CGFloat = 8, sw: CGFloat = 24, gap: CGFloat = 6
        for (i, noteColor) in NoteColor.allCases.enumerated() {
            let button = NSButton(frame: NSRect(x: pad + CGFloat(i) * (sw + gap),
                                                y: FillPickerView.preferredSize.height - pad - sw,
                                                width: sw, height: sw))
            button.image = NoteWindowController.swatch(noteColor.body)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.tag = i
            button.target = self
            button.action = #selector(presetTapped(_:))
            button.toolTip = noteColor.displayName
            button.refusesFirstResponder = true
            if current == .preset(noteColor) {
                button.wantsLayer = true
                button.layer?.borderWidth = 2
                button.layer?.borderColor = NSColor.controlAccentColor.cgColor
                button.layer?.cornerRadius = 4
            }
            addSubview(button)
        }
        let custom = NSButton(frame: NSRect(x: pad, y: pad,
                                            width: FillPickerView.preferredSize.width - 2 * pad, height: 22))
        custom.title = "Custom…"
        custom.bezelStyle = .rounded
        custom.target = self
        custom.action = #selector(customTapped)
        custom.refusesFirstResponder = true
        addSubview(custom)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        onPreset(NoteColor.allCases[sender.tag])
    }

    @objc private func customTapped() { onCustom() }
}

/// Opacity slider shown from the toolbar (PLAN.md §9). Floor 25 %; the controller
/// applies the slider-boundary semantics (100 % clears translucency).
final class OpacityPopoverView: NSView {
    private let slider: NSSlider
    private let onChange: (Double) -> Void

    init(value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: 0.25, maxValue: 1.0,
                          target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.refusesFirstResponder = true
        slider.frame = NSRect(x: 10, y: 4, width: 160, height: 20)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sliderMoved() { onChange(slider.doubleValue) }
}
