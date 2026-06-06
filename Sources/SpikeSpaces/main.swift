// spike-spaces — Phase 0 spike for SpaceNote (see PLAN.md §6).
//
// Establishes, on THIS macOS build:
//   (a) whether the read-tier CGS/SkyLight calls work and what the space dicts
//       actually look like (keys, uuid presence, types),
//   (b) whether space uuids / ordinals are stable across reboots (compare the
//       appended spike-spaces.log between sessions; each dump carries its boot time),
//   (c) Strategy A′: whether write-tier calls can move OUR OWN window to another
//       space unprivileged — verified by CGS readback, never assumed.
//
// Usage:
//   swift run SpikeSpaces --dump    # one-shot: resolve symbols, dump spaces, exit
//   swift run SpikeSpaces           # interactive window; keys:
//     d      dump all displays/spaces + test-window space
//     1-9    A′ test: CGSMoveWindowsToManagedSpace(test window → user space #N)
//     a      A′ test: CGSAddWindowsToSpaces(+next space) then RemoveFromSpaces(current)
//     q      quit
//   Switching desktops dumps automatically (activeSpaceDidChange).
//
// Everything is logged to ./spike-spaces.log (appended) for reboot comparison.

import AppKit
import Darwin
import Foundation

// MARK: - CGS types

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// CGSCopySpacesForWindows mask: current | other | user — i.e. all spaces.
let kCGSAllSpacesMask: Int32 = 7

// MARK: - Logging (stdout + append-only file for cross-reboot comparison)

final class Log {
    static let shared = Log()
    let path: String
    private let handle: FileHandle?

    private init() {
        path = FileManager.default.currentDirectoryPath + "/spike-spaces.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    func line(_ s: String) {
        print(s)
        handle?.write((s + "\n").data(using: .utf8)!)
    }
}

func log(_ s: String) { Log.shared.line(s) }

// MARK: - SkyLight dynamic loader (dlsym-primary per PLAN.md)

final class SkyLight {
    // Read tier — required; the spike (and the app) cannot proceed without these.
    let mainConnectionID: @convention(c) () -> CGSConnectionID
    let copyManagedDisplaySpaces: @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    let copySpacesForWindows: @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    // Read tier — optional, informational.
    let getActiveSpace: (@convention(c) (CGSConnectionID) -> CGSSpaceID)?
    // Write tier — Strategy A′ hypotheses (PLAN.md §1); may be absent or silently inert.
    let addWindowsToSpaces: (@convention(c) (CGSConnectionID, CFArray, CFArray) -> Void)?
    let removeWindowsFromSpaces: (@convention(c) (CGSConnectionID, CFArray, CFArray) -> Void)?
    let moveWindowsToManagedSpace: (@convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void)?

    let report: [String]

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            log("FATAL: dlopen(SkyLight) failed: \(String(cString: dlerror()))")
            return nil
        }
        var rep: [String] = []
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { rep.append("  ✗ \(name)  NOT FOUND"); return nil }
            rep.append("  ✓ \(name)")
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let main = sym("CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self),
            let cmds = sym("CGSCopyManagedDisplaySpaces", as: (@convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?).self),
            let csfw = sym("CGSCopySpacesForWindows", as: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        else {
            report = rep
            log("FATAL: required read-tier symbol missing:")
            rep.forEach { log($0) }
            return nil
        }
        mainConnectionID = main
        copyManagedDisplaySpaces = cmds
        copySpacesForWindows = csfw
        getActiveSpace = sym("CGSGetActiveSpace", as: (@convention(c) (CGSConnectionID) -> CGSSpaceID).self)
        addWindowsToSpaces = sym("CGSAddWindowsToSpaces", as: (@convention(c) (CGSConnectionID, CFArray, CFArray) -> Void).self)
        removeWindowsFromSpaces = sym("CGSRemoveWindowsFromSpaces", as: (@convention(c) (CGSConnectionID, CFArray, CFArray) -> Void).self)
        moveWindowsToManagedSpace = sym("CGSMoveWindowsToManagedSpace", as: (@convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void).self)
        report = rep
    }
}

// MARK: - Space inspection

struct UserSpace {
    let ordinal: Int          // 1-based, across displays in CGS order
    let id64: CGSSpaceID
    let uuid: String
    let displayIndex: Int
    let displayIdentifier: String
}

func spacesForWindow(_ sky: SkyLight, _ cid: CGSConnectionID, _ windowNumber: Int) -> [CGSSpaceID] {
    let ids = [NSNumber(value: UInt32(windowNumber))] as CFArray
    guard let arr = sky.copySpacesForWindows(cid, kCGSAllSpacesMask, ids)?.takeRetainedValue() as? [NSNumber] else {
        return []
    }
    return arr.map { $0.uint64Value }
}

