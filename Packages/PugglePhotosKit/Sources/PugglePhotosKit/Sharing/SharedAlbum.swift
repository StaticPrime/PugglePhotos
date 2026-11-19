import Foundation

/// Someone a shared album is shared with, or the person who shares it.
public struct ShareParticipant: Hashable, Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Invited, and not yet joined.
        case invited
        case joined
    }

    /// Stays the same however their name shows: their iCloud identity, or the address they were invited at.
    public var id: String
    public var name: String
    /// The email address or phone number they were invited at, when it's known.
    public var address: String?
    public var status: Status
    public var isOwner: Bool

    public init(id: String, name: String, address: String? = nil, status: Status = .joined, isOwner: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.status = status
        self.isOwner = isOwner
    }

    /// Up to two initials, for the round badge beside their name: from their name, else their address.
    public var initials: String {
        let words = name.split { $0 == " " || $0 == "-" }.filter { $0.first?.isLetter == true }
        let letters = words.count > 1 ? [words.first!, words.last!].compactMap(\.first) : words.first.map { Array($0.prefix(1)) } ?? []
        if !letters.isEmpty { return String(letters).uppercased() }
        return (address?.first.map { String($0) } ?? "?").uppercased()
    }
}

/// Who can join a shared album: only the people invited, or anyone who has its link.
public enum ShareAccess: String, Codable, Sendable, CaseIterable {
    case invited, anyoneWithLink

    public var displayName: String {
        switch self {
        case .invited: "People You Choose"
        case .anyoneWithLink: "Anyone with the Link"
        }
    }
}

/// One photo or video in a shared album, as everyone it's shared with sees it.
public struct SharedItem: Hashable, Codable, Sendable, Identifiable {
    /// The same on every Mac the album is shared to.
    public var id: UUID
    public var kind: MediaKind
    public var date: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Seconds, for videos.
    public var duration: TimeInterval
    public var fileName: String?
    public var caption: String
    public var note: String
    /// The seed its place in the book comes from: the one it has in its owner's library, so it lies on the page,
    /// leans and keeps its sticky note just as it does in the owner's book.
    public var layoutSeed: UInt64
    /// On its owner's Mac, the library photo it is; nil anywhere else.
    public var source: PhotoID?

    public init(id: UUID = UUID(), kind: MediaKind, date: Date, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval = 0,
                fileName: String? = nil, caption: String = "", note: String = "", layoutSeed: UInt64, source: PhotoID? = nil) {
        self.id = id
        self.kind = kind
        self.date = date
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.fileName = fileName
        self.caption = caption
        self.note = note
        self.layoutSeed = layoutSeed
        self.source = source
    }
}

/// An album shared through iCloud: one of yours, still yours to change, or someone else's, yours to look at. It
/// carries the whole book: the photos and videos in the album's order, their captions and notes, the cover, the story,
/// and the book with its look, the photos' places on its pages, sticky notes and writing. Labels and the journal
/// stay with their owner.
public struct SharedAlbum: Identifiable, Hashable, Codable, Sendable {
    /// The owner's album's own identifier, the same on every Mac it's shared to.
    public var id: UUID
    public var title: String
    public var story: String
    public var created: Date
    /// When what's in it last changed.
    public var modified: Date
    /// In the album's order.
    public var items: [SharedItem]
    public var cover: UUID?
    /// The book, its photos named as `photoID(of:)` names them; nil for a book as it first comes.
    public var book: BookSettings?
    public var owner: ShareParticipant
    /// Everyone it's shared with, the owner first.
    public var participants: [ShareParticipant]
    public var access: ShareAccess
    /// The link that opens it, once there is one.
    public var url: URL?
    /// Whether it's yours, shared with others, or someone else's, shared with you.
    public var isMine: Bool

    public init(id: UUID, title: String, story: String = "", created: Date, modified: Date, items: [SharedItem], cover: UUID? = nil,
                book: BookSettings? = nil, owner: ShareParticipant, participants: [ShareParticipant] = [], access: ShareAccess = .invited,
                url: URL? = nil, isMine: Bool) {
        self.id = id
        self.title = title
        self.story = story
        self.created = created
        self.modified = modified
        self.items = items
        self.cover = cover
        self.book = book
        self.owner = owner
        self.participants = participants
        self.access = access
        self.url = url
        self.isMine = isMine
    }

    // MARK: Its photos, named apart from any library's

    static let prefix = "shared:"

    /// How a photo of a shared album is named on a Mac it's shared with, apart from every photo in that Mac's library.
    public func photoID(of item: SharedItem) -> PhotoID { Self.photoID(album: id, item: item.id) }

