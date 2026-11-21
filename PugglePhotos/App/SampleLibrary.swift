#if DEBUG
import AppKit
import AVFoundation
import PugglePhotosKit
import UniformTypeIdentifiers

/// `-PHSampleLibrary YES`: a made-up library of illustrated photos, used by the self-test and for screenshots so
/// nothing ever touches the real Photos library. It lives in memory; changes, and files dropped in, last until quit.
final class SamplePhotoSource: PhotoSource {
    private(set) var items: [PhotoID: MediaItem] = [:]
    private var scenes: [PhotoID: (scene: SampleScene, seed: Int)] = [:]
    /// The sample library's own albums, which the catalog's albums mirror.
    private(set) var albums: [LibraryAlbum] = []
    private var albumNumber = 0
    private var recent: [PhotoID] = []
    private var videoFiles: [PhotoID: URL] = [:]
    /// Files dropped in, which the photos made from them are drawn and played from (they're only read, never kept).
    private(set) var addedFiles: [PhotoID: URL] = [:]
    private var addedNumber = 0
    private let today: Date
    var onChange: (() -> Void)?
    var access: LibraryAccess
    /// Counts each change to the library, for the self-test.
    private(set) var changeCount = 0
    /// Makes the next change fail, as if the person said no.
    var refuseNextChange = false
    /// `-PHSampleLoadDelay 3` holds the first load back that many seconds, as a big library takes a while to load.
    private var loadDelay = UserDefaults.standard.double(forKey: "PHSampleLoadDelay")

    let catalog: Catalog

    init(today: Date = Date(), count: Int = 0, access: LibraryAccess = .authorized) {
        self.access = access
        self.today = today
        let library = SampleLibrary.make(today: today, extra: count)
        for entry in library.entries {
            items[entry.item.id] = entry.item
            scenes[entry.item.id] = (entry.scene, entry.seed)
        }
        albums = library.albums
        recent = library.recent
        catalog = library.catalog
    }

    func requestAccess(_ completion: @escaping @MainActor (LibraryAccess) -> Void) {
        access = .authorized
        DispatchQueue.main.async { completion(.authorized) }
    }

