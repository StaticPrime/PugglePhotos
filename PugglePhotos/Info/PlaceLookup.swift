import CoreLocation
import MapKit
import PugglePhotosKit

/// A place found by searching for it.
nonisolated struct FoundPlace: Hashable, Sendable, Identifiable {
    let name: String
    /// Where it is: its town, region and country.
    let detail: String
    let place: GeoPoint

    var id: String { "\(name)|\(place.latitude),\(place.longitude)" }
}

/// Names places and finds them by name, for Get Info.
protocol PlaceLookup: AnyObject {
    /// "2nd Street District, Austin, Texas, United States", or nil if it can't be said.
    func name(of place: GeoPoint) async -> String?
    /// Places these words name, the nearest to `near` first.
    func search(_ words: String, near: GeoPoint?) async -> [FoundPlace]
}

/// Asks macOS's map service, which is sent the place or the words to look up.
final class MapPlaceLookup: PlaceLookup {
    private var names: [GeoPoint: String] = [:]

    func name(of place: GeoPoint) async -> String? {
        if let name = names[place] { return name }
        let geocoder = CLGeocoder()
        let name: String? = await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(CLLocation(latitude: place.latitude, longitude: place.longitude)) { @Sendable placemarks, _ in
                let mark = placemarks?.first
                continuation.resume(returning: PlaceName.words([mark?.areasOfInterest?.first, mark?.subLocality, mark?.locality,
                                                                mark?.administrativeArea, mark?.country]))
            }
        }
        if let name { names[place] = name }
        return name
    }

    func search(_ words: String, near: GeoPoint?) async -> [FoundPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = words
        if let near {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                                                latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        }
        let search = MKLocalSearch(request: request)
        return await withCheckedContinuation { continuation in
            search.start { @Sendable response, _ in
                let places = (response?.mapItems ?? []).prefix(8).map { item in
                    let mark = item.placemark
                    return FoundPlace(name: item.name ?? mark.name ?? "", detail: PlaceName.words([mark.locality, mark.administrativeArea, mark.country]) ?? "",
                                      place: GeoPoint(latitude: mark.coordinate.latitude, longitude: mark.coordinate.longitude))
                }
                continuation.resume(returning: Array(places))
            }
        }
    }
}

#if DEBUG
/// Stands in for the map service on the sample library, for the self-test and screenshots: it knows the sample
/// family's places, and nothing leaves the Mac.
final class SamplePlaceLookup: PlaceLookup {
    static let places = [
        FoundPlace(name: "Pioneer Courthouse Square", detail: "Portland, Oregon, United States", place: GeoPoint(latitude: 45.5189, longitude: -122.6793)),
        FoundPlace(name: "Trillium Lake", detail: "Government Camp, Oregon, United States", place: GeoPoint(latitude: 45.2700, longitude: -121.7376)),
        FoundPlace(name: "Cannon Beach", detail: "Oregon, United States", place: GeoPoint(latitude: 45.8918, longitude: -123.9615)),
        FoundPlace(name: "Mount Hood Meadows", detail: "Oregon, United States", place: GeoPoint(latitude: 45.3317, longitude: -121.6650)),
        FoundPlace(name: "Multnomah Falls", detail: "Oregon, United States", place: GeoPoint(latitude: 45.5762, longitude: -122.1158)),
        FoundPlace(name: "Pike Place Market", detail: "Seattle, Washington, United States", place: GeoPoint(latitude: 47.6097, longitude: -122.3425)),
    ]

    /// The sample place within a few kilometres, named.
    func name(of place: GeoPoint) async -> String? {
        let nearest = Self.places.min { Self.distance($0.place, place) < Self.distance($1.place, place) }
        guard let nearest, Self.distance(nearest.place, place) < 0.05 else { return nil }
        return PlaceName.words([nearest.name, nearest.detail])
    }

    func search(_ words: String, near: GeoPoint?) async -> [FoundPlace] {
        let words = words.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return [] }
        return Self.places.filter { $0.name.localizedCaseInsensitiveContains(words) || $0.detail.localizedCaseInsensitiveContains(words) }
    }

    private static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double { hypot(a.latitude - b.latitude, a.longitude - b.longitude) }
}
#endif
