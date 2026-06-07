import Foundation
import CoreGraphics

/// Persisted model for one note (PLAN.md §3). Window/text state lives in the
/// controller; this is what survives relaunch.
struct Note: Identifiable, Codable {
    let id: UUID
    var rtfFilename: String
    var color: NoteFill
    /// The *expanded* frame (screen coords). A collapsed note persists its
    /// expanded geometry plus `isCollapsed`.
    var frame: CGRect
    var isCollapsed: Bool
    var isTranslucent: Bool
    /// Remembered body alpha while translucent — always sub-1.0 (PLAN.md §9).
    /// Decode default 0.8 keeps v1 manifests (which lacked the field) working.
    var translucentOpacity: Double
    var isFloating: Bool
    /// Per-note format toolbar visibility (PLAN.md §9). New notes start bare.
    var showsToolbar: Bool
    /// Space resolution tuple (PLAN.md §1): uuid, display, ordinal-on-display.
    /// nil = unstamped → shown on current space and stamped there.
    var spaceUUID: String?
    var displayIdentifier: String?
    var desktopOrdinal: Int?

    init(id: UUID = UUID(), color: NoteFill, frame: CGRect) {
        self.id = id
        self.rtfFilename = "\(id.uuidString).rtf"
        self.color = color
        self.frame = frame
        self.isCollapsed = false
        self.isTranslucent = false
        self.translucentOpacity = 0.8
        self.isFloating = false
        self.showsToolbar = false
    }

    /// Effective body alpha for rendering. Pure + testable; `applyAppearance()`
    /// is its only consumer (PLAN.md §9).
    var effectiveAlpha: CGFloat {
        isTranslucent ? CGFloat(translucentOpacity) : 1.0
    }

    /// Apply a value from the toolbar's opacity slider (PLAN.md §9). 100 % clears
    /// translucency but *preserves* `translucentOpacity`, so toggling translucency
    /// back on never lands on an invisible `1.0`-while-translucent state. Stored
    /// values stay in `[0.25, 1.0)`.
    mutating func applyOpacitySlider(_ value: Double) {
        let clamped = max(0.25, min(value, 1.0))
        if clamped >= 1.0 {
            isTranslucent = false           // translucentOpacity left as the remembered value
        } else {
            translucentOpacity = clamped
            isTranslucent = true
        }
    }

    // MARK: - Codable
    // Custom decode supplies defaults for fields absent from v1 manifests
    // (translucentOpacity, showsToolbar) so old files load unchanged; encode is
    // synthesized.

    enum CodingKeys: String, CodingKey {
        case id, rtfFilename, color, frame, isCollapsed, isTranslucent
        case translucentOpacity, isFloating, showsToolbar
        case spaceUUID, displayIdentifier, desktopOrdinal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        rtfFilename = try c.decode(String.self, forKey: .rtfFilename)
        color = try c.decode(NoteFill.self, forKey: .color)
        frame = try c.decode(CGRect.self, forKey: .frame)
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        isTranslucent = try c.decodeIfPresent(Bool.self, forKey: .isTranslucent) ?? false
        translucentOpacity = try c.decodeIfPresent(Double.self, forKey: .translucentOpacity) ?? 0.8
        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        showsToolbar = try c.decodeIfPresent(Bool.self, forKey: .showsToolbar) ?? false
        spaceUUID = try c.decodeIfPresent(String.self, forKey: .spaceUUID)
        displayIdentifier = try c.decodeIfPresent(String.self, forKey: .displayIdentifier)
        desktopOrdinal = try c.decodeIfPresent(Int.self, forKey: .desktopOrdinal)
    }
}

struct Manifest: Codable {
    var version: Int
    var notes: [Note]

    static let currentVersion = 2
}
