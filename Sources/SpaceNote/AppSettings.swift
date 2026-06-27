import Foundation

/// Lightweight UserDefaults-backed app preferences.
enum AppSettings {
    private static let showInDockKey = "ShowInDock"

    /// Dock icon + menu bar (regular) vs. menu-bar-only (accessory).
    /// Default false = menu-bar-only utility, matching Info.plist `LSUIElement`.
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: showInDockKey) }
        set { UserDefaults.standard.set(newValue, forKey: showInDockKey) }
    }
}
