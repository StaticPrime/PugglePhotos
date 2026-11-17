#if DEBUG
import CoreGraphics
import Foundation

/// Paints the sample library's "photos": simple illustrated scenes, different every time, drawn with Core Graphics
/// so they can be made at any size on any thread.
nonisolated enum SampleScene: String, CaseIterable, Sendable {
    case lake, beach, party, snow, hike, city, garden, food, pug, sunset, screenshot, scan

    /// Width over height for photos of this scene.
    func aspect(seed: Int) -> CGFloat {
        switch self {
        case .screenshot: return 16.0 / 10.0
        case .scan: return seed % 2 == 0 ? 7.0 / 5.0 : 5.0 / 7.0
        default: return seed % 5 == 3 ? 3.0 / 4.0 : 4.0 / 3.0
        }
    }

    /// Renders the scene `maxPixels` along its longer side (or `aspectOverride` wide over tall).
    static func render(_ scene: SampleScene, seed: Int, maxPixels: CGFloat, aspect aspectOverride: CGFloat? = nil,
                       time: CGFloat = 0) -> CGImage? {
        let aspect = aspectOverride ?? scene.aspect(seed: seed)
        let width = Int(aspect >= 1 ? maxPixels : maxPixels * aspect)
        let height = Int(aspect >= 1 ? maxPixels / aspect : maxPixels)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Draw in a top-left space 1000 units wide.
        let unit = CGFloat(width) / 1000
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: unit, y: -unit)
        var painter = Painter(context: context, width: 1000, height: CGFloat(height) / unit, random: Random(seed: seed), time: time)
        painter.paint(scene)
        return context.makeImage()
    }
}

/// A small repeatable random number generator, so each sample photo looks the same every time.
nonisolated struct Random: Sendable {
    private var state: UInt64

    init(seed: Int) { state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        return z ^ (z >> 29)
    }

    mutating func unit() -> CGFloat { CGFloat(next() % 10_000) / 10_000 }
    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }
    mutating func int(_ count: Int) -> Int { Int(next() % UInt64(max(count, 1))) }
}

