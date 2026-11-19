import AppKit
import AVFoundation
import ImageIO
import PugglePhotosKit
import UniformTypeIdentifiers

/// The library's pictures, and those of the albums shared with you, which are files kept beside the shared albums.
/// Everything to do with the library itself goes to the library; a photo shared with you is only ever looked at.
final class SharedPicturesSource: PhotoSource {
    let base: PhotoSource
    /// Where a photo shared with you is kept, if it's there.
    var pictureURL: (PhotoID) -> URL? = { _ in nil }

    init(base: PhotoSource) { self.base = base }

    var access: LibraryAccess { base.access }
    func requestAccess(_ completion: @escaping @MainActor (LibraryAccess) -> Void) { base.requestAccess(completion) }
    func load(_ completion: @escaping @MainActor (LibraryContents) -> Void) { base.load(completion) }

    var onChange: (() -> Void)? {
        get { base.onChange }
        set { base.onChange = newValue }
    }

    @discardableResult
    func requestImage(_ id: PhotoID, pixels: CGSize, fit: Bool,
                      completion: @escaping @MainActor (CGImage?, _ isFinal: Bool) -> Void) -> ImageRequest? {
        guard SharedAlbum.isShared(id) else { return base.requestImage(id, pixels: pixels, fit: fit, completion: completion) }
        guard let url = pictureURL(id) else {
            DispatchQueue.main.async { completion(nil, true) }
            return nil
        }
        let task = Task {
            let picture = await Self.picture(url, pixels: max(pixels.width, pixels.height), fit: fit)
            guard !Task.isCancelled else { return }
            completion(picture?.cgImage, true)
        }
        return ImageRequest { task.cancel() }
    }

    /// A picture from a file, at least `pixels` along the side that matters: its longer side to fit it whole, its
    /// shorter to crop it to a square that fills. A movie gives its first frame.
    @concurrent private nonisolated static func picture(_ url: URL, pixels: CGFloat, fit: Bool) async -> SendableImage? {
        var image: CGImage?
        let isMovie = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        if !isMovie, let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? pixels
            let height = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? pixels
            let longest = fit ? pixels : pixels * max(width, height) / max(1, min(width, height))
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: max(1, longest)] as CFDictionary)
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels * 2, height: pixels * 2)
            image = try? await generator.image(at: .zero).image
        }
        guard let image else { return nil }
        guard !fit else { return SendableImage(cgImage: image) }
        // Cropped to the square in its middle.
        let side = min(image.width, image.height)
        let square = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return SendableImage(cgImage: image.cropping(to: square) ?? image)
    }

    func prefetchThumbnails(start: [PhotoID], stop: [PhotoID], pixels: CGSize) {
        base.prefetchThumbnails(start: start.filter { !SharedAlbum.isShared($0) }, stop: stop.filter { !SharedAlbum.isShared($0) }, pixels: pixels)
    }

    func stopPrefetching() { base.stopPrefetching() }

    func requestPlayerItem(_ id: PhotoID, completion: @escaping @MainActor (AVPlayerItem?) -> Void) {
        guard SharedAlbum.isShared(id) else { return base.requestPlayerItem(id, completion: completion) }
        completion(pictureURL(id).map { AVPlayerItem(url: $0) })
    }

    func loadFileNames(_ ids: [PhotoID], completion: @escaping @MainActor ([PhotoID: String]) -> Void) {
        base.loadFileNames(ids.filter { !SharedAlbum.isShared($0) }, completion: completion)
    }

    // Changes are to the library: a photo shared with you never goes to it.

    func setDates(_ changes: [Redate.Change], completion: @escaping @MainActor (Error?) -> Void) {
        base.setDates(changes.filter { !SharedAlbum.isShared($0.id) }, completion: completion)
    }

    func setFavorite(_ ids: [PhotoID], _ favorite: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        base.setFavorite(ids.filter { !SharedAlbum.isShared($0) }, favorite, completion: completion)
    }

    func addFiles(_ files: [ImportFile], progress: @escaping @MainActor @Sendable (Int) -> Void,
                  completion: @escaping @MainActor (AddedFiles) -> Void) {
        base.addFiles(files, progress: progress, completion: completion)
    }

    func deleteItems(_ ids: [PhotoID], completion: @escaping @MainActor (Error?) -> Void) {
        base.deleteItems(ids.filter { !SharedAlbum.isShared($0) }, completion: completion)
    }

    func createAlbum(title: String, items: [PhotoID], completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        base.createAlbum(title: title, items: items.filter { !SharedAlbum.isShared($0) }, completion: completion)
    }

    func updateAlbum(_ id: String, title: String, items: [PhotoID], completion: @escaping @MainActor (Error?) -> Void) {
        base.updateAlbum(id, title: title, items: items.filter { !SharedAlbum.isShared($0) }, completion: completion)
    }

    func deleteAlbum(_ id: String, completion: @escaping @MainActor (Error?) -> Void) { base.deleteAlbum(id, completion: completion) }

    func exportOriginal(_ id: PhotoID, completion: @escaping @MainActor (URL?) -> Void) {
        guard !SharedAlbum.isShared(id) else { return completion(pictureURL(id)) }
        base.exportOriginal(id, completion: completion)
    }
}
