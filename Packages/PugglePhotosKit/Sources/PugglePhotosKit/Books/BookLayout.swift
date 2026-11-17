import CoreGraphics
import Foundation

/// A photo or video going into a book.
public struct BookItem: Hashable, Sendable {
    public let id: PhotoID
    /// Width over height.
    public let aspect: Double
    public let isVideo: Bool

    public init(id: PhotoID, aspect: Double, isVideo: Bool = false) {
        self.id = id
        self.aspect = aspect > 0 ? aspect : 1
        self.isVideo = isVideo
    }
}

/// One photo on a page: where its frame's middle is, how big its picture is and how far it leans. Page coordinates
/// run from the top left of a 600 × 780 page.
public struct BookPlacement: Hashable, Sendable {
    public let id: PhotoID
    public let isVideo: Bool
    /// The photo's own shape, width over height.
    public let aspect: Double
    public var center: CGPoint
    /// The picture's size inside its frame. Instant frames show a square picture.
    public var imageSize: CGSize
    /// Degrees, clockwise.
    public var angle: Double
    public var caption: String

    public init(id: PhotoID, isVideo: Bool, aspect: Double, center: CGPoint, imageSize: CGSize, angle: Double, caption: String) {
        self.id = id
        self.isVideo = isVideo
        self.aspect = aspect
        self.center = center
        self.imageSize = imageSize
        self.angle = angle
        self.caption = caption
    }

    /// The white border around the picture: sides, top and bottom.
    public func border(_ frame: BookFrame) -> (side: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch frame {
        case .instant:
            return (imageSize.width * 0.06, imageSize.width * 0.06, imageSize.width * 0.27)
        case .print, .taped:
            let border = max(imageSize.width, imageSize.height) * 0.035
            return (border, border, border)
        case .plain:
            return (0, 0, 0)
        }
    }

    public func frameSize(_ frame: BookFrame) -> CGSize {
        let border = border(frame)
        return CGSize(width: imageSize.width + border.side * 2, height: imageSize.height + border.top + border.bottom)
    }

    /// The frame, around the placement's own origin (its center), before it leans.
    public func frameRect(_ frame: BookFrame) -> CGRect {
        let size = frameSize(frame)
        return CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    }

    /// The picture, in the same coordinates as `frameRect`.
    public func imageRect(_ frame: BookFrame) -> CGRect {
        let outer = frameRect(frame)
        let border = border(frame)
        return CGRect(x: outer.minX + border.side, y: outer.minY + border.top, width: imageSize.width, height: imageSize.height)
    }

    /// Where the caption goes: in the instant frame's wide bottom border, or on the paper under the frame.
    public func captionRect(_ frame: BookFrame) -> CGRect {
        let outer = frameRect(frame)
        if frame == .instant {
            let border = border(frame)
            return CGRect(x: outer.minX + border.side, y: outer.maxY - border.bottom, width: imageSize.width, height: border.bottom)
        }
        return CGRect(x: outer.minX - 20, y: outer.maxY + 4, width: outer.width + 40, height: 28)
    }

    /// A point from page coordinates into the placement's own (centered, unleaning) coordinates.
    public func local(_ point: CGPoint) -> CGPoint {
        let radians = -angle * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: dx * cos(radians) - dy * sin(radians), y: dx * sin(radians) + dy * cos(radians))
    }

    /// A point from the placement's own coordinates onto the page.
    public func page(_ point: CGPoint) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + point.x * cos(radians) - point.y * sin(radians),
                       y: center.y + point.x * sin(radians) + point.y * cos(radians))
    }

    public func contains(_ point: CGPoint, frame: BookFrame) -> Bool {
        frameRect(frame).insetBy(dx: -2, dy: -2).contains(local(point))
    }

    /// The frame's four corners on the page.
    public func corners(_ frame: BookFrame) -> [CGPoint] {
        let rect = frameRect(frame)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map(page)
    }
}

public enum BookPageKind: Hashable, Sendable {
    /// The outside of the front cover.
    case cover
    /// The inside of a cover: endpaper.
    case insideCover
    /// The album's name, dates, story and cover photo.
    case title
    case photos
    case blank
    /// The outside of the back cover.
    case back
}

