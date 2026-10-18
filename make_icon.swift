#!/usr/bin/env swift
import Cocoa

// The Focus mark: an eye with a warm iris ring (it sees what's on the screen).
// Designed on a 100-unit grid; same geometry as `MenuBarRing.mark` in LockInApp.swift.
func drawMark(in body: NSRect) {
    let u = body.width * 0.0068
    let c = NSPoint(x: body.midX, y: body.midY)
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c.x + (x - 50) * u, y: c.y - (y - 50) * u) }

    let eye = NSBezierPath()
    eye.move(to: p(10, 50))
    eye.curve(to: p(90, 50), controlPoint1: p(26, 26), controlPoint2: p(74, 26))
    eye.curve(to: p(10, 50), controlPoint1: p(74, 74), controlPoint2: p(26, 74))
    eye.close()
    eye.lineWidth = 7.5 * u
    eye.lineJoinStyle = .round
    NSColor.white.setStroke()
    eye.stroke()

    let ir = 16 * u
    let iris = NSBezierPath(ovalIn: NSRect(x: c.x - ir, y: c.y - ir, width: ir * 2, height: ir * 2))
    iris.lineWidth = 6.5 * u
    NSColor(red: 1.0, green: 0.55, blue: 0.24, alpha: 1).setStroke()
    iris.stroke()

    let pr = 6.5 * u
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)).fill()
}

let background = [
    NSColor(red: 0.20, green: 0.22, blue: 0.36, alpha: 1),
    NSColor(red: 0.07, green: 0.08, blue: 0.15, alpha: 1),
]

func renderIcon(size: Int) -> NSImage {
    let dim = CGFloat(size)
    let image = NSImage(size: NSSize(width: dim, height: dim))
    image.lockFocus()

    let body = NSRect(x: 0, y: 0, width: dim, height: dim).insetBy(dx: dim * 0.098, dy: dim * 0.098)
    let radius = body.width * 0.225

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = dim * 0.012
    shadow.shadowOffset = NSSize(width: 0, height: -dim * 0.01)
    shadow.set()
    let bgPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor.black.setFill()
    bgPath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: background)?.draw(in: bgPath, angle: -90)
    drawMark(in: body)

    image.unlockFocus()
    return image
}

/// iOS wants a full-bleed, opaque square; the system applies the corner mask.
func saveIOSIcon(to path: String) {
    let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGradient(colors: background)?.draw(in: rect, angle: -90)
    drawMark(in: rect.insetBy(dx: 100, dy: 100))
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
if args.count > 2, args[1] == "--ios" {
    saveIOSIcon(to: args[2])
    print("Done")
    exit(0)
}

let iconsetPath = args.count > 1 ? args[1] : "/tmp/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let img = renderIcon(size: size)
    savePNG(img, to: "\(iconsetPath)/icon_\(size)x\(size).png")
    if size <= 512 {
        let img2 = renderIcon(size: size * 2)
        savePNG(img2, to: "\(iconsetPath)/icon_\(size)x\(size)@2x.png")
    }
}
print("Done")
