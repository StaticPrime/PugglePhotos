import CoreGraphics
import Foundation

/// The paper a photo book's pages are made of.
public enum BookPaper: String, Codable, Sendable, CaseIterable {
    case cream, kraft, black, blush, sky, linen

    public var displayName: String {
        switch self {
        case .cream: "Cream"
        case .kraft: "Kraft"
        case .black: "Black Album"
        case .blush: "Blush"
        case .sky: "Sky"
        case .linen: "Linen"
        }
    }

    /// The paper's color, as 0xRRGGBB.
    public var color: UInt32 {
        switch self {
        case .cream: 0xF7F1E3
        case .kraft: 0xCDAA7D
        case .black: 0x1E1E21
        case .blush: 0xF8E4E8
        case .sky: 0xE2EEF7
        case .linen: 0xEDE7DB
        }
    }

    /// Whether writing on it is light, as on the black pages of an old album.
    public var isDark: Bool { self == .black }
}

/// How each photo sits on the page.
public enum BookFrame: String, Codable, Sendable, CaseIterable {
    /// An instant photo: a square picture in a white frame with room to write underneath.
    case instant
    /// A print with a thin white border.
    case print
    /// The photo alone.
    case plain
    /// A print held down with strips of tape.
    case taped

    public var displayName: String {
        switch self {
        case .instant: "Instant Photos"
        case .print: "Prints"
        case .plain: "Plain Photos"
        case .taped: "Taped Prints"
        }
    }
}

/// How much the photos lean.
public enum BookTilt: String, Codable, Sendable, CaseIterable {
    case none, gentle, playful

    public var displayName: String {
        switch self {
        case .none: "Straight"
        case .gentle: "A Little Tilted"
        case .playful: "Every Which Way"
        }
    }

    /// The most a photo leans either way, in degrees.
    public var maxDegrees: Double {
        switch self {
        case .none: 0
        case .gentle: 4
        case .playful: 9
        }
    }
}

/// How many photos share a page.
public enum BookPerPage: String, Codable, Sendable, CaseIterable {
    case one, two, three, mixed

    public var displayName: String {
        switch self {
        case .one: "One Photo a Page"
        case .two: "Two Photos a Page"
        case .three: "Three Photos a Page"
        case .mixed: "A Mix"
        }
    }
}

/// The book's cover cloth.
public enum BookCover: String, Codable, Sendable, CaseIterable {
    case rose, navy, sage, sand, charcoal

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var color: UInt32 {
        switch self {
        case .rose: 0xC2546F
        case .navy: 0x253B5E
        case .sage: 0x7E9A7B
        case .sand: 0xC8AE88
        case .charcoal: 0x3A3A3E
        }
    }
}

/// Where the person put one photo, or how they turned it, overriding the book's own layout.
public struct BookPlacementOverride: Codable, Hashable, Sendable {
    /// The middle of the photo's frame, in page coordinates.
    public var center: CGPoint?
    /// Degrees, clockwise.
    public var angle: Double?
    /// 1 is the size the layout chose.
    public var scale: Double?

    public init(center: CGPoint? = nil, angle: Double? = nil, scale: Double? = nil) {
        self.center = center
        self.angle = angle
        self.scale = scale
    }

    public var isEmpty: Bool { center == nil && angle == nil && scale == nil }
}

/// How an album looks as a photo book. Albums without settings use the defaults.
public struct BookSettings: Codable, Hashable, Sendable {
    public var paper: BookPaper
    public var frame: BookFrame
    public var tilt: BookTilt
    public var perPage: BookPerPage
    public var cover: BookCover
    /// Changing it lays the book out afresh.
    public var seed: UInt64
    public var overrides: [PhotoID: BookPlacementOverride]
    /// Photos left out of the book (they stay in the album).
    public var hidden: [PhotoID]

    public init(paper: BookPaper = .cream, frame: BookFrame = .instant, tilt: BookTilt = .gentle, perPage: BookPerPage = .mixed,
                cover: BookCover = .rose, seed: UInt64 = 1, overrides: [PhotoID: BookPlacementOverride] = [:], hidden: [PhotoID] = []) {
        self.paper = paper
        self.frame = frame
        self.tilt = tilt
        self.perPage = perPage
        self.cover = cover
        self.seed = seed
        self.overrides = overrides
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey { case paper, frame, tilt, perPage, cover, seed, overrides, hidden }

    // Settings saved by a later version with choices this one doesn't know fall back to the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BookSettings()
        paper = (try? container.decodeIfPresent(BookPaper.self, forKey: .paper)) ?? defaults.paper
        frame = (try? container.decodeIfPresent(BookFrame.self, forKey: .frame)) ?? defaults.frame
        tilt = (try? container.decodeIfPresent(BookTilt.self, forKey: .tilt)) ?? defaults.tilt
        perPage = (try? container.decodeIfPresent(BookPerPage.self, forKey: .perPage)) ?? defaults.perPage
        cover = (try? container.decodeIfPresent(BookCover.self, forKey: .cover)) ?? defaults.cover
        seed = (try? container.decodeIfPresent(UInt64.self, forKey: .seed)) ?? defaults.seed
        overrides = (try? container.decodeIfPresent([PhotoID: BookPlacementOverride].self, forKey: .overrides)) ?? [:]
        hidden = (try? container.decodeIfPresent([PhotoID].self, forKey: .hidden)) ?? []
    }
}

extension Catalog {
    /// An album's book settings, or the defaults.
    public func book(_ album: UUID) -> BookSettings { self.album(album)?.book ?? BookSettings() }

    public mutating func setBook(_ settings: BookSettings, for album: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == album }) else { return }
        albums[index].book = settings == BookSettings() ? nil : settings
    }
}
