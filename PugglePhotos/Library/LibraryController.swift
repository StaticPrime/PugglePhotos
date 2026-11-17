import AppKit
import Observation
import PugglePhotosKit

extension Notification.Name {
    /// Posted by `LibraryController` when the library, the catalog or access changes. `userInfo["change"]` is a
    /// `LibraryController.Change`.
    static let libraryDidChange = Notification.Name("PugglePhotos.libraryDidChange")
}

/// The library and the catalog together: what every window shows, and the one place every change goes through, so
/// each can be undone. Catalog changes undo by restoring the catalog as it was; changes to the Photos library undo
/// by writing the old values back.
@Observable
final class LibraryController {
    nonisolated enum Change { case items, catalog, access }

    @ObservationIgnored let source: PhotoSource
    /// Nil keeps the catalog in memory only.
    @ObservationIgnored let store: CatalogStore?
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored let thumbnails: ThumbnailCache

    private(set) var snapshot = LibrarySnapshot.empty
    private(set) var catalog = Catalog()
    @ObservationIgnored private(set) var membership = Membership(Catalog())
    private(set) var recentlyAdded: [PhotoID] = []
    private(set) var photosAlbums: [ExternalAlbum] = []
    private(set) var access: LibraryAccess
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    @ObservationIgnored var formatting = Formatting()

    /// Shows a problem to the person: a title and an explanation. The window controller sets this.
    @ObservationIgnored var reportProblem: ((String, String) -> Void)?

    @ObservationIgnored private var fileNames: [PhotoID: String] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    @ObservationIgnored private var loadGeneration = 0

    init(source: PhotoSource, store: CatalogStore?) {
        self.source = source
        self.store = store
        access = source.access
        thumbnails = ThumbnailCache(source: source)
    }

    var arranger: Arranger { Arranger(snapshot: snapshot, catalog: catalog, membership: membership) }

    /// Reads the catalog and, with permission, the library; then keeps up with changes made elsewhere.
    func start(catalog initial: Catalog? = nil) {
        if let initial {
            setCatalog(initial)
        } else {
            loadCatalog()
        }
        source.onChange = { [weak self] in self?.scheduleReload() }
        if access == .authorized { reload() }
    }

    func requestAccess() {
        source.requestAccess { [weak self] access in
            guard let self else { return }
            self.access = access
            post(.access)
            if access == .authorized { reload() }
        }
    }