/// Dumps the raw managed-display-spaces structure verbatim (the point is to pin the
/// dict shape on this build — do not pre-filter), and returns the user spaces found.
@discardableResult
func dumpAll(_ sky: SkyLight, _ cid: CGSConnectionID, testWindowNumber: Int?) -> [UserSpace] {
    let boot = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
    let fmt = ISO8601DateFormatter()
    log("---- DUMP \(fmt.string(from: Date()))  (booted \(fmt.string(from: boot))) ----")

    guard let raw = sky.copyManagedDisplaySpaces(cid)?.takeRetainedValue() else {
        log("ERROR: CGSCopyManagedDisplaySpaces returned nil")
        return []
    }
    guard let displays = raw as? [[String: Any]] else {
        log("ERROR: unexpected top-level shape (not array of dicts). Raw: \(raw)")
        return []
    }

    var userSpaces: [UserSpace] = []
    var ordinal = 0
    for (di, disp) in displays.enumerated() {
        let dispID = disp["Display Identifier"] as? String ?? "<missing>"
        log("Display[\(di)] \"\(dispID)\"")
        if let cur = disp["Current Space"] as? [String: Any] {
            log("  Current Space: \(cur)")
        } else {
            log("  Current Space: MISSING/UNEXPECTED: \(String(describing: disp["Current Space"]))")
        }
        if let spaces = disp["Spaces"] as? [[String: Any]] {
            for (si, sp) in spaces.enumerated() {
                log("  Space[\(si)]: \(sp)")
                let type = (sp["type"] as? NSNumber)?.intValue ?? -1
                let id64 = (sp["id64"] as? NSNumber)?.uint64Value
                let uuid = sp["uuid"] as? String ?? ""
                if type == 0, let id64 {
                    ordinal += 1
                    userSpaces.append(UserSpace(ordinal: ordinal, id64: id64, uuid: uuid,
                                                displayIndex: di, displayIdentifier: dispID))
                }
            }
        } else {
            log("  Spaces: MISSING/UNEXPECTED: \(String(describing: disp["Spaces"]))")
        }
        for key in disp.keys where !["Display Identifier", "Current Space", "Spaces"].contains(key) {
            log("  (extra display key) \(key) = \(disp[key]!)")
        }
    }

    log("User spaces (type==0): " + userSpaces.map {
        "#\($0.ordinal) id64=\($0.id64) uuid=\($0.uuid.isEmpty ? "<EMPTY>" : $0.uuid) display=\($0.displayIndex)"
    }.joined(separator: " | "))

    if let active = sky.getActiveSpace {
        log("CGSGetActiveSpace → \(active(cid))")
    }
    if let wn = testWindowNumber {
        log("Test window #\(wn) on space(s): \(spacesForWindow(sky, cid, wn))")
    }
    log("")
    return userSpaces
}

// MARK: - Strategy A′ write tests (own window only; verdict by readback)

func verdict(_ label: String, before: [CGSSpaceID], after: [CGSSpaceID], target: CGSSpaceID) {
    let result: String
    if after == [target] {
        result = "MOVED ✓ — A′ write tier WORKS for own windows"
    } else if after == before {
        result = "NO-OP ✗ — call silently ignored (restricted on this build)"
    } else {
        result = "ODD STATE ⚠ — investigate"
    }
    log("VERDICT[\(label)]: before=\(before) after=\(after) target=\(target) → \(result)\n")
}

func testMove(_ sky: SkyLight, _ cid: CGSConnectionID, window: NSWindow, to target: UserSpace) {
    let wn = window.windowNumber
    let before = spacesForWindow(sky, cid, wn)
    log("A′ TEST move: window #\(wn) \(before) → ordinal #\(target.ordinal) (id64 \(target.id64))")
    guard let move = sky.moveWindowsToManagedSpace else {
        log("VERDICT[move]: CGSMoveWindowsToManagedSpace symbol ABSENT — untestable\n")
        return
    }
    move(cid, [NSNumber(value: UInt32(wn))] as CFArray, target.id64)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        verdict("move", before: before, after: spacesForWindow(sky, cid, wn), target: target.id64)
    }
}

