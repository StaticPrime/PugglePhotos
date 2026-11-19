import CoreGraphics
import Foundation

/// A photo or video going into a book.
public struct BookItem: Hashable, Sendable {
    public let id: PhotoID
    /// Width over height.
    public let aspect: Double
    public let isVideo: Bool
    /// Where on its page the photo lies, how it leans and where its sticky note goes come from this: by default its
    /// identifier's, or the one a photo shared with you had in its owner's library, so it lies just as it does there.
    public let seed: UInt64

    public init(id: PhotoID, aspect: Double, isVideo: Bool = false, seed: UInt64? = nil) {
        self.id = id
        self.aspect = aspect > 0 ? aspect : 1
        self.isVideo = isVideo
        self.seed = seed ?? KenBurns.seed(id)
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
    /// The photo's note, and how it shows here.
    public var note: String
    public var noteStyle: BookNoteStyle
    /// Its sticky note, when the note's on one.
    public var sticky: BookSticky

    public init(id: PhotoID, isVideo: Bool, aspect: Double, center: CGPoint, imageSize: CGSize, angle: Double, caption: String,
                note: String = "", noteStyle: BookNoteStyle = .hidden, sticky: BookSticky? = nil) {
        self.id = id
        self.isVideo = isVideo
        self.aspect = aspect
        self.center = center
        self.imageSize = imageSize
        self.angle = angle
        self.caption = caption
        self.note = note
        self.noteStyle = noteStyle
        self.sticky = sticky ?? BookSticky(center: .zero, size: CGSize(width: 140, height: 130), angle: 0)
    }

    /// Whether the note shows, and how.
    public var showsNote: Bool { !note.isEmpty && noteStyle != .hidden }
    public var hasSticky: Bool { !note.isEmpty && noteStyle == .sticky }

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

    /// Where the caption goes: in the instant frame's wide bottom border (its top part, when the note's written
    /// there too), or on the paper under the frame.
    public func captionRect(_ frame: BookFrame) -> CGRect {
        let outer = frameRect(frame)
        if frame == .instant {
            let border = border(frame)
            let height = showsNote && noteStyle == .onPhoto ? border.bottom * 0.45 : border.bottom
            return CGRect(x: outer.minX + border.side, y: outer.maxY - border.bottom, width: imageSize.width, height: height)
        }
        return CGRect(x: outer.minX - 20, y: outer.maxY + 4, width: outer.width + 40, height: 28)
    }

    /// The room a note written under a photo takes on the page.
    public static let noteRoom: CGFloat = 58

    /// Where the note is written, for notes on or under the photo: in an instant frame's border (under the
    /// caption), across the bottom of the picture, or on the paper under the frame (and its caption).
    public func noteRect(_ frame: BookFrame) -> CGRect {
        let outer = frameRect(frame)
        switch noteStyle {
        case .onPhoto where frame == .instant:
            let border = border(frame)
            let top = caption.isEmpty ? outer.maxY - border.bottom : outer.maxY - border.bottom * 0.55
            return CGRect(x: outer.minX + border.side, y: top, width: imageSize.width, height: outer.maxY - top - border.bottom * 0.06)
        case .onPhoto:
            let picture = imageRect(frame)
            let height = min(picture.height * 0.3, 80)
            return CGRect(x: picture.minX + 10, y: picture.maxY - height - 4, width: picture.width - 20, height: height)
        default:
            let top = outer.maxY + 4 + (frame != .instant && !caption.isEmpty ? 26 : 0)
            return CGRect(x: outer.minX - 6, y: top, width: outer.width + 12, height: Self.noteRoom - 6)
        }
    }

    /// Where a sticky note goes when the person hasn't moved it: over the frame's top right corner, hanging off it a
    /// little, leaning a little.
    public static func defaultSticky(frameSize: CGSize, seed: UInt64) -> BookSticky {
        let side = min(max(frameSize.width * 0.48, 120), 180)
        var random = SplitMix(seed: seed)
        let lean = Double(Int(random.next() % 81) - 40) / 10
        return BookSticky(center: CGPoint(x: frameSize.width / 2 - side * 0.28, y: -frameSize.height / 2 + side * 0.22),
                          size: CGSize(width: side, height: (side * 0.94).rounded()), angle: lean)
    }

    /// A point from the placement's own coordinates into its sticky note's (centered, unleaning) coordinates.
    public func stickyLocal(_ point: CGPoint) -> CGPoint {
        let own = local(point)
        let radians = -sticky.angle * .pi / 180
        let dx = own.x - sticky.center.x, dy = own.y - sticky.center.y
        return CGPoint(x: dx * cos(radians) - dy * sin(radians), y: dx * sin(radians) + dy * cos(radians))
    }

    /// A point on the sticky note (in its own coordinates) onto the page.
    public func stickyPage(_ point: CGPoint) -> CGPoint {
        let radians = sticky.angle * .pi / 180
        return page(CGPoint(x: sticky.center.x + point.x * cos(radians) - point.y * sin(radians),
                            y: sticky.center.y + point.x * sin(radians) + point.y * cos(radians)))
    }

    public func stickyContains(_ point: CGPoint) -> Bool {
        hasSticky && sticky.rect.insetBy(dx: -2, dy: -2).contains(stickyLocal(point))
    }

    /// The sticky note's four corners on the page.
    public func stickyCorners() -> [CGPoint] {
        let rect = sticky.rect
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map(stickyPage)
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

    // MARK: Resizing

    /// The shortest a frame's longer side can be made: small, but still a photo to look at.
    public static let smallestFrameSide: CGFloat = 110

    /// How many times bigger or smaller the photo can be made from the size it is now: down to a frame whose longer
    /// side is `smallestFrameSide`, up to one that fills its page but for a margin.
    public func resizeRange(_ frame: BookFrame) -> ClosedRange<Double> {
        let size = frameSize(frame)
        guard size.width > 0, size.height > 0 else { return 1...1 }
        let smallest = Self.smallestFrameSide / max(size.width, size.height)
        let biggest = min((BookLayout.pageSize.width - 40) / size.width, (BookLayout.pageSize.height - 40) / size.height)
        return Double(min(smallest, 1))...Double(max(biggest, 1))
    }

    /// How many times as big the photo becomes when its bottom right corner is dragged to a point on the page: how
    /// far along its diagonal the point is, so it keeps its shape, within `resizeRange`. `grab` is where on the
    /// corner it was taken hold of, from the corner itself in the photo's own coordinates, so that spot follows the
    /// pointer rather than the corner jumping to it.
    public func resizeFactor(draggingCornerTo point: CGPoint, grab: CGPoint = .zero, frame: BookFrame) -> Double {
        let rect = frameRect(frame)
        let local = local(point)
        // Where the corner is to go, from the top left corner, which stays put.
        let target = CGPoint(x: local.x - grab.x - rect.minX, y: local.y - grab.y - rect.minY)
        let length = rect.width * rect.width + rect.height * rect.height
        guard length > 0 else { return 1 }
        let factor = Double((target.x * rect.width + target.y * rect.height) / length)
        let range = resizeRange(frame)
        return min(max(factor, range.lowerBound), range.upperBound)
    }

    /// Where the photo's middle goes when it's made `factor` times as big, so its top left corner (as it leans)
    /// stays where it is.
    public func center(resizedBy factor: Double, frame: BookFrame) -> CGPoint {
        let rect = frameRect(frame)
        let shrink = 1 - CGFloat(factor)
        return page(CGPoint(x: shrink * rect.minX, y: shrink * rect.minY))
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
    /// A page left blank so the last sheet has two sides.
    case blank
    /// A page the person added, for writing on.
    case added
    /// The outside of the back cover.
    case back
}

public struct BookPage: Hashable, Sendable {
    public let kind: BookPageKind
    public var placements: [BookPlacement]
    /// The page number printed at the bottom of photo pages and added pages.
    public let number: Int?
    /// How writing finds this page again; nil for a blank page, which comes and goes.
    public let spot: BookSpot?
    /// What's written on it.
    public var writings: [BookWriting]

    public init(kind: BookPageKind, placements: [BookPlacement] = [], number: Int? = nil, spot: BookSpot? = nil,
                writings: [BookWriting] = []) {
        self.kind = kind
        self.placements = placements
        self.number = number
        self.spot = spot
        self.writings = writings
    }

    /// Pages that photos are put on and picked up from: pages of photos, and pages the person added.
    public var holdsPhotos: Bool { kind == .photos || kind == .added }
}

/// A photo book laid out page by page: the cover, the inside cover, a title page, pages of photos (one, two or
/// three to a page, each leaning a little and jostled from its spot) with any pages the person added among them,
/// a blank page if needed to finish a sheet, the inside back cover and the back. The same photos and settings
/// always give the same book; the person's own moves, sticky notes and writing are laid over the top.
public struct BookLayout: Sendable {
    public static let pageSize = CGSize(width: 600, height: 780)
    public let pages: [BookPage]
    public let settings: BookSettings
    /// The page of photos the book puts each photo on, before any is moved to another page by hand. Writing beside
    /// photos, and photos moved to a page of photos, find their page by these.
    public let homePages: [PhotoID: Int]

    public init(items: [BookItem], captions: [PhotoID: String], notes: [PhotoID: String] = [:], settings: BookSettings,
                coverPhoto: PhotoID?) {
        self.settings = settings
        let hidden = Set(settings.hidden)
        let shown = items.filter { !hidden.contains($0.id) }
        var random = SplitMix(seed: settings.seed &* 0x9E37_79B9_7F4A_7C15 &+ 7)
        var pages = [BookPage(kind: .cover, spot: .cover), BookPage(kind: .insideCover, spot: .insideFront)]
        // The title page has the cover photo, a little turned.
        var titlePage = BookPage(kind: .title, spot: .title)
        if let cover = coverPhoto, let item = items.first(where: { $0.id == cover }) {
            titlePage.placements = [Self.place(item, in: CGRect(x: 150, y: 70, width: 300, height: 360), caption: "", note: "", settings: settings,
                                               leanScale: 0.6, applyingOverrides: false)]
        }
        pages.append(titlePage)
        var number = 1
        // An added page goes right after the page it was added after, so the newest of several added after the same
        // page comes first; pages added after it follow it.
        let extras = settings.extraPages
        var placed = Set<UUID>()
        func addExtras(after anchor: BookAnchor) {
            for extra in extras.reversed() where extra.after == anchor && !placed.contains(extra.id) {
                placed.insert(extra.id)
                pages.append(BookPage(kind: .added, number: number, spot: .page(extra.id)))
                number += 1
                addExtras(after: .page(extra.id))
            }
        }
        addExtras(after: .title)
        var index = 0
        while index < shown.count {
            let count = min(Self.capacity(settings.perPage, random: &random), shown.count - index)
            let group = Array(shown[index..<(index + count)])
            let slots = Self.slots(for: group, frame: settings.frame)
            let placements = zip(group, slots).map { item, slot in
                Self.place(item, in: slot, caption: captions[item.id] ?? "", note: notes[item.id] ?? "", settings: settings,
                           leanScale: count == 1 ? 0.6 : 1)
            }
            pages.append(BookPage(kind: .photos, placements: placements, number: number, spot: group.first.map { .photo($0.id) }))
            number += 1
            index += count
            for item in group { addExtras(after: .photo(item.id)) }
        }
        // Pages added after something no longer in the book go at the end of it.
        for extra in extras where !placed.contains(extra.id) {
            placed.insert(extra.id)
            pages.append(BookPage(kind: .added, number: number, spot: .page(extra.id)))
            number += 1
            addExtras(after: .page(extra.id))
        }
        // Each photo's own page. Photos moved by hand to another page go there, on top of what's on it, and the rest
        // stay where they are; they're laid on in the album's order, so a book comes out the same every time.
        var home: [PhotoID: Int] = [:]
        for (index, page) in pages.enumerated() where page.kind == .photos {
            for placement in page.placements { home[placement.id] = index }
        }
        for item in shown {
            guard let spot = settings.overrides[item.id]?.page, let from = home[item.id] else { continue }
            let target: Int? = switch spot {
            case let .photo(other): home[other]
            default: pages.firstIndex { $0.kind == .added && $0.spot == spot }
            }
            guard let target, target != from, let at = pages[from].placements.firstIndex(where: { $0.id == item.id }) else { continue }
            pages[target].placements.append(pages[from].placements.remove(at: at))
        }
        homePages = home
        // Two cover pages follow, and every sheet has two sides, so the pages so far must come out even.
        if pages.count % 2 == 1 { pages.append(BookPage(kind: .blank)) }
        pages.append(BookPage(kind: .insideCover, spot: .insideBack))
        pages.append(BookPage(kind: .back, spot: .back))
        // Writing goes on its page: a page of photos is found by any photo of its own.
        for writing in settings.writings {
            let target: Int? = switch writing.spot {
            case let .photo(id): home[id]
            default: pages.firstIndex { $0.spot == writing.spot }
            }
            if let target { pages[target].writings.append(writing) }
        }
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
    static func place(_ item: BookItem, in slot: CGRect, caption: String, note: String, settings: BookSettings, leanScale: Double,
                      applyingOverrides: Bool = true) -> BookPlacement {
        let frame = settings.frame
        let noteStyle = applyingOverrides ? settings.noteStyle(for: item.id) : .hidden
        // Room for a caption, and a note, written on the paper under the frame.
        let captionRoom: CGFloat = (frame != .instant && !caption.isEmpty ? 30 : 0)
            + (!note.isEmpty && noteStyle == .underPhoto ? BookPlacement.noteRoom : 0)
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
        var jitter = SplitMix(seed: settings.seed ^ item.seed)
        let dx = CGFloat(Int(jitter.next() % 29) - 14)
        let dy = CGFloat(Int(jitter.next() % 21) - 10)
        let lean = settings.tilt.maxDegrees * leanScale * (Double(jitter.next() % 2001) / 1000 - 1)
        var placement = BookPlacement(id: item.id, isVideo: item.isVideo, aspect: item.aspect,
                                      center: CGPoint(x: slot.midX + dx, y: slot.midY - captionRoom / 2 + dy),
                                      imageSize: size, angle: (lean * 10).rounded() / 10, caption: caption,
                                      note: note, noteStyle: noteStyle)
        let override = applyingOverrides ? settings.overrides[item.id] : nil
        if let override {
            if let center = override.center { placement.center = center }
            if let angle = override.angle { placement.angle = angle }
            if let scale = override.scale {
                placement.imageSize = CGSize(width: placement.imageSize.width * scale, height: placement.imageSize.height * scale)
            }
        }
        placement.sticky = override?.sticky
            ?? BookPlacement.defaultSticky(frameSize: placement.frameSize(frame), seed: settings.seed ^ item.seed ^ 0x5717)
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

    /// Where a photo is, if it's in the book: on its own page, or one it was moved to.
    public func find(_ id: PhotoID) -> (page: Int, placement: BookPlacement)? {
        for (index, page) in pages.enumerated() where page.holdsPhotos {
            if let placement = page.placements.first(where: { $0.id == id }) { return (index, placement) }
        }
        return nil
    }

    /// Whether a photo can be put down on a page: a page of photos, an added page, or the blank page at the end (which
    /// is kept once something's on it).
    public func takesPhotos(_ page: Int) -> Bool {
        pages.indices.contains(page) && (pages[page].holdsPhotos || pages[page].kind == .blank)
    }

    /// How a photo moved to a page finds it again: a page of photos by the first photo the book puts there, an added
    /// page by its name. Nil for pages photos can't go on, and for the blank page at the end, until it's kept.
    public func spot(forPhotosOn page: Int) -> BookSpot? {
        guard pages.indices.contains(page), pages[page].holdsPhotos else { return nil }
        return pages[page].spot
    }

    /// The photo on a page under a point, the topmost first.
    public func placement(at point: CGPoint, onPage page: Int) -> BookPlacement? {
        guard pages.indices.contains(page) else { return nil }
        return pages[page].placements.reversed().first { $0.contains(point, frame: settings.frame) }
    }

    /// The photo whose sticky note is under a point on a page; sticky notes lie over every photo.
    public func sticky(at point: CGPoint, onPage page: Int) -> BookPlacement? {
        guard pages.indices.contains(page) else { return nil }
        return pages[page].placements.reversed().first { $0.stickyContains(point) }
    }

    /// The page a spot is on: for a photo, its own page, wherever it has been moved to.
    public func page(of spot: BookSpot) -> Int? {
        if case let .photo(id) = spot { return homePages[id] }
        return pages.firstIndex { $0.spot == spot }
    }

    /// Where writing put at a point on a page belongs: the page itself, or for a page of photos, the photo of its own
    /// nearest the point, so the writing stays with it if the book is laid out afresh. Nil for a blank page.
    public func spot(forWritingAt point: CGPoint, onPage page: Int) -> BookSpot? {
        guard pages.indices.contains(page) else { return nil }
        let target = pages[page]
        if target.kind == .photos {
            let own = target.placements.filter { homePages[$0.id] == page }
            let nearest = own.min { hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y) }
            return nearest.map { .photo($0.id) } ?? target.spot
        }
        return target.spot
    }

    /// Where a page added now, next to a page, goes: after that page (or for the title page, before the photos).
    /// Nil for the covers and the inside covers, which can't have pages after them.
    public func anchor(after page: Int) -> BookAnchor? {
        guard pages.indices.contains(page) else { return nil }
        let target = pages[page]
        switch target.kind {
        case .title: return .title
        case .photos:
            // After the page's own photos, which find it however the photos on it are moved about.
            if let own = target.placements.last(where: { homePages[$0.id] == page }) { return .photo(own.id) }
            if case let .photo(id)? = target.spot { return .photo(id) }
            return nil
        case .added:
            if case let .page(id) = target.spot { return .page(id) }
            return nil
        case .blank:
            // The blank page at the end: after the last page of photos or added page before it.
            return (0..<page).reversed().lazy.compactMap { self.anchor(after: $0) }.first
        default: return nil
        }
    }
}
