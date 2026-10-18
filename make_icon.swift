#!/usr/bin/env swift
import Cocoa

// The Focus mark: an eye looking down at the tape, a beam from its pupil to the cell it's
// reading (0 1 0). Designed on a 1024 canvas, y down; the menu bar's `MenuBarRing.mark`
// in LockInApp.swift is the same eye and cells without the beam or digits.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let navy = rgb(0x0D1756)
let mint = rgb(0x7FE3D4)

/// Draws the full-bleed icon into `square` (the 1024 canvas).
func drawIcon(in square: NSRect) {
    let s = square.width / 1024
    let k: CGFloat = 1.08
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        let mx = 512 + (x - 512) * k, my = 526 + (y - 526) * k
        return NSPoint(x: square.minX + mx * s, y: square.maxY - my * s)
    }
    func d(_ v: CGFloat) -> CGFloat { v * k * s }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        let o = p(x, y + h)
        return NSRect(x: o.x, y: o.y, width: d(w), height: d(h))
    }

    NSGradient(colors: [rgb(0x2A3FA8), rgb(0x0B1450)])?.draw(in: square, angle: -45)

    // The eye: a lens of two circular arcs, 600 wide and 320 tall, centered at (512, 392).
    let eye = NSBezierPath()
    let r: CGFloat = 361.25
    for (cy, from, to) in [(593.25, CGFloat.pi + 0.5913, 2 * CGFloat.pi - 0.5913), (190.75, 0.5913, CGFloat.pi - 0.5913)] {
        for i in 0...96 {
            let a = from + (to - from) * CGFloat(i) / 96
            let pt = p(512 + r * cos(a), cy + r * sin(a))
            if eye.isEmpty { eye.move(to: pt) } else { eye.line(to: pt) }
        }
    }
    eye.close()
    NSGradient(colors: [.white, rgb(0xE6ECFF)])?.draw(in: eye, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    eye.addClip()
    navy.setFill()
    NSBezierPath(ovalIn: rect(388, 312, 248, 248)).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let beam = NSBezierPath()
    beam.move(to: p(480, 470)); beam.line(to: p(544, 470)); beam.line(to: p(604, 700)); beam.line(to: p(420, 700))
    beam.close()
    NSGradient(colors: [mint.withAlphaComponent(0.9), mint.withAlphaComponent(0.15)])?.draw(in: beam, angle: -90)

    mint.setFill()
    NSBezierPath(ovalIn: rect(468, 412, 88, 88)).fill()

    // The tape: one strip, three cells, the read one lit.
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: rect(232, 700, 560, 120), xRadius: d(34), yRadius: d(34)).addClip()
    for (x, color) in [(CGFloat(232), NSColor.white.withAlphaComponent(0.14)), (422, mint), (612, NSColor.white.withAlphaComponent(0.14))] {
        color.setFill()
        rect(x, 700, 180, 120).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    for x in [CGFloat(322), 702] {
        let zero = NSBezierPath(roundedRect: rect(x - 17, 730, 34, 60), xRadius: d(17), yRadius: d(17))
        zero.lineWidth = d(9)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        zero.stroke()
    }
    let one = NSBezierPath()
    one.move(to: p(500, 742)); one.line(to: p(515, 730)); one.line(to: p(515, 790))
    one.lineWidth = d(10)
    one.lineCapStyle = .round
    one.lineJoinStyle = .round
    navy.setStroke()
    one.stroke()
}

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

    NSGraphicsContext.current?.saveGraphicsState()
    bgPath.addClip()
    drawIcon(in: body)
    NSGraphicsContext.current?.restoreGraphicsState()

    image.unlockFocus()
    return image
}

/// iOS wants a full-bleed, opaque square; the system applies the corner mask.
func saveIOSIcon(to path: String) {
    let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    drawIcon(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
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
