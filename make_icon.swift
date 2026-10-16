#!/usr/bin/env swift
import Cocoa

// The Focus mark: a goal ring closing on a single point. Same geometry as
// `FocusMark` in LockInApp.swift (menu bar), drawn on the macOS icon grid.
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

    NSGradient(colors: [
        NSColor(red: 0.20, green: 0.22, blue: 0.36, alpha: 1),
        NSColor(red: 0.07, green: 0.08, blue: 0.15, alpha: 1),
    ])?.draw(in: bgPath, angle: -90)

    let c = NSPoint(x: body.midX, y: body.midY)
    let r = body.width * 0.27
    let line = body.width * 0.085

    let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    track.lineWidth = line
    NSColor.white.withAlphaComponent(0.14).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 290, clockwise: true)
    arc.lineWidth = line
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    let d = body.width * 0.115
    NSColor(red: 1.0, green: 0.55, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)).fill()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.iconset"
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
