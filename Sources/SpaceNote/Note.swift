import Foundation

/// Persisted model for one note (PLAN.md §3). Window/text state lives in the
/// controller; this is what survives relaunch.
struct Note: Identifiable, Codable {
    let id: UUID
    var rtfFilename: String
    var color: NoteColor
    /// The *expanded* frame (screen coords). A collapsed note persists its
    /// expanded geometry plus `isCollapsed`.
    var frame: CGRect
    var isCollapsed: Bool
    var isTranslucent: Bool
    var isFloating: Bool
    /// Space resolution tuple (PLAN.md §1): uuid, display, ordinal-on-display.
    /// nil = unstamped → shown on current space and stamped there.
    var spaceUUID: String?
    var displayIdentifier: String?
    var desktopOrdinal: Int?

    init(id: UUID = UUID(), color: NoteColor, frame: CGRect) {
        self.id = id
        self.rtfFilename = "\(id.uuidString).rtf"
        self.color = color
        self.frame = frame
        self.isCollapsed = false
        self.isTranslucent = false
        self.isFloating = false
    }
}

struct Manifest: Codable {
    var version: Int
    var notes: [Note]

    static let currentVersion = 1
}
