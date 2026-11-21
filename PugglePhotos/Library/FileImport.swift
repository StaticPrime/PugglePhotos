import AVFoundation
import Foundation
import ImageIO
import PugglePhotosKit
import UniformTypeIdentifiers

/// A photo or video file on its way into the library: what it is, and when it was taken.
nonisolated struct ImportFile: Sendable {
    let url: URL
    /// `.photo` or `.video`.
    let kind: MediaKind
    /// When it was taken: what the file itself says, or failing that, the earliest date it has on disk.
    let date: Date
    /// Whether the date came from inside the file, where the Photos library reads it for itself.
    let dateIsInFile: Bool
    /// How big it is, in pixels, the way up it's shown.
    let pixelSize: CGSize
    /// How long a video runs.
    let duration: TimeInterval

    var name: String { url.lastPathComponent }
}

/// What a drop held, once read: the photos and videos to add, and the names of files that looked like photos or
/// videos but couldn't be read.
nonisolated struct DroppedFiles: Sendable {
    var files: [ImportFile] = []
    var unreadable: [String] = []
}

/// Photos and videos dropped on PugglePhotos from elsewhere. Only images macOS can read and movies it can play are
/// taken; folders are searched all the way down.
nonisolated enum FileImport {
    /// Whether a file is a photo or a video the library can take, and which.
    static func kind(of url: URL) -> MediaKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return type.flatMap(kind(of:))
    }

    static func kind(of type: UTType) -> MediaKind? {
        if type.conforms(to: .movie) { return movieTypes.contains(type.identifier) ? .video : nil }
        if type.conforms(to: .image) { return imageTypes.contains(type.identifier) ? .photo : nil }
        return nil
    }

    /// The image formats macOS reads, and the movie formats it plays.
    private static let imageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    private static let movieTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    /// A folder to look in (not a package, like an app, that only looks like a file).
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Whether a folder holds a photo or video anywhere inside, looking at no more than `limit` things, so a drag
    /// over the window stays quick.
    static func folderHasMedia(_ folder: URL, limit: Int = 2000) -> Bool {
        guard let walker = walk(folder) else { return false }
        var looked = 0
        while looked < limit, let next = walker.nextObject() as? URL {
            looked += 1
            if !isFolder(next), kind(of: next) != nil { return true }
        }
        return false
    }

    /// The photos and videos among some files and folders, folders searched all the way down (in name order),
    /// each file once.
    static func media(in dropped: [URL]) -> [URL] {
        var found: [URL] = []
        var seen: Set<URL> = []
        for url in dropped {
            var files = [url]
            if isFolder(url) {
                files = []
                if let walker = walk(url) {
                    while let next = walker.nextObject() as? URL {
                        if !isFolder(next) { files.append(next) }
                    }
                }
                files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
            for file in files where kind(of: file) != nil && seen.insert(file.standardizedFileURL).inserted {
                found.append(file)
            }
        }
        return found
    }

    private static func walk(_ folder: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
    }

    /// Reads what each photo and video is, how big, and when it was taken. Slow for many files, so it runs off the
    /// main thread.
    @concurrent static func read(_ dropped: [URL]) async -> DroppedFiles {
        var result = DroppedFiles()
        for url in media(in: dropped) {
            let file = kind(of: url) == .video ? await video(url) : photo(url)
            if let file { result.files.append(file) } else { result.unreadable.append(url.lastPathComponent) }
        }
        return result
    }

    private static func photo(_ url: URL) -> ImportFile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // Orientations 5 to 8 turn the picture on its side.
        let sideways = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        let inFile = dateInImage(properties)
        return ImportFile(url: url, kind: .photo, date: inFile ?? diskDate(url), dateIsInFile: inFile != nil,
                          pixelSize: sideways ? CGSize(width: height, height: width) : CGSize(width: width, height: height), duration: 0)
    }

    private static func video(_ url: URL) async -> ImportFile? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let shown = size.applying(transform)
        var inFile: Date?
        if let item = try? await asset.load(.creationDate) { inFile = try? await item.load(.dateValue) }
        return ImportFile(url: url, kind: .video, date: inFile ?? diskDate(url), dateIsInFile: inFile != nil,
                          pixelSize: CGSize(width: abs(shown.width), height: abs(shown.height)), duration: duration.seconds)
    }

    /// When a photo was taken, as its camera wrote it down: the moment it was taken, else digitized, else saved.
    static func dateInImage(_ properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates: [(Any?, Any?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifOffsetTimeOriginal]),
            (exif[kCGImagePropertyExifDateTimeDigitized], exif[kCGImagePropertyExifOffsetTimeDigitized]),
            (tiff[kCGImagePropertyTIFFDateTime], exif[kCGImagePropertyExifOffsetTime]),
        ]
        for (text, offset) in candidates {
            if let text = text as? String, let date = cameraDate(text, offset: offset as? String) { return date }
        }
        return nil
    }

    /// A camera's "2021:06:12 15:30:00", in the time zone its offset ("+02:00") gives, or else this Mac's.
    static func cameraDate(_ text: String, offset: String?) -> Date? {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 6, numbers[0] > 1800, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offset.flatMap(timeZone(offset:)) ?? .current
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2],
                                                  hour: numbers[3], minute: numbers[4], second: numbers[5]))
    }

    static func timeZone(offset text: String) -> TimeZone? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-")).split(separator: ":").compactMap { Int($0) }
        let minutes = parts.count > 1 ? parts[1] : 0
        guard let hours = parts.first, (0...14).contains(hours), (0..<60).contains(minutes) else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return TimeZone(secondsFromGMT: text.hasPrefix("-") ? -seconds : seconds)
    }

    /// The earliest date a file has on disk: when it was made, or last changed if that's earlier (copying a file
    /// makes it anew but keeps when it was changed).
    static func diskDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min() ?? Date()
    }

    /// Whether a photo in the library looks like a file: the same name, the same size (or length, for a video),
    /// taken at the same moment, or at the same time of day read in another time zone.
    static func matches(_ item: MediaItem, _ file: ImportFile) -> Bool {
        guard item.kind.isVideo == file.kind.isVideo, item.fileName?.lowercased() == file.name.lowercased() else { return false }
        if file.kind.isVideo {
            guard abs(item.duration - file.duration) < 0.5 else { return false }
        } else {
            let width = Int(file.pixelSize.width.rounded()), height = Int(file.pixelSize.height.rounded())
            guard (item.pixelWidth == width && item.pixelHeight == height) || (item.pixelWidth == height && item.pixelHeight == width) else { return false }
        }
        let apart = abs(item.date.timeIntervalSince(file.date))
        let offZone = apart.truncatingRemainder(dividingBy: 900)
        return apart < 2 || (apart <= 14 * 3600 + 2 && (offZone < 2 || offZone > 898))
    }

    /// "Photo", "3 Photos", "Video", "2 Videos", "5 Photos and Videos": how a menu names what was added.
    static func countTitle(_ files: [ImportFile]) -> String {
        let videos = files.filter(\.kind.isVideo).count, photos = files.count - videos
        switch (photos, videos) {
        case (1, 0): return "Photo"
        case (_, 0): return "\(photos) Photos"
        case (0, 1): return "Video"
        case (0, _): return "\(videos) Videos"
        default: return "\(files.count) Photos and Videos"
        }
    }

    /// "photos", "videos" or "photos and videos", for sentences about several.
    static func plural(_ files: [ImportFile]) -> String {
        let videos = files.filter(\.kind.isVideo).count
        return videos == 0 ? "photos" : videos == files.count ? "videos" : "photos and videos"
    }
}
