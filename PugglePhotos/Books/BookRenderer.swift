import AppKit
import PugglePhotosKit

/// Draws a photo book's pages: paper with a little grain, each photo in its frame with a soft shadow, captions and
/// notes in the book's handwriting, sticky notes, tape, page numbers, the title page, endpapers and the cloth covers,
/// and the back of a photo turned over. The same drawing serves the screen, the page turns, PDFs and printing.
final class BookRenderer {
    let settings: BookSettings
    let title: String
    let subtitle: String
    let story: String
    /// The picture for a photo, if it has arrived; whole, not cropped.
    var image: (PhotoID) -> CGImage?
    /// The photo turned over to show its back, if any.
    var turnedOver: PhotoID?
    /// A photo left off its page while it turns over above it.
    var hiding: PhotoID?
    /// The day a photo was taken, as written on its back.
    var day: (PhotoID) -> String = { _ in "" }
    /// Writing left off its page while it's being written, in place above it.
    var editing: UUID?

    init(settings: BookSettings, title: String, subtitle: String, story: String, image: @escaping (PhotoID) -> CGImage?) {
        self.settings = settings
        self.title = title
        self.subtitle = subtitle
        self.story = story
        self.image = image
    }

    static let pageSize = BookLayout.pageSize

    /// A page as a picture, `pixelWidth` pixels wide.
    func render(_ page: BookPage, index: Int, isLeft: Bool, pixelWidth: CGFloat) -> CGImage? {
        let width = Int(pixelWidth.rounded())
        let height = Int((pixelWidth * Self.pageSize.height / Self.pageSize.width).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Page coordinates: top left, 600 wide.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / Self.pageSize.width, y: -CGFloat(height) / Self.pageSize.height)
        draw(page, index: index, isLeft: isLeft, in: context)
        return context.makeImage()
    }

    /// Draws a page in page coordinates (600 × 780, from the top left) into a context already set up that way.
    func draw(_ page: BookPage, index: Int, isLeft: Bool, in context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        let bounds = CGRect(origin: .zero, size: Self.pageSize)
        switch page.kind {
        case .cover:
            drawCloth(in: context, bounds: bounds)
            drawCoverFront(in: context, bounds: bounds)
        case .back:
            drawCloth(in: context, bounds: bounds)
            drawPaw(in: context, center: CGPoint(x: bounds.midX, y: bounds.maxY - 110), size: 46,
                    color: NSColor.black.withAlphaComponent(0.16).cgColor)
        case .insideCover:
            drawEndpaper(in: context, bounds: bounds)
        case .title:
            drawPaper(in: context, bounds: bounds)
            for placement in page.placements { drawPlacement(placement, in: context) }
            drawTitleText(in: context, below: page.placements.first.map { $0.center.y + $0.frameSize(settings.frame).height / 2 } ?? 120)
        case .photos, .blank, .added:
            drawPaper(in: context, bounds: bounds)
            for placement in page.placements where placement.id != hiding { drawPlacement(placement, in: context) }
            // Sticky notes lie over every photo on the page.
            for placement in page.placements where placement.hasSticky && placement.id != hiding && placement.id != turnedOver {
                drawSticky(placement, in: context)
            }
            if let number = page.number { drawPageNumber(number, in: bounds) }
        }
        // Words written on the page lie over everything on it.
        for writing in page.writings where writing.id != editing { drawWriting(writing, onCloth: page.kind == .cover || page.kind == .back, in: context) }
        if page.kind != .cover, page.kind != .back { drawGutter(in: context, bounds: bounds, isLeft: isLeft) }
    }

    // MARK: Writing

    /// The color writing shows in on a page: its ink, and for automatic ink, dark on light paper and light on dark
    /// paper and on the cloth covers.
    func inkColor(_ ink: BookInk, onCloth: Bool) -> NSColor {
        let hex = ink.color(onDark: onCloth || settings.paper.isDark)
        return NSColor(cgColor: Self.color(hex)) ?? .black
    }

    /// The font writing is in, at its size.
    func writingFont(_ writing: BookWriting) -> NSFont { handwriting(writing.size) }

