import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct PhotoMapTests {
    let lake = GeoPoint(latitude: 45.2700, longitude: -121.7376)
    let beach = GeoPoint(latitude: 45.8918, longitude: -123.9615)

    /// `count` photos a few metres apart around `place`, one an hour.
    func photos(_ prefix: String, at place: GeoPoint, count: Int, favorite: Int? = nil) -> [MapPhoto] {
        (0..<count).map { index in
            MapPhoto(id: PhotoID("\(prefix)-\(index)"),
                     point: MapPoint(GeoPoint(latitude: place.latitude + Double(index) * 0.00002, longitude: place.longitude)),
                     isFavorite: index == favorite)
        }
    }

    @Test func placesLieOnTheMapAsMapsDrawThem() {
        let middle = MapPoint(GeoPoint(latitude: 0, longitude: 0))
        #expect(abs(middle.x - 0.5) < 1e-12 && abs(middle.y - 0.5) < 1e-12)
        #expect(MapPoint(GeoPoint(latitude: 0, longitude: -180)).x == 0)
        #expect(abs(MapPoint(GeoPoint(latitude: 85.051_128_78, longitude: 0)).y) < 1e-6)
        #expect(MapPoint(GeoPoint(latitude: 89, longitude: 0)).y == MapPoint(GeoPoint(latitude: 86, longitude: 0)).y)
        for place in [lake, beach, GeoPoint(latitude: -33.86, longitude: 151.21)] {
            let back = MapPoint(place).place
            #expect(abs(back.latitude - place.latitude) < 1e-9 && abs(back.longitude - place.longitude) < 1e-9)
        }
        #expect(MapPoint(lake).y < MapPoint(GeoPoint(latitude: 10, longitude: 0)).y, "north is up")
    }

    @Test func photosRegroupOnlyAtWholeStepsOfZoom() {
        let cell = PhotoMap.cellSize(visibleWidth: 0.01, viewWidth: 1000, spacing: 72)
        #expect(cell >= 0.01 / 1000 * 72)
        #expect(log2(cell) == log2(cell).rounded(), "a power of two")
        #expect(PhotoMap.cellSize(visibleWidth: 0.0095, viewWidth: 1000, spacing: 72) == cell, "a touch of zoom keeps the squares")
        #expect(PhotoMap.cellSize(visibleWidth: 0.005, viewWidth: 1000, spacing: 72) == cell / 2, "a whole step halves them")
    }

    @Test func photosTakenTogetherAreShownAsOne() {
        let all = photos("lake", at: lake, count: 5) + photos("beach", at: beach, count: 3)
        let clusters = PhotoMap.clusters(all, cell: PhotoMap.cellSize(visibleWidth: 0.02, viewWidth: 1000, spacing: 72))
        #expect(clusters.count == 2)
        #expect(clusters.map(\.photos.count).sorted() == [3, 5])
        #expect(Set(clusters.flatMap(\.photos)) == Set(all.map(\.id)) && clusters.flatMap(\.photos).count == all.count,
                "every photo once")
        let lakeCluster = clusters.first { $0.photos.count == 5 }!
        #expect(lakeCluster.photos == (0..<5).map { PhotoID("lake-\($0)") }, "oldest first")
        #expect(all.filter { lakeCluster.photos.contains($0.id) }.allSatisfy { lakeCluster.bounds.contains($0.point) })
    }

    @Test func aClusterShowsItsNewestFavoriteElseItsNewest() {
        let cell = PhotoMap.cellSize(visibleWidth: 0.02, viewWidth: 1000, spacing: 72)
        let plain = PhotoMap.clusters(photos("lake", at: lake, count: 4), cell: cell)
        #expect(plain.first?.cover == PhotoID("lake-3"))
        let liked = PhotoMap.clusters(photos("lake", at: lake, count: 4, favorite: 1), cell: cell)
        #expect(liked.first?.cover == PhotoID("lake-1"))
        #expect(liked.first?.point == MapPoint(GeoPoint(latitude: lake.latitude + 0.00002, longitude: lake.longitude)),
                "pinned where its cover was taken")
    }

    @Test func clustersNeverSitOnTopOfEachOther() {
        let cell = 1.0 / 1024
        // Two photos either side of a square's edge, a hair apart.
        let edge = 300 * cell
        let pair = [MapPhoto(id: "a", point: MapPoint(x: edge - cell * 0.05, y: 0.4)), MapPhoto(id: "b", point: MapPoint(x: edge + cell * 0.05, y: 0.4))]
        #expect(PhotoMap.clusters(pair, cell: cell).count == 1)
        // A scatter of photos: no two clusters closer than three quarters of a square.
        let scatter = (0..<400).map { index in
            MapPhoto(id: PhotoID("p\(index)"), point: MapPoint(x: 0.3 + Double((index * 37) % 101) * cell * 0.13, y: 0.4 + Double((index * 53) % 97) * cell * 0.11))
        }
        let clusters = PhotoMap.clusters(scatter, cell: cell)
        #expect(clusters.flatMap(\.photos).count == scatter.count)
        for (index, a) in clusters.enumerated() {
            for b in clusters[(index + 1)...] {
                #expect(hypot(a.point.x - b.point.x, a.point.y - b.point.y) >= cell * 0.75)
            }
        }
    }

    @Test func theSamePhotosGatherTheSameWayWhereverTheMapIsMoved() {
        let all = photos("lake", at: lake, count: 5) + photos("beach", at: beach, count: 3)
        let cell = PhotoMap.cellSize(visibleWidth: 0.02, viewWidth: 1000, spacing: 72)
        let everywhere = PhotoMap.clusters(all, cell: cell)
        #expect(PhotoMap.clusters(all.reversed().reversed(), cell: cell) == everywhere)
        let aroundLake = MapRect(around: [MapPoint(lake)])!.outset(by: cell * 2)
        let lakeOnly = PhotoMap.clusters(all, cell: cell, in: aroundLake)
        #expect(lakeOnly.count == 1 && everywhere.contains(lakeOnly[0]), "the same cluster, by the same name")
    }

    @Test func photosInOneSpotCantBeParted() {
        let spot = (0..<3).map { MapPhoto(id: PhotoID("s\($0)"), point: MapPoint(lake)) }
        #expect(PhotoMap.clusters(spot, cell: 1.0 / 4096).first?.isOnePlace == true)
        let spread = photos("lake", at: lake, count: 2) + photos("far", at: GeoPoint(latitude: lake.latitude + 0.01, longitude: lake.longitude), count: 1)
        #expect(PhotoMap.clusters(spread, cell: 1.0 / 64).first?.isOnePlace == false)
        #expect(PhotoMap.clusters([spot[0]], cell: 1.0 / 64).first?.isOnePlace == true)
    }
}
