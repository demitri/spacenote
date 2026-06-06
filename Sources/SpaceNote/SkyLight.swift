import Foundation

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// dlsym loader for the private SkyLight (CGS) functions (PLAN.md §1, §7).
/// Read tier (managed-display dump, per-window space query) is required;
/// the write tier (own-window move — Strategy A′, verified working on
/// macOS 26.5.1 in Phase 0) is optional and its absence degrades loudly.
final class SkyLight {
    /// CGSCopySpacesForWindows mask: current | other | user.
    static let allSpacesMask: Int32 = 7

    let mainConnectionID: @convention(c) () -> CGSConnectionID
    let copyManagedDisplaySpaces: @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    /// Returns a FLAT array of space IDs — call with a single window only.
    let copySpacesForWindows: @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    /// Write tier. CGSAdd/RemoveWindowsFromSpaces also verified working and can
    /// substitute if this one ever disappears (see spike).
    let moveWindowsToManagedSpace: (@convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void)?

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            NSLog("SpaceNote: dlopen(SkyLight) FAILED: %s — space features unavailable", dlerror())
            return nil
        }
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else {
                NSLog("SpaceNote: SkyLight symbol %@ not found", name)
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let main = sym("CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self),
            let dump = sym("CGSCopyManagedDisplaySpaces",
                           as: (@convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?).self),
            let query = sym("CGSCopySpacesForWindows",
                            as: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        else {
            NSLog("SpaceNote: required read-tier CGS symbols missing — space features unavailable")
            return nil
        }
        mainConnectionID = main
        copyManagedDisplaySpaces = dump
        copySpacesForWindows = query
        moveWindowsToManagedSpace = sym(
            "CGSMoveWindowsToManagedSpace",
            as: (@convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void).self)
    }
}
