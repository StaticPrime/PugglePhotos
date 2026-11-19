import Foundation

/// A place on the map, in the square the world is drawn on (the Mercator projection maps use): x runs from the date
/// line in the west (0) to the date line in the east (1), y from the top of the map, far in the north (0), to its foot
/// (1).
public struct MapPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Where a place on the globe lies on the map. The far north and south, which the map doesn't reach, lie on its
    /// edges.
    public init(_ place: GeoPoint) {
        let latitude = min(max(place.latitude, -85.051_128_78), 85.051_128_78) * .pi / 180
        x = (place.longitude + 180) / 360
        y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2
    }

    /// The place on the globe it shows.
    public var place: GeoPoint {
        GeoPoint(latitude: atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi, longitude: x * 360 - 180)
    }
}

/// A stretch of the map, in the same square.
public struct MapRect: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The smallest stretch holding all these points; nil when there are none.
    public init?(around points: some Sequence<MapPoint>) {
        var iterator = points.makeIterator()
        guard let first = iterator.next() else { return nil }
        self.init(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        while let point = iterator.next() { include(point) }
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public func contains(_ point: MapPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Grown by `amount` on every side (shrunk, when it's less than nothing).
    public func outset(by amount: Double) -> MapRect {
        MapRect(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
    }

    mutating func include(_ point: MapPoint) {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }
}

/// A photo or video with a place, as the map needs it.
public struct MapPhoto: Hashable, Sendable {
    public var id: PhotoID
    public var point: MapPoint
    public var isFavorite: Bool

    public init(id: PhotoID, point: MapPoint, isFavorite: Bool = false) {
        self.id = id
        self.point = point
        self.isFavorite = isFavorite
    }
}

/// Photos close together at the scale the map's shown at, shown as one: its cover, and how many there are.
public struct MapCluster: Hashable, Sendable, Identifiable {
    /// The same for the same photos at the same scale, so a cluster stays put as the map is moved about.
    public let id: String
    /// Oldest first.
    public let photos: [PhotoID]
    /// The one shown: of the photos in the square most of them are in, the newest favorite, else the newest.
    public let cover: PhotoID
    /// Where it's pinned: where its cover was taken.
    public let point: MapPoint
    /// Where all its photos were taken.
    public let bounds: MapRect

    /// Whether its photos were all taken in about the same spot (within some 40 metres), so zooming in wouldn't
    /// part them.
    public var isOnePlace: Bool { photos.count == 1 || max(bounds.width, bounds.height) < PhotoMap.samePlace }
}

/// Photos on a map, gathered into clusters so they don't pile up on one another.
public enum PhotoMap {
    /// About 40 metres at the equator, in map units: photos closer than this are taken to be in one spot.
    public static let samePlace = 1e-6

    /// The side of the squares photos are gathered by, for a map showing `visibleWidth` of the world across
    /// `viewWidth` points, with clusters at least `spacing` points apart. A power of two, so the photos regroup only
    /// when the map's zoomed in or out a whole step, never at each touch of the zoom.
    public static func cellSize(visibleWidth: Double, viewWidth: Double, spacing: Double) -> Double {
        guard visibleWidth > 0, viewWidth > 0, spacing > 0 else { return 1 }
        return pow(2, log2(visibleWidth / viewWidth * spacing).rounded(.up))
    }

    /// Gathers photos, given in date order, into clusters at least about `cell` apart: by the square of the map
    /// they're in, then any two whose covers would still sit almost on top of each other, into one. With `region`,
    /// only the photos in it are gathered (give it a margin of a square or two, so clusters at its edges come whole).
    public static func clusters(_ photos: [MapPhoto], cell: Double, in region: MapRect? = nil) -> [MapCluster] {
        guard cell > 0 else { return [] }
        let scale = Int(log2(cell).rounded())
        func square(_ point: MapPoint) -> Square {
            Square(column: Int((point.x / cell).rounded(.down)), row: Int((point.y / cell).rounded(.down)))
        }
        var bySquare: [Square: [Int]] = [:]
        for (index, photo) in photos.enumerated() where region?.contains(photo.point) ?? true {
            bySquare[square(photo.point), default: []].append(index)
        }
        // The fullest first, then by place, so the same photos always gather the same way.
        let drafts = bySquare.map { Draft(square: $0.key, members: $0.value, photos: photos) }
            .sorted { ($0.members.count, $1.square) > ($1.members.count, $0.square) }
        var kept: [Draft] = []
        var keptBySquare: [Square: [Int]] = [:]
        for draft in drafts {
            let around = square(draft.point)
            let near = (-1...1).flatMap { dx in (-1...1).flatMap { dy in keptBySquare[Square(column: around.column + dx, row: around.row + dy)] ?? [] } }
            if let index = near.first(where: { distance(kept[$0].point, draft.point) < cell * 0.75 }) {
                // Its cover, and so where it's pinned, stay: no cluster moves nearer another.
                kept[index].members += draft.members
            } else {
                keptBySquare[around, default: []].append(kept.count)
                kept.append(draft)
            }
        }
        return kept.map { draft in
            let members = draft.members.sorted()
            return MapCluster(id: "\(scale):\(draft.square.column):\(draft.square.row)", photos: members.map { photos[$0].id },
                              cover: photos[draft.cover].id, point: draft.point,
                              bounds: MapRect(around: members.map { photos[$0].point })!)
        }
    }

    private static func distance(_ a: MapPoint, _ b: MapPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private struct Square: Hashable, Comparable {
        var column: Int
        var row: Int

        static func < (a: Square, b: Square) -> Bool { (a.column, a.row) < (b.column, b.row) }
    }

    /// A cluster being gathered: its photos by their place in the date order, and its cover, the newest favorite of
    /// those in its square, else the newest.
    private struct Draft {
        let square: Square
        var members: [Int]
        let cover: Int
        let point: MapPoint

        init(square: Square, members: [Int], photos: [MapPhoto]) {
            self.square = square
            self.members = members
            cover = members.filter { photos[$0].isFavorite }.max() ?? members.max()!
            point = photos[cover].point
        }
    }
}
