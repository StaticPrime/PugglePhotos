import AppKit
import AVFoundation
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
    /// Something to play, for a video.
    func requestPlayerItem(_ id: PhotoID, completion: @escaping @MainActor (AVPlayerItem?) -> Void)
    /// Original file names, which take a while to read for a big library.
    func loadFileNames(_ ids: [PhotoID], completion: @escaping @MainActor ([PhotoID: String]) -> Void)

    /// Changes when photos were taken, all in one change to the library.
    func setDates(_ changes: [Redate.Change], completion: @escaping @MainActor (Error?) -> Void)
    /// Marks photos as favorites, or not, all in one change to the library.
    func setFavorite(_ ids: [PhotoID], _ favorite: Bool, completion: @escaping @MainActor (Error?) -> Void)

    /// Makes an album in the library holding these photos, and answers with its identifier.
    func createAlbum(title: String, items: [PhotoID], completion: @escaping @MainActor (Result<String, Error>) -> Void)
    /// Makes a library album match: this title, exactly these photos, in this order. One change to the library.
    func updateAlbum(_ id: String, title: String, items: [PhotoID], completion: @escaping @MainActor (Error?) -> Void)
    /// Deletes a library album. The photos in it stay in the library.
    func deleteAlbum(_ id: String, completion: @escaping @MainActor (Error?) -> Void)
}
