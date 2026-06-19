#!/usr/bin/env swift
//
// make-icon.swift — render the ModDrag master app-icon artwork (1024x1024 PNG).
//
// Draws a minimal macOS-style window glyph on a rounded-superellipse ("squircle")
// background, matching the menu-bar `macwindow` symbol for visual consistency.
//
// Usage: swift scripts/make-icon.swift <output.png>
//
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let S: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Transparent canvas.
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// --- Squircle background (Apple-grid inset ~ 824px, generous corner radius). ---
let margin: CGFloat = 100
let bgRect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let bgRadius: CGFloat = 190
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
// Vertical indigo/blue gradient.
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(96, 125, 232), color(58, 92, 210)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
// Soft top highlight.
let hi = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(255, 255, 255, 0.18), color(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(hi, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S*0.55), options: [])
ctx.restoreGState()

// Subtle inner hairline for definition.
ctx.addPath(CGPath(roundedRect: bgRect.insetBy(dx: 2, dy: 2), cornerWidth: bgRadius-2, cornerHeight: bgRadius-2, transform: nil))
ctx.setStrokeColor(color(255, 255, 255, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()

// --- Window glyph: a window caught mid-drag (trailing ghosts + move arrow). ---
let winW: CGFloat = 470
let winH: CGFloat = 360
let winRadius: CGFloat = 46
// Nudge the live window down-right so the motion trail has room up-left.
let drag = CGVector(dx: 34, dy: -28)
let winRect = CGRect(x: (S - winW)/2 + drag.dx, y: (S - winH)/2 + drag.dy, width: winW, height: winH)
let winPath = CGPath(roundedRect: winRect, cornerWidth: winRadius, cornerHeight: winRadius, transform: nil)

func shiftedWindow(_ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    CGPath(roundedRect: winRect.offsetBy(dx: dx, dy: dy), cornerWidth: winRadius, cornerHeight: winRadius, transform: nil)
}

// Motion trail: two ghost copies receding up-left, implying the drag path.
for (off, alpha) in [(CGPoint(x: -110, y: 92), 0.16), (CGPoint(x: -55, y: 46), 0.30)] {
    ctx.addPath(shiftedWindow(off.x, off.y))
    ctx.setFillColor(color(255, 255, 255, alpha))
    ctx.fillPath()
}

// Speed streaks trailing off the upper-left corner.
ctx.setLineCap(.round)
ctx.setStrokeColor(color(255, 255, 255, 0.45))
let streakBase = CGPoint(x: winRect.minX - 150, y: winRect.maxY + 70)
for (i, len) in [86.0, 120.0, 78.0].enumerated() {
    let y = streakBase.y - CGFloat(i) * 52
    ctx.setLineWidth(16)
    ctx.move(to: CGPoint(x: streakBase.x, y: y))
    ctx.addLine(to: CGPoint(x: streakBase.x + CGFloat(len), y: y - CGFloat(len) * 0.84))
    ctx.strokePath()
}

// Drop shadow behind the live window.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.28))
ctx.addPath(winPath)
ctx.setFillColor(color(255, 255, 255, 1))
ctx.fillPath()
ctx.restoreGState()

// Title bar fill (slightly grey) clipped to the window shape.
let titleBarH: CGFloat = 96
let titleRect = CGRect(x: winRect.minX, y: winRect.maxY - titleBarH, width: winW, height: titleBarH)
ctx.saveGState()
ctx.addPath(winPath)
ctx.clip()
ctx.setFillColor(color(238, 241, 248, 1))
ctx.fill(titleRect)
// Divider line under the title bar.
ctx.setFillColor(color(206, 212, 226, 1))
ctx.fill(CGRect(x: winRect.minX, y: winRect.maxY - titleBarH, width: winW, height: 3))
ctx.restoreGState()

// Three traffic-light dots.
let dotR: CGFloat = 19
let dotY = winRect.maxY - titleBarH/2
let dotColors = [color(237, 106, 94), color(244, 191, 79), color(98, 197, 84)]
for (i, c) in dotColors.enumerated() {
    let cx = winRect.minX + 56 + CGFloat(i) * 58
    ctx.setFillColor(c)
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: dotY - dotR, width: 2*dotR, height: 2*dotR))
}


NSGraphicsContext.current!.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(Int(S))x\(Int(S)))")
