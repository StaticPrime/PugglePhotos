import CoreGraphics

extension CGContext {
    /// Draws a linear gradient through `colors` at `locations` from `start` to `end` (and no further), across everything
    /// that can be drawn here. Quartz writes a gradient into a PDF as a plain shading and drops its colors'
    /// transparency: the light laid across a cover came out as a solid sweep from white to black, and sticky notes grey.
    /// So a gradient with a see-through color is drawn as a picture of itself, made by the same gradient drawing, which
    /// keeps its transparency wherever it goes; an opaque one is drawn as it is.
    func drawGradient(_ colors: [CGColor], locations: [CGFloat], from start: CGPoint, to end: CGPoint) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
        guard colors.contains(where: { $0.alpha < 1 }) else {
            drawLinearGradient(gradient, start: start, end: end, options: [])
            return
        }
        let along = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let length = hypot(along.x, along.y)
        guard length > 0 else { return }
        // About two samples a device pixel along the way, so it's as smooth as the gradient itself.
        let device = userSpaceToDeviceSpaceTransform
        let deviceLength = hypot(along.x * device.a + along.y * device.c, along.x * device.b + along.y * device.d)
        let samples = Int(min(4096, max(64, (deviceLength * 2).rounded(.up))))
        guard let ramp = CGContext(data: nil, width: samples, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ramp.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: CGFloat(samples), y: 0.5), options: [])
        guard let picture = ramp.makeImage() else { return }
        // Laid along the way, and across as far as anything here can be drawn.
        let angle = atan2(along.y, along.x)
        let toAxis = CGAffineTransform(translationX: start.x, y: start.y).rotated(by: angle).inverted()
        let clip = boundingBoxOfClipPath
        let corners = [CGPoint(x: clip.minX, y: clip.minY), CGPoint(x: clip.maxX, y: clip.minY),
                       CGPoint(x: clip.minX, y: clip.maxY), CGPoint(x: clip.maxX, y: clip.maxY)]
        let across = corners.map { abs($0.applying(toAxis).y) }.max() ?? 0
        guard across > 0, across.isFinite else { return }
        saveGState()
        defer { restoreGState() }
        translateBy(x: start.x, y: start.y)
        rotate(by: angle)
        interpolationQuality = .high
        draw(picture, in: CGRect(x: 0, y: -across, width: length, height: across * 2))
    }
}
