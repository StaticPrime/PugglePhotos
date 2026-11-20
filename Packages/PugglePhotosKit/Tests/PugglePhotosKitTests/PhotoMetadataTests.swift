import Foundation
import ImageIO
import Testing
@testable import PugglePhotosKit

@Suite struct PhotoMetadataTests {
    @Test func aPhotosFileSaysHowItWasTaken() {
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Puggle",
                                                       kCGImagePropertyTIFFModel as String: "Puggle Pocket 3\u{0}"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [NSNumber(value: 100)],
                                                       kCGImagePropertyExifFocalLength as String: NSNumber(value: 6.86),
                                                       kCGImagePropertyExifFNumber as String: NSNumber(value: 1.8),
                                                       kCGImagePropertyExifExposureTime as String: NSNumber(value: 1.0 / 121),
                                                       kCGImagePropertyExifExposureBiasValue as String: NSNumber(value: 0),
                                                       kCGImagePropertyExifLensModel as String: "Pocket back camera 6.86mm f/1.8"],
        ]
        let metadata = PhotoMetadata(imageProperties: properties, fileSize: 2_400_000, format: "HEIC")
        #expect(metadata.camera == "Puggle Pocket 3", "the maker said once, and stray characters dropped")
        #expect(metadata.lens == "Pocket back camera 6.86mm f/1.8")
        #expect(metadata.settings == ["ISO 100", "6.9 mm", "0 ev", "ƒ1.8", "1/121 s"])
        #expect(metadata.hasCamera && metadata.fileSize == 2_400_000 && metadata.format == "HEIC")
    }

    @Test func aFileThatSaysNothingSaysNothing() {
        let metadata = PhotoMetadata(imageProperties: [:], format: "PNG")
        #expect(metadata.camera == nil && metadata.lens == nil && metadata.settings.isEmpty && !metadata.hasCamera)
    }

    @Test func settingsAreWrittenAsCamerasWriteThem() {
        #expect(PhotoMetadata(make: "Puggle", model: "Field 7").camera == "Puggle Field 7")
        #expect(PhotoMetadata(make: "PUGGLE CORPORATION", model: "PUGGLE Z 6").camera == "PUGGLE Z 6")
        #expect(PhotoMetadata(make: "Puggle").camera == "Puggle")
        #expect(PhotoMetadata.shutter(2) == "2 s" && PhotoMetadata.shutter(1.5) == "1.5 s" && PhotoMetadata.shutter(0.004) == "1/250 s")
        #expect(PhotoMetadata.stops(0.67) == "+0.7 ev" && PhotoMetadata.stops(-1) == "−1 ev" && PhotoMetadata.stops(0.01) == "0 ev")
        #expect(PhotoMetadata.millimetres(26) == "26 mm" && PhotoMetadata.millimetres(6.86) == "6.9 mm")
        #expect(PhotoMetadata(aperture: 8).settings == ["ƒ8"])
        #expect(PhotoMetadata.megapixels(width: 4032, height: 3024) == "12 MP")
        #expect(PhotoMetadata.megapixels(width: 740, height: 493) == "0.4 MP")
    }

    @Test func placesAreNamedMostParticularFirstAndOnce() {
        #expect(PlaceName.words(["2nd Street District", "Austin", "Texas", "United States"]) == "2nd Street District, Austin, Texas, United States")
        #expect(PlaceName.words(["Portland", nil, " ", "portland", "Oregon"]) == "Portland, Oregon")
        #expect(PlaceName.words([nil, ""]) == nil)
        #expect(PlaceName.coordinates(GeoPoint(latitude: 45.52312, longitude: -122.67652)) == "45.5231° N, 122.6765° W")
        #expect(PlaceName.coordinates(GeoPoint(latitude: -33.86, longitude: 151.21)) == "33.8600° S, 151.2100° E")
    }
}
