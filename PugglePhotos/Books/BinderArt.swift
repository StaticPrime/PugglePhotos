import AppKit
import PugglePhotosKit

/// What's drawn around and over the pages of a ring binder album: its open boards in the cover's cloth, the spine
/// between them with the ring mechanism's metal plate, the rings arching from the holes in one page over to the other,
/// and the edges of the sheets stacked under the open pages. A glued book has none of it.
enum BinderArt {
    /// A picture `size` points big at `scale` pixels a point, drawn from the top left.
    private static func picture(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(context)
        return context.makeImage()
    }

    private static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
    }

    /// Metal seen across a rod or a plate: shade at both edges, its body, and a shine a little off the middle.
    private static func metal(_ finish: BookRingFinish) -> CGGradient? {
        let tones = finish.tones
        return gradient([tones.shade, tones.body, tones.shine, tones.body, tones.shade].map(BookRenderer.color), [0, 0.28, 0.42, 0.7, 1])
    }

    // MARK: The boards

    /// One open board: the cover's cloth over padding that rounds off at the edges, its outer corners rounded. The
    /// side along the spine is straight, where the board meets the spine at its hinge.
    static func board(size: CGSize, cover: BookCover, spineOnRight: Bool, scale: CGFloat) -> CGImage? {
        picture(size, scale: scale) { context in
            let bounds = CGRect(origin: .zero, size: size)
            let radius = min(size.width, size.height) * 0.02
            context.addPath(outline(bounds, radius: radius, straightRight: spineOnRight))
            context.clip()
            BookRenderer.drawCloth(cover, in: context, bounds: bounds)
            // The padding rounds off into shade at the outer edges, the light catching it along the top.
            let shade = NSColor.black.withAlphaComponent(0.22).cgColor, clear = NSColor.black.withAlphaComponent(0).cgColor
            let band = min(size.width, size.height) * 0.03
            if let rounding = gradient([shade, clear], [0, 1]) {
                let outerX = spineOnRight ? bounds.minX : bounds.maxX
                context.drawLinearGradient(rounding, start: CGPoint(x: outerX, y: 0), end: CGPoint(x: outerX + (spineOnRight ? band : -band), y: 0), options: [])
                context.drawLinearGradient(rounding, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.maxY - band), options: [])
            }
            if let light = gradient([NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor], [0, 1]) {
                context.drawLinearGradient(light, start: CGPoint(x: 0, y: bounds.minY), end: CGPoint(x: 0, y: bounds.minY + band), options: [])
            }
        }
    }

    /// A rectangle with its corners rounded, but for the two on one side, which stay square.
    private static func outline(_ rect: CGRect, radius: CGFloat, straightRight: Bool) -> CGPath {
        let path = CGMutablePath()
        let left = straightRight ? radius : 0, right = straightRight ? 0 : radius
        path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - right, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + right), radius: right)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - right, y: rect.maxY), radius: right)
        path.addLine(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - left), radius: left)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + left))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + left, y: rect.minY), radius: left)
        path.closeSubpath()
        return path
    }

    // MARK: The spine

    /// The spine between the boards: its cloth folding away into the hinges at both sides, and on it the ring
    /// mechanism's metal plate, running from above the first ring to below the last, with a rivet at each end.
    /// `rings` are where the rings are, down the spine.
    static func spine(size: CGSize, cover: BookCover, finish: BookRingFinish, rings: [CGFloat], scale: CGFloat) -> CGImage? {
        picture(size, scale: scale) { context in
            let bounds = CGRect(origin: .zero, size: size)
            BookRenderer.drawCloth(cover, in: context, bounds: bounds)
            let fold = NSColor.black.withAlphaComponent(0.42).cgColor, flat = NSColor.black.withAlphaComponent(0.08).cgColor
            if let folding = gradient([fold, flat, flat, fold], [0, 0.22, 0.78, 1]) {
                context.drawLinearGradient(folding, start: CGPoint(x: bounds.minX, y: 0), end: CGPoint(x: bounds.maxX, y: 0), options: [])
            }
            // The hinges: a groove where each board folds.
            context.setLineWidth(1)
            for x in [bounds.minX + 1.5, bounds.maxX - 1.5] {
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
                context.strokeLineSegments(between: [CGPoint(x: x, y: bounds.minY), CGPoint(x: x, y: bounds.maxY)])
            }
            guard let first = rings.first, let last = rings.last else { return }
            let width = size.width * 0.5
            let plate = CGRect(x: bounds.midX - width / 2, y: first - width * 1.6, width: width, height: last - first + width * 3.2)
            let shape = CGPath(roundedRect: plate, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 3 * scale, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addPath(shape)
            context.setFillColor(BookRenderer.color(finish.tones.body))
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(shape)
            context.clip()
            if let metal = metal(finish) {
                context.drawLinearGradient(metal, start: CGPoint(x: plate.minX, y: 0), end: CGPoint(x: plate.maxX, y: 0), options: [])
            }
            context.restoreGState()
            // The ridge down its middle, where the spring is.
            context.setLineWidth(max(0.8, width * 0.06))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            context.strokeLineSegments(between: [CGPoint(x: plate.midX - width * 0.08, y: plate.minY + width), CGPoint(x: plate.midX - width * 0.08, y: plate.maxY - width)])
            // A rivet at each end.
            for y in [plate.minY + width * 0.55, plate.maxY - width * 0.55] {
                let rivet = CGRect(x: plate.midX - width * 0.17, y: y - width * 0.17, width: width * 0.34, height: width * 0.34)
                context.setFillColor(BookRenderer.color(finish.tones.shade))
                context.fillEllipse(in: rivet.insetBy(dx: -0.6, dy: -0.6))
                context.setFillColor(BookRenderer.color(finish.tones.shine))
                context.fillEllipse(in: rivet.offsetBy(dx: -0.4, dy: -0.4).insetBy(dx: rivet.width * 0.18, dy: rivet.height * 0.18))
            }
        }
    }

    // MARK: The rings

    /// The rings over the pages, `size` points big: each a metal rod arching from a hole in one page (at `from`) over
    /// the spine to a hole in the other (at `to`), `thickness` thick at the heights in `rings`. Brightest where it
    /// rises highest, darker where it goes down into the holes, and casting a soft shadow on the pages.
    static func rings(size: CGSize, finish: BookRingFinish, rings: [CGFloat], from: CGFloat, to: CGFloat, thickness: CGFloat,
                      scale: CGFloat) -> CGImage? {
        picture(size, scale: scale) { context in
            let tones = finish.tones
            for y in rings {
                let rod = CGRect(x: from - thickness / 2, y: y - thickness / 2, width: to - from + thickness, height: thickness)
                let shape = CGPath(roundedRect: rod, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil)
                // Its shadow on the pages, a little below and to the right.
                context.saveGState()
                context.setShadow(offset: CGSize(width: thickness * 0.3 * scale, height: -thickness * 0.65 * scale), blur: thickness * 0.9 * scale,
                                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
                context.addPath(shape)
                context.setFillColor(BookRenderer.color(tones.shade))
                context.fillPath()
                context.restoreGState()
                // The rod, round like a wire, and darker toward its ends, where it bends down into the holes.
                context.saveGState()
                context.addPath(shape)
                context.clip()
                if let metal = metal(finish) {
                    context.drawLinearGradient(metal, start: CGPoint(x: 0, y: rod.minY), end: CGPoint(x: 0, y: rod.maxY), options: [])
                }
                let dim = NSColor.black.withAlphaComponent(0.5).cgColor, none = NSColor.black.withAlphaComponent(0).cgColor
                if let ends = gradient([dim, none, none, dim], [0, 0.2, 0.8, 1]) {
                    context.drawLinearGradient(ends, start: CGPoint(x: rod.minX, y: 0), end: CGPoint(x: rod.maxX, y: 0), options: [])
                }
                context.restoreGState()
                // The glint along its top, where it's highest.
                context.setLineCap(.round)
                context.setLineWidth(max(0.6, thickness * 0.14))
                context.setStrokeColor(NSColor.white.withAlphaComponent(finish == .black ? 0.35 : 0.75).cgColor)
                let glint = y - thickness * 0.17
                context.strokeLineSegments(between: [CGPoint(x: rod.minX + rod.width * 0.28, y: glint), CGPoint(x: rod.maxX - rod.width * 0.28, y: glint)])
            }
        }
    }

    // MARK: The stacked pages

    /// The edges of `sheets` sheets stacked under an open page `height` points tall, each peeking out a little further
    /// past its outer edge and a little lower, at most ten. On the left page they show to its left.
    static func stack(sheets: Int, height: CGFloat, paper: BookPaper, onLeft: Bool, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let count = min(sheets, 10)
        guard count > 0 else { return nil }
        let step: CGFloat = 1.5, drop: CGFloat = 0.45
        let size = CGSize(width: CGFloat(count) * step + 1, height: height + CGFloat(count) * drop + 1)
        let image = picture(size, scale: scale) { context in
            let edge = NSColor.black.withAlphaComponent(paper.isDark ? 0.6 : 0.22).cgColor
            for sheet in stride(from: count, through: 1, by: -1) {
                let reach = CGFloat(sheet) * step
                // From well under the page above out to its own edge.
                let rect = onLeft ? CGRect(x: size.width - reach, y: CGFloat(sheet) * drop, width: reach + 20, height: height)
                    : CGRect(x: -20, y: CGFloat(sheet) * drop, width: reach + 20, height: height)
                context.setFillColor(BookRenderer.color(paper.color))
                context.fill(rect)
                context.setFillColor(NSColor.black.withAlphaComponent(0.02 * CGFloat(sheet)).cgColor)
                context.fill(rect)
                context.setStrokeColor(edge)
                context.setLineWidth(0.5)
                let x = onLeft ? rect.minX + 0.25 : rect.maxX - 0.25
                context.strokeLineSegments(between: [CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)])
                context.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.maxY - 0.25), CGPoint(x: rect.maxX, y: rect.maxY - 0.25)])
            }
        }
        return image.map { ($0, size) }
    }
}
