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

/// Where the person put one photo, or how they turned it, and how its note shows, overriding the book's own layout.
public struct BookPlacementOverride: Codable, Hashable, Sendable {
    /// The middle of the photo's frame, in page coordinates.
    public var center: CGPoint?
    /// Degrees, clockwise.
    public var angle: Double?
    /// 1 is the size the layout chose.
    public var scale: Double?
    /// How this photo's note shows, if not as the book's notes do.
    public var noteStyle: BookNoteStyle?
    /// Where its sticky note was moved to, how big it was made and its color.
    public var sticky: BookSticky?

    public init(center: CGPoint? = nil, angle: Double? = nil, scale: Double? = nil, noteStyle: BookNoteStyle? = nil,
                sticky: BookSticky? = nil) {
        self.center = center
        self.angle = angle
        self.scale = scale
        self.noteStyle = noteStyle
        self.sticky = sticky
    }

    public var isEmpty: Bool { center == nil && angle == nil && scale == nil && noteStyle == nil && sticky == nil }

    enum CodingKeys: String, CodingKey { case center, angle, scale, noteStyle, sticky }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try? container.decodeIfPresent(CGPoint.self, forKey: .center)
        angle = try? container.decodeIfPresent(Double.self, forKey: .angle)
        scale = try? container.decodeIfPresent(Double.self, forKey: .scale)
        noteStyle = try? container.decodeIfPresent(BookNoteStyle.self, forKey: .noteStyle)
        sticky = try? container.decodeIfPresent(BookSticky.self, forKey: .sticky)
    }
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
    /// How the photos' notes show, unless a photo says otherwise; nil to write them in an instant photo's white
    /// space, or on the page under other kinds of photos.
    public var notes: BookNoteStyle?
    /// The font family everything in the book is written in; nil for the one chosen in Settings.
    public var handwriting: String?
    /// Words written on the pages.
    public var writings: [BookWriting]
    /// Pages added for writing on.
    public var extraPages: [BookExtraPage]

    public init(paper: BookPaper = .cream, frame: BookFrame = .instant, tilt: BookTilt = .gentle, perPage: BookPerPage = .mixed,
                cover: BookCover = .rose, seed: UInt64 = 1, overrides: [PhotoID: BookPlacementOverride] = [:], hidden: [PhotoID] = [],
                notes: BookNoteStyle? = nil, handwriting: String? = nil, writings: [BookWriting] = [], extraPages: [BookExtraPage] = []) {
        self.paper = paper
        self.frame = frame
        self.tilt = tilt
        self.perPage = perPage
        self.cover = cover
        self.seed = seed
        self.overrides = overrides
        self.hidden = hidden
        self.notes = notes
        self.handwriting = handwriting
        self.writings = writings
        self.extraPages = extraPages
    }

    enum CodingKeys: String, CodingKey { case paper, frame, tilt, perPage, cover, seed, overrides, hidden, notes, handwriting, writings, extraPages }

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
        notes = try? container.decodeIfPresent(BookNoteStyle.self, forKey: .notes)
        handwriting = try? container.decodeIfPresent(String.self, forKey: .handwriting)
        writings = (try? container.decodeIfPresent([BookWriting].self, forKey: .writings)) ?? []
        extraPages = (try? container.decodeIfPresent([BookExtraPage].self, forKey: .extraPages)) ?? []
    }

    /// How the book's notes show: as chosen, or else by the frames.
    public var noteStyle: BookNoteStyle { notes ?? (frame == .instant ? .onPhoto : .underPhoto) }

    /// How one photo's note shows.
    public func noteStyle(for id: PhotoID) -> BookNoteStyle { overrides[id]?.noteStyle ?? noteStyle }

    /// Changes one photo's override, dropping it when nothing's left in it.
    public mutating func changeOverride(_ id: PhotoID, _ change: (inout BookPlacementOverride) -> Void) {
        var override = overrides[id] ?? BookPlacementOverride()
        change(&override)
        overrides[id] = override.isEmpty ? nil : override
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
