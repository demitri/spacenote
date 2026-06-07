import AppKit

/// A note's background fill: either one of the six classic presets or an
/// arbitrary custom color the user picked (PLAN.md §9). Persisted as a plain
/// string — `"yellow"` for a preset, `"#RRGGBB"` for a custom — so v1 manifests
/// (which stored a bare `NoteColor` raw value) decode unchanged.
enum NoteFill: Equatable {
    case preset(NoteColor)
    case custom(rgb: UInt32)

    /// Paper fill behind the body text.
    var body: NSColor {
        switch self {
        case .preset(let color): color.body
        case .custom(let rgb):   NoteFill.color(fromHex: rgb)
        }
    }

    /// The darker title-band / toolbar tint. Presets are hand-tuned; a custom
    /// fill derives one programmatically, mirroring the preset body→strip
    /// relationship (darken, nudge saturation).
    var strip: NSColor {
        switch self {
        case .preset(let color):
            return color.strip
        case .custom(let rgb):
            let base = NoteFill.color(fromHex: rgb)
            guard let hsb = base.usingColorSpace(.sRGB) else { return base }
            return NSColor(hue: hsb.hueComponent,
                           saturation: min(1, hsb.saturationComponent * 1.15),
                           brightness: hsb.brightnessComponent * 0.90,
                           alpha: 1)
        }
    }

    /// Chrome ink (strip glyphs, toolbar symbols) chosen for contrast against
    /// the fill so a dark *custom* color doesn't swallow black-on-dark glyphs.
    /// All presets are light, so they keep the classic `black @ 45%`.
    var chromeInk: NSColor {
        let c = body.usingColorSpace(.sRGB) ?? body
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance < 0.5
            ? NSColor.white.withAlphaComponent(0.7)
            : NSColor.black.withAlphaComponent(0.45)
    }

    static func color(fromHex hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

// MARK: - Codable (single string value, backward-compatible with v1)

extension NoteFill: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("#") {
            let hexPart = String(raw.dropFirst())
            guard hexPart.count == 6, let value = UInt32(hexPart, radix: 16) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid custom color \"\(raw)\" (expected #RRGGBB)"))
            }
            self = .custom(rgb: value)
        } else if let preset = NoteColor(rawValue: raw) {
            self = .preset(preset)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown note color \"\(raw)\""))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .preset(let color):
            try container.encode(color.rawValue)
        case .custom(let rgb):
            try container.encode(String(format: "#%06X", rgb & 0xFFFFFF))
        }
    }
}
