import AppKit

/// The classic six Stickies colors. Body fills the note; strip is the darker
/// title band. Notes stay paper-light regardless of system appearance (the
/// window pins itself to .aqua), so one palette suffices.
enum NoteColor: String, Codable, CaseIterable {
    case yellow, blue, green, pink, purple, gray

    var body: NSColor { NoteColor.rgb(bodyHex) }
    var strip: NSColor { NoteColor.rgb(stripHex) }

    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    private var bodyHex: UInt32 {
        switch self {
        case .yellow: 0xFFF9B0
        case .blue:   0xAEE0FB
        case .green:  0xC5F2B8
        case .pink:   0xFFCCE5
        case .purple: 0xDDCFFC
        case .gray:   0xE9E9E9
        }
    }

    private var stripHex: UInt32 {
        switch self {
        case .yellow: 0xF4E687
        case .blue:   0x8FCDF3
        case .green:  0xA8E59A
        case .pink:   0xF9AED1
        case .purple: 0xC3ADF2
        case .gray:   0xD4D4D4
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
