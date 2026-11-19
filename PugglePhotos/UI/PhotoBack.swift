import AppKit
import PugglePhotosKit

/// The back of a photo, as it shows when the photo is turned over in the grid or in a book: off-white photo paper
/// with a faint pattern, the day it was taken written in the corner, then its caption and its note, in handwriting.
enum PhotoBack {
    struct Content: Hashable {
        var day: String
        var caption: String
        var note: String
        /// The handwriting's font family; nil for the one chosen in Settings.
        var family: String?
    }

    /// What's on a photo's back.
    static func content(of id: PhotoID, library: LibraryController, family: String? = nil) -> Content {
        let day = library.snapshot.day(of: id).map(library.formatting.writtenDay) ?? ""
        let details = library.details(id)
        return Content(day: day, caption: details.caption, note: details.note, family: family)
    }

    static let paper = NSColor(srgbRed: 0.985, green: 0.975, blue: 0.95, alpha: 1)
    static let ink = NSColor(srgbRed: 0.15, green: 0.25, blue: 0.53, alpha: 1)
    static let pencilInk = NSColor(srgbRed: 0.33, green: 0.34, blue: 0.4, alpha: 1)

    /// Where the pencil for writing on the back sits, in a back `size` big (top-down coordinates).
    static func pencilRect(in size: CGSize) -> CGRect {
        let side = max(22, min(size.width, size.height) * 0.17)
        let margin = max(5, min(size.width, size.height) * 0.05)
        return CGRect(x: size.width - side - margin, y: size.height - side - margin, width: side, height: side)
    }

    /// The back as a picture `size` points big, for a thumbnail; with the pencil for writing on it.
    static func image(_ content: Content, size: CGSize, scale: CGFloat, cornerRadius: CGFloat = 4) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let rect = CGRect(origin: .zero, size: size)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        draw(content, in: rect, context: context, prompt: true)
        drawPencil(in: pencilRect(in: size), context: context)
        return context.makeImage()
    }

    /// Draws the back into `rect` of a context set up top-down. `prompt` invites writing when there's no note.
    static func draw(_ content: Content, in rect: CGRect, context: CGContext, prompt: Bool) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        context.saveGState()
        context.setFillColor(paper.cgColor)
        context.fill(rect)
        drawPattern(in: rect, context: context)
        let side = min(rect.width, rect.height)
        let margin = max(6, side * 0.08)
        var y = rect.minY + margin * 0.8
        let width = rect.width - margin * 2
        if !content.day.isEmpty {
            let font = Handwriting.font(content.family, size: max(8, side * 0.085))
            y += draw(content.day, font: font, color: pencilInk, at: CGPoint(x: rect.minX + margin, y: y), width: width, maxHeight: font.pointSize * 1.6)
            y += side * 0.03
        }
        if !content.caption.isEmpty, side >= 70 {
            let font = Handwriting.font(content.family, size: max(9, side * 0.105), bold: true)
            y += draw(content.caption, font: font, color: ink, at: CGPoint(x: rect.minX + margin, y: y), width: width,
                      maxHeight: font.pointSize * 2.7)
            y += side * 0.02
        }
        let bottom = rect.maxY - margin - (prompt ? side * 0.12 : 0)
        if !content.note.isEmpty, bottom - y > 8 {
            // As big as fits, down to a smallest readable size.
            var size = max(9, side * 0.1)
            var font = Handwriting.font(content.family, size: size)
            while size > 7, height(of: content.note, font: font, width: width) > bottom - y {
                size *= 0.92
                font = Handwriting.font(content.family, size: size)
            }
            _ = draw(content.note, font: font, color: ink, at: CGPoint(x: rect.minX + margin, y: y), width: width, maxHeight: bottom - y)
        } else if content.note.isEmpty, prompt, side >= 100, bottom - y > 20 {
            let font = Handwriting.font(content.family, size: max(9, side * 0.09))
            _ = draw("Nothing written on the back yet.", font: font, color: pencilInk.withAlphaComponent(0.45),
                     at: CGPoint(x: rect.minX + margin, y: y + side * 0.02), width: width, maxHeight: bottom - y)
        }
        context.restoreGState()
    }

    /// The paper's faint pattern: tiny paw prints, the way photo paper is printed on the back.
    private static func drawPattern(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(NSColor(srgbRed: 0.55, green: 0.5, blue: 0.45, alpha: 0.06).cgColor)
        let step: CGFloat = 26
        var row = 0
        for y in stride(from: rect.minY + 8, to: rect.maxY, by: step) {
            for x in stride(from: rect.minX + (row % 2 == 0 ? 6 : 6 + step / 2), to: rect.maxX, by: step) {
                context.fillEllipse(in: CGRect(x: x - 2.4, y: y - 1, width: 4.8, height: 4))
                for (dx, dy) in [(-2.6, -2.6), (-0.9, -3.8), (0.9, -3.8), (2.6, -2.6)] as [(CGFloat, CGFloat)] {
                    context.fillEllipse(in: CGRect(x: x + dx - 0.8, y: y + dy - 1, width: 1.6, height: 2))
                }
            }
            row += 1
        }
        context.restoreGState()
    }

    private static func drawPencil(in rect: CGRect, context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()
        if let symbol = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.width * 0.5, weight: .semibold))?.tinted(Theme.accent) {
            let size = symbol.size
            symbol.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.92
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: attributes(font, .black))
            .boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height)
    }

    /// Writes text from a point, wrapping at `width` and stopping at `maxHeight`; answers how tall it came out.
    private static func draw(_ text: String, font: NSFont, color: NSColor, at origin: CGPoint, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let height = min(height(of: text, font: font, width: width), maxHeight)
        guard height > 0 else { return 0 }
        NSAttributedString(string: text, attributes: attributes(font, color))
            .draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return height
    }
}