func testAddRemove(_ sky: SkyLight, _ cid: CGSConnectionID, window: NSWindow, userSpaces: [UserSpace]) {
    let wn = window.windowNumber
    let before = spacesForWindow(sky, cid, wn)
    guard let add = sky.addWindowsToSpaces, let remove = sky.removeWindowsFromSpaces else {
        log("VERDICT[add/remove]: symbol(s) ABSENT — untestable\n")
        return
    }
    guard let currentID = before.first,
          let target = userSpaces.first(where: { $0.id64 != currentID }) else {
        log("A′ TEST add/remove: need ≥2 user spaces and a readable current space — skipped\n")
        return
    }
    let wins = [NSNumber(value: UInt32(wn))] as CFArray
    log("A′ TEST add/remove: window #\(wn) \(before) — add to \(target.id64), then remove from \(currentID)")
    add(cid, wins, [NSNumber(value: target.id64)] as CFArray)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        log("  after add: \(spacesForWindow(sky, cid, wn)) (expect both spaces if add worked)")
        remove(cid, wins, [NSNumber(value: currentID)] as CFArray)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            verdict("add/remove", before: before, after: spacesForWindow(sky, cid, wn), target: target.id64)
        }
    }
}

// MARK: - Interactive app

final class KeyView: NSView {
    var onKey: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if let ch = event.charactersIgnoringModifiers, !ch.isEmpty { onKey?(ch) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sky: SkyLight
    let cid: CGSConnectionID
    let automove: Bool
    var window: NSWindow!
    var userSpaces: [UserSpace] = []

    init(sky: SkyLight, cid: CGSConnectionID, automove: Bool) {
        self.sky = sky
        self.cid = cid
        self.automove = automove
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 480, height: 200),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "spike-spaces"
        window.isReleasedWhenClosed = false

        let view = KeyView()
        let label = NSTextField(wrappingLabelWithString: """
        spike-spaces — output goes to terminal + spike-spaces.log

        d    dump displays/spaces (also fires on desktop switch)
        1-9  A′: move THIS window to user space #N, verify by readback
        a    A′: add-to-next-space, remove-from-current, verify
        q    quit

        Also: drag this window to another desktop via Mission Control,
        then press d — checks readback after an MC drag.
        """)
        label.frame = NSRect(x: 16, y: 12, width: 448, height: 176)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
        window.contentView = view
        view.onKey = { [weak self] ch in self?.handleKey(ch) }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            log("== activeSpaceDidChangeNotification ==")
            self.userSpaces = dumpAll(self.sky, self.cid, testWindowNumber: self.window.windowNumber)
        }

        userSpaces = dumpAll(sky, cid, testWindowNumber: window.windowNumber)

        if automove { runAutomove() }
    }

    /// Unattended A′ test: move our window to a different user space, verify by
    /// readback, then add/remove, then exit. No keyboard interaction needed.
    func runAutomove() {
        let wn = window.windowNumber
        let current = spacesForWindow(sky, cid, wn)
        guard let target = userSpaces.first(where: { !current.contains($0.id64) }) else {
            log("automove: need ≥2 user spaces — aborting")
            NSApp.terminate(nil)
            return
        }
        log(">>> automove: unattended A′ test sequence <<<")
        testMove(sky, cid, window: window, to: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            testAddRemove(self.sky, self.cid, window: self.window, userSpaces: self.userSpaces)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            log(">>> automove complete <<<")
            NSApp.terminate(nil)
        }
    }

    func handleKey(_ ch: String) {
        switch ch {
        case "d":
            userSpaces = dumpAll(sky, cid, testWindowNumber: window.windowNumber)
        case "a":
            userSpaces = dumpAll(sky, cid, testWindowNumber: window.windowNumber)
            testAddRemove(sky, cid, window: window, userSpaces: userSpaces)
        case "q":
            NSApp.terminate(nil)
        default:
            if let n = Int(ch), n >= 1 {
                userSpaces = dumpAll(sky, cid, testWindowNumber: window.windowNumber)
                guard let target = userSpaces.first(where: { $0.ordinal == n }) else {
                    log("No user space with ordinal #\(n) (have \(userSpaces.count))")
                    return
                }
                testMove(sky, cid, window: window, to: target)
            }
        }
    }
}

// MARK: - Entry

guard let sky = SkyLight() else { exit(2) }
log("==== spike-spaces session start ====")
log("Symbol resolution:")
sky.report.forEach { log($0) }
let cid = sky.mainConnectionID()
log("CGSMainConnectionID → \(cid)")
log("Log file: \(Log.shared.path)\n")

if CommandLine.arguments.contains("--dump") {
    dumpAll(sky, cid, testWindowNumber: nil)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(sky: sky, cid: cid,
                           automove: CommandLine.arguments.contains("--automove"))
app.delegate = delegate
app.run()
