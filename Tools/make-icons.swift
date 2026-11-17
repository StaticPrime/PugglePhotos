#!/usr/bin/env swift
// Renders the PugglePhotos app icon at every size macOS needs.
// Usage: swift Tools/make-icons.swift PugglePhotos/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputFolder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Runs `body` with the drawing turned `degrees` around `center`.
func rotated(_ degrees: CGFloat, around center: NSPoint, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: degrees)
    transform.translateX(by: -center.x, yBy: -center.y)
    transform.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// An instant photo: a white print with a deeper margin at the bottom, and a picture drawn inside it.
func instantPhoto(_ frame: NSRect, shadow: NSColor, picture: (NSRect) -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let printShadow = NSShadow()
    printShadow.shadowColor = shadow
    printShadow.shadowBlurRadius = 22
    printShadow.shadowOffset = NSSize(width: 0, height: -10)
    printShadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18).fill()
    NSGraphicsContext.restoreGraphicsState()
    let inner = NSRect(x: frame.minX + 30, y: frame.minY + 30, width: frame.width - 60, height: frame.height - 116)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6).addClip()
    picture(inner)
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws the icon in a 1024x1024 design space with a top-left origin.
func drawIcon() {
    // Body: a light pink rounded square on the macOS icon grid (824pt body, 100pt margin).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x7A0F3D, 0.30)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0xFFD3E3).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFFEAF2), ending: color(0xFFC1D8))!.draw(in: bodyPath, angle: 90)

    // The print behind: tilted right, filled with the logo's pink.
    let back = NSRect(x: 372, y: 196, width: 420, height: 500)
    rotated(9, around: NSPoint(x: back.midX, y: back.midY)) {
        instantPhoto(back, shadow: color(0x7A0F3D, 0.25)) { inner in
            NSGradient(starting: color(0xFF5A9A), ending: color(0xE8236F))!.draw(in: inner, angle: -90)
        }
    }

    // The print in front: tilted left, with teal mountains under a yellow sun.
    let front = NSRect(x: 276, y: 236, width: 430, height: 512)
    rotated(-7, around: NSPoint(x: front.midX, y: front.midY)) {
        instantPhoto(front, shadow: color(0x7A0F3D, 0.30)) { inner in
            NSGradient(starting: color(0xE8F8FF), ending: color(0xBDE9F7))!.draw(in: inner, angle: -90)
            color(0xFEC138).setFill()
            NSBezierPath(ovalIn: NSRect(x: inner.maxX - 132, y: inner.minY + 46, width: 86, height: 86)).fill()
            let farRange = NSBezierPath()
            farRange.move(to: NSPoint(x: inner.minX, y: inner.maxY))
            farRange.line(to: NSPoint(x: inner.minX, y: inner.maxY - 120))
            farRange.line(to: NSPoint(x: inner.minX + 120, y: inner.minY + 150))
            farRange.line(to: NSPoint(x: inner.minX + 230, y: inner.maxY - 110))
            farRange.line(to: NSPoint(x: inner.maxX - 90, y: inner.minY + 186))
            farRange.line(to: NSPoint(x: inner.maxX, y: inner.maxY - 90))
            farRange.line(to: NSPoint(x: inner.maxX, y: inner.maxY))
            farRange.close()
            color(0x45CEC9).setFill()
            farRange.fill()
            let nearRange = NSBezierPath()
            nearRange.move(to: NSPoint(x: inner.minX, y: inner.maxY))
            nearRange.line(to: NSPoint(x: inner.minX, y: inner.maxY - 60))
            nearRange.line(to: NSPoint(x: inner.minX + 170, y: inner.minY + 196))
            nearRange.line(to: NSPoint(x: inner.maxX - 40, y: inner.maxY - 30))
            nearRange.line(to: NSPoint(x: inner.maxX, y: inner.maxY))
            nearRange.close()
            color(0x009EA2).setFill()
            nearRange.fill()
        }
    }

    // Paw print badge on the left, overlapping the front print's lower-left corner.
    let center = NSPoint(x: 314, y: 728)
    let pads: [NSRect] = [
        NSRect(x: center.x - 92, y: center.y - 30, width: 184, height: 150),
        NSRect(x: center.x - 152, y: center.y - 112, width: 70, height: 88),
        NSRect(x: center.x - 82, y: center.y - 168, width: 72, height: 92),
        NSRect(x: center.x + 10, y: center.y - 168, width: 72, height: 92),
        NSRect(x: center.x + 82, y: center.y - 112, width: 70, height: 88),
    ]
    NSGraphicsContext.saveGraphicsState()
    let pawShadow = NSShadow()
    pawShadow.shadowColor = color(0x7C2D12, 0.25)
    pawShadow.shadowBlurRadius = 12
    pawShadow.shadowOffset = NSSize(width: 0, height: -6)
    pawShadow.set()
    NSColor.white.setFill()
    for pad in pads { NSBezierPath(ovalIn: pad.insetBy(dx: -18, dy: -18)).fill() }
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFB020).setFill()
    for pad in pads { NSBezierPath(ovalIn: pad).fill() }
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(size))
    transform.scaleX(by: CGFloat(size) / 1024, yBy: -CGFloat(size) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: points * scale).write(to: outputFolder.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outputFolder.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icons to \(outputFolder.path)")
