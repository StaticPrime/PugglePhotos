import CoreGraphics
import Foundation

/// How a photo's note shows in a book.
public enum BookNoteStyle: String, Codable, Sendable, CaseIterable {
    /// On a sticky note stuck to the photo.
    case sticky
    /// Written on the photo: in an instant photo's wide border, or across the bottom of the picture.
    case onPhoto
    /// Written on the page under the photo.
    case underPhoto
    /// Not shown.
    case hidden

    public var displayName: String {
        switch self {
        case .sticky: "On Sticky Notes"
        case .onPhoto: "Written on the Photos"
        case .underPhoto: "Written Under the Photos"
        case .hidden: "Hidden"
        }
    }

    /// For one photo rather than the whole book.
    public var singularName: String {
        switch self {
        case .sticky: "On a Sticky Note"
        case .onPhoto: "Written on the Photo"
        case .underPhoto: "Written Under the Photo"
        case .hidden: "Hidden"
        }
    }

    /// The name for books with these frames: an instant photo's note is written in the white space under its
    /// picture.
    public func displayName(for frame: BookFrame) -> String {
        switch (self, frame) {
        case (.onPhoto, .instant): "Written in the White Space"
        case (.underPhoto, .instant): "Written on the Page Below"
        default: displayName
        }
    }
}

/// A sticky note's paper.
public enum BookStickyColor: String, Codable, Sendable, CaseIterable {
    case yellow, pink, blue, green, orange

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// As 0xRRGGBB.
    public var color: UInt32 {
        switch self {
        case .yellow: 0xFFEE9C
        case .pink: 0xFFC6D6
        case .blue: 0xC4E2FB
        case .green: 0xCFEFBE
        case .orange: 0xFFD3A0
        }
    }
}

/// Where a sticky note sits on its photo. It's kept in the photo's own coordinates (from the middle of its frame,
/// before the photo leans), so it moves and turns with the photo, and it may hang off the edge.
public struct BookSticky: Codable, Hashable, Sendable {
    public var center: CGPoint
    public var size: CGSize
    /// Degrees, clockwise, on top of the photo's own lean.
    public var angle: Double
    public var color: BookStickyColor

    public init(center: CGPoint, size: CGSize, angle: Double, color: BookStickyColor = .yellow) {
        self.center = center
        self.size = size
        self.angle = angle
        self.color = color
    }

    /// The smallest a sticky note can be made.
    public static let smallest = CGSize(width: 70, height: 60)

    /// Its paper, around its own middle, before it leans.
    public var rect: CGRect { CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height) }
}

/// The color of the ink something is written in.
public enum BookInk: String, Codable, Sendable, CaseIterable {
    /// Dark on light paper; light on black paper and on the cloth covers.
    case automatic, black, blue, red, green, white, gold

    public var displayName: String {
        self == .automatic ? "Automatic" : rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// As 0xRRGGBB, on paper (or cloth, when `onDark`).
    public func color(onDark: Bool) -> UInt32 {
        switch self {
        case .automatic: onDark ? 0xF4F1EA : 0x2A2733
        case .black: 0x24222B
        case .blue: 0x2B4C9B
        case .red: 0xB3313B
        case .green: 0x2F6B3F
        case .white: 0xF7F5F0
        case .gold: 0xC9A24A
        }
    }
}

/// A page of a book, as writing finds it again after the book is laid out afresh: the covers and the title page
/// by what they are, a page of photos by a photo on it, and an added page by its own name.
public enum BookSpot: Codable, Hashable, Sendable {
    case cover
    case insideFront
    case title
    /// The page this photo is on, wherever that is.
    case photo(PhotoID)
    /// A page the person added.
    case page(UUID)
    case insideBack
    case back
}

/// Where an added page goes.
public enum BookAnchor: Codable, Hashable, Sendable {
    /// After the title page, before the photos.
    case title
    /// After the page this photo is on.
    case photo(PhotoID)
    /// After another added page.
    case page(UUID)
}

/// A page added to the book for writing on.
public struct BookExtraPage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var after: BookAnchor

    public init(id: UUID = UUID(), after: BookAnchor) {
        self.id = id
        self.after = after
    }
}

/// Words written on a page: anywhere on it, at any angle, in the book's handwriting.
public struct BookWriting: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var spot: BookSpot
    /// The middle of the writing, in page coordinates.
    public var center: CGPoint
    /// How wide the lines run before they wrap, in page points.
    public var width: CGFloat
    /// How big the letters are, in page points.
    public var size: CGFloat
    /// Degrees, clockwise.
    public var angle: Double
    public var ink: BookInk

    public init(id: UUID = UUID(), text: String = "", spot: BookSpot, center: CGPoint, width: CGFloat = 300, size: CGFloat = 26,
                angle: Double = 0, ink: BookInk = .automatic) {
        self.id = id
        self.text = text
        self.spot = spot
        self.center = center
        self.width = width
        self.size = size
        self.angle = angle
        self.ink = ink
    }

    /// The narrowest and the most a line can run, and the smallest and biggest letters.
    public static let widths: ClosedRange<CGFloat> = 60...560
    public static let sizes: ClosedRange<CGFloat> = 12...72

    /// A point from page coordinates into the writing's own (centered, unleaning) coordinates.
    public func local(_ point: CGPoint) -> CGPoint {
        let radians = -angle * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: dx * cos(radians) - dy * sin(radians), y: dx * sin(radians) + dy * cos(radians))
    }

    /// A point from the writing's own coordinates onto the page.
    public func page(_ point: CGPoint) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + point.x * cos(radians) - point.y * sin(radians),
                       y: center.y + point.x * sin(radians) + point.y * cos(radians))
    }
}
