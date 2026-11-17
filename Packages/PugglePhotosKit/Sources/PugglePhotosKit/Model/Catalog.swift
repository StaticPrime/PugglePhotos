import Foundation

/// The colors a label can have.
public enum LabelColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, gray

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// sRGB components, 0 to 1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        func hex(_ value: UInt32) -> (Double, Double, Double) {
            (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        return switch self {
        case .red: hex(0xEF4444)
        case .orange: hex(0xF97316)
        case .yellow: hex(0xEAB308)
        case .green: hex(0x22C55E)
        case .teal: hex(0x14B8A6)
        case .blue: hex(0x3B82F6)
        case .purple: hex(0x8B5CF6)
        case .pink: hex(0xEC4899)
        case .brown: hex(0x92400E)
        case .gray: hex(0x6B7280)
        }
    }
}

/// A label that can be put on any number of photos, like "Family" or "Funny".
public struct PhotoLabel: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var color: LabelColor
    /// An optional emoji shown before the name; empty for none.
    public var emoji: String

    public init(id: UUID = UUID(), name: String, color: LabelColor, emoji: String = "") {
        self.id = id
        self.name = name
        self.color = color
        self.emoji = emoji
    }

    /// The name with its emoji in front, as the sidebar shows it.
    public var displayName: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
}

/// How an album shows its photos.
public enum AlbumOrder: String, Codable, Sendable, CaseIterable {
    /// The order photos were added in, or the order they were dragged into.
    case custom
    case oldestFirst
    case newestFirst
}

/// An album: photos chosen by hand, in an order of the user's choosing. A photo can be in any number of albums.
public struct Album: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    /// The album's story or description.
    public var note: String
    public var created: Date
    /// The photo shown as the album's cover; when nil (or no longer in the album), the album's first photo.
    public var cover: PhotoID?
    public var items: [PhotoID]
    public var order: AlbumOrder

    public init(id: UUID = UUID(), title: String, note: String = "", created: Date = Date(), cover: PhotoID? = nil,
                items: [PhotoID] = [], order: AlbumOrder = .oldestFirst) {
        self.id = id
        self.title = title
        self.note = note
        // Whole seconds, so the date reads back exactly from the saved file.
        self.created = Date(timeIntervalSinceReferenceDate: created.timeIntervalSinceReferenceDate.rounded(.down))
        self.cover = cover
        self.items = items
        self.order = order
    }
}

/// What PugglePhotos knows about one photo beyond the library's own information.
public struct PhotoDetails: Hashable, Codable, Sendable {
    /// A short title, shown under the photo and in lists.
    public var caption: String
    /// A longer note: the story behind the photo.
    public var note: String
    /// Label IDs, in the order they were added.
    public var labels: [UUID]

    public init(caption: String = "", note: String = "", labels: [UUID] = []) {
        self.caption = caption
        self.note = note
        self.labels = labels
    }

    public var isEmpty: Bool { caption.isEmpty && note.isEmpty && labels.isEmpty }

    enum CodingKeys: String, CodingKey { case caption, note, labels }

    // Empty fields are left out of the file, and missing ones read as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        labels = try container.decodeIfPresent([UUID].self, forKey: .labels) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !caption.isEmpty { try container.encode(caption, forKey: .caption) }
        if !note.isEmpty { try container.encode(note, forKey: .note) }
        if !labels.isEmpty { try container.encode(labels, forKey: .labels) }
    }
}