    func load(_ completion: @escaping @MainActor (LibraryContents) -> Void) {
        let contents = LibraryContents(items: Array(items.values), recentlyAdded: recent, albums: albums)
        let delay = loadDelay
        loadDelay = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completion(contents) }
    }

    func loadFileNames(_ ids: [PhotoID], completion: @escaping @MainActor ([PhotoID: String]) -> Void) {
        var names: [PhotoID: String] = [:]
        for id in ids {
            if let file = addedFiles[id] { names[id] = file.lastPathComponent }
            guard let item = items[id], let scene = scenes[id] else { continue }
            let number = abs(scene.seed) % 9000 + 1000
            names[id] = switch (scene.scene, item.kind) {
            case (_, .video): "IMG_\(number).MOV"
            case (.screenshot, _): "Screenshot \(number).png"
            case (.scan, _): "Scan \(number % 100).jpg"
            default: "IMG_\(number).HEIC"
            }
        }
        DispatchQueue.main.async { completion(names) }
    }

    @discardableResult
    func requestImage(_ id: PhotoID, pixels: CGSize, fit: Bool,
                      completion: @escaping @MainActor (CGImage?, Bool) -> Void) -> ImageRequest? {
        if let file = addedFiles[id], let item = items[id] {
            let cancelled = CancelFlag()
            let maxPixels = min(max(pixels.width, pixels.height) * 2, 2400)
            Task {
                let image = await Self.picture(of: file, isVideo: item.kind.isVideo, maxPixels: maxPixels)
                guard !cancelled.isSet else { return }
                completion(image?.cgImage, true)
            }
            return ImageRequest { cancelled.set() }
        }
        guard let spec = scenes[id], let item = items[id] else {
            completion(nil, true)
            return nil
        }
        let aspect = CGFloat(item.aspectRatio)
        // Enough pixels that the shorter side covers the request when cropping to fill.
        let longest = max(pixels.width, pixels.height)
        let needed = fit ? longest : longest * max(aspect, 1 / aspect)
        let maxPixels = min(max(needed, 32), 2400)
        let cancelled = CancelFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !cancelled.isSet else { return }
            let image = SampleScene.render(spec.scene, seed: spec.seed, maxPixels: maxPixels, aspect: aspect).map(SendableImage.init)
            Task { @MainActor in
                guard !cancelled.isSet else { return }
                completion(image?.cgImage, true)
            }
        }
        return ImageRequest { cancelled.set() }
    }

    /// The photos whose thumbnails the grid asked to have ready, for the self-test. Sample pictures are drawn
    /// quickly, so nothing is made ahead.
    private(set) var prefetching: Set<PhotoID> = []

    func prefetchThumbnails(start: [PhotoID], stop: [PhotoID], pixels: CGSize) {
        prefetching.subtract(stop)
        prefetching.formUnion(start)
    }

    func stopPrefetching() { prefetching = [] }

    func requestPlayerItem(_ id: PhotoID, completion: @escaping @MainActor (AVPlayerItem?) -> Void) {
        if let file = addedFiles[id] {
            completion(items[id]?.kind == .video ? AVPlayerItem(url: file) : nil)
            return
        }
        guard let spec = scenes[id], items[id]?.kind == .video else {
            completion(nil)
            return
        }
        if let url = videoFiles[id] {
            completion(AVPlayerItem(url: url))
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos Sample", isDirectory: true)
        let url = folder.appendingPathComponent("\(spec.scene.rawValue)-\(spec.seed).mov")
        Task {
            let made = await SampleVideo.make(at: url, scene: spec.scene, seed: spec.seed)
            if made { videoFiles[id] = url }
            completion(made ? AVPlayerItem(url: url) : nil)
        }
    }

    func setDates(_ changes: [Redate.Change], completion: @escaping @MainActor (Error?) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(LibraryError.notAllowed) }
            return
        }
        for change in changes { items[change.id]?.date = change.to }
        changed(completion)
    }

    func setFavorite(_ ids: [PhotoID], _ favorite: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(LibraryError.notAllowed) }
            return
        }
        for id in ids { items[id]?.isFavorite = favorite }
        changed(completion)
    }

    func setPlaces(_ changes: [PlaceChange], completion: @escaping @MainActor (Error?) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(LibraryError.notAllowed) }
            return
        }
        for change in changes { items[change.id]?.location = change.to }
        changed(completion)
    }

    /// Sample photos were taken on a made-up pocket camera, its settings varying a little from photo to photo;
    /// screenshots and scans say nothing about a camera.
    func metadata(_ id: PhotoID) async -> PhotoMetadata? {
        guard let item = items[id] else { return nil }
        let size = await originalSizes([id])[id]
        let seed = scenes[id]?.seed ?? 0
        if item.kind == .screenshot { return PhotoMetadata(fileSize: size, format: "PNG") }
        if scenes[id]?.scene == .scan || addedFiles[id] != nil {
            return PhotoMetadata(fileSize: size, format: addedFiles[id]?.pathExtension.uppercased() ?? "JPEG")
        }
        if item.kind.isVideo { return PhotoMetadata(make: "Puggle", model: "Pocket 3", fileSize: size, format: "MOV", frameRate: 30) }
        return PhotoMetadata(make: "Puggle", model: "Pocket 3", lens: "Pocket 3 back camera 6.9 mm ƒ1.8", iso: [50, 64, 100, 200, 400][seed % 5],
                             focalLength: 6.9, aperture: 1.8, exposureTime: 1.0 / Double([60, 120, 250, 500, 1000][seed % 5]),
                             exposureBias: 0, fileSize: size, format: "HEIC")
    }

    // MARK: Adding files

    /// Makes a photo or video for each file, taken when the file says and added just now, as the Photos library
    /// would; the file itself is only read.
    func addFiles(_ files: [ImportFile], progress: @escaping @MainActor @Sendable (Int) -> Void,
                  completion: @escaping @MainActor (AddedFiles) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            let refused = files.map { AddedFiles.Refusal(name: $0.name, reason: LibraryError.notAllowed.localizedDescription) }
            DispatchQueue.main.async { completion(AddedFiles(ids: [], refused: refused)) }
            return
        }
        var added = AddedFiles()
        for file in files {
            addedNumber += 1
            let id = PhotoID("sample-added-\(addedNumber)")
            items[id] = MediaItem(id: id, kind: file.kind, date: file.date, addedDate: today.addingTimeInterval(TimeInterval(addedNumber)),
                                  pixelWidth: Int(file.pixelSize.width.rounded()), pixelHeight: Int(file.pixelSize.height.rounded()),
                                  duration: file.duration)
            addedFiles[id] = file.url
            recent.append(id)
            added.ids.append(id)
        }
        changed { _ in
            progress(files.count)
            completion(added)
        }
    }

    func deleteItems(_ ids: [PhotoID], completion: @escaping @MainActor (Error?) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(LibraryError.notAllowed) }
            return
        }
        let doomed = Set(ids)
        for id in ids {
            items[id] = nil
            addedFiles[id] = nil
            scenes[id] = nil
        }
        recent.removeAll { doomed.contains($0) }
        for index in albums.indices { albums[index].items.removeAll { doomed.contains($0) } }
        changed(completion)
    }

    /// A picture of a dropped file: a thumbnail of a photo, the first frame of a video.
    @concurrent nonisolated private static func picture(of file: URL, isVideo: Bool, maxPixels: CGFloat) async -> SendableImage? {
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return (try? await generator.image(at: .zero).image).map(SendableImage.init)
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(SendableImage.init)
    }

    // MARK: Albums

    func createAlbum(title: String, items: [PhotoID], completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(.failure(LibraryError.notAllowed)) }
            return
        }
        albumNumber += 1
        let id = "sample-album-new-\(albumNumber)"
        albums.append(LibraryAlbum(id: id, title: title, items: items.filter { self.items[$0] != nil }))
        changed { _ in completion(.success(id)) }
    }

    func updateAlbum(_ id: String, title: String, items: [PhotoID], completion: @escaping @MainActor (Error?) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(LibraryError.notAllowed) }
            return
        }
        guard let index = albums.firstIndex(where: { $0.id == id }) else {
            DispatchQueue.main.async { completion(LibraryError.missing) }
            return
        }
        albums[index].title = title
        albums[index].items = items.filter { self.items[$0] != nil }
        changed(completion)
    }

    func deleteAlbum(_ id: String, completion: @escaping @MainActor (Error?) -> Void) {
        if refuseNextChange {
            refuseNextChange = false
            DispatchQueue.main.async { completion(LibraryError.notAllowed) }
            return
        }
        albums.removeAll { $0.id == id }
        changed(completion)
    }

    /// A sample photo drawn as a file, as big as it says it is (up to 2,400 pixels, to be quick), or its movie.
    private(set) var exported: [PhotoID] = []

    /// How big each sample's file would be from a camera, about 0.4 bytes a pixel for a photo and 3 MB a second for a
    /// movie, or a dropped file's own size.
    func originalSizes(_ ids: [PhotoID]) async -> [PhotoID: Int64] {
        var sizes: [PhotoID: Int64] = [:]
        for id in ids {
            if let file = addedFiles[id], let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                sizes[id] = Int64(size)
            } else if let item = items[id] {
                sizes[id] = item.kind.isVideo ? Int64(max(item.duration, 1) * 3_000_000) : Int64(Double(item.pixelWidth * item.pixelHeight) * 0.4)
            }
        }
        return sizes
    }

    func exportOriginal(_ id: PhotoID, completion: @escaping @MainActor (URL?) -> Void) {
        exported.append(id)
        if let file = addedFiles[id] {
            DispatchQueue.main.async { completion(file) }
            return
        }
        guard let item = items[id], let spec = scenes[id] else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos Sample Originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(spec.scene.rawValue)-\(spec.seed)"
        if item.kind.isVideo {
            let url = folder.appendingPathComponent(name + ".mov")
            Task {
                let made = await SampleVideo.make(at: url, scene: spec.scene, seed: spec.seed)
                completion(made ? url : nil)
            }
            return
        }
        let url = folder.appendingPathComponent(name + ".jpg")
        let maxPixels = CGFloat(min(max(item.pixelWidth, item.pixelHeight), 2400)), aspect = CGFloat(item.aspectRatio)
        Task {
            let written = await Self.writeJPEG(scene: spec.scene, seed: spec.seed, maxPixels: maxPixels, aspect: aspect, to: url)
            completion(written ? url : nil)
        }
    }

    @concurrent nonisolated private static func writeJPEG(scene: SampleScene, seed: Int, maxPixels: CGFloat, aspect: CGFloat, to url: URL) async -> Bool {
        guard let image = SampleScene.render(scene, seed: seed, maxPixels: maxPixels, aspect: aspect),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Changes an album the way someone using another app on the library would, for the self-test.
    func changeAlbumElsewhere(_ id: String, _ change: (inout LibraryAlbum?) -> Void) {
        var album = albums.first { $0.id == id }
        change(&album)
        albums.removeAll { $0.id == id }
        if let album { albums.append(album) }
        changeCount += 1
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// Like the Photos library, reports the change it just made a moment later.
    private func changed(_ completion: @escaping @MainActor (Error?) -> Void) {
        changeCount += 1
        DispatchQueue.main.async { [weak self] in
            completion(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.onChange?() }
        }
    }
}

/// A flag a background job checks to see whether it's still wanted.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The sample library's contents: days out with family over several years, a pet, a few videos, screenshots, and a
/// batch of scanned prints all dated the day they were scanned (to try dragging them to the right day).
enum SampleLibrary {
    struct Entry {
        let item: MediaItem
        let scene: SampleScene
        let seed: Int
    }

    struct Contents {
        var entries: [Entry]
        var albums: [LibraryAlbum]
        var recent: [PhotoID]
        var catalog: Catalog
    }

    private struct Event {
        let key: String
        let scene: SampleScene
        let start: DateComponents
        let count: Int
        var videos = 0
        var favorites: Set<Int> = []
    }

    /// The day the sample library treats as "today" in screenshots, so they don't change from day to day.
    static let fixedEvents: [(String, SampleScene, Int, Int, Int, Int, Int)] = [
        // key, scene, year, month, day, hour, count
        ("lake19", .lake, 2019, 7, 4, 10, 12),
        ("snow19", .snow, 2019, 12, 25, 9, 6),
        ("beach20", .beach, 2020, 8, 15, 11, 10),
        ("hike21", .hike, 2021, 5, 22, 8, 8),
        ("party21", .party, 2021, 10, 30, 15, 6),
        ("garden22", .garden, 2022, 6, 18, 10, 7),
        ("birthday23", .party, 2023, 3, 12, 14, 9),
        ("lake23", .lake, 2023, 7, 21, 9, 8),
        ("snow24", .snow, 2024, 1, 14, 11, 6),
        ("city24", .city, 2024, 9, 2, 20, 5),
        ("beach25", .beach, 2025, 6, 14, 10, 6),
        ("sunset25", .sunset, 2025, 6, 14, 19, 4),
        ("pug26", .pug, 2026, 2, 8, 13, 6),
        ("garden26", .garden, 2026, 4, 19, 10, 5),
        ("food26", .food, 2026, 9, 27, 12, 4),
    ]

    static func make(today: Date, extra: Int = 0) -> Contents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var entries: [Entry] = []
        var byEvent: [String: [PhotoID]] = [:]
        var seed = 7
        /// Where the family takes each kind of photo (at home, the lake, the coast, up the mountain, on the trail and
        /// in the city), a few steps apart within `spread` degrees. Screenshots and scans say nowhere.
        func place(of scene: SampleScene, seed: Int, spread: Double) -> GeoPoint? {
            let home = (45.5231, -122.6765)
            let base: (Double, Double)
            switch scene {
            case .party, .garden, .pug: base = home
            case .lake: base = (45.2700, -121.7376)
            case .beach, .sunset: base = (45.8918, -123.9615)
            case .snow: base = (45.3317, -121.6650)
            case .hike: base = (45.5762, -122.1158)
            case .city, .food: base = (47.6097, -122.3425)
            case .screenshot, .scan: return nil
            }
            let across = Double((seed * 7919) % 201 - 100) / 100, down = Double((seed * 104_729) % 201 - 100) / 100
            return GeoPoint(latitude: base.0 + down * spread, longitude: base.1 + across * spread)
        }
        func add(_ key: String, _ scene: SampleScene, at date: Date, kind: MediaKind = .photo, favorite: Bool = false,
                 added: Date? = nil, duration: TimeInterval = 0, spread: Double = 0.002) {
            seed += 1
            let id = PhotoID("sample-\(key)-\(byEvent[key, default: []].count + 1)")
            let aspect = kind == .video ? 16.0 / 9.0 : Double(scene.aspect(seed: seed))
            let pixelWidth = kind == .panorama ? 9000 : (aspect >= 1 ? 4032 : 3024)
            let pixelHeight = kind == .panorama ? 3000 : Int(Double(pixelWidth) / aspect)
            let item = MediaItem(id: id, kind: kind, date: date, addedDate: added ?? date.addingTimeInterval(3600),
                                 pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, isFavorite: favorite,
                                 location: place(of: scene, seed: seed, spread: spread))
            entries.append(Entry(item: item, scene: scene, seed: seed))
            byEvent[key, default: []].append(id)
        }

        let favorites: Set<String> = ["lake19-3", "beach20-2", "birthday23-5", "pug26-1", "pug26-4", "sunset25-2", "snow19-1", "hike21-6"]
        for (key, scene, year, month, day, hour, count) in fixedEvents {
            let start = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 5))!
            for index in 0..<count {
                let date = start.addingTimeInterval(Double(index) * 11 * 60 + Double(index * index) * 17)
                let isVideo = (key == "birthday23" && index == 4) || (key == "lake23" && index == 2) || (key == "pug26" && index == 3)
                let kind: MediaKind = isVideo ? .video : (key == "hike21" && index == 7 ? .panorama : (index == 1 && key == "beach25" ? .livePhoto : .photo))
                add(key, scene, at: date, kind: kind, favorite: favorites.contains("\(key)-\(index + 1)"),
                    duration: isVideo ? 14 + Double(index) : 0)
            }
        }

        // Memories: the same day in each of the last three years.
        for yearsAgo in 1...3 {
            guard let day = calendar.date(byAdding: .year, value: -yearsAgo, to: today) else { continue }
            let scene: SampleScene = [.pug, .lake, .party][yearsAgo - 1]
            let start = calendar.date(bySettingHour: 10, minute: 30, second: 0, of: day) ?? day
            for index in 0..<4 {
                add("onthisday\(yearsAgo)", scene, at: start.addingTimeInterval(Double(index) * 25 * 60), favorite: index == 0)
            }
        }

        // Screenshots and recent photos.
        for index in 0..<2 {
            add("screens", .screenshot, at: today.addingTimeInterval(-Double(index + 3) * 86_400), kind: .screenshot,
                added: today.addingTimeInterval(-Double(index + 3) * 86_400))
        }
        // Scanned prints, all dated when they were scanned: the batch to drag back to the right day.
        let scanned = calendar.date(byAdding: .day, value: -2, to: calendar.date(bySettingHour: 14, minute: 2, second: 0, of: today)!)!
        for index in 0..<8 {
            add("scans", .scan, at: scanned.addingTimeInterval(Double(index) * 9), added: scanned.addingTimeInterval(Double(index) * 9))
        }

        // `-PHSampleCount 50000` makes the library much bigger, for timing.
        if extra > 0 {
            let start = calendar.date(from: DateComponents(year: 2005, month: 1, day: 1))!
            let scenes: [SampleScene] = [.lake, .beach, .party, .snow, .hike, .city, .garden, .food, .pug, .sunset]
            for index in 0..<extra {
                add("bulk\(index / 1000)", scenes[index % scenes.count], at: start.addingTimeInterval(Double(index) * 4987), spread: 6)
            }
        }

        let recent = entries.filter { ($0.item.addedDate ?? .distantPast) > today.addingTimeInterval(-30 * 86_400) }
            .sorted { $0.item.addedDate! < $1.item.addedDate! }.map(\.item.id)
        // Every catalog album has its twin in the library; two more albums exist only in the library so far, and
        // arrive in the catalog when it first loads.
        var catalog = catalog(byEvent)
        var albums: [LibraryAlbum] = []
        for (index, album) in catalog.albums.enumerated() {
            let id = "sample-album-\(index + 1)"
            albums.append(LibraryAlbum(id: id, title: album.title, items: album.items))
            catalog.link(album.id, toPhotosAlbum: id)
        }
        albums.append(LibraryAlbum(id: "sample-album-imported", title: "Imported Photos", items: (byEvent["pug26"] ?? []) + (byEvent["food26"] ?? [])))
        albums.append(LibraryAlbum(id: "sample-album-scans", title: "Scanned Prints", items: byEvent["scans"] ?? []))
        // A journal entry for the day a year ago, so today's memory has words to go with it.
        if let yearAgo = calendar.date(byAdding: .year, value: -1, to: today) {
            catalog.setEntry("Waffles discovered the leaf pile and would not come inside. We gave up and had cocoa on the porch.",
                             mood: "😂", for: CivilDay(yearAgo, in: calendar.timeZone), edited: yearAgo)
        }
        return Contents(entries: entries, albums: albums, recent: recent, catalog: catalog)
    }

    /// Albums, labels, captions and notes to go with the sample photos.
    private static func catalog(_ byEvent: [String: [PhotoID]]) -> Catalog {
        func ids(_ keys: String...) -> [PhotoID] { keys.flatMap { byEvent[$0] ?? [] } }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func made(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day))! }

        var catalog = Catalog()
        let lake = catalog.addAlbum(title: "Summer at the Lake", items: ids("lake19", "lake23"), created: made(2023, 8, 1))
        catalog.setAlbumNote(lake, to: "Every July we rent the little cabin with the green door. The kids count the days.")
        catalog.setCover(byEvent["lake23"]?.first, of: lake)
        let birthday = catalog.addAlbum(title: "Mia’s 7th Birthday", items: ids("birthday23"), created: made(2023, 3, 13))
        catalog.setAlbumNote(birthday, to: "Unicorn cake, nine balloons and one very tired dog.")
        catalog.addAlbum(title: "Snow Days", items: ids("snow19", "snow24"), created: made(2024, 1, 15))
        let beach = catalog.addAlbum(title: "Beach Trips", items: ids("beach20", "beach25", "sunset25"), created: made(2020, 8, 20))
        catalog.setCover(byEvent["sunset25"]?[1], of: beach)
        catalog.addAlbum(title: "Waffles the Pug", items: ids("pug26", "onthisday1"), created: made(2026, 2, 9))
        catalog.addAlbum(title: "Out on the Trail", items: ids("hike21", "garden22", "garden26"), created: made(2021, 5, 30))
        let favorites2025 = catalog.addAlbum(title: "Best of 2025", items: ids("beach25", "sunset25"), created: made(2025, 12, 31))
        catalog.setAlbumOrder(favorites2025, to: .custom)

        let family = catalog.addLabel(name: "Family", color: .pink, emoji: "❤️")
        let funny = catalog.addLabel(name: "Funny", color: .yellow, emoji: "😂")
        let food = catalog.addLabel(name: "Food", color: .orange, emoji: "🍰")
        let pets = catalog.addLabel(name: "Pets", color: .brown, emoji: "🐶")
        let outdoors = catalog.addLabel(name: "Outdoors", color: .green, emoji: "🌲")
        catalog.setLabel(family, on: ids("birthday23", "snow19", "lake19").enumerated().filter { $0.offset % 2 == 0 }.map(\.element), true)
        catalog.setLabel(funny, on: Array(ids("party21", "pug26").prefix(4)), true)
        catalog.setLabel(food, on: ids("food26"), true)
        catalog.setLabel(pets, on: ids("pug26", "onthisday1"), true)
        catalog.setLabel(outdoors, on: ids("hike21", "lake23"), true)

        if let first = byEvent["lake19"]?[2] {
            catalog.setCaption("First jump off the dock", for: [first])
            catalog.setNote("She stood there for ten minutes, then jumped before anyone could count to three.", for: first)
        }
        if let cake = byEvent["birthday23"]?[1] { catalog.setCaption("Cake first, presents later", for: [cake]) }
        if let waffles = byEvent["pug26"]?.first { catalog.setCaption("Waffles meets the ball", for: [waffles]) }
        if let snowman = byEvent["snow19"]?[2] { catalog.setCaption("Mr. Carrot Nose", for: [snowman]) }
        // Notes on the backs of a few photos, for the books.
        let backs: [(String, Int, String)] = [
            ("beach20", 1, "Low tide! We walked all the way out to the sandbar and back."),
            ("beach20", 4, "Dad’s famous sandcastle, about four minutes before the wave."),
            ("sunset25", 1, "Ten minutes after this the whole sky went purple."),
            ("beach25", 2, "Found the perfect shell. Kept it in the car all summer."),
        ]
        for (event, index, note) in backs {
            if let id = byEvent[event]?[index] { catalog.setNote(note, for: id) }
        }

        let journal: [(Int, Int, Int, String, String)] = [
            (2023, 7, 21, "😌", "Lake day. The water was freezing and nobody cared. Mia finally swam out to the raft on her own, then made everyone watch her do it twice more."),
            (2025, 6, 14, "🤩", "The sky went pink, then orange, then a purple we didn’t have a name for. We stayed on the sand until the stars came out."),
            (2026, 2, 8, "🥰", "Waffles came home today! He snored the whole drive back and has already claimed the good chair."),
            (2026, 9, 27, "", "Tried the new bakery’s lemon cake. Worth the line. Waffles tried to steal a slice twice."),
        ]
        for (year, month, day, mood, text) in journal {
            catalog.setEntry(text, mood: mood, for: CivilDay(year: year, month: month, day: day), edited: made(year, month, day).addingTimeInterval(20 * 3600))
        }
        return catalog
    }
}

/// Makes a short movie of a sample scene for the sample library's videos.
nonisolated enum SampleVideo {
    @concurrent static func make(at url: URL, scene: SampleScene, seed: Int) async -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = CGSize(width: 640, height: 360)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let frames = 48
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard let image = SampleScene.render(scene, seed: seed, maxPixels: size.width, aspect: 16.0 / 9.0,
                                                 time: CGFloat(frame) / CGFloat(frames)),
                  let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
#endif