public struct BookPage: Hashable, Sendable {
    public let kind: BookPageKind
    public var placements: [BookPlacement]
    /// The page number printed at the bottom of photo pages.
    public let number: Int?

    public init(kind: BookPageKind, placements: [BookPlacement] = [], number: Int? = nil) {
        self.kind = kind
        self.placements = placements
        self.number = number
    }
}

/// A photo book laid out page by page: the cover, the inside cover, a title page, pages of photos (one, two or
/// three to a page, each leaning a little and jostled from its spot), a blank page if needed to finish a sheet,
/// the inside back cover and the back. The same photos and settings always give the same book; the person's own
/// moves and turns are laid over the top.
public struct BookLayout: Sendable {
    public static let pageSize = CGSize(width: 600, height: 780)
    public let pages: [BookPage]
    public let settings: BookSettings

    public init(items: [BookItem], captions: [PhotoID: String], settings: BookSettings, coverPhoto: PhotoID?) {
        self.settings = settings
        let hidden = Set(settings.hidden)
        let shown = items.filter { !hidden.contains($0.id) }
        var random = SplitMix(seed: settings.seed &* 0x9E37_79B9_7F4A_7C15 &+ 7)
        var pages = [BookPage(kind: .cover), BookPage(kind: .insideCover)]
        // The title page has the cover photo, a little turned.
        var titlePage = BookPage(kind: .title)
        if let cover = coverPhoto, let item = items.first(where: { $0.id == cover }) {
            titlePage.placements = [Self.place(item, in: CGRect(x: 150, y: 70, width: 300, height: 360), caption: "", settings: settings,
                                               leanScale: 0.6, applyingOverrides: false)]
        }
        pages.append(titlePage)
        var index = 0
        var number = 1
        while index < shown.count {
            let count = min(Self.capacity(settings.perPage, random: &random), shown.count - index)
            let group = Array(shown[index..<(index + count)])
            let slots = Self.slots(for: group, frame: settings.frame)
            let placements = zip(group, slots).map { item, slot in
                Self.place(item, in: slot, caption: captions[item.id] ?? "", settings: settings, leanScale: count == 1 ? 0.6 : 1)
            }
            pages.append(BookPage(kind: .photos, placements: placements, number: number))
            number += 1
            index += count
        }
        // Two cover pages follow, and every sheet has two sides, so the pages so far must come out even.
        if pages.count % 2 == 1 { pages.append(BookPage(kind: .blank)) }
        pages.append(BookPage(kind: .insideCover))
        pages.append(BookPage(kind: .back))
        self.pages = pages
    }

    /// How many photos the next page holds.
    static func capacity(_ perPage: BookPerPage, random: inout SplitMix) -> Int {
        switch perPage {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .mixed:
            let pattern = [2, 3, 2, 1, 3, 2, 2, 3]
            return pattern[Int(random.next() % UInt64(pattern.count))]
        }
    }

    /// The spaces on a page for one, two or three photos, chosen by their shapes.
    static func slots(for items: [BookItem], frame: BookFrame) -> [CGRect] {
        switch items.count {
        case 1:
            return [CGRect(x: 70, y: 70, width: 460, height: 620)]
        case 2:
            let tall = frame == .instant || items.allSatisfy { $0.aspect < 0.95 }
            if tall {
                // Two tall frames, one high on the left and one low on the right.
                return [CGRect(x: 40, y: 50, width: 300, height: 380), CGRect(x: 260, y: 360, width: 300, height: 380)]
            }
            return [CGRect(x: 60, y: 40, width: 480, height: 340), CGRect(x: 60, y: 400, width: 480, height: 340)]
        default:
            return [CGRect(x: 80, y: 30, width: 440, height: 360), CGRect(x: 30, y: 410, width: 280, height: 330),
                    CGRect(x: 290, y: 420, width: 280, height: 330)]
        }
    }