/// Everything the user has made in PugglePhotos: albums, labels, captions and notes. The photos themselves stay
/// in the Photos library; the catalog refers to them by `PhotoID`.
public struct Catalog: Hashable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var albums: [Album]
    public var labels: [PhotoLabel]
    public var photos: [PhotoID: PhotoDetails]

    public init(albums: [Album] = [], labels: [PhotoLabel] = [], photos: [PhotoID: PhotoDetails] = [:]) {
        version = Self.currentVersion
        self.albums = albums
        self.labels = labels
        self.photos = photos
    }

    enum CodingKeys: String, CodingKey { case version, albums, labels, photos }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        albums = try container.decodeIfPresent([Album].self, forKey: .albums) ?? []
        labels = try container.decodeIfPresent([PhotoLabel].self, forKey: .labels) ?? []
        photos = try container.decodeIfPresent([PhotoID: PhotoDetails].self, forKey: .photos) ?? [:]
    }

    // MARK: Looking things up

    public func album(_ id: UUID) -> Album? { albums.first { $0.id == id } }
    public func label(_ id: UUID) -> PhotoLabel? { labels.first { $0.id == id } }
    public func details(_ id: PhotoID) -> PhotoDetails { photos[id] ?? PhotoDetails() }

    /// A title nobody has used yet: "Untitled Album", then "Untitled Album 2"…
    public func unusedAlbumTitle(_ base: String = "Untitled Album") -> String {
        Self.unused(base, taken: Set(albums.map { $0.title.lowercased() }))
    }

    public func unusedLabelName(_ base: String = "New Label") -> String {
        Self.unused(base, taken: Set(labels.map { $0.name.lowercased() }))
    }

    static func unused(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Albums

    /// Adds an album at the end and returns its ID.
    @discardableResult
    public mutating func addAlbum(title: String, items: [PhotoID] = [], created: Date = Date()) -> UUID {
        let album = Album(title: title, created: created, items: Self.unique(items))
        albums.append(album)
        return album.id
    }

    public mutating func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
    }

    public mutating func renameAlbum(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    public mutating func setAlbumNote(_ id: UUID, to note: String) {
        update(id) { $0.note = note }
    }

    public mutating func setAlbumOrder(_ id: UUID, to order: AlbumOrder) {
        update(id) { $0.order = order }
    }

    public mutating func setCover(_ photo: PhotoID?, of id: UUID) {
        update(id) { $0.cover = photo }
    }

    /// Adds photos to the end of an album, skipping any it already has. Returns how many were added.
    @discardableResult
    public mutating func add(_ photos: [PhotoID], toAlbum id: UUID) -> Int {
        var added = 0
        update(id) { album in
            var present = Set(album.items)
            for photo in photos where present.insert(photo).inserted {
                album.items.append(photo)
                added += 1
            }
        }
        return added
    }

    /// Removes photos from an album (never from the library). A removed cover falls back to the first photo.
    public mutating func remove(_ photos: Set<PhotoID>, fromAlbum id: UUID) {
        update(id) { album in
            album.items.removeAll { photos.contains($0) }
            if let cover = album.cover, photos.contains(cover) { album.cover = nil }
        }
    }

    /// Puts photos, in the order given, before the photo now at `index` in the album's `items` (or at the end):
    /// photos already in the album move there and the rest are added there. Used when photos are dragged into
    /// place in an album shown in its own order.
    public mutating func move(_ photos: [PhotoID], inAlbum id: UUID, toIndex index: Int) {
        update(id) { album in
            let placing = Self.unique(photos)
            let moving = Set(placing)
            // Count the moving photos before the target so the insertion point stays put once they're removed.
            let clamped = max(0, min(index, album.items.count))
            let shift = album.items[..<clamped].filter { moving.contains($0) }.count
            album.items.removeAll { moving.contains($0) }
            album.items.insert(contentsOf: placing, at: clamped - shift)
        }
    }

    private mutating func update(_ id: UUID, _ change: (inout Album) -> Void) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        change(&albums[index])
    }

    // MARK: Labels

    @discardableResult
    public mutating func addLabel(name: String, color: LabelColor, emoji: String = "") -> UUID {
        let label = PhotoLabel(name: name, color: color, emoji: emoji)
        labels.append(label)
        return label.id
    }

    public mutating func updateLabel(_ label: PhotoLabel) {
        guard let index = labels.firstIndex(where: { $0.id == label.id }) else { return }
        labels[index] = label
    }

    /// Deletes a label and takes it off every photo.
    public mutating func deleteLabel(_ id: UUID) {
        labels.removeAll { $0.id == id }
        for (photo, details) in photos where details.labels.contains(id) {
            setDetails(photo) { $0.labels.removeAll { $0 == id } }
        }
    }

    /// Puts a label on photos, or takes it off.
    public mutating func setLabel(_ id: UUID, on photos: [PhotoID], _ on: Bool) {
        for photo in photos {
            setDetails(photo) { details in
                if on {
                    if !details.labels.contains(id) { details.labels.append(id) }
                } else {
                    details.labels.removeAll { $0 == id }
                }
            }
        }
    }

    /// Takes the label off if every one of the photos has it; otherwise puts it on all of them.
    public mutating func toggleLabel(_ id: UUID, on photos: [PhotoID]) {
        let allHaveIt = !photos.isEmpty && photos.allSatisfy { details($0).labels.contains(id) }
        setLabel(id, on: photos, !allHaveIt)
    }

    // MARK: Captions and notes

    public mutating func setCaption(_ caption: String, for photos: [PhotoID]) {
        for photo in photos { setDetails(photo) { $0.caption = caption } }
    }

    public mutating func setNote(_ note: String, for photo: PhotoID) {
        setDetails(photo) { $0.note = note }
    }

    /// Changes one photo's details, dropping the entry once it holds nothing.
    mutating func setDetails(_ photo: PhotoID, _ change: (inout PhotoDetails) -> Void) {
        var details = photos[photo] ?? PhotoDetails()
        change(&details)
        photos[photo] = details.isEmpty ? nil : details
    }

    static func unique(_ ids: [PhotoID]) -> [PhotoID] {
        var seen = Set<PhotoID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Which albums each photo is in and which photos each label is on, worked out once per catalog change.
public struct Membership: Sendable {
    public let albumsByPhoto: [PhotoID: [UUID]]
    public let photosByLabel: [UUID: Set<PhotoID>]

    public init(_ catalog: Catalog) {
        var albumsByPhoto: [PhotoID: [UUID]] = [:]
        for album in catalog.albums {
            for photo in album.items { albumsByPhoto[photo, default: []].append(album.id) }
        }
        var photosByLabel: [UUID: Set<PhotoID>] = [:]
        for (photo, details) in catalog.photos {
            for label in details.labels { photosByLabel[label, default: []].insert(photo) }
        }
        self.albumsByPhoto = albumsByPhoto
        self.photosByLabel = photosByLabel
    }

    public func albums(containing photo: PhotoID) -> [UUID] { albumsByPhoto[photo] ?? [] }
    public func photos(labeled label: UUID) -> Set<PhotoID> { photosByLabel[label] ?? [] }
}
