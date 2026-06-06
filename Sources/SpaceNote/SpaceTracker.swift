import AppKit

/// One user desktop space, as parsed from CGSCopyManagedDisplaySpaces.
struct SpaceInfo: Equatable {
    let id64: CGSSpaceID
    let uuid: String              // empty for the primary desktop of a display
    let displayIdentifier: String
    let ordinal: Int              // 1-based among user spaces on its display
}

/// Point-in-time parse of the managed display/space topology.
struct SpacesSnapshot {
    let userSpaces: [SpaceInfo]
    let currentSpaceIDs: Set<CGSSpaceID>      // the visible space of each display
    let displayIdentifiers: [String]          // in CGS order

    static let empty = SpacesSnapshot(userSpaces: [], currentSpaceIDs: [], displayIdentifiers: [])

    func space(withID id: CGSSpaceID) -> SpaceInfo? {
        userSpaces.first { $0.id64 == id }
    }

    /// Resolve a note's persisted tuple to a live space (PLAN.md §1):
    /// non-empty uuid wins; otherwise (display, ordinal); unknown display
    /// falls back to the first display. nil = the space no longer exists.
    func resolve(spaceUUID: String?, displayIdentifier: String?, desktopOrdinal: Int?) -> SpaceInfo? {
        if let uuid = spaceUUID, !uuid.isEmpty,
           let match = userSpaces.first(where: { $0.uuid == uuid }) {
            return match
        }
        guard spaceUUID != nil, let ordinal = desktopOrdinal else { return nil }
        let display = displayIdentifier.flatMap { displayIdentifiers.contains($0) ? $0 : nil }
            ?? displayIdentifiers.first
        return userSpaces.first { $0.displayIdentifier == display && $0.ordinal == ordinal }
    }
}

/// Wraps the CGS calls: snapshot parsing, per-window space queries, and
/// readback-verified window moves. Main-thread only.
final class SpaceTracker {
    private let sky: SkyLight?
    private let cid: CGSConnectionID
    private(set) var snapshot: SpacesSnapshot = .empty

    /// False once a write has verifiably failed (or symbols are absent):
    /// notes then open on the current space and stamps are FROZEN — never
    /// overwrite the user's layout data with a reality we couldn't honor.
    private(set) var writesAvailable: Bool
    var readsAvailable: Bool { sky != nil }

    init() {
        if ProcessInfo.processInfo.environment["SPACENOTE_FORCE_DEGRADED"] == "1" {
            NSLog("SpaceNote: SPACENOTE_FORCE_DEGRADED=1 — space features disabled for this run")
            sky = nil
        } else {
            sky = SkyLight()
        }
        cid = sky?.mainConnectionID() ?? 0
        writesAvailable = sky?.moveWindowsToManagedSpace != nil
        if sky == nil {
            NSLog("SpaceNote: DEGRADED MODE — notes will open on the current space (stock Stickies behavior)")
        }
        refresh()
    }

    func refresh() {
        guard let sky else { return }
        guard let displays = sky.copyManagedDisplaySpaces(cid)?.takeRetainedValue()
                as? [[String: Any]] else {
            NSLog("SpaceNote: ERROR — CGSCopyManagedDisplaySpaces returned unexpected shape; keeping previous snapshot")
            return
        }
        var spaces: [SpaceInfo] = []
        var currentIDs: Set<CGSSpaceID> = []
        var displayIDs: [String] = []
        for display in displays {
            guard let displayID = display["Display Identifier"] as? String else {
                NSLog("SpaceNote: ERROR — display dict without identifier: \(display)")
                continue
            }
            displayIDs.append(displayID)
            if let current = display["Current Space"] as? [String: Any],
               let id = (current["id64"] as? NSNumber)?.uint64Value {
                currentIDs.insert(id)
            } else {
                NSLog("SpaceNote: ERROR — no parseable Current Space for display \(displayID)")
            }
            guard let rawSpaces = display["Spaces"] as? [[String: Any]] else {
                NSLog("SpaceNote: ERROR — no parseable Spaces array for display \(displayID)")
                continue
            }
            var ordinal = 0
            for raw in rawSpaces {
                guard let type = (raw["type"] as? NSNumber)?.intValue,
                      let id = (raw["id64"] as? NSNumber)?.uint64Value else {
                    NSLog("SpaceNote: ERROR — space dict missing type/id64: \(raw)")
                    continue
                }
                guard type == 0 else { continue }   // fullscreen-app spaces are not note territory
                ordinal += 1
                spaces.append(SpaceInfo(id64: id,
                                        uuid: raw["uuid"] as? String ?? "",
                                        displayIdentifier: displayID,
                                        ordinal: ordinal))
            }
        }
        snapshot = SpacesSnapshot(userSpaces: spaces,
                                  currentSpaceIDs: currentIDs,
                                  displayIdentifiers: displayIDs)
    }

    /// The space(s) a window is currently on. Empty = not yet committed by the
    /// WindowServer (normal right after orderFront — retry next turn).
    func spaceIDs(forWindow windowNumber: Int) -> [CGSSpaceID] {
        guard let sky, windowNumber > 0 else { return [] }
        let windows = [NSNumber(value: UInt32(windowNumber))] as CFArray
        guard let ids = sky.copySpacesForWindows(cid, SkyLight.allSpacesMask, windows)?
                .takeRetainedValue() as? [NSNumber] else { return [] }
        return ids.map { $0.uint64Value }
    }

    /// Fire-and-forget move; caller MUST verify via spaceIDs(forWindow:) a beat
    /// later and report failure (the call no-ops silently when restricted).
    func moveWindow(_ windowNumber: Int, to space: SpaceInfo) {
        guard let sky, let move = sky.moveWindowsToManagedSpace, windowNumber > 0 else { return }
        move(cid, [NSNumber(value: UInt32(windowNumber))] as CFArray, space.id64)
    }

    func reportWriteFailure() {
        guard writesAvailable else { return }
        writesAvailable = false
        NSLog("""
        SpaceNote: SPACE WRITE FAILED — a verified move did not take effect. \
        Falling back to current-space behavior; persisted space stamps are frozen \
        so your layout is preserved for when this works again.
        """)
    }
}
