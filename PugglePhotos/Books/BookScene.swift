import AppKit
import PugglePhotosKit

/// The book as the window shows it, drawn into any context: the desk, the book's shadow, the open cover's boards with a
/// binder's spine and the edges of the sheets under the pages, the pages, and the rings over them. PDF pages are drawn
/// this way, from the same stage, art and page drawing as the window, so they look just like it.
struct BookScene {
    let layout: BookLayout
    let renderer: BookRenderer

    // MARK: The desk

    /// The desk's colors, from where it's lightest out, by day or by night.
    static func deskColors(dark: Bool) -> [CGColor] {
        dark ? [NSColor(srgbRed: 0.2, green: 0.19, blue: 0.2, alpha: 1).cgColor, NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1).cgColor]
            : [NSColor(srgbRed: 0.88, green: 0.85, blue: 0.81, alpha: 1).cgColor, NSColor(srgbRed: 0.73, green: 0.69, blue: 0.64, alpha: 1).cgColor]
    }

    /// Where the desk is lightest, and where its light has faded (both as shares of its size, from the top left).
    static let deskCenter = CGPoint(x: 0.5, y: 0.45), deskEdge = CGPoint(x: 1.25, y: 1.3)

    static func drawDesk(in context: CGContext, size: CGSize, dark: Bool) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: deskColors(dark: dark) as CFArray,
                                        locations: [0, 1]) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        // An ellipse around the lightest spot, out to the edge of the light.
        context.translateBy(x: deskCenter.x * size.width, y: deskCenter.y * size.height)
        context.scaleBy(x: (deskEdge.x - deskCenter.x) * size.width, y: (deskEdge.y - deskCenter.y) * size.height)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation])
    }

    // MARK: The book

    /// How many sheets lie under each open page: those already turned under the left, those still to come under the
    /// right.
    static func sheets(under pages: (left: Int?, right: Int?), in layout: BookLayout) -> (before: Int, after: Int) {
        guard let left = pages.left, let right = pages.right else { return (0, 0) }
        return (max(0, (left - 1) / 2), max(0, (layout.pages.count - 2 - right) / 2))
    }

    /// Draws a place in the book (`state`) on a desk `size` points big, into a context set up from the top left in
    /// points. `deviceScale` is how many of the context's own units make a point: shadows are drawn in those units.
    func draw(_ state: Int, in context: CGContext, size: CGSize, dark: Bool, deviceScale: CGFloat) {
        let settings = layout.settings
        let stage = BookStage(size: size, binding: settings.binding)
        let pages = layout.state(state)
        let open = pages.left != nil && pages.right != nil
        Self.drawDesk(in: context, size: size, dark: dark)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: stage.offset(state: state, stateCount: layout.stateCount), y: 0)

        // The shadow under the book. Core Graphics blurs half as far as Core Animation for the same radius: twice the
        // window's radius matches its shadow row for row.
        let shadow = stage.shadow(open: open, closedOnLeft: pages.left != nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -BookStage.shadowDrop * deviceScale), blur: BookStage.shadowRadius * 2 * deviceScale,
                          color: NSColor.black.withAlphaComponent(CGFloat(BookStage.shadowOpacity)).cgColor)
        context.addPath(CGPath(roundedRect: shadow.rect, cornerWidth: shadow.radius, cornerHeight: shadow.radius, transform: nil))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        if open {
            // The boards, a binder's spine between them, and the sheets under the pages.
            for (rect, spineOnRight) in [(stage.leftBoard, true), (stage.rightBoard, false)] {
                at(rect.origin, in: context) {
                    BinderArt.drawBoard(in: context, size: rect.size, cover: settings.cover, spineOnRight: spineOnRight, folds: !settings.binding.hasRings)
                }
            }
            if settings.binding.hasRings {
                let panel = stage.spinePanel
                at(panel.origin, in: context) {
                    BinderArt.drawSpine(in: context, size: panel.size, cover: settings.cover, finish: settings.rings, rings: stage.spineRingHeights,
                                        deviceScale: deviceScale)
                }
            }
            let sheets = Self.sheets(under: pages, in: layout)
            for (count, left) in [(sheets.before, true), (sheets.after, false)] {
                let page = stage.pageRect(left: left)
                guard let stack = BinderArt.stackSize(sheets: count, height: page.height) else { continue }
                at(CGPoint(x: left ? page.minX - stack.width : page.maxX, y: page.minY), in: context) {
                    BinderArt.drawStack(in: context, size: stack, sheets: count, height: page.height, paper: settings.paper, onLeft: left)
                }
            }
        }

        // The pages, their outer corners rounded; a closed cover is its whole board, past the page, rounded as it is.
        for (index, left) in [(pages.left, true), (pages.right, false)] {
            guard let index else { continue }
            let rect = stage.pageRect(left: left)
            context.saveGState()
            if open {
                context.addPath(BinderArt.outline(rect, radius: BookStage.pageCornerRadius, straightRight: left))
                context.clip()
            }
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: stage.unit, y: stage.unit)
            renderer.draw(layout.pages[index], index: index, isLeft: left, in: context)
            context.restoreGState()
        }

        // A binder's rings, over the pages.
        if open, settings.binding.hasRings {
            let box = stage.ringBox, thickness = stage.ringThickness
            at(box.origin, in: context) {
                BinderArt.drawRings(in: context, size: box.size, finish: settings.rings, rings: stage.ringHeights, from: thickness * 2,
                                    to: box.width - thickness * 2, thickness: thickness, deviceScale: deviceScale)
            }
        }
    }

    /// Draws with the origin moved to `origin`.
    private func at(_ origin: CGPoint, in context: CGContext, _ draw: () -> Void) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        draw()
        context.restoreGState()
    }
}
