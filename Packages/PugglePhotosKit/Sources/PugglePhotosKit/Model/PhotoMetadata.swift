import Foundation
import ImageIO

/// What a photo's or video's file says about how it was taken, and its size and format, as Get Info shows them. It's
/// read from the file and never written: the camera and its settings were what they were.
public struct PhotoMetadata: Hashable, Sendable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Int?
    /// Millimetres.
    public var focalLength: Double?
    public var aperture: Double?
    /// Seconds.
    public var exposureTime: Double?
    /// Stops.
    public var exposureBias: Double?
    /// Bytes.
    public var fileSize: Int64?
    /// The kind of file, as its extension says it: "HEIC", "JPEG", "MOV".
    public var format: String?
    /// Frames a second, for a video.
    public var frameRate: Double?

    public init(make: String? = nil, model: String? = nil, lens: String? = nil, iso: Int? = nil, focalLength: Double? = nil,
                aperture: Double? = nil, exposureTime: Double? = nil, exposureBias: Double? = nil, fileSize: Int64? = nil,
                format: String? = nil, frameRate: Double? = nil) {
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.focalLength = focalLength
        self.aperture = aperture
        self.exposureTime = exposureTime
        self.exposureBias = exposureBias
        self.fileSize = fileSize
        self.format = format
        self.frameRate = frameRate
    }

    /// From an image file's properties, as ImageIO reads them.
    public init(imageProperties properties: [String: Any], fileSize: Int64? = nil, format: String? = nil) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        // A setting written as a fraction over nothing reads as no setting.
        func number(_ key: CFString) -> Double? { (exif[key as String] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        self.init(make: Self.words(tiff[kCGImagePropertyTIFFMake as String]), model: Self.words(tiff[kCGImagePropertyTIFFModel as String]),
                  lens: Self.words(exif[kCGImagePropertyExifLensModel as String]) ?? Self.words(aux[kCGImagePropertyExifAuxLensModel as String]),
                  iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue,
                  focalLength: number(kCGImagePropertyExifFocalLength), aperture: number(kCGImagePropertyExifFNumber),
                  exposureTime: number(kCGImagePropertyExifExposureTime), exposureBias: number(kCGImagePropertyExifExposureBiasValue),
                  fileSize: fileSize, format: format)
    }

    private static func words(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !text.isEmpty else { return nil }
        return text
    }

    /// The camera, its maker named once: a model that already starts with its maker's name stands alone.
    public var camera: String? {
        guard let model else { return make }
        guard let make, let first = make.split(separator: " ").first,
              !model.lowercased().hasPrefix(first.lowercased()) else { return model }
        return "\(make) \(model)"
    }

    /// Whether the file says anything about the camera or how it was set.
    public var hasCamera: Bool { camera != nil || lens != nil || !settings.isEmpty }

    /// How the camera was set, in the words cameras use: "ISO 100", "26 mm", "0 ev", "ƒ1.8", "1/120 s".
    public var settings: [String] {
        var settings: [String] = []
        if let iso { settings.append("ISO \(iso)") }
        if let focalLength { settings.append(Self.millimetres(focalLength)) }
        if let exposureBias { settings.append(Self.stops(exposureBias)) }
        if let aperture { settings.append("ƒ" + Self.decimal(aperture)) }
        if let exposureTime { settings.append(Self.shutter(exposureTime)) }
        return settings
    }

    /// Millions of pixels: "12 MP", "0.4 MP".
    public static func megapixels(width: Int, height: Int) -> String {
        let millions = Double(width) * Double(height) / 1_000_000
        return (millions >= 10 ? decimal(millions.rounded()) : decimal((millions * 10).rounded() / 10)) + " MP"
    }

    static func millimetres(_ length: Double) -> String { (length < 10 ? decimal((length * 10).rounded() / 10) : decimal(length.rounded())) + " mm" }

    static func stops(_ bias: Double) -> String {
        let rounded = (bias * 10).rounded() / 10
        if rounded == 0 { return "0 ev" }
        return (rounded > 0 ? "+" : "−") + decimal(abs(rounded)) + " ev"
    }

    /// "1/120 s" under a second, "2 s" or "1.5 s" over.
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0 s" }
        if seconds >= 1 { return decimal((seconds * 10).rounded() / 10) + " s" }
        return "1/" + decimal((1 / seconds).rounded()) + " s"
    }

    /// "1.8", and "8" rather than "8.0". A number too big to be a whole one is still written, never stops the app.
    static func decimal(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// A video's frames a second, "30 fps", if it says a rate that's a rate.
    public var frameRateText: String? {
        frameRate.flatMap { $0.isFinite && $0 > 0 ? Self.decimal($0.rounded()) + " fps" : nil }
    }
}

/// A place in words.
public enum PlaceName {
    /// The parts of a place's name joined, the most particular first, each said once: "2nd Street District, Austin,
    /// Texas, United States". Nil when there's nothing to say.
    public static func words(_ parts: [String?]) -> String? {
        var said: [String] = []
        for part in parts {
            guard let part = part?.trimmingCharacters(in: .whitespaces), !part.isEmpty,
                  !said.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else { continue }
            said.append(part)
        }
        return said.isEmpty ? nil : said.joined(separator: ", ")
    }

    /// A place by its coordinates: "45.5231° N, 122.6765° W".
    public static func coordinates(_ place: GeoPoint) -> String {
        String(format: "%.4f° %@, %.4f° %@", abs(place.latitude), place.latitude < 0 ? "S" : "N",
               abs(place.longitude), place.longitude < 0 ? "W" : "E")
    }
}