    /// How much room writing takes: its width, and as tall as its lines (one line at least).
    func writingSize(_ writing: BookWriting) -> CGSize {
        let font = writingFont(writing)
        let text = writing.text.isEmpty ? " " : writing.text
        return CGSize(width: writing.width, height: max(textHeight(text, font: font, width: writing.width), ceil(font.ascender - font.descender + font.leading)))
    }

    /// Words written on a page, around their middle, at their angle, in the book's handwriting.
    private func drawWriting(_ writing: BookWriting, onCloth: Bool, in context: CGContext) {
        guard !writing.text.isEmpty else { return }
        let size = writingSize(writing)
        context.saveGState()
        context.translateBy(x: writing.center.x, y: writing.center.y)
        context.rotate(by: writing.angle * .pi / 180)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var color = inkColor(writing.ink, onCloth: onCloth)
        if onCloth {
            // Ink on cloth sinks in a little.
            color = color.withAlphaComponent(0.9)
        }
        NSAttributedString(string: writing.text, attributes: [.font: writingFont(writing), .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(with: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), options: [.usesLineFragmentOrigin])
        context.restoreGState()
    }

    // MARK: Paper

    private var ink: NSColor {
        settings.paper.isDark ? NSColor(white: 0.94, alpha: 1) : NSColor(srgbRed: 0.16, green: 0.15, blue: 0.2, alpha: 1)
    }

    private func drawPaper(in context: CGContext, bounds: CGRect) {
        context.setFillColor(Self.color(settings.paper.color))
        context.fill(bounds)
        if let grain = Self.grain(for: settings.paper) {
            context.saveGState()
            context.setAlpha(settings.paper.isDark ? 0.5 : 0.8)
            context.draw(grain, in: CGRect(x: 0, y: 0, width: 160, height: 160), byTiling: true)
            context.restoreGState()
        }
    }

    /// Shade along the spine, as a page curves into the binding.
    private func drawGutter(in context: CGContext, bounds: CGRect, isLeft: Bool) {
        let colors = [NSColor.black.withAlphaComponent(settings.paper.isDark ? 0.35 : 0.16).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) else { return }
        let start = CGPoint(x: isLeft ? bounds.maxX : bounds.minX, y: 0)
        let end = CGPoint(x: isLeft ? bounds.maxX - 46 : bounds.minX + 46, y: 0)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }

    private static var grains: [BookPaper: CGImage] = [:]

    /// A tile of paper grain: speckles, and fibers in kraft paper or a weave in linen.
    static func grain(for paper: BookPaper) -> CGImage? {
        if let cached = grains[paper] { return cached }
        let side = 160
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        var random = GrainRandom(seed: UInt64((BookPaper.allCases.firstIndex(of: paper) ?? 0) + 1))
        let dark = paper.isDark
        for _ in 0..<900 {
            let shade = dark ? CGFloat(1) : CGFloat(0)
            context.setFillColor(CGColor(srgbRed: shade, green: shade, blue: shade, alpha: random.range(0.015, 0.06)))
            let size = random.range(0.6, 1.8)
            context.fillEllipse(in: CGRect(x: random.range(0, 160), y: random.range(0, 160), width: size, height: size))
        }
        if paper == .kraft {
            context.setLineWidth(0.6)
            for _ in 0..<70 {
                context.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.22, blue: 0.1, alpha: random.range(0.08, 0.2)))
                let x = random.range(0, 160), y = random.range(0, 160), length = random.range(4, 14), turn = random.range(0, .pi)
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + cos(turn) * length, y: y + sin(turn) * length))
                context.strokePath()
            }
        }
        if paper == .linen {
            context.setLineWidth(0.5)
            context.setStrokeColor(CGColor(srgbRed: 0.4, green: 0.35, blue: 0.25, alpha: 0.07))
            for line in stride(from: 0, to: 160, by: 3) {
                context.move(to: CGPoint(x: CGFloat(line), y: 0))
                context.addLine(to: CGPoint(x: CGFloat(line), y: 160))
                context.move(to: CGPoint(x: 0, y: CGFloat(line)))
                context.addLine(to: CGPoint(x: 160, y: CGFloat(line)))
            }
            context.strokePath()
        }
        let image = context.makeImage()
        grains[paper] = image
        return image
    }

    // MARK: Photos

    /// One photo: its shadow, its frame, the picture, a play badge for videos, tape, its caption and its note; or
    /// its back, when it's turned over.
    func drawPlacement(_ placement: BookPlacement, in context: CGContext, selected: Bool = false) {
        if placement.id == turnedOver {
            drawBack(placement, in: context)
            return
        }
        let frame = settings.frame
        context.saveGState()
        context.translateBy(x: placement.center.x, y: placement.center.y)
        context.rotate(by: placement.angle * .pi / 180)
        let outer = placement.frameRect(frame)
        let picture = placement.imageRect(frame)
        // The shadow, then the frame (or the picture alone).
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 10,
                          color: NSColor.black.withAlphaComponent(settings.paper.isDark ? 0.55 : 0.28).cgColor)
        context.setFillColor(frame == .plain ? NSColor(white: 0.85, alpha: 1).cgColor : CGColor(srgbRed: 0.995, green: 0.993, blue: 0.98, alpha: 1))
        context.fill(outer)
        context.restoreGState()
        if frame == .instant {
            // A hint of the instant film's texture at the bottom.
            context.setFillColor(NSColor.black.withAlphaComponent(0.025).cgColor)
            context.fill(CGRect(x: outer.minX, y: picture.maxY, width: outer.width, height: outer.maxY - picture.maxY))
        }
        drawPicture(placement, in: context, rect: picture)
        if placement.isVideo { drawPlayBadge(in: context, rect: picture) }
        if frame == .taped { drawTape(in: context, frame: outer) }
        if !placement.caption.isEmpty { drawCaption(placement.caption, in: placement.captionRect(frame), onFrame: frame == .instant) }
        if placement.showsNote, placement.noteStyle == .onPhoto || placement.noteStyle == .underPhoto { drawNote(placement, frame: frame) }
        context.restoreGState()
    }

    /// The back of a photo: its frame's shape in photo paper, with the day, the caption and the note.
    private func drawBack(_ placement: BookPlacement, in context: CGContext) {
        let frame = settings.frame
        context.saveGState()
        context.translateBy(x: placement.center.x, y: placement.center.y)
        context.rotate(by: placement.angle * .pi / 180)
        let outer = placement.frameRect(frame)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 10,
                          color: NSColor.black.withAlphaComponent(settings.paper.isDark ? 0.55 : 0.28).cgColor)
        context.setFillColor(PhotoBack.paper.cgColor)
        context.fill(outer)
        context.restoreGState()
        PhotoBack.draw(PhotoBack.Content(day: day(placement.id), caption: placement.caption, note: placement.note, family: settings.handwriting),
                       in: outer, context: context, prompt: false)
        context.restoreGState()
    }

    /// A photo's note written on it or under it: in an instant photo's white space, across the bottom of the
    /// picture in white, or on the paper beneath.
    private func drawNote(_ placement: BookPlacement, frame: BookFrame) {
        let rect = placement.noteRect(frame)
        let onPicture = placement.noteStyle == .onPhoto && frame != .instant
        let onFrame = placement.noteStyle == .onPhoto && frame == .instant
        let color: NSColor = onPicture ? .white : (onFrame ? NSColor(srgbRed: 0.15, green: 0.22, blue: 0.45, alpha: 0.92) : ink.withAlphaComponent(0.88))
        var size = min(19, max(11, rect.height * (onFrame ? 0.4 : 0.34)))
        while size > 9, textHeight(placement.note, font: handwriting(size), width: rect.width) > rect.height { size -= 1 }
        let previous = NSGraphicsContext.current?.cgContext
        if onPicture {
            previous?.saveGState()
            previous?.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.75).cgColor)
        }
        drawText(placement.note, font: handwriting(size), color: color, in: rect, lines: max(1, Int(rect.height / (size * 1.2))))
        if onPicture { previous?.restoreGState() }
    }

    // MARK: Sticky notes

    /// A sticky note stuck to a photo: square paper, a touch lighter at the top where it's stuck, lifting a little
    /// at the bottom corner, with the note written on it.
    func drawSticky(_ placement: BookPlacement, in context: CGContext) {
        let sticky = placement.sticky
        context.saveGState()
        context.translateBy(x: placement.center.x, y: placement.center.y)
        context.rotate(by: placement.angle * .pi / 180)
        context.translateBy(x: sticky.center.x, y: sticky.center.y)
        context.rotate(by: sticky.angle * .pi / 180)
        let rect = sticky.rect
        let curl = min(rect.width, rect.height) * 0.11
        let paper = CGMutablePath()
        paper.move(to: CGPoint(x: rect.minX, y: rect.minY))
        paper.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        paper.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - curl))
        paper.addQuadCurve(to: CGPoint(x: rect.maxX - curl, y: rect.maxY), control: CGPoint(x: rect.maxX - curl * 0.1, y: rect.maxY - curl * 0.1))
        paper.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        paper.closeSubpath()
        // The shadow falls more where the paper lifts.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 1.5, height: 4), blur: 7, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.addPath(paper)
        context.setFillColor(Self.color(sticky.color.color))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(paper)
        context.clip()
        let colors = [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
                      NSColor.black.withAlphaComponent(0.07).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.3, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        // The sticky strip along the top.
        context.setFillColor(NSColor.black.withAlphaComponent(0.035).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.17))
        // The lifted corner catches the light.
        let lift = CGMutablePath()
        lift.move(to: CGPoint(x: rect.maxX, y: rect.maxY - curl))
        lift.addQuadCurve(to: CGPoint(x: rect.maxX - curl, y: rect.maxY), control: CGPoint(x: rect.maxX - curl * 0.1, y: rect.maxY - curl * 0.1))
        lift.addLine(to: CGPoint(x: rect.maxX - curl * 1.2, y: rect.maxY - curl * 1.2))
        lift.closeSubpath()
        context.addPath(lift)
        context.setFillColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        context.fillPath()
        context.restoreGState()
        // The note.
        let room = CGRect(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.17, width: rect.width * 0.8, height: rect.height * 0.74)
        var size = min(26, max(10, min(rect.width, rect.height) * 0.15))
        while size > 8, textHeight(placement.note, font: handwriting(size), width: room.width) > room.height { size -= 0.5 }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawText(placement.note, font: handwriting(size), color: NSColor(srgbRed: 0.17, green: 0.16, blue: 0.24, alpha: 0.92), in: room,
                 lines: max(1, Int(room.height / (size * 1.15))), alignment: .left, top: true)
        NSGraphicsContext.current = previous
        context.restoreGState()
    }

    /// One photo alone, its front or its back, as a picture `scale` pixels to a page point with room around it for
    /// its shadow; unturned, for turning over above the page. Also answers the picture's size in page points.
    func photoSide(_ placement: BookPlacement, back: Bool, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let frame = placement.frameSize(settings.frame)
        let margin: CGFloat = 24
        let size = CGSize(width: frame.width + margin * 2, height: frame.height + margin * 2)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        var alone = placement
        alone.center = CGPoint(x: size.width / 2, y: size.height / 2)
        alone.angle = 0
        let turned = turnedOver
        turnedOver = back ? placement.id : nil
        drawPlacement(alone, in: context)
        turnedOver = turned
        return context.makeImage().map { ($0, size) }
    }

    /// The picture, cropped to fill its space, or a soft gray while it loads.
    private func drawPicture(_ placement: BookPlacement, in context: CGContext, rect: CGRect) {
        guard let image = image(placement.id) else {
            context.setFillColor(NSColor(white: settings.paper.isDark ? 0.3 : 0.88, alpha: 1).cgColor)
            context.fill(rect)
            return
        }
        context.saveGState()
        context.clip(to: rect)
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        // The context runs top down; pictures draw bottom up, so flip around the picture's middle.
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }

    private func drawPlayBadge(in context: CGContext, rect: CGRect) {
        let radius = min(rect.width, rect.height) * 0.11
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(NSColor.white.cgColor)
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: center.x - radius * 0.32, y: center.y - radius * 0.45))
        triangle.addLine(to: CGPoint(x: center.x + radius * 0.5, y: center.y))
        triangle.addLine(to: CGPoint(x: center.x - radius * 0.32, y: center.y + radius * 0.45))
        triangle.closeSubpath()
        context.addPath(triangle)
        context.fillPath()
    }

    /// Two strips of tape over the top corners.
    private func drawTape(in context: CGContext, frame: CGRect) {
        for (corner, turn) in [(CGPoint(x: frame.minX + 8, y: frame.minY + 4), -38.0), (CGPoint(x: frame.maxX - 8, y: frame.minY + 4), 38.0)] {
            context.saveGState()
            context.translateBy(x: corner.x, y: corner.y)
            context.rotate(by: turn * .pi / 180)
            context.setFillColor(CGColor(srgbRed: 0.96, green: 0.93, blue: 0.82, alpha: 0.72))
            context.fill(CGRect(x: -34, y: -11, width: 68, height: 22))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
            context.fill(CGRect(x: -34, y: -11, width: 68, height: 5))
            context.restoreGState()
        }
    }

    // MARK: Words

    /// The book's handwriting, or the one chosen in Settings.
    func handwriting(_ size: CGFloat, bold: Bool = false) -> NSFont {
        Handwriting.font(settings.handwriting, size: size, bold: bold)
    }

    func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return ceil(NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
            .boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height)
    }

    static func serif(_ size: CGFloat) -> NSFont {
        for name in ["Baskerville-SemiBold", "Georgia-Bold", "Palatino-Bold"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func drawCaption(_ text: String, in rect: CGRect, onFrame: Bool) {
        let color = onFrame ? NSColor(srgbRed: 0.16, green: 0.15, blue: 0.2, alpha: 0.9) : ink.withAlphaComponent(0.88)
        let size = min(20, max(12, rect.height * (onFrame ? 0.42 : 0.62)))
        drawText(text, font: handwriting(size), color: color, in: rect, lines: 2)
    }

    /// Writes text in a rectangle, wrapping, at most `lines` lines (and no taller than the rectangle), in the middle
    /// of it or from its top.
    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, lines: Int, alignment: NSTextAlignment = .center,
                          top: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let string = NSAttributedString(string: text, attributes: attributes)
        let needed = string.boundingRect(with: CGSize(width: rect.width, height: 1000), options: [.usesLineFragmentOrigin]).height
        var height = min(needed, font.boundingRectForFont.height * CGFloat(lines) * 1.1)
        if top { height = min(height, max(rect.height, font.pointSize * 1.3)) }
        string.draw(with: CGRect(x: rect.minX, y: top ? rect.minY : rect.midY - height / 2, width: rect.width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPageNumber(_ number: Int, in bounds: CGRect) {
        drawText("\(number)", font: .systemFont(ofSize: 11, weight: .medium), color: ink.withAlphaComponent(0.45),
                 in: CGRect(x: 0, y: bounds.maxY - 34, width: bounds.width, height: 16), lines: 1)
    }

    /// The album's name, its dates and its story, under the cover photo.
    private func drawTitleText(in context: CGContext, below top: CGFloat) {
        var y = max(top + 36, 150)
        let titleFont = handwriting(40, bold: true)
        drawText(title, font: titleFont, color: ink, in: CGRect(x: 50, y: y, width: 500, height: 56), lines: 2)
        y += 58
        if !subtitle.isEmpty {
            drawText(subtitle, font: .systemFont(ofSize: 14, weight: .medium), color: ink.withAlphaComponent(0.6),
                     in: CGRect(x: 60, y: y, width: 480, height: 20), lines: 1)
            y += 34
        }
        if !story.isEmpty {
            drawText(story, font: handwriting(19), color: ink.withAlphaComponent(0.85),
                     in: CGRect(x: 70, y: y, width: 460, height: max(40, 740 - y)), lines: 8)
        }
    }

    // MARK: Covers

    private func drawCloth(in context: CGContext, bounds: CGRect) {
        context.setFillColor(Self.color(settings.cover.color))
        context.fill(bounds)
        // The weave.
        context.setLineWidth(0.6)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.06).cgColor)
        for line in stride(from: CGFloat(0), to: bounds.maxX, by: 4) {
            context.move(to: CGPoint(x: line, y: 0))
            context.addLine(to: CGPoint(x: line, y: bounds.maxY))
        }
        context.strokePath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        for line in stride(from: CGFloat(0), to: bounds.maxY, by: 4) {
            context.move(to: CGPoint(x: 0, y: line))
            context.addLine(to: CGPoint(x: bounds.maxX, y: line))
        }
        context.strokePath()
        // Light falling across it.
        let colors = [NSColor.white.withAlphaComponent(0.14).cgColor, NSColor.black.withAlphaComponent(0.12).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
        }
    }

    /// The front: the cover photo in a white border and the title stamped below it.
    private func drawCoverFront(in context: CGContext, bounds: CGRect) {
        let photoRect = CGRect(x: 120, y: 110, width: 360, height: 360)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        context.fill(photoRect)
        context.restoreGState()
        let cover = BookPlacement(id: coverPhoto ?? PhotoID(""), isVideo: false, aspect: 1, center: CGPoint(x: photoRect.midX, y: photoRect.midY),
                                  imageSize: CGSize(width: 330, height: 330), angle: 0, caption: "")
        if coverPhoto != nil { drawPicture(cover, in: context, rect: photoRect.insetBy(dx: 15, dy: 15)) }
        let stamp = Self.serif(42)
        let shadowColor = NSColor.black.withAlphaComponent(0.3)
        drawText(title, font: stamp, color: shadowColor, in: CGRect(x: 51, y: 529, width: 500, height: 110), lines: 2)
        drawText(title, font: stamp, color: NSColor(white: 0.98, alpha: 0.92), in: CGRect(x: 50, y: 527, width: 500, height: 110), lines: 2)
        if !subtitle.isEmpty {
            drawText(subtitle, font: .systemFont(ofSize: 14, weight: .semibold), color: NSColor(white: 1, alpha: 0.75),
                     in: CGRect(x: 60, y: 650, width: 480, height: 20), lines: 1)
        }
    }

    /// The photo on the cover; set by the book.
    var coverPhoto: PhotoID?

    /// Endpaper: the paper with tiny paw prints in the cover's color.
    private func drawEndpaper(in context: CGContext, bounds: CGRect) {
        drawPaper(in: context, bounds: bounds)
        let color = Self.color(settings.cover.color).copy(alpha: settings.paper.isDark ? 0.35 : 0.16) ?? Self.color(settings.cover.color)
        var row = 0
        for y in stride(from: CGFloat(40), to: bounds.maxY, by: 70) {
            let shift: CGFloat = row % 2 == 0 ? 0 : 35
            for x in stride(from: CGFloat(30) + shift, to: bounds.maxX, by: 70) {
                drawPaw(in: context, center: CGPoint(x: x, y: y), size: 16, color: color, turn: row % 2 == 0 ? -0.3 : 0.3)
            }
            row += 1
        }
    }

    private func drawPaw(in context: CGContext, center: CGPoint, size: CGFloat, color: CGColor, turn: CGFloat = 0) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: turn)
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: -size * 0.5, y: -size * 0.1, width: size, height: size * 0.82))
        for (dx, dy) in [(-0.62, -0.42), (-0.24, -0.72), (0.24, -0.72), (0.62, -0.42)] {
            context.fillEllipse(in: CGRect(x: size * CGFloat(dx) - size * 0.17, y: size * CGFloat(dy) - size * 0.2, width: size * 0.34,
                                           height: size * 0.42))
        }
        context.restoreGState()
    }

    /// A small repeatable random number generator for paper grain.
    struct GrainRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

        mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return low + (high - low) * CGFloat((state >> 33) % 10_000) / 10_000
        }
    }

    static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
