import AppKit
import AVFoundation
import Photos
import PugglePhotosKit

/// The Photos library on this Mac, through PhotoKit. PugglePhotos reads it, and writes only two things, both when
/// the person asks: when photos were taken, and whether they're favorites.
final class SystemPhotoSource: NSObject, PhotoSource, PHPhotoLibraryChangeObserver {
    private let manager = PHCachingImageManager()
    private var assets: [PhotoID: PHAsset] = [:]
    private var observing = false
    var onChange: (() -> Void)?

    var access: LibraryAccess { Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    nonisolated static func access(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized, .limited: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestAccess(_ completion: @escaping @MainActor (LibraryAccess) -> Void) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            completion(Self.access(status))
        }
    }

    func load(_ completion: @escaping @MainActor (LibraryContents) -> Void) {
        if !observing, access == .authorized {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        Task {
            let loaded = await Self.read()
            assets = loaded.assets
            completion(loaded.contents)
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.onChange?() }
    }

    // MARK: Reading

    private nonisolated struct Loaded: Sendable {
        var contents: LibraryContents
        var assets: [PhotoID: PHAsset]
    }

    /// Reads every photo and video, the recently added list and the albums, off the main thread.
    @concurrent private nonisolated static func read() async -> Loaded {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var items: [MediaItem] = []
        var assets: [PhotoID: PHAsset] = [:]
        items.reserveCapacity(result.count)
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard let item = mediaItem(asset) else { return }
            items.append(item)
            assets[item.id] = asset
        }

        var recent: [PhotoID] = []
        if let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRecentlyAdded,
                                                                    options: nil).firstObject {
            let added = PHAsset.fetchAssets(in: collection, options: nil)
            added.enumerateObjects { asset, _, _ in recent.append(PhotoID(asset.localIdentifier)) }
        }

        var albums: [ExternalAlbum] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            var ids: [PhotoID] = []
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                ids.append(PhotoID(asset.localIdentifier))
            }
            albums.append(ExternalAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled", items: ids))
        }
        albums.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Loaded(contents: LibraryContents(items: items, recentlyAdded: recent, albums: albums), assets: assets)
    }

    private nonisolated static func mediaItem(_ asset: PHAsset) -> MediaItem? {
        let kind: MediaKind
        switch asset.mediaType {
        case .video: kind = .video
        case .image:
            if asset.mediaSubtypes.contains(.photoLive) { kind = .livePhoto }
            else if asset.mediaSubtypes.contains(.photoScreenshot) { kind = .screenshot }
            else if asset.mediaSubtypes.contains(.photoPanorama) { kind = .panorama }
            else { kind = .photo }
        default: return nil
        }
        var added: Date?
        if #available(macOS 26, *) { added = asset.addedDate }
        let location = asset.location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        return MediaItem(id: PhotoID(asset.localIdentifier), kind: kind,
                         date: asset.creationDate ?? added ?? asset.modificationDate ?? Date(timeIntervalSince1970: 0),
                         addedDate: added, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                         duration: asset.duration, isFavorite: asset.isFavorite, location: location)
    }

    func loadFileNames(_ ids: [PhotoID], completion: @escaping @MainActor ([PhotoID: String]) -> Void) {
        let wanted = ids.compactMap { id in assets[id].map { (id, $0) } }
        Task {
            let names = await Self.fileNames(wanted)
            completion(names)
        }
    }

    @concurrent private nonisolated static func fileNames(_ assets: [(PhotoID, PHAsset)]) async -> [PhotoID: String] {
        var names: [PhotoID: String] = [:]
        for (id, asset) in assets {
            if let name = PHAssetResource.assetResources(for: asset).first?.originalFilename { names[id] = name }
        }
        return names
    }

    // MARK: Images and videos

    @discardableResult
    func requestImage(_ id: PhotoID, pixels: CGSize, fit: Bool,
                      completion: @escaping @MainActor (CGImage?, Bool) -> Void) -> ImageRequest? {
        guard let asset = assets[id] else {
            completion(nil, true)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = fit ? .exact : .fast
        options.isNetworkAccessAllowed = true
        let requestID = manager.requestImage(for: asset, targetSize: pixels, contentMode: fit ? .aspectFit : .aspectFill,
                                             options: options) { @Sendable image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled else { return }
            let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(SendableImage.init)
            Task { @MainActor in completion(cgImage?.cgImage, !degraded) }
        }
        let manager = manager
        return ImageRequest { manager.cancelImageRequest(requestID) }
    }

    func requestPlayerItem(_ id: PhotoID, completion: @escaping @MainActor (AVPlayerItem?) -> Void) {
        guard let asset = assets[id], asset.mediaType == .video else {
            completion(nil)
            return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        manager.requestAVAsset(forVideo: asset, options: options) { @Sendable video, _, _ in
            let box = video.map(SendableAsset.init)
            Task { @MainActor in completion(box.map { AVPlayerItem(asset: $0.asset) }) }
        }
    }

    private nonisolated struct SendableAsset: @unchecked Sendable { let asset: AVAsset }

    // MARK: Changes

    func setDates(_ changes: [Redate.Change], completion: @escaping @MainActor (Error?) -> Void) {
        let targets = changes.compactMap { change in assets[change.id].map { DateTarget(asset: $0, date: change.to) } }
        guard targets.count == changes.count else {
            completion(LibraryError.missing)
            return
        }
        perform({
            for target in targets { PHAssetChangeRequest(for: target.asset).creationDate = target.date }
        }, completion: completion)
    }

    func setFavorite(_ ids: [PhotoID], _ favorite: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        let targets = ids.compactMap { assets[$0] }
        guard targets.count == ids.count else {
            completion(LibraryError.missing)
            return
        }
        perform({
            for asset in targets { PHAssetChangeRequest(for: asset).isFavorite = favorite }
        }, completion: completion)
    }

    private nonisolated struct DateTarget: Sendable {
        let asset: PHAsset
        let date: Date
    }

    /// One change block for the whole batch, so macOS asks the person at most once.
    private func perform(_ changes: @escaping @Sendable () -> Void, completion: @escaping @MainActor (Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges(changes) { @Sendable success, error in
            Task { @MainActor in
                if success {
                    completion(nil)
                } else {
                    completion(error.map { LibraryError.failed($0.localizedDescription) } ?? LibraryError.notAllowed)
                }
            }
        }
    }
}
