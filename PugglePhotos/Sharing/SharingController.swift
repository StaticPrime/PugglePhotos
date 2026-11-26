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
    private let defaults: UserDefaults
    /// Yours and those shared with you.
    private(set) var albums: [SharedAlbum]
    private var observers: [NSObjectProtocol] = []
    private var syncWork: DispatchWorkItem?
    /// Albums of yours being sent now, which aren't sent again until that's done.
    private var publishing: Set<UUID> = []
    /// Albums of yours whose last send, made as they changed, failed, with why. They aren't sent again at every
    /// change, so the person is told once, but when PugglePhotos next comes to the front, by when they may have made
    /// room in iCloud, say.
    private var stalled: [UUID: String] = [:]
    /// Albums whose sharing sheet closed while they were still being sent for the first time: they aren't to be
    /// shared after all.
    private var abandoned: Set<UUID> = []
    /// Albums being taken back out of iCloud.
    private var discarding: Set<UUID> = []
    /// Shows a problem to the person; the window controller sets this.
    var reportProblem: ((String, String) -> Void)?

    init(library: LibraryController, backend: SharingBackend, store: SharedAlbumsStore, notifications: MemoryNotificationCenter,
         defaults: UserDefaults = .standard) {
        self.library = library
        self.backend = backend
        self.store = store
        self.notifications = notifications
        self.defaults = defaults
        albums = store.load()
        library.sharedPictures = store
        library.setSharedAlbums(albums.filter { !$0.isMine })
        backend.onReceive = { [weak self] in self?.received($0) }
        backend.onGone = { [weak self] in self?.gone($0) }
        backend.onUpdate = { [weak self] in self?.replace($0) }
        backend.onStatus = { [weak self] in
            guard let self else { return }
            sweepUnfinished()
            NotificationCenter.default.post(name: .sharingDidChange, object: self)
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .libraryDidChange, object: library, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryStalled() }
            },
        ]
    }

    func start() {
        backend.start()
        sweepUnfinished()
    }

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

    /// How much of the person's iCloud storage an album of theirs takes at full size, or will once it's shared; nil
    /// unless every photo's size is known.
    func size(of albumID: UUID) async -> Int64? {
        guard let album = library.catalog.album(albumID) else { return nil }
        return await library.originalSize(of: album.items.filter(library.snapshot.inLibrary))
    }

    /// Shares an album of yours with the people you choose, or with anyone who has its link.
    func share(_ albumID: UUID, access: ShareAccess, completion: @escaping (Error?) -> Void) {
        guard !discarding.contains(albumID) else {
            completion(SharingError.failed("What was sent of it before is still being taken out of iCloud. Try again in a moment."))
            return
        }
        guard var album = current(albumID, previous: mine(albumID)) else {
            completion(SharingError.unavailable(Self.reason(status)))
            return
        }
        album.access = access
        abandoned.remove(albumID)
        publish(album, completion: completion)
    }

    /// Sends an album of yours. Sharing it the first time, it's noted as unfinished until it's shared, so that what's
    /// sent of it can be taken back out of iCloud if it never is (when PugglePhotos quits partway, say). A first send
    /// that fills up iCloud is taken out again at once: the room is more use to the person than half an album.
    private func publish(_ album: SharedAlbum, completion: ((Error?) -> Void)? = nil) {
        let first = mine(album.id) == nil
        if first { unfinished.insert(album.id) }
        publishing.insert(album.id)
        let library = library
        backend.publish(album, picture: { item in await library.exportOriginal(item.source) }) { [weak self] result in
            guard let self else { return }
            publishing.remove(album.id)
            switch result {
            case let .success(shared):
                if first, abandoned.remove(album.id) != nil {
                    // Its sheet closed before it was done: it isn't to be shared after all.
                    backend.stopSharing(album.id) { [weak self] error in if error == nil { self?.unfinished.remove(album.id) } }
                    return
                }
                unfinished.remove(album.id)
                stalled[album.id] = nil
                replace(shared)
                completion?(nil)
                // Changed again while it was being sent.
                scheduleSync()
            case let .failure(error):
                Task {
                    let full = Self.isStorageFull(error)
                    let reason = await self.words(for: error, sending: album, first: first)
                    if first, full || self.abandoned.contains(album.id) { self.discard(album.id) }
                    if let completion {
                        completion(SharingError.failed(reason))
                    } else if self.stalled[album.id] == nil {
                        self.stalled[album.id] = reason
                        NotificationCenter.default.post(name: .sharingDidChange, object: self)
                        self.reportProblem?("“\(album.title)” couldn’t be brought up to date for the people it’s shared with.",
                                            full ? reason : reason + " It’ll be tried again when PugglePhotos next comes to the front.")
                    }
                }
            }
        }
    }

    private static func isStorageFull(_ error: Error) -> Bool {
        if case .storageFull? = error as? SharingError { return true }
        return false
    }

    /// What to tell the person about a send that failed. When iCloud filled up: how much room the album needs, and,
    /// the first time it's shared, how much went up before it filled, the best measure there is of the room there was.
    private func words(for error: Error, sending album: SharedAlbum, first: Bool) async -> String {
        guard case let .storageFull(stored)? = error as? SharingError else { return error.localizedDescription }
        let sources = { (items: [SharedItem]) in items.compactMap(\.source) }
        if first {
            let needed = await library.originalSize(of: sources(album.items))
            let fit = await library.originalSize(of: sources(album.items.filter { stored.contains($0.id) }))
            return SharingSpace.full(title: album.title, needed: needed, fit: fit)
        }
        return SharingSpace.fullUpdating(remaining: await library.originalSize(of: sources(album.items.filter { !stored.contains($0.id) })))
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
    /// changes, so a run of changes goes as one. Albums whose last send failed wait to be tried again.
    private func scheduleSync() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func sync() {
        guard library.hasLoaded else { return }
        for shared in mine where !publishing.contains(shared.id) && stalled[shared.id] == nil {
            guard let now = current(shared.id, previous: shared), !now.sameContent(as: shared) else { continue }
            publish(now)
        }
    }

    /// Why an album of yours isn't up to date for the people it's shared with, while it isn't.
    func stallReason(_ album: UUID) -> String? { stalled[album] }

    /// Sends again the albums of yours whose last send failed, with whatever's changed since. When PugglePhotos comes
    /// to the front, as the person may have made room in iCloud meanwhile; if it fails again, they've been told.
    func retryStalled() {
        for id in Array(stalled.keys) where !publishing.contains(id) {
            guard let shared = mine(id) else {
                stalled[id] = nil
                continue
            }
            if let now = current(id, previous: shared) { publish(now) }
        }
    }

    // MARK: Albums that didn't get shared

    /// Albums of yours on their way to being shared for the first time, or that stopped partway and haven't been taken
    /// back out of iCloud yet. Kept between launches, so what was sent of one that never got shared can't be forgotten
    /// there.
    private var unfinished: Set<UUID> {
        get { Set((defaults.stringArray(forKey: "SharingUnfinished") ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: "SharingUnfinished") }
    }

    var unfinishedAlbums: Set<UUID> { unfinished }

    /// The sharing sheet for an album of yours closed without it being shared: whatever was sent of it is taken back
    /// out of iCloud, once a send still going has finished.
    func abandon(_ album: UUID) {
        guard mine(album) == nil, unfinished.contains(album) else { return }
        if publishing.contains(album) { abandoned.insert(album) } else { discard(album) }
    }

    /// Takes what was sent of an album of yours that didn't get shared back out of iCloud. It stays unfinished until
    /// that's done, so a failure is tried again when PugglePhotos next opens.
    private func discard(_ album: UUID) {
        abandoned.remove(album)
        guard !discarding.contains(album) else { return }
        discarding.insert(album)
        backend.discard(album) { [weak self] error in
            guard let self else { return }
            discarding.remove(album)
            if error == nil { unfinished.remove(album) }
        }
    }

    /// Takes out of iCloud what was sent of albums that never got shared: one whose sending stopped when PugglePhotos
    /// last quit, say. Once iCloud can be reached.
    private func sweepUnfinished() {
        guard status.me != nil else { return }
        for album in unfinished where mine(album) == nil && !publishing.contains(album) { discard(album) }
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

    /// Joins an album shared with you from its link alone, as `accept(_:completion:)` does with what macOS hands over
    /// when the link is clicked. A copy of PugglePhotos that updates itself as it opens hands the new version the link.
    func accept(link: URL, completion: @escaping (Result<UUID, Error>) -> Void) {
        guard let cloud = backend as? CloudKitSharing else {
            completion(.failure(SharingError.unavailable(Self.reason(status))))
            return
        }
        cloud.accept(link: link) { [weak self] result in
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
        if mine { stalled[album] = nil }
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
