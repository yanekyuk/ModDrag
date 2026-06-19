#!/usr/bin/env swift
//
// make-tray.swift — render the menu-bar (status item) glyph as a vector PDF.
//
// Output is a monochrome, transparent template image: a minimal window outline
// (no move arrow, no motion trail) sized for the macOS menu bar. Drawing it as a
// PDF keeps it crisp at every display scale. The app loads it with isTemplate =
// true so macOS tints it automatically for light/dark menu bars.
//
// Usage: swift scripts/make-tray.swift <output.pdf>
//
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TrayIcon.pdf"
let S: CGFloat = 18                       // menu-bar template canvas (points)

let data = NSMutableData()
let consumer = CGDataConsumer(data: data as CFMutableData)!
var mediaBox = CGRect(x: 0, y: 0, width: S, height: S)
let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
ctx.beginPDFPage(nil)

let black = CGColor(gray: 0, alpha: 1)
ctx.setStrokeColor(black)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)

// Window outline — a rounded rectangle filling most of the canvas.
let lw: CGFloat = 1.7
let win = CGRect(x: 1.6, y: 3.2, width: S - 3.2, height: S - 5.8)
let radius: CGFloat = 2.6
ctx.addPath(CGPath(
    roundedRect: win.insetBy(dx: lw/2, dy: lw/2),
    cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setLineWidth(lw)
ctx.strokePath()

// Title-bar separator line near the top.
let titleY = win.maxY - 3.4
ctx.move(to: CGPoint(x: win.minX + lw/2, y: titleY))
ctx.addLine(to: CGPoint(x: win.maxX - lw/2, y: titleY))
ctx.setLineWidth(lw)
ctx.strokePath()

ctx.endPDFPage()
ctx.closePDF()

try! (data as Data).write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(Int(S))x\(Int(S)) pt vector template)")
