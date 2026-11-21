import AppKit
import CloudKit
import ImageIO
import PugglePhotosKit
import Security
import UniformTypeIdentifiers

/// Shared albums through iCloud. Each album of yours that's shared is a zone of its own in your private database,
/// shared whole: a record for the album and one for each photo or video, holding its original file (see
/// `SharedAlbumRecords`). People join through the system's invitation, and the photos count against your iCloud
/// storage. Albums shared with you are read from your shared database, their pictures downloaded to where the store
/// keeps them, and read again whenever iCloud says they've changed: through a push while PugglePhotos is open, and
/// whenever it opens or comes to the front.
final class CloudKitSharing: NSObject, SharingBackend {
    nonisolated static let containerIdentifier = "iCloud.com.pugglesoft.PugglePhotos"

    /// Whether this copy of PugglePhotos is signed to use the iCloud container shared albums are kept in. Without
    /// that, iCloud mustn't be touched at all: CloudKit stops an app asking for a container it isn't signed for.
    nonisolated static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerIdentifier) == true
    }

    /// Made only once sharing starts, so nothing reaches for iCloud before it's known to be allowed.
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private let store: SharedAlbumsStore
    private let defaults: UserDefaults
    var onReceive: ((SharedAlbum) -> Void)?
    var onGone: ((UUID) -> Void)?
    var onUpdate: ((SharedAlbum) -> Void)?
    var onStatus: (() -> Void)?
    private(set) var status: SharingStatus = .unavailable("Checking iCloud…")
    var invitesThroughSystem: Bool { true }

    /// Albums of yours as last shared, for keeping who's in them up to date.
    private var mine: [UUID: SharedAlbum] = [:]
    /// The shares of albums of yours, as last read or saved.
    private var shares: [UUID: CKShare] = [:]
    /// What iCloud holds of each album of yours: each photo's record, as `SharedAlbumRecords.itemInfo` gives it, and
    /// the album's own record. Read from iCloud the first time an album is sent after PugglePhotos opens.
    private var sentItems: [UUID: [UUID: Data]] = [:]
    private var sentAlbums: [UUID: Data] = [:]
    /// Where each album shared with you is in the shared database.
    private var sharedZones: [UUID: CKRecordZone.ID] = [:]
    private var isFetching = false
    private var fetchesAgain = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    /// The system's invitation while it shows, and the album it's for.
    private var picker: NSSharingServicePicker?
    private var invitingAlbum: UUID?

    init(store: SharedAlbumsStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    // MARK: Starting and keeping up

    func start() {
        for album in store.load() where album.isMine { mine[album.id] = album }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkAccount() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetchChanges() }
            },
        ]
        // Pushes can go astray; a look every quarter of an hour catches what they miss.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchChanges() }
        }
        NSApp.registerForRemoteNotifications()
        checkAccount()
    }

    private func checkAccount() {
        Task {
            let status = await accountStatus()
            if status.me?.id != self.status.me?.id {
                // Another iCloud account: what was known of the last one's albums is no longer so.
                mine = [:]
                shares = [:]
                sentItems = [:]
                sentAlbums = [:]
                sharedZones = [:]
                if status.me != nil { for album in store.load() where album.isMine { mine[album.id] = album } }
            }
            if status != self.status {
                self.status = status
                onStatus?()
            }
            guard let me = status.me else { return }
            await subscribe(as: me)
            fetchChanges()
        }
    }

    private func accountStatus() async -> SharingStatus {
        do {
            switch try await container.accountStatus() {
            case .available:
                let id = (try? await container.userRecordID())?.recordName ?? "me"
                return .ready(me: ShareParticipant(id: id, name: NSFullUserName(), isOwner: true))
            case .noAccount:
                return .unavailable("Sign in to iCloud in System Settings to share albums.")
            case .restricted:
                return .unavailable("iCloud is restricted on this Mac, so albums can’t be shared.")
            case .temporarilyUnavailable:
                return .unavailable("iCloud needs your attention in System Settings before albums can be shared.")
            default:
                return .unavailable("iCloud can’t be reached right now.")
            }
        } catch {
            return .unavailable("iCloud can’t be reached right now.")
        }
    }

    /// Asks iCloud to send a push whenever an album shared with you changes, or someone joins one of yours.
    private func subscribe(as me: ShareParticipant) async {
        let key = "SharingSubscribed-\(me.id)"
        guard !defaults.bool(forKey: key) else { return }
        do {
            for (database, name) in [(container.sharedCloudDatabase, "shared-with-you"), (container.privateCloudDatabase, "yours-shared")] {
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                let subscription = CKDatabaseSubscription(subscriptionID: name)
                subscription.notificationInfo = info
                let result = try await database.modifySubscriptions(saving: [subscription], deleting: [])
                _ = try result.saveResults[name]?.get()
            }
            defaults.set(true, forKey: key)
        } catch {
            // Asked again next time PugglePhotos opens; changes are looked for whenever it comes to the front.
        }
    }

    /// A push from iCloud: something shared has changed.
    func receivedPush(_ userInfo: [String: Any]) {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              note.containerIdentifier == Self.containerIdentifier else { return }
        fetchChanges()
    }

    /// Reads what's changed in iCloud since last time: albums shared with you, and who's in yours.
    func fetchChanges() {
        guard status.me != nil else { return }
        guard !isFetching else {
            fetchesAgain = true
            return
        }
        isFetching = true
        Task {
            await fetchShared()
            await fetchMine()
            isFetching = false
            if fetchesAgain {
                fetchesAgain = false
                fetchChanges()
            }
        }
    }

    /// The zones changed and deleted in a database since `token`, and the token to read on from next time.
    private func changes(in database: CKDatabase, since token: CKServerChangeToken?) async throws
        -> (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: CKServerChangeToken) {
        var changed: [CKRecordZone.ID] = []
        var deleted: [CKRecordZone.ID] = []
        var token = token
        while true {
            let result = try await database.databaseChanges(since: token)
            changed += result.modifications.map(\.zoneID)
            deleted += result.deletions.map(\.zoneID)
            token = result.changeToken
            if !result.moreComing { return (changed.filter { !deleted.contains($0) }, deleted, result.changeToken) }
        }
    }

    private func token(_ name: String) -> CKServerChangeToken? {
        guard let me = status.me, let data = defaults.data(forKey: "SharingToken-\(name)-\(me.id)") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func setToken(_ token: CKServerChangeToken?, _ name: String) {
        guard let me = status.me else { return }
        let key = "SharingToken-\(name)-\(me.id)"
        if let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Albums shared with you

    private func fetchShared() async {
        let since = token("shared")
        // Kept here before looking: one that comes meanwhile, from its link, isn't missing.
        let known = Set(store.load().filter { !$0.isMine }.map(\.id))
        let found: (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: CKServerChangeToken)
        do {
            found = try await changes(in: container.sharedCloudDatabase, since: since)
        } catch let error as CKError where error.code == .changeTokenExpired {
            setToken(nil, "shared")
            fetchesAgain = true
            return
        } catch {
            return
        }
        for zone in found.deleted {
            guard let id = SharedAlbumRecords.album(inZone: zone.zoneName) else { continue }
            sharedZones[id] = nil
            onGone?(id)
        }
        var complete = true
        for zone in found.changed {
            guard let id = SharedAlbumRecords.album(inZone: zone.zoneName) else { continue }
            sharedZones[id] = zone
            do {
                let (album, whole) = try await read(zone, album: id)
                onReceive?(album)
                complete = complete && whole
            } catch {
                complete = false
            }
        }
        if since == nil {
            // Read from the start: an album kept here that iCloud no longer shares with you has gone.
            let present = Set(found.changed.compactMap { SharedAlbumRecords.album(inZone: $0.zoneName) })
            for id in known.subtracting(present) { onGone?(id) }
        }
        // An album that couldn't be read whole, or whose pictures didn't all come, is read again next time.
        if complete { setToken(found.token, "shared") }
    }

    /// An album shared with you, read from its zone, with the pictures not yet on this Mac downloaded, and whether
    /// they all came. A photo whose picture didn't come is left out until it does.
    private func read(_ zone: CKRecordZone.ID, album id: UUID) async throws -> (album: SharedAlbum, whole: Bool) {
        let database = container.sharedCloudDatabase
        var info: Data?
        var items: [UUID: Data] = [:]
        var share: CKShare?
        var token: CKServerChangeToken?
        while true {
            let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token, desiredKeys: [SharedAlbumRecords.infoKey])
            for case let .success(modification) in changes.modificationResultsByID.values {
                let record = modification.record
                if let record = record as? CKShare {
                    share = record
                } else if record.recordType == SharedAlbumRecords.albumType {
                    info = record[SharedAlbumRecords.infoKey] as? Data
                } else if record.recordType == SharedAlbumRecords.itemType, let item = UUID(uuidString: record.recordID.recordName) {
                    items[item] = record[SharedAlbumRecords.infoKey] as? Data
                }
            }
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        if share == nil { share = try await database.record(for: Self.shareID(in: zone)) as? CKShare }
        let people = share.map(participants(of:)) ?? []
        guard let info, let share,
              var album = SharedAlbumRecords.album(id: id, info: info, items: items,
                                                   owner: people.first(where: \.isOwner) ?? ShareParticipant(id: "owner", name: "", isOwner: true),
                                                   participants: people, access: Self.access(of: share), url: share.url)
        else { throw SharingError.failed("The album hasn’t all come from iCloud yet.") }
        let store = store
        let missing = album.items.filter { !FileManager.default.fileExists(atPath: store.pictureURL(album: id, item: $0).path) }
        for batch in missing.batches(of: 8) {
            let results = try await database.records(for: batch.map { Self.recordID(of: $0.id, in: zone) },
                                                      desiredKeys: [SharedAlbumRecords.originalKey])
            for item in batch {
                guard case let .success(record)? = results[Self.recordID(of: item.id, in: zone)],
                      let file = (record[SharedAlbumRecords.originalKey] as? CKAsset)?.fileURL else { continue }
                try? await Self.copy(file, to: store.pictureURL(album: id, item: item))
            }
        }
        let count = album.items.count
        album.items.removeAll { !FileManager.default.fileExists(atPath: store.pictureURL(album: id, item: $0).path) }
        return (album, album.items.count == count)
    }

    /// Joins an album someone shared with you, from the link they sent, and answers with it, its pictures here.
    func accept(_ metadata: CKShare.Metadata, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        Task {
            do {
                let zone = metadata.share.recordID.zoneID
                guard metadata.containerIdentifier == Self.containerIdentifier, let id = SharedAlbumRecords.album(inZone: zone.zoneName) else {
                    throw SharingError.failed("That link isn’t to an album shared from PugglePhotos.")
                }
                guard metadata.participantRole != .owner else {
                    throw SharingError.failed("“\(metadata.share[CKShare.SystemFieldKey.title] as? String ?? "That album")” is yours: it’s under Shared Albums in the sidebar.")
                }
                if metadata.participantStatus != .accepted { _ = try await container.accept(metadata) }
                sharedZones[id] = zone
                completion(.success(try await read(zone, album: id).album))
            } catch {
                completion(.failure(Self.problem(error)))
            }
        }
    }

    /// Leaves an album shared with you: taking its share from your shared database takes you out of it.
    func leave(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        Task {
            do {
                if let zone = try await sharedZone(of: album) {
                    let database = container.sharedCloudDatabase
                    do {
                        let result = try await database.modifyRecords(saving: [], deleting: [Self.shareID(in: zone)])
                        try result.deleteResults[Self.shareID(in: zone)]?.get()
                    } catch {
                        let result = try await database.modifyRecordZones(saving: [], deleting: [zone])
                        try result.deleteResults[zone]?.get()
                    }
                }
                sharedZones[album] = nil
                completion(nil)
            } catch {
                completion(Self.problem(error))
            }
        }
    }

    private func sharedZone(of album: UUID) async throws -> CKRecordZone.ID? {
        if let zone = sharedZones[album] { return zone }
        for zone in try await container.sharedCloudDatabase.allRecordZones() {
            if let id = SharedAlbumRecords.album(inZone: zone.zoneID.zoneName) { sharedZones[id] = zone.zoneID }
        }
        return sharedZones[album]
    }

    // MARK: Albums of yours, shared

    /// Who's in each album of yours as iCloud now says, and whether any has stopped being shared elsewhere.
    private func fetchMine() async {
        let database = container.privateCloudDatabase
        let since = token("private")
        // Shared before looking: one shared for the first time meanwhile isn't missing.
        let known = Set(mine.keys)
        let found: (changed: [CKRecordZone.ID], deleted: [CKRecordZone.ID], token: CKServerChangeToken)
        do {
            found = try await changes(in: database, since: since)
        } catch let error as CKError where error.code == .changeTokenExpired {
            setToken(nil, "private")
            fetchesAgain = true
            return
        } catch {
            return
        }
        for zone in found.deleted {
            guard let id = SharedAlbumRecords.album(inZone: zone.zoneName), mine[id] != nil else { continue }
            forgetMine(id)
            onGone?(id)
        }
        for zone in found.changed {
            guard let id = SharedAlbumRecords.album(inZone: zone.zoneName), let shared = mine[id] else { continue }
            shares[id] = nil
            guard (try? await existingShare(of: id)) != nil else { continue }
            let now = updated(shared)
            if now != shared { onUpdate?(now) }
        }
        if since == nil {
            // Read from the start: an album of yours that iCloud no longer holds stopped being shared elsewhere.
            let present = Set(found.changed.compactMap { SharedAlbumRecords.album(inZone: $0.zoneName) })
            for id in known.subtracting(present) where mine[id] != nil {
                forgetMine(id)
                onGone?(id)
            }
        }
        setToken(found.token, "private")
    }

    func publish(_ album: SharedAlbum, picture: @escaping @MainActor (SharedItem) async -> URL?,
                 completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        Task {
            do {
                completion(.success(try await send(album, picture: picture)))
            } catch where Self.isStorageFull(error) {
                // What went up before iCloud filled is known, for the person to be told how much room there was.
                completion(.failure(SharingError.storageFull(stored: Set((sentItems[album.id] ?? [:]).keys))))
            } catch {
                completion(.failure(Self.problem(error)))
            }
        }
    }

    /// Whether iCloud turned something down for want of room in the person's storage.
    private nonisolated static func isStorageFull(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .quotaExceeded { return true }
        return error.code == .partialFailure
            && (error.partialErrorsByItemID?.values.contains { ($0 as? CKError)?.code == .quotaExceeded } ?? false)
    }

    /// Brings what iCloud holds of an album of yours up to date: photos new to it go with their files, a few at a time,
    /// and those whose captions or notes changed go again without them. Then the album's own record, which says which
    /// photos are in it and in what order, so the people it's shared with see photos only once they've come, with
    /// those taken out of it deleted; then its share, made the first time.
    private func send(_ album: SharedAlbum, picture: @escaping @MainActor (SharedItem) async -> URL?) async throws -> SharedAlbum {
        let database = container.privateCloudDatabase
        let zone = Self.zone(of: album.id)
        if sentItems[album.id] == nil { try await prepare(zone, for: album.id) }
        var sent = sentItems[album.id] ?? [:]
        var thumbnail: Data?
        let thumbnailItem = album.cover ?? album.items.first?.id
        for batch in album.items.filter({ sent[$0.id] != SharedAlbumRecords.itemInfo($0) }).batches(of: 8) {
            var records: [CKRecord] = []
            var files: [URL] = []
            defer { for file in files { try? FileManager.default.removeItem(at: file) } }
            for item in batch {
                let record = CKRecord(recordType: SharedAlbumRecords.itemType, recordID: Self.recordID(of: item.id, in: zone))
                record[SharedAlbumRecords.infoKey] = SharedAlbumRecords.itemInfo(item)
                if sent[item.id] == nil {
                    guard let file = await picture(item) else {
                        throw SharingError.failed("“\(item.fileName ?? "A photo")” couldn’t be read from the Photos library to share.")
                    }
                    files.append(file)
                    record[SharedAlbumRecords.originalKey] = CKAsset(fileURL: file)
                    if item.id == thumbnailItem, !item.kind.isVideo { thumbnail = await Self.thumbnail(of: file) }
                }
                records.append(record)
            }
            try await save(records, in: database)
            for item in batch { sent[item.id] = SharedAlbumRecords.itemInfo(item) }
            sentItems[album.id] = sent
        }
        let gone = Set(sent.keys).subtracting(album.items.map(\.id))
        let info = SharedAlbumRecords.albumInfo(album)
        if sentAlbums[album.id] != info || !gone.isEmpty {
            let record = CKRecord(recordType: SharedAlbumRecords.albumType,
                                  recordID: CKRecord.ID(recordName: SharedAlbumRecords.albumName, zoneID: zone))
            record[SharedAlbumRecords.infoKey] = info
            try await save([record], deleting: gone.map { Self.recordID(of: $0, in: zone) }, in: database)
            sentAlbums[album.id] = info
            for id in gone { sent[id] = nil }
            sentItems[album.id] = sent
        }
        let permission = Self.permission(album.access)
        let existing = try await existingShare(of: album.id)
        if existing == nil || existing?[CKShare.SystemFieldKey.title] as? String != album.title || existing?.publicPermission != permission {
            try await changeShare(of: album.id, creating: true) { share in
                share[CKShare.SystemFieldKey.title] = album.title
                share.publicPermission = permission
                if let thumbnail { share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail }
            }
        }
        mine[album.id] = album
        return updated(album)
    }

    /// Before an album of yours is first sent since PugglePhotos opened: its zone, made if it's new, and what's in it
    /// already, so only what's changed is sent.
    private func prepare(_ zone: CKRecordZone.ID, for album: UUID) async throws {
        let database = container.privateCloudDatabase
        let made = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
        _ = try made.saveResults[zone]?.get()
        var items: [UUID: Data] = [:]
        var token: CKServerChangeToken?
        while true {
            let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token, desiredKeys: [SharedAlbumRecords.infoKey])
            for case let .success(modification) in changes.modificationResultsByID.values {
                let record = modification.record
                if let share = record as? CKShare {
                    shares[album] = share
                } else if record.recordType == SharedAlbumRecords.albumType {
                    sentAlbums[album] = record[SharedAlbumRecords.infoKey] as? Data
                } else if record.recordType == SharedAlbumRecords.itemType, let id = UUID(uuidString: record.recordID.recordName),
                          let info = record[SharedAlbumRecords.infoKey] as? Data {
                    items[id] = info
                }
            }
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        sentItems[album] = items
    }

    /// Saves records, only the fields set on them, so a photo's file stays when what's said about it changes; a
    /// batch iCloud finds too big goes in halves.
    private func save(_ records: [CKRecord], deleting: [CKRecord.ID] = [], in database: CKDatabase) async throws {
        do {
            let result = try await retrying {
                try await database.modifyRecords(saving: records, deleting: deleting, savePolicy: .changedKeys, atomically: false)
            }
            for outcome in result.saveResults.values { _ = try outcome.get() }
            for outcome in result.deleteResults.values {
                do {
                    try outcome.get()
                } catch let error as CKError where error.code == .unknownItem {
                    // Gone already.
                }
            }
        } catch let error as CKError where error.code == .limitExceeded && records.count > 1 {
            try await save(Array(records[..<(records.count / 2)]), deleting: deleting, in: database)
            try await save(Array(records[(records.count / 2)...]), in: database)
        }
    }

    /// The share of an album of yours, as last read or saved, else as iCloud holds it; nil if it has none.
    private func existingShare(of album: UUID) async throws -> CKShare? {
        if let share = shares[album] { return share }
        do {
            let share = try await container.privateCloudDatabase.record(for: Self.shareID(in: Self.zone(of: album))) as? CKShare
            shares[album] = share
            return share
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Changes the share of an album of yours and saves it, making it first if `creating`. A share changed in iCloud
    /// meanwhile (someone joined, say) is read again and changed afresh.
    @discardableResult
    private func changeShare(of album: UUID, creating: Bool = false, _ change: (CKShare) -> Void) async throws -> CKShare {
        for attempt in 0..<2 {
            if attempt > 0 { shares[album] = nil }
            let share: CKShare
            if let existing = try await existingShare(of: album) {
                share = existing
            } else if creating {
                share = CKShare(recordZoneID: Self.zone(of: album))
            } else {
                throw SharingError.notShared
            }
            change(share)
            do {
                let result = try await retrying { try await self.container.privateCloudDatabase.modifyRecords(saving: [share], deleting: []) }
                guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else { break }
                shares[album] = saved
                return saved
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                continue
            }
        }
        throw SharingError.failed("The album’s sharing couldn’t be changed. Try again in a little while.")
    }

    /// An album of yours as it's now shared: who's in it, how, and its link, from its share.
    private func updated(_ album: SharedAlbum) -> SharedAlbum {
        var album = album
        if let share = shares[album.id] {
            album.participants = participants(of: share)
            album.access = Self.access(of: share)
            album.url = share.url
        }
        mine[album.id] = album
        return album
    }

    private func current(_ album: UUID) throws -> SharedAlbum {
        guard let shared = mine[album] else { throw SharingError.notShared }
        return updated(shared)
    }

    private func forgetMine(_ album: UUID) {
        mine[album] = nil
        shares[album] = nil
        sentItems[album] = nil
        sentAlbums[album] = nil
    }

    func setAccess(_ access: ShareAccess, of album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        run(completion) {
            try await self.changeShare(of: album) { $0.publicPermission = Self.permission(access) }
            return try self.current(album)
        }
    }

    /// Adds someone by their email address or phone number. They're told by the link, which the system's invitation
    /// sends; this is for when it isn't used.
    func invite(_ address: String, to album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        run(completion) {
            let person = address.contains("@") ? try await self.container.shareParticipant(forEmailAddress: address)
                                                : try await self.container.shareParticipant(forPhoneNumber: address)
            person.permission = .readOnly
            try await self.changeShare(of: album) { $0.addParticipant(person) }
            return try self.current(album)
        }
    }

    func remove(_ participant: ShareParticipant, from album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        run(completion) {
            try await self.changeShare(of: album) { share in
                for person in share.participants where person.role != .owner && Self.matches(person, participant) {
                    share.removeParticipant(person)
                }
            }
            return try self.current(album)
        }
    }

    /// Stops sharing an album of yours by deleting its zone: the share goes, and with it the album from everyone's Mac.
    func stopSharing(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        Task {
            do {
                let zone = Self.zone(of: album)
                let result = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zone])
                try result.deleteResults[zone]?.get()
            } catch let error as CKError where error.code == .zoneNotFound {
                // Not in iCloud already.
            } catch {
                completion(Self.problem(error))
                return
            }
            forgetMine(album)
            completion(nil)
        }
    }

    /// Takes back out of iCloud what was sent of an album of yours that never got shared, by deleting its zone, as
    /// stopping sharing does. Never an album that is shared.
    func discard(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        guard mine[album] == nil else { return completion(nil) }
        stopSharing(album, completion: completion)
    }

    private func run(_ completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void, _ work: @escaping () async throws -> SharedAlbum) {
        Task {
            do {
                completion(.success(try await work()))
            } catch {
                completion(.failure(Self.problem(error)))
            }
        }
    }

    // MARK: The system's invitation

    /// Shows the system's invitation to an album of yours, which sends its link by Messages, Mail or AirDrop, or
    /// copies it.
    func showInvitation(for album: UUID, relativeTo view: NSView) {
        Task {
            guard let share = try? await existingShare(of: album) else { return }
            let provider = NSItemProvider()
            let access: CKSharingParticipantAccessOption = share.publicPermission == .none ? .specifiedRecipientsOnly : .anyoneWithLink
            provider.registerCKShare(share, container: container,
                                     allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readOnly,
                                                                                    allowedParticipantAccessOptions: access))
            let picker = NSSharingServicePicker(items: [provider])
            picker.delegate = self
            self.picker = picker
            invitingAlbum = album
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
    }

    /// Reads an album's share again, once the invitation's been sent, to show who's been invited.
    private func refreshShare(of album: UUID) {
        Task {
            shares[album] = nil
            guard (try? await existingShare(of: album)) != nil, let shared = mine[album] else { return }
            onUpdate?(updated(shared))
        }
    }

    // MARK: Who's who

    /// Everyone in a share, the owner first.
    private func participants(of share: CKShare) -> [ShareParticipant] {
        let people = share.participants.compactMap { person($0, in: share) }
        return people.filter(\.isOwner) + people.filter { !$0.isOwner }
    }

    private func person(_ participant: CKShare.Participant, in share: CKShare) -> ShareParticipant? {
        guard participant.acceptanceStatus != .removed else { return nil }
        let identity = participant.userIdentity
        let isMe = participant == share.currentUserParticipant
        let name = identity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) } ?? ""
        let isOwner = participant.role == .owner
        return ShareParticipant(id: isMe ? (status.me?.id ?? Self.id(of: participant)) : Self.id(of: participant),
                                name: name.isEmpty && isMe ? (status.me?.name ?? "") : name,
                                address: identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber,
                                status: isOwner || participant.acceptanceStatus == .accepted ? .joined : .invited, isOwner: isOwner)
    }

    /// How someone in a share is known however their name shows: their iCloud identity, or the address they were
    /// invited at.
    private static func id(of participant: CKShare.Participant) -> String {
        let identity = participant.userIdentity
        if let record = identity.userRecordID?.recordName, record != CKCurrentUserDefaultName { return record }
        return identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber ?? identity.lookupInfo?.userRecordID?.recordName ?? "someone"
    }

    private static func matches(_ participant: CKShare.Participant, _ person: ShareParticipant) -> Bool {
        let lookup = participant.userIdentity.lookupInfo
        return id(of: participant) == person.id
            || (person.address != nil && (lookup?.emailAddress == person.address || lookup?.phoneNumber == person.address))
    }

    // MARK: Helpers

    private static func zone(of album: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SharedAlbumRecords.zoneName(of: album), ownerName: CKCurrentUserDefaultName)
    }

    private static func shareID(in zone: CKRecordZone.ID) -> CKRecord.ID { CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone) }

    private static func recordID(of item: UUID, in zone: CKRecordZone.ID) -> CKRecord.ID { CKRecord.ID(recordName: item.uuidString, zoneID: zone) }

    private static func permission(_ access: ShareAccess) -> CKShare.ParticipantPermission { access == .anyoneWithLink ? .readOnly : .none }

    private static func access(of share: CKShare) -> ShareAccess { share.publicPermission == .none ? .invited : .anyoneWithLink }

    /// Runs `work`, and once more after the pause iCloud asks for when it's busy or the network dropped.
    private func retrying<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as CKError where [.serviceUnavailable, .requestRateLimited, .zoneBusy, .networkFailure].contains(error.code) {
            try await Task.sleep(for: .seconds(error.retryAfterSeconds ?? 3))
            return try await work()
        }
    }

    /// Words for the person about what went wrong.
    nonisolated static func problem(_ error: Error) -> Error {
        guard let error = error as? CKError else { return error }
        switch error.code {
        case .notAuthenticated:
            return SharingError.failed("Sign in to iCloud in System Settings to share albums.")
        case .quotaExceeded:
            return SharingError.failed("Your iCloud storage is full. Shared albums are kept in it at full size, so free up some space, or choose more in System Settings.")
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return SharingError.failed("iCloud can’t be reached right now. Try again in a little while.")
        case .tooManyParticipants:
            return SharingError.failed("The album is shared with as many people as iCloud allows.")
        case .participantMayNeedVerification:
            return SharingError.failed("iCloud needs to check it’s you. Open the link again from the message it came in.")
        case .unknownItem, .zoneNotFound:
            return SharingError.notShared
        case .partialFailure:
            if let first = error.partialErrorsByItemID?.values.first { return problem(first) }
            return SharingError.failed(error.localizedDescription)
        default:
            return SharingError.failed(error.localizedDescription)
        }
    }

    /// Copies a downloaded picture to where the store keeps it, whole or not at all.
    @concurrent nonisolated private static func copy(_ file: URL, to destination: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? manager.removeItem(at: partial)
        try manager.copyItem(at: file, to: partial)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: partial, to: destination)
    }

    /// A small picture of the album for the system's invitation to show.
    @concurrent nonisolated private static func thumbnail(of file: URL) async -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension CloudKitSharing: NSSharingServicePickerDelegate, NSCloudSharingServiceDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { picker = nil }
    }

    // Nothing promises these three come on the main thread, and Swift stops the app if a main-actor method is called
    // on another. Whichever thread they come on, what they do is done on the main actor.

    nonisolated func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        let saved = ShareHandoff(share: share)
        Self.onMain { [weak self] in
            guard let self, let album = invitingAlbum, let shared = mine[album] else { return }
            shares[album] = saved.share
            onUpdate?(updated(shared))
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        Self.onMain { [weak self] in
            guard let self, let album = invitingAlbum else { return }
            stopSharing(album) { [weak self] error in
                if error == nil { self?.onGone?(album) }
            }
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: (any Error)?) {
        Self.onMain { [weak self] in
            guard let self else { return }
            picker = nil
            if let album = invitingAlbum { refreshShare(of: album) }
        }
    }

    /// Does work on the main actor: at once on the main thread, else as soon as the main thread is free.
    private nonisolated static func onMain(_ work: @escaping @Sendable @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        picker = nil
        if let album = invitingAlbum { refreshShare(of: album) }
    }
}

/// A share handed from whichever thread AppKit tells of it on to the main actor, the only place it's used.
private struct ShareHandoff: @unchecked Sendable {
    let share: CKShare
}

private extension Array {
    func batches(of size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
