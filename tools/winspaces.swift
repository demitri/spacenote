// Dev verifier: prints which space each window of an app is on, via CGS readback.
// Usage: swift tools/winspaces.swift [AppName=SpaceNote]
import AppKit
import Darwin

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SpaceNote"

typealias CID = Int32
guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let mainSym = dlsym(h, "CGSMainConnectionID"),
      let querySym = dlsym(h, "CGSCopySpacesForWindows") else {
    fatalError("SkyLight symbols unavailable")
}
let mainCID = unsafeBitCast(mainSym, to: (@convention(c) () -> CID).self)
let query = unsafeBitCast(
    querySym, to: (@convention(c) (CID, Int32, CFArray) -> Unmanaged<CFArray>?).self)
let cid = mainCID()

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows {
    guard (w[kCGWindowOwnerName as String] as? String) == target,
          (w[kCGWindowLayer as String] as? Int) == 0,   // note windows only, not status item
          let num = w[kCGWindowNumber as String] as? Int else { continue }
    let spaces = query(cid, 7, [NSNumber(value: UInt32(num))] as CFArray)?
        .takeRetainedValue() as? [NSNumber] ?? []
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window=\(num) spaces=\(spaces.map(\.uint64Value)) size=\(bounds["Width"] ?? "?")x\(bounds["Height"] ?? "?")")
}
