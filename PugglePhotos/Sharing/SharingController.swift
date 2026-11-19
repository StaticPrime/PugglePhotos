import AppKit
import CloudKit
import PugglePhotosKit

extension Notification.Name {
    /// Posted by `SharingController` when shared albums change: yours, or those shared with you.
    static let sharingDidChange = Notification.Name("PugglePhotos.sharingDidChange")
}

/// Shared albums: yours, shared with other people, and theirs, shared with you. What's shared of an album of yours
/// keeps up with the album as you change it. Albums shared with you come and change as their owners share them, and a
/// notification tells you when one arrives or has photos added.
final class SharingController {
    let backend: SharingBackend
    let store: SharedAlbumsStore
    private unowned let library: LibraryController
    private let notifications: MemoryNotificationCenter
    /// Yours and those shared with you.
    private(set) var albums: [SharedAlbum]
    private var observer: NSObjectProtocol?
    private var syncWork: DispatchWorkItem?
    /// Albums of yours being sent now, which aren't sent again until that's done.
    private var publishing: Set<UUID> = []
    /// Shows a problem to the person; the window controller sets this.
    var reportProblem: ((String, String) -> Void)?

    init(library: LibraryController, backend: SharingBackend, store: SharedAlbumsStore, notifications: MemoryNotificationCenter) {
        self.library = library
        self.backend = backend
        self.store = store
        self.notifications = notifications
        albums = store.load()
        library.sharedPictures = store
        library.setSharedAlbums(albums.filter { !$0.isMine })
        backend.onReceive = { [weak self] in self?.received($0) }
        backend.onGone = { [weak self] in self?.gone($0) }
        backend.onUpdate = { [weak self] in self?.replace($0) }
        backend.onStatus = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .sharingDidChange, object: self)
        }
        observer = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    func start() { backend.start() }

    var status: SharingStatus { backend.status }
    var mine: [SharedAlbum] { albums.filter(\.isMine) }
    var sharedWithMe: [SharedAlbum] { albums.filter { !$0.isMine } }

    /// What's shared of an album of yours, if it's shared.
    func mine(_ album: UUID) -> SharedAlbum? { albums.first { $0.isMine && $0.id == album } }
    func sharedWithMe(_ album: UUID) -> SharedAlbum? { albums.first { !$0.isMine && $0.id == album } }

    // MARK: Sharing your albums

    /// An album of yours as it would be shared now: its photos in the order it shows them, from the library.
    private func current(_ albumID: UUID, previous: SharedAlbum?) -> SharedAlbum? {
        guard let album = library.catalog.album(albumID), let me = status.me else { return nil }
        let arranger = library.arranger
        let present = album.items.filter(library.snapshot.inLibrary)
        let ordered = album.order == .custom ? present : arranger.sorted(present, by: .dateTaken, ascending: album.order != .newestFirst)
        return SharedAlbum.sharing(album, items: ordered.compactMap(library.snapshot.item), catalog: library.catalog,
                                   cover: arranger.cover(of: album), owner: me, handwriting: Handwriting.family, previous: previous)
    }

    /// Shares an album of yours with the people you choose, or with anyone who has its link.
    func share(_ albumID: UUID, access: ShareAccess, completion: @escaping (Error?) -> Void) {
        guard var album = current(albumID, previous: mine(albumID)) else {
            completion(SharingError.unavailable(Self.reason(status)))
            return
        }
        album.access = access
        publish(album, completion: completion)
    }

    private func publish(_ album: SharedAlbum, completion: ((Error?) -> Void)? = nil) {
        publishing.insert(album.id)
        let library = library
        backend.publish(album, picture: { item in await library.exportOriginal(item.source) }) { [weak self] result in
            guard let self else { return }
            publishing.remove(album.id)
            switch result {
            case let .success(shared):
                replace(shared)
                completion?(nil)
                // Changed again while it was being sent.
                scheduleSync()
            case let .failure(error):
                if let completion {
                    completion(error)
                } else {
                    reportProblem?("“\(album.title)” couldn’t be brought up to date for the people it’s shared with.", error.localizedDescription)
                }
            }
        }
    }

    func setAccess(_ access: ShareAccess, of album: UUID, completion: @escaping (Error?) -> Void) {
        backend.setAccess(access, of: album) { [weak self] result in self?.finish(result, completion) }
    }

    func invite(_ address: String, to album: UUID, completion: @escaping (Error?) -> Void) {
        backend.invite(address, to: album) { [weak self] result in self?.finish(result, completion) }
    }

    func showInvitation(for album: UUID, relativeTo view: NSView) { backend.showInvitation(for: album, relativeTo: view) }

    func remove(_ participant: ShareParticipant, from album: UUID, completion: @escaping (Error?) -> Void) {
        backend.remove(participant, from: album) { [weak self] result in self?.finish(result, completion) }
    }

    /// Stops sharing an album of yours. The album stays yours; it goes from everyone it was shared with.
    func stopSharing(_ album: UUID, completion: @escaping (Error?) -> Void) {
        backend.stopSharing(album) { [weak self] error in
            if error == nil { self?.forget(album, mine: true) }
            completion(error)
        }
    }

    /// Puts an album's link on the clipboard.
    @discardableResult
    func copyLink(_ album: UUID) -> Bool {
        guard let url = mine(album)?.url ?? sharedWithMe(album)?.url else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        return true
    }

    private func finish(_ result: Result<SharedAlbum, Error>, _ completion: (Error?) -> Void) {
        switch result {
        case let .success(album):
            replace(album)
            completion(nil)
        case let .failure(error):
            completion(error)
        }
    }

    /// Brings what's shared of each album of yours up to date with the album, a moment after the library or catalog
    /// changes, so a run of changes goes as one.
    private func scheduleSync() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func sync() {
        guard library.hasLoaded else { return }
        for shared in mine where !publishing.contains(shared.id) {
            guard let now = current(shared.id, previous: shared), !now.sameContent(as: shared) else { continue }
            publish(now)
        }
    }

    // MARK: Albums shared with you

    private func received(_ album: SharedAlbum) {
        let old = sharedWithMe(album.id)
        replace(album)
        let notice = old.map { SharedAlbumNotice.added(from: $0, to: album, formatting: library.formatting) }
            ?? SharedAlbumNotice.shared(album, formatting: library.formatting)
        if old != nil { store.removePictures(of: album.id, keeping: album.items) }
        if let notice {
            let picture = (album.items.first { $0.id == album.cover } ?? album.items.first { !$0.kind.isVideo })
                .map { store.pictureURL(album: album.id, item: $0) }
            notifications.showSharedAlbum(notice, image: picture)
        }
    }

    /// Leaves an album shared with you: it goes, pictures and all.
    func leave(_ album: UUID, completion: @escaping (Error?) -> Void) {
        backend.leave(album) { [weak self] error in
            if error == nil { self?.forget(album, mine: false) }
            completion(error)
        }
    }

    /// Joins an album shared with you from the link its owner sent, answering once it's here. It's opened at once, so
    /// no notification says it's come.
    func accept(_ metadata: CKShare.Metadata, completion: @escaping (Result<UUID, Error>) -> Void) {
        guard let cloud = backend as? CloudKitSharing else {
            completion(.failure(SharingError.unavailable(Self.reason(status))))
            return
        }
        cloud.accept(metadata) { [weak self] result in
            switch result {
            case let .success(album):
                self?.replace(album)
                completion(.success(album.id))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    /// A push from iCloud, which may say something shared has changed.
    func receivedPush(_ userInfo: [String: Any]) {
        (backend as? CloudKitSharing)?.receivedPush(userInfo)
    }

    private func gone(_ album: UUID) {
        forget(album, mine: sharedWithMe(album) == nil)
    }

    private func forget(_ album: UUID, mine: Bool) {
        albums.removeAll { $0.id == album && $0.isMine == mine }
        if !mine { store.removePictures(of: album) }
        changed(touchesLibrary: !mine)
    }

    // MARK: Keeping them

    private func replace(_ album: SharedAlbum) {
        if let index = albums.firstIndex(where: { $0.id == album.id && $0.isMine == album.isMine }) {
            albums[index] = album
        } else {
            albums.append(album)
        }
        changed(touchesLibrary: !album.isMine)
    }

    private func changed(touchesLibrary: Bool) {
        do {
            try store.save(albums)
        } catch {
            reportProblem?("Shared albums couldn’t be saved.", error.localizedDescription)
        }
        if touchesLibrary { library.setSharedAlbums(sharedWithMe) }
        NotificationCenter.default.post(name: .sharingDidChange, object: self)
    }

    static func reason(_ status: SharingStatus) -> String {
        if case let .unavailable(reason) = status { return reason }
        return "The album couldn’t be shared."
    }
}