    /// Reads the whole library again.
    func reload(completion: (() -> Void)? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        source.load { [weak self] contents in
            guard let self, generation == loadGeneration else { return }
            var items = contents.items
            for index in items.indices where items[index].fileName == nil {
                items[index].fileName = fileNames[items[index].id]
            }
            snapshot = LibrarySnapshot(items: items)
            recentlyAdded = contents.recentlyAdded
            photosAlbums = contents.albums
            isLoading = false
            hasLoaded = true
            post(.items)
            loadMissingFileNames()
            completion?()
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func loadMissingFileNames() {
        let missing = snapshot.items.filter { $0.fileName == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        source.loadFileNames(missing) { [weak self] names in
            guard let self, !names.isEmpty else { return }
            fileNames.merge(names) { _, new in new }
            let changed = names.compactMap { id, name -> MediaItem? in
                guard var item = snapshot.item(id) else { return nil }
                item.fileName = name
                return item
            }
            snapshot = snapshot.updating(changed)
            post(.items)
        }
    }

    // MARK: The catalog

    private func loadCatalog() {
        guard let store else { return }
        do {
            setCatalog(try store.load())
        } catch let error as CatalogStore.StoreError {
            setCatalog(Catalog())
            let detail: String = switch error {
            case let .damaged(movedTo?):
                "The file was kept as “\(movedTo.lastPathComponent)” in \(movedTo.deletingLastPathComponent().path), and PugglePhotos started a new one. Copies from earlier days are in the Backups folder there."
            case .damaged(nil):
                "PugglePhotos started a new one. Copies from earlier days are in \(store.backupsFolder.path)."
            case .newerVersion:
                "Update PugglePhotos to see them. Until then, changes you make here won’t be saved."
            }
            if case .newerVersion = error { readOnly = true }
            DispatchQueue.main.async { [weak self] in self?.reportProblem?(error.localizedDescription, detail) }
        } catch {
            setCatalog(Catalog())
        }
    }

    /// Set when the saved catalog came from a newer PugglePhotos, so it's never overwritten.
    @ObservationIgnored private var readOnly = false

    private func setCatalog(_ catalog: Catalog) {
        self.catalog = catalog
        membership = Membership(catalog)
        post(.catalog)
    }

    /// Changes the catalog as one undoable step.
    func edit(_ actionName: String, _ change: (inout Catalog) -> Void) {
        var updated = catalog
        change(&updated)
        guard updated != catalog else { return }
        replaceCatalog(with: updated, actionName: actionName)
    }

    private func replaceCatalog(with new: Catalog, actionName: String) {
        let old = catalog
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.replaceCatalog(with: old, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        setCatalog(new)
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the catalog now (at quit, and half a second after each change).
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let store, !readOnly else { return }
        do {
            try store.save(catalog)
        } catch {
            reportProblem?("Your albums, labels and notes couldn’t be saved.", error.localizedDescription)
        }
    }

    // MARK: Changes to the Photos library

    /// Changes when photos were taken. Undo puts the old dates back.
    func changeDates(_ changes: [Redate.Change], actionName: String = "Change Date", completion: ((Bool) -> Void)? = nil) {
        let real = changes.filter { $0.from != $0.to }
        guard !real.isEmpty else {
            completion?(true)
            return
        }
        // Undo is registered now, not when the library answers, so that undoing and redoing land on the right
        // stacks. If the library refuses, the step does nothing.
        let outcome = ChangeOutcome()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard !outcome.failed else { return }
                target.changeDates(Redate.reversed(real), actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        source.setDates(real) { [weak self] error in
            guard let self else { return }
            if let error {
                outcome.failed = true
                reportProblem?(real.count == 1 ? "The date couldn’t be changed." : "The dates couldn’t be changed.",
                               error.localizedDescription)
                completion?(false)
                return
            }
            let changed = real.compactMap { change -> MediaItem? in
                guard var item = snapshot.item(change.id) else { return nil }
                item.date = change.to
                return item
            }
            snapshot = snapshot.updating(changed)
            post(.items)
            completion?(true)
        }
    }

    /// Favorites photos, or stops. Undo puts each one back as it was.
    func setFavorite(_ ids: [PhotoID], _ favorite: Bool) {
        let changing = ids.filter { snapshot.item($0).map { $0.isFavorite != favorite } ?? false }
        guard !changing.isEmpty else { return }
        let outcome = ChangeOutcome()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard !outcome.failed else { return }
                target.setFavorite(changing, !favorite)
            }
        }
        undoManager.setActionName(favorite ? "Favorite" : "Unfavorite")
        source.setFavorite(changing, favorite) { [weak self] error in
            guard let self else { return }
            if let error {
                outcome.failed = true
                reportProblem?("Favorites couldn’t be changed.", error.localizedDescription)
                return
            }
            let changed = changing.compactMap { id -> MediaItem? in
                guard var item = snapshot.item(id) else { return nil }
                item.isFavorite = favorite
                return item
            }
            snapshot = snapshot.updating(changed)
            post(.items)
        }
    }

    /// Favorites them all unless they all are already, in which case it unfavorites them.
    func toggleFavorite(_ ids: [PhotoID]) {
        let allFavorites = !ids.isEmpty && ids.allSatisfy { snapshot.item($0)?.isFavorite == true }
        setFavorite(ids, !allFavorites)
    }

    // MARK: Helpers for views

    /// Album IDs in the order the sidebar and album covers show them.
    func sortedAlbumIDs(sort: AlbumSort, ascending: Bool) -> [UUID] {
        arranger.albumSummaries(sort: sort, ascending: ascending).map(\.id)
    }

    func title(of id: PhotoID) -> String { arranger.title(of: id) }

    private func post(_ change: Change) {
        NotificationCenter.default.post(name: .libraryDidChange, object: self, userInfo: ["change": change])
    }
}

/// Whether a change sent to the library was refused, for its undo step to check.
nonisolated final class ChangeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var failed: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Thumbnails, kept in memory by size so scrolling back is instant.
final class ThumbnailCache {
    private let source: PhotoSource
    private let cache = NSCache<NSString, CGImageBox>()

    init(source: PhotoSource) {
        self.source = source
        cache.countLimit = 3000
    }

    /// Sizes snap to a few steps so the same thumbnail serves nearby zoom levels.
    static func bucket(_ pixels: CGFloat) -> CGFloat {
        for step: CGFloat in [64, 128, 256, 384, 512, 768, 1024] where pixels <= step { return step }
        return pixels.rounded(.up)
    }

    func cached(_ id: PhotoID, pixels: CGFloat) -> CGImage? {
        cache.object(forKey: key(id, Self.bucket(pixels)))?.image
    }

    /// A square thumbnail at least `pixels` across. Calls back with nil only when there's nothing to show.
    func request(_ id: PhotoID, pixels: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ImageRequest? {
        let side = Self.bucket(pixels)
        let key = key(id, side)
        if let image = cache.object(forKey: key)?.image {
            completion(image)
            return nil
        }
        return source.requestImage(id, pixels: CGSize(width: side, height: side), fit: false) { [weak self] image, isFinal in
            if let image, isFinal { self?.cache.setObject(CGImageBox(image), forKey: key) }
            if image != nil || isFinal { completion(image) }
        }
    }

    func removeAll() { cache.removeAllObjects() }

    private func key(_ id: PhotoID, _ side: CGFloat) -> NSString { "\(id.rawValue)|\(Int(side))" as NSString }
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
