import AppKit
import AVFoundation
import CoreLocation
import Photos
import PugglePhotosKit

/// The Photos library on this Mac, through PhotoKit. PugglePhotos reads it, and changes it only when the person
/// asks: when photos were taken, whether they're favorites, its albums, and photos and videos dragged in (which
/// Undo deletes again).
final class SystemPhotoSource: NSObject, PhotoSource, PHPhotoLibraryChangeObserver {
    private let manager = PHCachingImageManager()
    private var assets: [PhotoID: PHAsset] = [:]
    /// The Photos identifiers of every photo the library was last read to have. Changes to an album leave any other
    /// photo in it alone: one put in since, or any at all before the library has been read.
    private var known: Set<String> = []
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
            known = Set(loaded.assets.values.map(\.localIdentifier))
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

        var albums: [LibraryAlbum] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            var ids: [PhotoID] = []
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                ids.append(PhotoID(asset.localIdentifier))
            }
            albums.append(LibraryAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled", items: ids))
        }
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
        let requestID = manager.requestImage(for: asset, targetSize: pixels, contentMode: fit ? .aspectFit : .aspectFill,
                                             options: Self.imageOptions(fit: fit)) { @Sendable image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled else { return }
            let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(SendableImage.init)
            Task { @MainActor in completion(cgImage?.cgImage, !degraded) }
        }
        let manager = manager
        return ImageRequest { manager.cancelImageRequest(requestID) }
    }

    /// How images are asked for. Thumbnails got ready ahead must be asked for the same way to be found ready.
    private static func imageOptions(fit: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = fit ? .exact : .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    func prefetchThumbnails(start: [PhotoID], stop: [PhotoID], pixels: CGSize) {
        let options = Self.imageOptions(fit: false)
        let stopping = stop.compactMap { assets[$0] }, starting = start.compactMap { assets[$0] }
        if !stopping.isEmpty { manager.stopCachingImages(for: stopping, targetSize: pixels, contentMode: .aspectFill, options: options) }
        if !starting.isEmpty { manager.startCachingImages(for: starting, targetSize: pixels, contentMode: .aspectFill, options: options) }
    }

    func stopPrefetching() { manager.stopCachingImagesForAllAssets() }

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

    func setPlaces(_ changes: [PlaceChange], completion: @escaping @MainActor (Error?) -> Void) {
        let targets = changes.compactMap { change in assets[change.id].map { PlaceTarget(asset: $0, place: change.to) } }
        guard targets.count == changes.count else {
            completion(LibraryError.missing)
            return
        }
        perform({
            for target in targets {
                PHAssetChangeRequest(for: target.asset).location = target.place.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            }
        }, completion: completion)
    }

    private nonisolated struct PlaceTarget: Sendable {
        let asset: PHAsset
        let place: GeoPoint?
    }

    /// What a photo's file says about how it was taken, read from a copy written out for it (fetched from iCloud if
    /// need be), or a video's camera and frame rate; with the file's size and format.
    func metadata(_ id: PhotoID) async -> PhotoMetadata? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject,
              let resource = Self.original(of: asset) else { return nil }
        let format = (resource.originalFilename as NSString).pathExtension.uppercased()
        var size: Int64?
        if #available(macOS 27, *) { size = resource.dataSize.map(Int64.init) }
        if asset.mediaType == .video {
            var metadata = await Self.videoMetadata(id.rawValue) ?? PhotoMetadata()
            metadata.fileSize = size
            metadata.format = format
            return metadata
        }
        let file: URL? = await withCheckedContinuation { continuation in exportOriginal(id) { continuation.resume(returning: $0) } }
        guard let file else { return PhotoMetadata(fileSize: size, format: format) }
        defer { try? FileManager.default.removeItem(at: file) }
        return await Self.imageMetadata(at: file, format: format) ?? PhotoMetadata(fileSize: size, format: format)
    }

    @concurrent private nonisolated static func videoMetadata(_ identifier: String) async -> PhotoMetadata? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        // The asset is handed over once, from PhotoKit's queue to this task, and only read after.
        struct Handed: @unchecked Sendable { let video: AVAsset? }
        let handed: Handed = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { @Sendable video, _, _ in continuation.resume(returning: Handed(video: video)) }
        }
        guard let video = handed.video else { return nil }
        let rate = try? await video.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)
        let common = (try? await video.load(.commonMetadata)) ?? []
        var make: String?
        var model: String?
        if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierMake).first { make = try? await item.load(.stringValue) }
        if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierModel).first { model = try? await item.load(.stringValue) }
        return PhotoMetadata(make: make, model: model, frameRate: rate.map(Double.init))
    }

    // MARK: Adding files

    func addFiles(_ files: [ImportFile], progress: @escaping @MainActor @Sendable (Int) -> Void,
                  completion: @escaping @MainActor (AddedFiles) -> Void) {
        Task {
            let added = await Self.add(files, progress: progress)
            completion(added)
        }
    }

    /// In batches, so a big drop can say how far along it is. A batch the library refuses is tried again a file at
    /// a time, to add the rest and name the files it won't take.
    @concurrent private nonisolated static func add(_ files: [ImportFile], progress: @escaping @MainActor @Sendable (Int) -> Void) async -> AddedFiles {
        var added = AddedFiles()
        var done = 0
        for start in stride(from: 0, to: files.count, by: 20) {
            let batch = Array(files[start..<min(start + 20, files.count)])
            do {
                added.ids += try await create(batch)
            } catch {
                for file in batch {
                    do {
                        added.ids += try await create([file])
                    } catch {
                        added.refused.append(AddedFiles.Refusal(name: file.name, reason: error.localizedDescription))
                    }
                }
            }
            done += batch.count
            await progress(done)
        }
        return added
    }

    /// One change to the library making an asset from each file, copied in under its own name. A file without a
    /// date inside it is given the date it has on disk.
    @concurrent private nonisolated static func create(_ files: [ImportFile]) async throws -> [PhotoID] {
        let made = LockedValue<[String]>([])
        try await PHPhotoLibrary.shared().performChanges {
            var ids: [String] = []
            for file in files {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.name
                options.shouldMoveFile = false
                request.addResource(with: file.kind.isVideo ? .video : .photo, fileURL: file.url, options: options)
                if !file.dateIsInFile { request.creationDate = file.date }
                if let id = request.placeholderForCreatedAsset?.localIdentifier { ids.append(id) }
            }
            made.value = ids
        }
        return made.value.map { PhotoID($0) }
    }

    func deleteItems(_ ids: [PhotoID], completion: @escaping @MainActor (Error?) -> Void) {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        guard found.count > 0 else {
            completion(nil)
            return
        }
        let doomed = FetchedAssets(result: found)
        perform({
            PHAssetChangeRequest.deleteAssets(doomed.result)
        }, completion: completion)
    }

    private nonisolated struct FetchedAssets: @unchecked Sendable {
        let result: PHFetchResult<PHAsset>
    }

    // MARK: Albums

    func createAlbum(title: String, items: [PhotoID], completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        let assets = items.compactMap { assets[$0] }
        let created = LockedValue<String?>(nil)
        perform({
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            if !assets.isEmpty { request.addAssets(assets as NSArray) }
            created.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }, completion: { error in
            if let error {
                completion(.failure(error))
            } else if let id = created.value {
                completion(.success(id))
            } else {
                completion(.failure(LibraryError.notAllowed))
            }
        })
    }

    func updateAlbum(_ id: String, title: String, items: [PhotoID], completion: @escaping @MainActor (Error?) -> Void) {
        let wanted = items.compactMap { item in assets[item].map { (item, $0) } }
        let known = known
        Task {
            let error = await Self.makeAlbum(id, match: title, items: wanted, known: known)
            completion(error)
        }
    }

    /// Reads the album as it is now, then changes only what differs: the title, photos to take out, photos to put
    /// in, and the order. All in one change block. Only photos in `known` are ever taken out.
    @concurrent private nonisolated static func makeAlbum(_ id: String, match title: String, items: [(PhotoID, PHAsset)],
                                                          known: Set<String>) async -> Error? {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            return LibraryError.missing
        }
        let current = PHAsset.fetchAssets(in: collection, options: nil)
        var currentIDs: [String] = []
        current.enumerateObjects { asset, _, _ in currentIDs.append(asset.localIdentifier) }
        let edit = AlbumEditPlan(current: currentIDs, wanted: items.map(\.1.localIdentifier), known: known,
                                 canRearrange: collection.canPerform(.rearrangeContent))
        let renaming = (collection.localizedTitle ?? "") != title && collection.canPerform(.rename)
        guard renaming || !edit.isEmpty else { return nil }
        let assets = Dictionary(items.map { ($0.1.localIdentifier, $0.1) }) { first, _ in first }
        let plan = AlbumPlan(collection: collection, current: current, title: renaming ? title : nil, removing: edit.removing,
                             adding: edit.adding.compactMap { assets[$0] }, moves: edit.moves.map { ($0.from, $0.to) })
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: plan.collection, assets: plan.current) else { return }
                if let title = plan.title { request.title = title }
                if !plan.removing.isEmpty { request.removeAssets(at: plan.removing) }
                if !plan.adding.isEmpty { request.addAssets(plan.adding as NSArray) }
                for move in plan.moves { request.moveAssets(at: IndexSet(integer: move.from), to: move.to) }
            }
            return nil
        } catch {
            return LibraryError.failed(error.localizedDescription)
        }
    }

    private nonisolated struct AlbumPlan: @unchecked Sendable {
        let collection: PHAssetCollection
        let current: PHFetchResult<PHAsset>
        let title: String?
        let removing: IndexSet
        let adding: [PHAsset]
        let moves: [(from: Int, to: Int)]
    }

    func deleteAlbum(_ id: String, completion: @escaping @MainActor (Error?) -> Void) {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            completion(nil)
            return
        }
        perform({
            PHAssetCollectionChangeRequest.deleteAssetCollections([collection] as NSArray)
        }, completion: completion)
    }

    /// A photo's or video's own file as it is now: its edited version when it has one, else its original, downloaded
    /// from iCloud if need be, written into the app's temporary folder.
    func exportOriginal(_ id: PhotoID, completion: @escaping @MainActor (URL?) -> Void) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject,
              let resource = Self.original(of: asset) else {
            completion(nil)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shared Originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension((resource.originalFilename as NSString).pathExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { @Sendable error in
            Task { @MainActor in completion(error == nil ? url : nil) }
        }
    }

    /// The file of a photo or video that's shared: its edited version when it has one, else its original.
    private nonisolated static func original(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        return wanted.lazy.compactMap { type in resources.first { $0.type == type } }.first
    }

    /// How big each photo's or video's file is as `exportOriginal` writes it. macOS says from version 27; before
    /// that, none is known.
    func originalSizes(_ ids: [PhotoID]) async -> [PhotoID: Int64] {
        guard #available(macOS 27, *) else { return [:] }
        return await Self.sizes(of: ids)
    }

    @available(macOS 27, *)
    @concurrent private nonisolated static func sizes(of ids: [PhotoID]) async -> [PhotoID: Int64] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        var sizes: [PhotoID: Int64] = [:]
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            if let size = original(of: asset)?.dataSize { sizes[PhotoID(asset.localIdentifier)] = Int64(size) }
        }
        return sizes
    }

    private nonisolated struct DateTarget: Sendable {
        let asset: PHAsset
        let date: Date
    }

    /// One change block for the whole batch, so macOS asks the person at most once. Changes made from the main actor
    /// go through here: PhotoKit runs the block on a queue of its own, and a block written in place, there, would
    /// belong to the main actor and stop the app the moment it ran (as making an album once did). This one is
    /// `@Sendable`, so it runs anywhere.
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
