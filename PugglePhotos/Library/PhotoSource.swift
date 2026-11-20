import AppKit
import AVFoundation
import ImageIO
import PugglePhotosKit

/// Whether PugglePhotos may see the Photos library.
enum LibraryAccess: Equatable {
    case notDetermined, authorized, denied, restricted
}

/// Everything loaded from the library in one go.
nonisolated struct LibraryContents: Sendable {
    var items: [MediaItem]
    /// Recently added items, oldest first, when the library keeps that list itself.
    var recentlyAdded: [PhotoID]
    /// The library's own albums (the ones people make), which PugglePhotos' albums mirror.
    var albums: [LibraryAlbum]
}

/// An image on its way. Cancel it when the view that wanted it moves on.
final class ImageRequest {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// What adding files to the library came to: the photos and videos made, in the files' order, and the files it
/// wouldn't take, with why.
nonisolated struct AddedFiles: Sendable {
    nonisolated struct Refusal: Sendable {
        var name: String
        var reason: String
    }

    var ids: [PhotoID] = []
    var refused: [Refusal] = []
}

/// An immutable image that can cross threads.
nonisolated struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

nonisolated enum LibraryError: LocalizedError {
    case notAllowed
    case missing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed: "PugglePhotos doesn’t have permission to change your Photos library."
        case .missing: "Some of the photos are no longer in your Photos library."
        case let .failed(reason): reason
        }
    }
}

/// Where photos come from: the Photos library, or the sample library used by the self-test and screenshots.
/// Every callback arrives on the main thread.
protocol PhotoSource: AnyObject {
    var access: LibraryAccess { get }
    /// Asks the person for permission when they haven't been asked yet.
    func requestAccess(_ completion: @escaping @MainActor (LibraryAccess) -> Void)
    /// Reads every photo and video.
    func load(_ completion: @escaping @MainActor (LibraryContents) -> Void)
    /// Called when the library changes outside PugglePhotos (or after PugglePhotos changes it).
    var onChange: (() -> Void)? { get set }

    /// An image at least `pixels` big. Thumbnails crop to fill the square; `fit` asks for the whole picture.
    /// The completion may run twice: a quick low-quality image first, then the final one.
    @discardableResult
    func requestImage(_ id: PhotoID, pixels: CGSize, fit: Bool,
                      completion: @escaping @MainActor (CGImage?, _ isFinal: Bool) -> Void) -> ImageRequest?
    /// Starts getting square thumbnails `pixels` big ready for some photos before they're asked for, and stops for
    /// others no longer near the screen.
    func prefetchThumbnails(start: [PhotoID], stop: [PhotoID], pixels: CGSize)
    /// Stops getting any thumbnails ready ahead.
    func stopPrefetching()
    /// Something to play, for a video.
    func requestPlayerItem(_ id: PhotoID, completion: @escaping @MainActor (AVPlayerItem?) -> Void)
    /// Original file names, which take a while to read for a big library.
    func loadFileNames(_ ids: [PhotoID], completion: @escaping @MainActor ([PhotoID: String]) -> Void)

    /// Changes when photos were taken, all in one change to the library.
    func setDates(_ changes: [Redate.Change], completion: @escaping @MainActor (Error?) -> Void)
    /// Marks photos as favorites, or not, all in one change to the library.
    func setFavorite(_ ids: [PhotoID], _ favorite: Bool, completion: @escaping @MainActor (Error?) -> Void)
    /// Changes where photos were taken (or says they were taken nowhere), all in one change to the library.
    func setPlaces(_ changes: [PlaceChange], completion: @escaping @MainActor (Error?) -> Void)
    /// Copies photo and video files into the library (the files stay where they are). `progress` hears how many
    /// files are done as it goes.
    func addFiles(_ files: [ImportFile], progress: @escaping @MainActor @Sendable (Int) -> Void,
                  completion: @escaping @MainActor (AddedFiles) -> Void)
    /// Deletes photos from the library, all in one change (macOS asks the person first; they go to Recently
    /// Deleted). Only for taking out photos PugglePhotos added, when that's undone.
    func deleteItems(_ ids: [PhotoID], completion: @escaping @MainActor (Error?) -> Void)

    /// Makes an album in the library holding these photos, and answers with its identifier.
    func createAlbum(title: String, items: [PhotoID], completion: @escaping @MainActor (Result<String, Error>) -> Void)
    /// Makes a library album match: this title, exactly these photos, in this order. One change to the library.
    func updateAlbum(_ id: String, title: String, items: [PhotoID], completion: @escaping @MainActor (Error?) -> Void)
    /// Deletes a library album. The photos in it stay in the library.
    func deleteAlbum(_ id: String, completion: @escaping @MainActor (Error?) -> Void)

    /// A photo's or video's original file as it is now (with any edits made to it), at full size, written to a
    /// temporary file for sharing; nil if it can't be had.
    func exportOriginal(_ id: PhotoID, completion: @escaping @MainActor (URL?) -> Void)
    /// How big each of these photos' and videos' files is as `exportOriginal` writes it, in bytes; those whose size
    /// isn't known are left out.
    func originalSizes(_ ids: [PhotoID]) async -> [PhotoID: Int64]
    /// What a photo's or video's file says about how it was taken, with its size and format; nil if it can't be
    /// read. May fetch the file from iCloud.
    func metadata(_ id: PhotoID) async -> PhotoMetadata?
}

extension PhotoSource {
    /// Sources that make pictures quickly don't need to work ahead.
    func prefetchThumbnails(start: [PhotoID], stop: [PhotoID], pixels: CGSize) {}
    func stopPrefetching() {}
    func originalSizes(_ ids: [PhotoID]) async -> [PhotoID: Int64] { [:] }
    func metadata(_ id: PhotoID) async -> PhotoMetadata? { nil }

    /// What an image file says about how it was taken; nil if it isn't an image ImageIO reads.
    @concurrent nonisolated static func imageMetadata(at url: URL, format: String? = nil) async -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        return PhotoMetadata(imageProperties: properties, fileSize: size, format: format ?? url.pathExtension.uppercased())
    }
}

/// Where a photo was taken, changed: nil for nowhere.
nonisolated struct PlaceChange: Hashable, Sendable {
    let id: PhotoID
    let from: GeoPoint?
    let to: GeoPoint?

    /// The changes that put them back.
    static func reversed(_ changes: [PlaceChange]) -> [PlaceChange] { changes.map { PlaceChange(id: $0.id, from: $0.to, to: $0.from) } }
}