nonisolated private struct Painter {
    let context: CGContext
    let width: CGFloat
    let height: CGFloat
    var random: Random
    let time: CGFloat

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    func gradient(_ top: UInt32, _ bottom: UInt32, from y0: CGFloat = 0, to y1: CGFloat? = nil) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray,
                                  locations: [0, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: y0, width: width, height: (y1 ?? height) - y0))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1 ?? height), options: [])
        context.restoreGState()
    }

    func fill(_ hex: UInt32, _ alpha: CGFloat = 1, _ path: CGPath) {
        context.setFillColor(color(hex, alpha))
        context.addPath(path)
        context.fillPath()
    }

    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32, _ alpha: CGFloat = 1) {
        fill(hex, alpha, CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil))
    }

    func rect(_ rect: CGRect, _ hex: UInt32, _ alpha: CGFloat = 1, radius: CGFloat = 0) {
        fill(hex, alpha, CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }

    /// A jagged ridge from the left edge to the right, filled down to the bottom.
    mutating func ridge(base: CGFloat, peak: CGFloat, count: Int, _ hex: UInt32, _ alpha: CGFloat = 1) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: base))
        let step = width / CGFloat(count)
        for index in 0..<count {
            let x = CGFloat(index) * step
            path.addLine(to: CGPoint(x: x + step * random.range(0.3, 0.7), y: base - peak * random.range(0.4, 1)))
            path.addLine(to: CGPoint(x: x + step, y: base - peak * random.range(0, 0.25)))
        }
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        fill(hex, alpha, path)
    }

    /// Rolling hills.
    mutating func hills(base: CGFloat, amplitude: CGFloat, _ hex: UInt32) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: base))
        let phase = random.range(0, 6)
        var x: CGFloat = 0
        while x <= width {
            path.addLine(to: CGPoint(x: x, y: base - amplitude * (0.5 + 0.5 * sin(x / 160 + phase))))
            x += 20
        }
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        fill(hex, 1, path)
    }

    func pine(_ x: CGFloat, _ bottom: CGFloat, _ size: CGFloat, _ hex: UInt32, snow: Bool = false) {
        rect(CGRect(x: x - size * 0.06, y: bottom - size * 0.2, width: size * 0.12, height: size * 0.2), 0x5B3A1E)
        for tier in 0..<3 {
            let top = bottom - size * (0.45 + 0.27 * CGFloat(tier)) - size * 0.1
            let half = size * (0.32 - 0.07 * CGFloat(tier))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + half, y: top + size * 0.42))
            path.addLine(to: CGPoint(x: x - half, y: top + size * 0.42))
            path.closeSubpath()
            fill(hex, 1, path)
            if snow {
                let cap = CGMutablePath()
                cap.move(to: CGPoint(x: x, y: top))
                cap.addLine(to: CGPoint(x: x + half * 0.45, y: top + size * 0.19))
                cap.addLine(to: CGPoint(x: x - half * 0.45, y: top + size * 0.19))
                cap.closeSubpath()
                fill(0xFFFFFF, 1, cap)
            }
        }
    }

    mutating func paint(_ scene: SampleScene) {
        switch scene {
        case .lake: lake()
        case .beach: beach()
        case .party: party()
        case .snow: snow()
        case .hike: hike()
        case .city: city()
        case .garden: garden()
        case .food: food()
        case .pug: pug()
        case .sunset: sunset()
        case .screenshot: screenshot()
        case .scan: scan()
        }
    }

    mutating func lake() {
        gradient(0x6EC6F5, 0xD8F1FF, to: height * 0.55)
        circle(random.range(150, 850), height * random.range(0.12, 0.22), 46, 0xFEC138)
        ridge(base: height * 0.5, peak: height * 0.3, count: 4, 0x7C93B8)
        ridge(base: height * 0.55, peak: height * 0.16, count: 6, 0x4F6F8F)
        gradient(0x3B8DBF, 0x1E5E86, from: height * 0.55)
        for _ in 0..<14 {
            let y = random.range(height * 0.6, height * 0.95)
            rect(CGRect(x: random.range(0, 900), y: y, width: random.range(40, 160), height: 4), 0xFFFFFF, 0.35, radius: 2)
        }
        for index in 0..<7 {
            pine(CGFloat(index) * 150 + random.range(-30, 30), height * 0.58, random.range(110, 190), 0x1F5E3B)
        }
        if random.int(2) == 0 {
            // A wooden dock.
            rect(CGRect(x: 620, y: height * 0.72, width: 380, height: 26), 0x8B5A2B)
            for post in 0..<4 { rect(CGRect(x: 640 + CGFloat(post) * 100, y: height * 0.72, width: 12, height: 70), 0x6B4420) }
        }
    }

    mutating func beach() {
        gradient(0x58C4F0, 0xBDEBFF, to: height * 0.5)
        circle(random.range(100, 900), height * random.range(0.1, 0.25), 52, 0xFFD34E)
        gradient(0x14B8C4, 0x0E8A9E, from: height * 0.5, to: height * 0.78)
        for _ in 0..<10 {
            rect(CGRect(x: random.range(0, 950), y: random.range(height * 0.52, height * 0.66), width: random.range(30, 90),
                        height: 4), 0xFFFFFF, 0.5, radius: 2)
        }
        hills(base: height * 0.72, amplitude: 18, 0xF6DDA5)
        // An umbrella and a towel.
        let x = random.range(250, 750)
        rect(CGRect(x: x - 4, y: height * 0.55, width: 8, height: height * 0.27), 0x6B4420)
        let canopy = CGMutablePath()
        canopy.addArc(center: CGPoint(x: x, y: height * 0.58), radius: 130, startAngle: .pi, endAngle: 0, clockwise: false)
        canopy.closeSubpath()
        fill([0xFF3681, 0xFEC138, 0x009EA2][random.int(3)], 1, canopy)
        rect(CGRect(x: x + 40, y: height * 0.84, width: 200, height: 60), [0x45CEC9, 0xFF8FB8, 0xFFFFFF][random.int(3)], 1, radius: 8)
    }

    mutating func party() {
        let walls: [(UInt32, UInt32)] = [(0xFFD1E3, 0xFFB0CC), (0xE4D4FF, 0xC9B2FF), (0xFFE6B3, 0xFFCF7A)]
        let wall = walls[random.int(walls.count)]
        gradient(wall.0, wall.1)
        rect(CGRect(x: 0, y: height * 0.78, width: width, height: height * 0.22), 0xA86B3C)
        let palette: [UInt32] = [0xFF3681, 0xFEC138, 0x009EA2, 0x8B5CF6, 0x22C55E, 0xF97316]
        for _ in 0..<7 {
            let x = random.range(80, 920), y = random.range(height * 0.15, height * 0.5) - time * 120
            context.setStrokeColor(color(0x555555, 0.6))
            context.setLineWidth(2)
            context.move(to: CGPoint(x: x, y: y + 60))
            context.addLine(to: CGPoint(x: x + random.range(-20, 20), y: y + 220))
            context.strokePath()
            fill(palette[random.int(palette.count)], 1, CGPath(ellipseIn: CGRect(x: x - 45, y: y - 60, width: 90, height: 120), transform: nil))
        }
        for _ in 0..<60 {
            circle(random.range(0, width), random.range(0, height * 0.75), random.range(3, 7), palette[random.int(palette.count)], 0.9)
        }
        // The cake, with candles.
        let cake = CGRect(x: 380, y: height * 0.62, width: 240, height: height * 0.17)
        rect(cake, 0xFFF4F8, 1, radius: 12)
        rect(CGRect(x: cake.minX, y: cake.minY + 18, width: cake.width, height: 18), 0xFF3681)
        for candle in 0..<5 {
            let cx = cake.minX + 40 + CGFloat(candle) * 40
            rect(CGRect(x: cx - 5, y: cake.minY - 44, width: 10, height: 44), palette[candle % palette.count])
            circle(cx, cake.minY - 54, 9, 0xFFB020)
        }
    }

    mutating func snow() {
        gradient(0xB9D3EA, 0xEEF4FA, to: height * 0.6)
        hills(base: height * 0.62, amplitude: 50, 0xF4F8FC)
        hills(base: height * 0.78, amplitude: 30, 0xFFFFFF)
        for index in 0..<6 {
            pine(CGFloat(index) * 180 + random.range(-40, 40), height * random.range(0.66, 0.8), random.range(120, 210), 0x235A44, snow: true)
        }
        for _ in 0..<120 {
            circle(random.range(0, width), (random.range(0, height) + time * 200).truncatingRemainder(dividingBy: height), random.range(2, 6), 0xFFFFFF, 0.9)
        }
        if random.int(2) == 0 {
            // A snowman.
            let x = random.range(300, 700), base = height * 0.86
            circle(x, base - 60, 70, 0xFFFFFF)
            circle(x, base - 170, 50, 0xFFFFFF)
            circle(x, base - 250, 36, 0xFFFFFF)
            circle(x - 12, base - 258, 5, 0x222222)
            circle(x + 12, base - 258, 5, 0x222222)
            let nose = CGMutablePath()
            nose.move(to: CGPoint(x: x, y: base - 250))
            nose.addLine(to: CGPoint(x: x + 40, y: base - 244))
            nose.addLine(to: CGPoint(x: x, y: base - 240))
            nose.closeSubpath()
            fill(0xF97316, 1, nose)
            rect(CGRect(x: x - 50, y: base - 222, width: 100, height: 14), 0xFF3681, 1, radius: 7)
        }
    }

    mutating func hike() {
        gradient(0x7CC8F2, 0xE3F5FF, to: height * 0.5)
        circle(random.range(100, 900), height * 0.16, 40, 0xFEC138)
        ridge(base: height * 0.5, peak: height * 0.38, count: 3, 0x8EA3C2)
        hills(base: height * 0.58, amplitude: 60, 0x5DA35A)
        hills(base: height * 0.74, amplitude: 40, 0x3F8A44)
        hills(base: height * 0.9, amplitude: 25, 0x2F6E35)
        let trail = CGMutablePath()
        trail.move(to: CGPoint(x: 420, y: height))
        trail.addCurve(to: CGPoint(x: 560, y: height * 0.6), control1: CGPoint(x: 700, y: height * 0.85), control2: CGPoint(x: 380, y: height * 0.7))
        context.setStrokeColor(color(0xD9B98A))
        context.setLineWidth(26)
        context.setLineCap(.round)
        context.addPath(trail)
        context.strokePath()
        for index in 0..<4 { pine(80 + CGFloat(index) * 260 + random.range(-30, 30), height * 0.82, random.range(90, 150), 0x1D4F2A) }
    }

    mutating func city() {
        gradient(0x0B1640, 0x283C7A)
        for _ in 0..<70 { circle(random.range(0, width), random.range(0, height * 0.55), random.range(1, 3), 0xFFFFFF, random.range(0.4, 1)) }
        circle(random.range(150, 850), height * 0.18, 44, 0xFFF6D8)
        var x: CGFloat = -20
        while x < width {
            let w = random.range(70, 140), h = random.range(height * 0.25, height * 0.62)
            rect(CGRect(x: x, y: height - h, width: w, height: h), [0x111A33, 0x18213F, 0x0D1530][random.int(3)])
            var wy = height - h + 16
            while wy < height - 20 {
                var wx = x + 10
                while wx < x + w - 14 {
                    if random.int(3) > 0 { rect(CGRect(x: wx, y: wy, width: 10, height: 14), 0xFEC138, random.range(0.5, 1)) }
                    wx += 22
                }
                wy += 26
            }
            x += w + random.range(4, 16)
        }
    }

    mutating func garden() {
        gradient(0xA7E3A1, 0x4FA35A)
        for _ in 0..<40 {
            let x = random.range(0, width), y = random.range(height * 0.25, height)
            context.setStrokeColor(color(0x2F7A35))
            context.setLineWidth(5)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + random.range(-10, 10), y: y + 90))
            context.strokePath()
            let petal: UInt32 = [0xFF3681, 0xFEC138, 0xFFFFFF, 0x8B5CF6, 0xF97316][random.int(5)]
            let r = random.range(14, 28)
            for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 3) {
                circle(x + cos(angle) * r, y + sin(angle) * r, r * 0.75, petal)
            }
            circle(x, y, r * 0.6, 0xFEC138)
        }
    }

    mutating func food() {
        gradient(0xC98E5A, 0x9A6334)
        for index in 0..<8 { rect(CGRect(x: 0, y: CGFloat(index) * height / 8, width: width, height: 3), 0x7A4A22, 0.35) }
        let cx = random.range(380, 620), cy = height * random.range(0.45, 0.55)
        circle(cx, cy, height * 0.36, 0xFFFFFF)
        circle(cx, cy, height * 0.29, 0xF3F3F0)
        let palette: [UInt32] = [0xF4B942, 0xE85D3A, 0x7CB342, 0xFFE0A3, 0x9C5A2E]
        for _ in 0..<9 {
            circle(cx + random.range(-90, 90), cy + random.range(-90, 90), random.range(26, 56), palette[random.int(palette.count)])
        }
        // A cup on the side.
        circle(cx + height * 0.55, cy - height * 0.15, 70, 0xFFFFFF)
        circle(cx + height * 0.55, cy - height * 0.15, 54, 0x6B3E1F)
    }

    /// A cartoon pug, PugglePhotos' favorite subject.
    mutating func pug() {
        let backgrounds: [(UInt32, UInt32)] = [(0xFFF1D6, 0xFFD9A0), (0xD6F3F1, 0x9ADFD9), (0xFFE0EC, 0xFFB3CF)]
        let background = backgrounds[random.int(backgrounds.count)]
        gradient(background.0, background.1)
        rect(CGRect(x: 0, y: height * 0.82, width: width, height: height * 0.18), 0x8B5A2B, 0.25)
        let cx = random.range(380, 620), cy = height * 0.5 + time * 20
        let r = height * 0.3
        // Ears, head, muzzle, eyes, nose and tongue.
        fill(0x844E21, 1, CGPath(ellipseIn: CGRect(x: cx - r * 1.15, y: cy - r * 0.95, width: r * 0.7, height: r * 0.9), transform: nil))
        fill(0x844E21, 1, CGPath(ellipseIn: CGRect(x: cx + r * 0.45, y: cy - r * 0.95, width: r * 0.7, height: r * 0.9), transform: nil))
        circle(cx, cy, r, 0xFECB77)
        fill(0x5A3A22, 1, CGPath(ellipseIn: CGRect(x: cx - r * 0.55, y: cy - r * 0.05, width: r * 1.1, height: r * 0.8), transform: nil))
        circle(cx - r * 0.42, cy - r * 0.28, r * 0.17, 0xFFFFFF)
        circle(cx + r * 0.42, cy - r * 0.28, r * 0.17, 0xFFFFFF)
        circle(cx - r * 0.4, cy - r * 0.26, r * 0.11, 0x1A1208)
        circle(cx + r * 0.44, cy - r * 0.26, r * 0.11, 0x1A1208)
        fill(0x1A1208, 1, CGPath(ellipseIn: CGRect(x: cx - r * 0.18, y: cy + r * 0.05, width: r * 0.36, height: r * 0.22), transform: nil))
        if random.int(3) > 0 {
            fill(0xFF8FB8, 1, CGPath(ellipseIn: CGRect(x: cx - r * 0.13, y: cy + r * 0.42, width: r * 0.26, height: r * 0.34), transform: nil))
        }
        // A ball to chase.
        circle(random.int(2) == 0 ? 150 : 850, height * 0.84, 44, [0x22C55E, 0xFF3681, 0xFEC138][random.int(3)])
    }

    mutating func sunset() {
        gradient(0x2B1B5C, 0xFF7A59, to: height * 0.6)
        circle(500 + random.range(-200, 200), height * 0.58, 90, 0xFFD27A)
        gradient(0x7A3E73, 0x2B1B48, from: height * 0.6)
        for _ in 0..<16 {
            rect(CGRect(x: random.range(250, 700), y: random.range(height * 0.62, height * 0.9), width: random.range(40, 160), height: 5),
                 0xFFD27A, 0.45, radius: 2)
        }
    }

    mutating func screenshot() {
        rect(CGRect(x: 0, y: 0, width: width, height: height), 0xF5F5F7)
        rect(CGRect(x: 0, y: 0, width: width, height: 60), 0xE8E8ED)
        for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() { circle(30 + CGFloat(index) * 26, 30, 8, UInt32(hex)) }
        rect(CGRect(x: 0, y: 60, width: 220, height: height - 60), 0xEBEBF0)
        for row in 0..<8 { rect(CGRect(x: 24, y: 90 + CGFloat(row) * 40, width: random.range(100, 170), height: 14), 0xB0B0B8, 1, radius: 7) }
        for row in 0..<3 {
            for column in 0..<3 {
                rect(CGRect(x: 260 + CGFloat(column) * 240, y: 100 + CGFloat(row) * 150, width: 210, height: 120),
                     [0xFF3681, 0x009EA2, 0xFEC138, 0x8B5CF6][(row + column + random.int(4)) % 4], 0.85, radius: 12)
            }
        }
    }

    /// An old print, scanned: faded colors, a white border.
    mutating func scan() {
        rect(CGRect(x: 0, y: 0, width: width, height: height), 0xF4EFE3)
        let inner = CGRect(x: 50, y: 50, width: width - 100, height: height - 100)
        context.saveGState()
        context.clip(to: inner)
        let tones: [(UInt32, UInt32)] = [(0xC9A97A, 0x8C6B45), (0xB7C4C9, 0x6F7E85), (0xD9B38C, 0xA0704A)]
        let tone = tones[random.int(tones.count)]
        gradient(tone.0, tone.1)
        circle(random.range(250, 750), inner.midY + 40, inner.height * 0.22, 0x5E4A36, 0.55)
        circle(random.range(250, 750), inner.midY - inner.height * 0.12, inner.height * 0.12, 0x5E4A36, 0.55)
        rect(CGRect(x: inner.minX, y: inner.maxY - inner.height * 0.2, width: inner.width, height: inner.height * 0.2), 0x4A3A2A, 0.3)
        context.restoreGState()
    }
}
#endif
