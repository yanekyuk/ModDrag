#!/usr/bin/env swift
//
// make-dmg-background.swift — render the disk-image window background as a PNG.
//
// Soft near-white gradient with a clean chevron arrow pointing from the app
// icon toward the /Applications shortcut, plus a short caption underneath. The
// geometry matches the icon positions set by build-dmg.sh:
//   window content     : 600 x 380   (points)
//   app icon centre     : (150, 190)  measured from top-left (Finder coords)
//   Applications centre : (450, 190)
//
// The bitmap rep is backed by 2x pixels (1200x760) but keeps a 600x380 point
// size, so all drawing is done in plain points — NO extra scaleBy, or every
// element doubles and slides off-canvas.
//
// Usage: swift scripts/make-dmg-background.swift <output.png>
//
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"

let W = 600, H = 380
let scale = 2                                  // retina backing

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: W * scale, pixelsHigh: H * scale,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)         // 600x380 pt over 1200x760 px

NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext                       // CTM already maps points → 2x px

let w = CGFloat(W), h = CGFloat(H)

// --- Background gradient (subtle, top lighter) -------------------------------
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1),
        CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(grad,
    start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

// --- Chevron arrow between the two icons -------------------------------------
// Finder y is measured from the top; CG y from the bottom. Icon row centre is
// 190 from the top → h - 190 from the bottom.
let cy = h - 190
let chevronColor = CGColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1)
ctx.setStrokeColor(chevronColor)
ctx.setLineWidth(9)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Three soft chevrons ">" centred between the icons (icon inner edges ~214/386).
let armX: CGFloat = 22
let armY: CGFloat = 20
for cx in [CGFloat(268), 300, 332] {
    ctx.move(to: CGPoint(x: cx - armX, y: cy + armY))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx - armX, y: cy - armY))
    ctx.strokePath()
}

// --- Caption -----------------------------------------------------------------
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.46, green: 0.50, blue: 0.57, alpha: 1),
    .paragraphStyle: para,
]
let caption = NSAttributedString(
    string: "To install, drag ModDrag into Applications",
    attributes: attrs)
// Place below the icon row: Finder y ~300 from top → CG y ~80, give it height.
caption.draw(in: NSRect(x: 0, y: 64, width: w, height: 20))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(W * scale)x\(H * scale) px, \(W)x\(H) pt)")
