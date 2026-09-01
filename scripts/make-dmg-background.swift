#!/usr/bin/env swift

// Renders the DMG window background.
//
// Run at both 1x and 2x and combine with `tiffutil -cathidpicheck` so the
// window stays crisp on Retina displays:
//
//   swift make-dmg-background.swift out.png 1
//   swift make-dmg-background.swift out@2x.png 2
//
// The background is deliberately light. Finder draws icon labels using the
// system appearance, not the image, so a dark background renders dark label
// text on dark pixels for anyone in light mode.

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <out.png> [scale]\n".utf8))
    exit(1)
}
let outPath = args[1]
let scale = args.count > 2 ? (Double(args[2]) ?? 1) : 1

// Window geometry, in points. Must match the values in make-dmg.sh.
let w = 660.0
let h = 400.0
let iconY = 205.0
let appX = 170.0
let dropX = 490.0

let px = Int(w * scale)
let py = Int(h * scale)

guard let ctx = CGContext(
    data: nil,
    width: px,
    height: py,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create context\n".utf8))
    exit(1)
}

ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

// Flip to top-left origin so the numbers above read the same way create-dmg's
// --icon coordinates do.
ctx.translateBy(x: 0, y: CGFloat(h))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a))
}

// Vertical gradient wash.
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgb(252, 252, 253), rgb(234, 236, 241)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: h),
    options: []
)

// Soft plates under each icon to anchor them visually.
for cx in [appX, dropX] {
    let r = 74.0
    ctx.setFillColor(rgb(255, 255, 255, 0.55))
    ctx.fillEllipse(in: CGRect(x: cx - r, y: iconY - r + 6, width: r * 2, height: r * 2))
}

// Arrow from the app toward the Applications link.
let arrowY = iconY + 6
let startX = appX + 96
let endX = dropX - 96
ctx.setStrokeColor(rgb(176, 181, 191))
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [1, 9])
ctx.move(to: CGPoint(x: startX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - 14, y: arrowY))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

ctx.setFillColor(rgb(176, 181, 191))
ctx.move(to: CGPoint(x: endX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - 15, y: arrowY - 8))
ctx.addLine(to: CGPoint(x: endX - 15, y: arrowY + 8))
ctx.closePath()
ctx.fillPath()

// Text. Drawn through NSGraphicsContext so AppKit string drawing lands in our
// bitmap, with the flip undone first so glyphs aren't upside down.
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centerX: Double, top: Double) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color)!,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let bounds = s.size()
    ctx.saveGState()
    // Undo the global flip locally, converting the top-left y we were given.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    let originY = h - top - Double(bounds.height)
    s.draw(at: NSPoint(x: centerX - Double(bounds.width) / 2, y: originY))
    ctx.restoreGState()
}

draw("MusicPlayerMenubar", size: 21, weight: .semibold, color: rgb(52, 56, 66), centerX: w / 2, top: 44)
draw("Drag the app into your Applications folder", size: 12.5, weight: .regular, color: rgb(126, 132, 143), centerX: w / 2, top: 76)

NSGraphicsContext.restoreGraphicsState()

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("could not render image\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: w, height: h)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode png\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
