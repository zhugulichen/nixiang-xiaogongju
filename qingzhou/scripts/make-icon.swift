import AppKit

let output = CommandLine.arguments[1]
let folder = URL(fileURLWithPath: output).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let rect = NSRect(x: 52, y: 52, width: 920, height: 920)
let background = NSBezierPath(roundedRect: rect, xRadius: 215, yRadius: 215)
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.65, blue: 0.57, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.32, blue: 0.34, alpha: 1))!.draw(in: background, angle: -60)
NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: 210, y: 180, width: 650, height: 650)).fill()
let sail = NSBezierPath()
sail.move(to: NSPoint(x: 490, y: 790)); sail.line(to: NSPoint(x: 490, y: 370)); sail.line(to: NSPoint(x: 235, y: 370)); sail.close()
NSColor.white.setFill(); sail.fill()
let small = NSBezierPath()
small.move(to: NSPoint(x: 540, y: 685)); small.line(to: NSPoint(x: 540, y: 370)); small.line(to: NSPoint(x: 763, y: 370)); small.close()
NSColor(calibratedRed: 0.73, green: 0.94, blue: 0.88, alpha: 1).setFill(); small.fill()
let hull = NSBezierPath()
hull.move(to: NSPoint(x: 207, y: 328)); hull.line(to: NSPoint(x: 810, y: 328))
hull.curve(to: NSPoint(x: 670, y: 213), controlPoint1: NSPoint(x: 770, y: 231), controlPoint2: NSPoint(x: 737, y: 213))
hull.line(to: NSPoint(x: 350, y: 213))
hull.curve(to: NSPoint(x: 207, y: 328), controlPoint1: NSPoint(x: 290, y: 213), controlPoint2: NSPoint(x: 249, y: 250)); hull.close()
NSColor.white.setFill(); hull.fill()
image.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
