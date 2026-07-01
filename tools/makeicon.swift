// makeicon.swift — draws the SpaceNote app icon with CoreGraphics and writes a PNG.
// Usage: swift tools/makeicon.swift <out.png> <pixelSize>
// Design space is 1024×1024; everything scales from there so it stays crisp at any size.
//
// Concept: the app's defining trait is per-Space persistence — a note remembers
// which Mission Control Space (desktop) it lives on. So the icon shows a hero
// sticky note sitting in front of a fan of little Mac "desktops," with a
// Mission-Control-style Spaces indicator at the top. It reads as "a note that
// belongs to a desktop," not merely "Stickies."

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let px = Int(args[2]) else {
    FileHandle.standardError.write("usage: makeicon.swift <out.png> <pixelSize>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create CGContext")
}

let scale = CGFloat(px) / 1024.0
ctx.scaleBy(x: scale, y: scale)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])!
}
func roundRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// ---------------------------------------------------------------- outer squircle
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundRect(body, 185)

// faint symmetric depth shadow (Big Sur+ icons keep this minimal)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 26, color: rgb(20, 30, 45, 0.10))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
ctx.restoreGState()

// backdrop: cool desktop gradient so the little screens/notes pop
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(grad([rgb(238, 243, 249), rgb(203, 215, 230)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// ---------------------------------------------------------------- a little Mac desktop
// A landscape "screen": wallpaper gradient + a translucent menu bar with a couple
// of status dots at the right. Different wallpaper hues = different Spaces.
func drawDesktop(center: CGPoint, w: CGFloat, h: CGFloat, rotationDeg: CGFloat,
                 wallTop: CGColor, wallBot: CGColor, dim: CGFloat = 0) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotationDeg * .pi / 180)
    let r = CGRect(x: -w/2, y: -h/2, width: w, height: h)
    let radius = h * 0.12
    let path = roundRect(r, radius)

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(20, 30, 45, 0.26))
    ctx.addPath(path); ctx.setFillColor(wallBot); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    // wallpaper
    ctx.drawLinearGradient(grad([wallTop, wallBot], [0, 1]),
                           start: CGPoint(x: 0, y: h/2), end: CGPoint(x: 0, y: -h/2), options: [])
    // translucent menu bar along the top — a broad cue that this is a Mac screen
    // (no status-icon detail: too fine to survive at small sizes)
    let barH = h * 0.15
    ctx.setFillColor(rgb(255, 255, 255, 0.55))
    ctx.fill(CGRect(x: -w/2, y: h/2 - barH, width: w, height: barH))
    ctx.setFillColor(rgb(255, 255, 255, 0.20))
    ctx.fill(CGRect(x: -w/2, y: h/2 - barH - 2, width: w, height: 2))
    // optional dim veil for receding desktops
    if dim > 0 {
        ctx.setFillColor(rgb(28, 40, 60, dim))
        ctx.fill(r)
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

// ---------------------------------------------------------------- a sticky note
func drawNote(center: CGPoint, size: CGFloat, rotationDeg: CGFloat,
              top: CGColor, bottom: CGColor, ruled: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotationDeg * .pi / 180)
    let r = CGRect(x: -size/2, y: -size/2, width: size, height: size)
    let path = roundRect(r, size * 0.085)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -7), blur: 20, color: rgb(20, 30, 45, 0.30))
    ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(grad([top, bottom], [0, 1]),
                           start: CGPoint(x: 0, y: size/2), end: CGPoint(x: 0, y: -size/2), options: [])
    ctx.drawLinearGradient(grad([rgb(255, 255, 255, 0.30), rgb(255, 255, 255, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: size/2), end: CGPoint(x: 0, y: size*0.08), options: [])
    if ruled {
        ctx.setStrokeColor(rgb(150, 96, 0, 0.20))
        ctx.setLineWidth(size * 0.018)
        ctx.setLineCap(.round)
        let inset = size * 0.16
        for ry in stride(from: size*0.22, through: -size*0.28, by: -size*0.165) {
            ctx.move(to: CGPoint(x: -size/2 + inset, y: ry))
            ctx.addLine(to: CGPoint(x: size/2 - inset, y: ry))
        }
        ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

// ---------------------------------------------------------------- compose
// The fanned desktops themselves convey "multiple Spaces" — the macOS way
// (Mission Control shows the desktops), not an iOS page-dot indicator.
// two Spaces (desktops) fanned behind, distinct wallpapers
drawDesktop(center: CGPoint(x: 372, y: 604), w: 486, h: 350, rotationDeg: 11,
            wallTop: rgb(126, 178, 236), wallBot: rgb(74, 128, 200), dim: 0.10)
drawDesktop(center: CGPoint(x: 652, y: 604), w: 486, h: 350, rotationDeg: -11,
            wallTop: rgb(120, 206, 190), wallBot: rgb(72, 158, 150), dim: 0.10)
// the current Space, centered and forward
drawDesktop(center: CGPoint(x: 512, y: 548), w: 552, h: 396, rotationDeg: 0,
            wallTop: rgb(180, 206, 240), wallBot: rgb(120, 160, 214))
// hero note living on the current Space
drawNote(center: CGPoint(x: 512, y: 512), size: 312, rotationDeg: 4,
         top: rgb(255, 231, 138), bottom: rgb(255, 197, 58), ruled: true)

// ---------------------------------------------------------------- write PNG
guard let image = ctx.makeImage() else { fatalError("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
do {
    try data.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
