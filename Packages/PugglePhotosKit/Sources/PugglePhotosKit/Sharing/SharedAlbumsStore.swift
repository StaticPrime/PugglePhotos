import Foundation

/// Keeps the shared albums, yours and those shared with you: `Shared Albums.json` in a folder, with the pictures of the
/// albums shared with you beside it, in `Pictures/<album>/`. Your own albums' pictures are the ones in your library.
public struct SharedAlbumsStore: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public var fileURL: URL { folder.appendingPathComponent("Shared Albums.json") }
    public var picturesFolder: URL { folder.appendingPathComponent("Pictures", isDirectory: true) }

    private struct File: Codable {
        var version: Int
        var albums: [SharedAlbum]
    }

    /// The shared albums saved, or none the first time. A file that can't be read gives none too: everything in it
    /// comes back from iCloud.
    public func load() -> [SharedAlbum] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode(File.self, from: data))?.albums ?? []
    }

    public func save(_ albums: [SharedAlbum]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(File(version: 1, albums: albums)).write(to: fileURL, options: .atomic)
    }

    /// Where the picture of a photo or video in an album shared with you is kept, named after it, with its original
    /// file's extension (or a movie's or a picture's when that isn't known).
    public func pictureURL(album: UUID, item: SharedItem) -> URL {
        let original = (item.fileName as NSString?)?.pathExtension.lowercased() ?? ""
        let ext = original.isEmpty ? (item.kind.isVideo ? "mov" : "jpg") : original
        return picturesFolder.appendingPathComponent(album.uuidString, isDirectory: true)
            .appendingPathComponent(item.id.uuidString).appendingPathExtension(ext)
    }

    /// Lets go of an album's pictures: it's no longer shared with you.
    public func removePictures(of album: UUID) {
        try? FileManager.default.removeItem(at: picturesFolder.appendingPathComponent(album.uuidString, isDirectory: true))
    }

    /// Lets go of the pictures of photos no longer in an album.
    public func removePictures(of album: UUID, keeping items: [SharedItem]) {
        let folder = picturesFolder.appendingPathComponent(album.uuidString, isDirectory: true)
        let kept = Set(items.map { pictureURL(album: album, item: $0).lastPathComponent })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Dates as exact numbers: to a fraction of a second, so an album read back is just as it was saved.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
