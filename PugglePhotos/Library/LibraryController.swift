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
/// by writing the old values back. Albums are mirrored: each has a twin album in the Photos library, which decides
/// its title and photos when they differ, and every change made here is sent there too.
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
            reconcileAlbums(contents.albums)
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
            // Albums' titles and photos belong to the Photos library and have their own undo, so restoring the
            // catalog leaves them as they are now.
            MainActor.assumeIsolated { target.replaceCatalog(with: old.keepingAlbumContents(from: target.catalog), actionName: actionName) }
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

    // MARK: Albums, mirrored in the Photos library

    @ObservationIgnored private var albumsInFlight: Set<UUID> = []
    @ObservationIgnored private var albumsChangedAgain: Set<UUID> = []
    @ObservationIgnored private var deletesInFlight = 0
    @ObservationIgnored private var reloadAfterAlbumChanges = false
    /// Albums the library wouldn't make this session, so they aren't asked for again until the next launch.
    @ObservationIgnored private var albumsRefused: Set<UUID> = []

    /// Whether album changes are still on their way to the Photos library.
    var isMirroringAlbums: Bool { !albumsInFlight.isEmpty || deletesInFlight > 0 }

    /// Makes an album with these photos, and its twin in the Photos library. Returns its ID.
    @discardableResult
    func newAlbum(title: String? = nil, items: [PhotoID] = []) -> UUID {
        var updated = catalog
        let id = updated.addAlbum(title: title ?? catalog.unusedAlbumTitle(), items: items)
        if let album = updated.album(id) { insertAlbum(album, actionName: "New Album") }
        return id
    }

    func addToAlbum(_ ids: [PhotoID], album: UUID) {
        changeAlbum(album, actionName: "Add to Album") { $0.add(ids, toAlbum: album) }
    }

    func removeFromAlbum(_ ids: [PhotoID], album: UUID) {
        changeAlbum(album, actionName: "Remove from Album") { $0.remove(Set(ids), fromAlbum: album) }
    }

    func renameAlbum(_ album: UUID, to title: String) {
        changeAlbum(album, actionName: "Rename Album") { $0.renameAlbum(album, to: title) }
    }

    /// Puts photos at a place in the album's own order.
    func moveInAlbum(_ ids: [PhotoID], album: UUID, toIndex index: Int) {
        changeAlbum(album, actionName: ids.count == 1 ? "Move Photo" : "Move Photos") { $0.move(ids, inAlbum: album, toIndex: index) }
    }

    func deleteAlbum(_ id: UUID) { removeAlbum(id, actionName: "Delete Album") }

    /// Changes an album's title or photos as one undoable step.
    private func changeAlbum(_ id: UUID, actionName: String, _ change: (inout Catalog) -> Void) {
        var updated = catalog
        change(&updated)
        guard let before = catalog.album(id), let after = updated.album(id),
              before.title != after.title || before.items != after.items else { return }
        setAlbumContents(id, title: after.title, items: after.items, actionName: actionName)
    }

    /// Gives an album this title and these photos, registers the way back, and sends the change to its twin.
    private func setAlbumContents(_ id: UUID, title: String, items: [PhotoID], actionName: String) {
        guard var album = catalog.album(id) else { return }
        let (oldTitle, oldItems) = (album.title, album.items)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setAlbumContents(id, title: oldTitle, items: oldItems, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        album.title = title
        album.items = items
        if let cover = album.cover, !items.contains(cover) { album.cover = nil }
        var updated = catalog
        updated.setAlbum(album)
        setCatalog(updated)
        scheduleSave()
        mirror(id)
    }

    /// Adds an album (a new one, or one that Undo brings back) and makes its twin in the Photos library.
    private func insertAlbum(_ album: Album, actionName: String) {
        var album = album
        album.photosAlbumID = nil
        undoManager.registerUndo(withTarget: self) { [album] target in
            MainActor.assumeIsolated { target.removeAlbum(album.id, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        var updated = catalog
        updated.setAlbum(album)
        setCatalog(updated)
        scheduleSave()
        mirror(album.id)
    }

    /// Deletes an album here and its twin in the Photos library. The photos stay in the library.
    private func removeAlbum(_ id: UUID, actionName: String) {
        guard let album = catalog.album(id) else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.insertAlbum(album, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        var updated = catalog
        updated.deleteAlbum(id)
        setCatalog(updated)
        scheduleSave()
        albumsChangedAgain.remove(id)
        guard let photosID = album.photosAlbumID else { return }
        deletesInFlight += 1
        source.deleteAlbum(photosID) { [weak self] error in
            guard let self else { return }
            deletesInFlight -= 1
            if let error {
                // The Photos library still has it, so it comes back here too, story and all.
                if catalog.album(id) == nil {
                    var restored = catalog
                    restored.setAlbum(album)
                    setCatalog(restored)
                    scheduleSave()
                }
                reportProblem?("The album couldn’t be deleted from your Photos library.", error.localizedDescription)
            }
            albumWorkFinished()
        }
    }

    /// Brings an album's twin in the Photos library in line with it, making the twin if there isn't one yet.
    /// Changes made while one is on its way go together once it arrives.
    private func mirror(_ id: UUID) {
        guard !albumsInFlight.contains(id) else {
            albumsChangedAgain.insert(id)
            return
        }
        guard let album = catalog.album(id) else { return }
        albumsInFlight.insert(id)
        if let photosID = album.photosAlbumID {
            source.updateAlbum(photosID, title: album.title, items: album.items) { [weak self] error in
                self?.mirrored(id, error: error)
            }
            return
        }
        source.createAlbum(title: album.title, items: album.items) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(photosID):
                if catalog.album(id) != nil {
                    var updated = catalog
                    updated.link(id, toPhotosAlbum: photosID)
                    setCatalog(updated)
                    scheduleSave()
                } else {
                    // Deleted while its twin was being made: delete the twin too.
                    deletesInFlight += 1
                    source.deleteAlbum(photosID) { [weak self] _ in
                        self?.deletesInFlight -= 1
                        self?.albumWorkFinished()
                    }
                }
                mirrored(id, error: nil)
            case let .failure(error):
                albumsRefused.insert(id)
                mirrored(id, error: error)
            }
        }
    }

    private func mirrored(_ id: UUID, error: Error?) {
        albumsInFlight.remove(id)
        if let error {
            albumsChangedAgain.remove(id)
            reportProblem?("The album couldn’t be changed in your Photos library.", error.localizedDescription)
            // What the library has wins.
            reloadAfterAlbumChanges = true
        } else if albumsChangedAgain.remove(id) != nil {
            mirror(id)
            return
        }
        albumWorkFinished()
    }

    private func albumWorkFinished() {
        guard !isMirroringAlbums, reloadAfterAlbumChanges else { return }
        reloadAfterAlbumChanges = false
        reload()
    }

    /// Takes the Photos library's albums: their titles and photos, new albums made there, and albums deleted there.
    /// Albums with changes still on their way wait for the next reload, so nothing is undone halfway.
    private func reconcileAlbums(_ library: [LibraryAlbum]) {
        guard !isMirroringAlbums else {
            reloadAfterAlbumChanges = true
            return
        }
        // An empty library with no albums is more likely one that isn't available right now than one emptied.
        if library.isEmpty, snapshot.count == 0, catalog.albums.contains(where: { $0.photosAlbumID != nil }) { return }
        var updated = catalog
        let result = updated.reconcileAlbums(with: library)
        if updated != catalog {
            setCatalog(updated)
            scheduleSave()
        }
        for id in result.unmirrored where !albumsRefused.contains(id) { mirror(id) }
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

/// A value set on one thread and read on another.
nonisolated final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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