    /// Fits a photo's frame into its space, then nudges and turns it a little.
    static func place(_ item: BookItem, in slot: CGRect, caption: String, settings: BookSettings, leanScale: Double,
                      applyingOverrides: Bool = true) -> BookPlacement {
        let frame = settings.frame
        // Room for a caption written on the paper under the frame.
        let captionRoom: CGFloat = frame != .instant && !caption.isEmpty ? 30 : 0
        let space = CGSize(width: slot.width * 0.94, height: (slot.height - captionRoom) * 0.94)
        let imageAspect = frame == .instant ? 1.0 : item.aspect
        // The frame's shape follows from the picture's: instant frames are 1.12 wide by 1.33 tall per picture
        // width; prints add 3.5% of the longer side all round.
        let size: CGSize
        switch frame {
        case .instant:
            let width = min(space.width / 1.12, space.height / 1.33)
            size = CGSize(width: width, height: width)
        case .print, .taped:
            let scale = min(space.width / (imageAspect + 0.07 * max(imageAspect, 1)), space.height / (1 + 0.07 * max(imageAspect, 1)))
            size = CGSize(width: scale * imageAspect, height: scale)
        case .plain:
            let scale = min(space.width / imageAspect, space.height)
            size = CGSize(width: scale * imageAspect, height: scale)
        }
        var jitter = SplitMix(seed: settings.seed ^ KenBurns.seed(item.id))
        let dx = CGFloat(Int(jitter.next() % 29) - 14)
        let dy = CGFloat(Int(jitter.next() % 21) - 10)
        let lean = settings.tilt.maxDegrees * leanScale * (Double(jitter.next() % 2001) / 1000 - 1)
        var placement = BookPlacement(id: item.id, isVideo: item.isVideo, aspect: item.aspect,
                                      center: CGPoint(x: slot.midX + dx, y: slot.midY - captionRoom / 2 + dy),
                                      imageSize: size, angle: (lean * 10).rounded() / 10, caption: caption)
        if applyingOverrides, let override = settings.overrides[item.id] {
            if let center = override.center { placement.center = center }
            if let angle = override.angle { placement.angle = angle }
            if let scale = override.scale {
                placement.imageSize = CGSize(width: placement.imageSize.width * scale, height: placement.imageSize.height * scale)
            }
        }
        placement.center = clamp(placement.center)
        return placement
    }

    /// Keeps a frame's middle on the page.
    public static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 40), pageSize.width - 40), y: min(max(point.y, 40), pageSize.height - 40))
    }

    // MARK: Reading the book

    /// The places a reader can be: the closed front cover, each open spread, the closed back cover.
    public var stateCount: Int { pages.count / 2 + 1 }

    /// The pages showing at a place: the left and right page indexes (only the right one when closed at the
    /// front, only the left at the back).
    public func state(_ index: Int) -> (left: Int?, right: Int?) {
        let last = stateCount - 1
        if index <= 0 { return (nil, 0) }
        if index >= last { return (pages.count - 1, nil) }
        return (index * 2 - 1, index * 2)
    }

    /// The leaf that turns going forward from a place: the page now on the right becomes its front, and the next
    /// place's left page its back.
    public func leafTurningForward(from index: Int) -> (front: Int, back: Int)? {
        guard index >= 0, index < stateCount - 1, let front = state(index).right, let back = state(index + 1).left else { return nil }
        return (front, back)
    }

    /// The place a page is seen at.
    public func state(showing page: Int) -> Int {
        page == 0 ? 0 : (page + 1) / 2
    }

    /// Where a photo is, if it's in the book.
    public func find(_ id: PhotoID) -> (page: Int, placement: BookPlacement)? {
        for (index, page) in pages.enumerated() where page.kind == .photos {
            if let placement = page.placements.first(where: { $0.id == id }) { return (index, placement) }
        }
        return nil
    }

    /// The photo on a page under a point, the topmost first.
    public func placement(at point: CGPoint, onPage page: Int) -> BookPlacement? {
        guard pages.indices.contains(page) else { return nil }
        return pages[page].placements.reversed().first { $0.contains(point, frame: settings.frame) }
    }
}
