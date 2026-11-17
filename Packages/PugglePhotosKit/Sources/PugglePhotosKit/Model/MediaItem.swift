import Foundation

/// Identifies one photo or video: the Photos library's own identifier for it on this Mac.
public struct PhotoID: Hashable, Comparable, Codable, CodingKeyRepresentable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Dictionaries keyed by PhotoID are written as JSON objects rather than arrays of pairs.
    public var codingKey: CodingKey { PhotoIDKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { rawValue = codingKey.stringValue }

    public static func < (lhs: PhotoID, rhs: PhotoID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

private struct PhotoIDKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// What kind of picture an item is. Live photos, screenshots and panoramas are photos with something extra.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo, video, livePhoto, screenshot, panorama

    public var isVideo: Bool { self == .video }

    public var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .livePhoto: "Live Photo"
        case .screenshot: "Screenshot"
        case .panorama: "Panorama"
        }
    }

    /// Kinds sort photos first, then the special photos, then videos.
    var sortRank: Int {
        switch self {
        case .photo: 0
        case .livePhoto: 1
        case .panorama: 2
        case .screenshot: 3
        case .video: 4
        }
    }
}

/// Where a picture was taken.
public struct GeoPoint: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One photo or video in the library, as the Photos library describes it. PugglePhotos' own notes about it
/// (captions, labels, albums) live in the `Catalog`.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public var id: PhotoID
    public var kind: MediaKind
    /// When it was taken. This is the date PugglePhotos sorts by and changes when photos are dragged to a day.
    public var date: Date
    /// When it was added to the library, if the library says.
    public var addedDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Seconds, for videos.
    public var duration: TimeInterval
    public var isFavorite: Bool
    public var location: GeoPoint?
    /// The original file's name, once it's known.
    public var fileName: String?

    public init(id: PhotoID, kind: MediaKind = .photo, date: Date, addedDate: Date? = nil, pixelWidth: Int = 4032,
                pixelHeight: Int = 3024, duration: TimeInterval = 0, isFavorite: Bool = false, location: GeoPoint? = nil,
                fileName: String? = nil) {
        self.id = id
        self.kind = kind
        self.date = date
        self.addedDate = addedDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.location = location
        self.fileName = fileName
    }

    /// Width divided by height; 1 when the size isn't known.
    public var aspectRatio: Double {
        pixelWidth > 0 && pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1
    }
}