    public static func photoID(album: UUID, item: UUID) -> PhotoID { PhotoID("\(prefix)\(album.uuidString)/\(item.uuidString)") }

    /// Whether a photo is from a shared album rather than the library.
    public static func isShared(_ id: PhotoID) -> Bool { id.rawValue.hasPrefix(prefix) }

    /// The album and item a shared photo's name points to.
    public static func parse(_ id: PhotoID) -> (album: UUID, item: UUID)? {
        guard isShared(id) else { return nil }
        let parts = id.rawValue.dropFirst(prefix.count).split(separator: "/")
        guard parts.count == 2, let album = UUID(uuidString: String(parts[0])), let item = UUID(uuidString: String(parts[1])) else { return nil }
        return (album, item)
    }

    public func item(_ id: PhotoID) -> SharedItem? {
        guard let parsed = Self.parse(id), parsed.album == self.id else { return nil }
        return items.first { $0.id == parsed.item }
    }

    public var photoIDs: [PhotoID] { items.map(photoID(of:)) }

    /// Its photos and videos as the library describes them, under their shared names. A live photo comes as a photo:
    /// only its picture is shared.
    public var mediaItems: [MediaItem] {
        items.map { item in
            MediaItem(id: photoID(of: item), kind: item.kind == .livePhoto ? .photo : item.kind, date: item.date, addedDate: nil,
                      pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, duration: item.duration, isFavorite: false,
                      location: nil, fileName: item.fileName)
        }
    }

    public var captions: [PhotoID: String] {
        Dictionary(uniqueKeysWithValues: items.filter { !$0.caption.isEmpty }.map { (photoID(of: $0), $0.caption) })
    }

    public var notes: [PhotoID: String] {
        Dictionary(uniqueKeysWithValues: items.filter { !$0.note.isEmpty }.map { (photoID(of: $0), $0.note) })
    }

    /// Its photos as the book lays them out, each with the seed it has in its owner's book.
    public var bookItems: [BookItem] {
        items.map { item in
            let aspect = item.pixelWidth > 0 && item.pixelHeight > 0 ? Double(item.pixelWidth) / Double(item.pixelHeight) : 1
            return BookItem(id: photoID(of: item), aspect: aspect, isVideo: item.kind.isVideo, seed: item.layoutSeed)
        }
    }

    /// The photo on its cover: the one chosen, else the first.
    public var coverID: PhotoID? {
        (items.first { $0.id == cover } ?? items.first).map(photoID(of:))
    }

    // MARK: Sharing an album of yours

    /// An album of yours as it's shared: its photos and videos (`items`, in the album's order), their captions and
    /// notes from `catalog`, its cover and story, and its book, every photo named apart from your library. A photo
    /// shared before keeps the name it was shared under, so what's said about it, and where it lies in the book, stays
    /// with it; who it's shared with, and how, carry over from `previous`.
    public static func sharing(_ album: Album, items: [MediaItem], catalog: Catalog, cover: PhotoID?, owner: ShareParticipant,
                               previous: SharedAlbum?, now: Date = Date()) -> SharedAlbum {
        var known: [PhotoID: UUID] = [:]
        for item in previous?.items ?? [] {
            if let source = item.source { known[source] = item.id }
        }
        let shared = items.map { item in
            let details = catalog.details(item.id)
            return SharedItem(id: known[item.id] ?? UUID(), kind: item.kind, date: item.date, pixelWidth: item.pixelWidth,
                              pixelHeight: item.pixelHeight, duration: item.duration, fileName: item.fileName, caption: details.caption,
                              note: details.note, layoutSeed: KenBurns.seed(item.id), source: item.id)
        }
        var result = SharedAlbum(id: album.id, title: album.title, story: album.note, created: album.created, modified: now,
                                 items: shared, owner: owner, participants: previous?.participants ?? [owner],
                                 access: previous?.access ?? .invited, url: previous?.url, isMine: true)
        var names: [PhotoID: PhotoID] = [:]
        for item in shared {
            if let source = item.source { names[source] = result.photoID(of: item) }
        }
        result.cover = cover.flatMap { cover in shared.first { $0.source == cover }?.id }
        result.book = album.book?.renamingPhotos { names[$0] }
        if let previous, result.sameContent(as: previous) { result.modified = previous.modified }
        return result
    }

    /// Whether two versions hold the same: everything but when it last changed.
    public func sameContent(as other: SharedAlbum) -> Bool {
        var other = other
        other.modified = modified
        return self == other
    }
}
