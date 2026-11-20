// Renders icon.png (1024 x 1024): the tweak's progress bar glyph, crossed out, on a dark rounded square.
// Run: swift make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let corner = size * 0.225
NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: corner, yRadius: corner).fill()

let mid = size / 2, line = size * 0.06, start = size * 0.16, end = size * 0.84, dotX = size * 0.40
let red = NSColor(calibratedRed: 0.95, green: 0.12, blue: 0.16, alpha: 1)
func stroke(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: from, y: mid))
    path.line(to: NSPoint(x: to, y: mid))
    path.lineWidth = line
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}
stroke(start, end, NSColor(calibratedWhite: 1, alpha: 0.35)) // the rest of the video
stroke(start, dotX, red)                                      // played
let r = size * 0.115
red.setFill()
NSBezierPath(ovalIn: NSRect(x: dotX - r, y: mid - r, width: 2 * r, height: 2 * r)).fill()
// The slash, with a gap of the background around it.
func slash(_ width: CGFloat, _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: size * 0.30, y: size * 0.22))
    path.line(to: NSPoint(x: size * 0.70, y: size * 0.78))
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}
slash(size * 0.11, NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))
slash(size * 0.05, .white)
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))
