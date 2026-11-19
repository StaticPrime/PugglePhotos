import Foundation

/// What a notification says about an album shared with you: when it's first shared, and when its owner adds to it.
public struct SharedAlbumNotice: Hashable, Sendable {
    public let album: UUID
    public let title: String
    public let body: String

    /// One per album, so a newer one takes the place of one still showing.
    public var identifier: String { "shared-\(album.uuidString)" }

    /// An album newly shared with you.
    public static func shared(_ album: SharedAlbum, formatting: Formatting) -> SharedAlbumNotice {
        let counts = Self.counts(album.items)
        let what = counts.photos + counts.videos == 0 ? "" : formatting.count(photos: counts.photos, videos: counts.videos) + ". "
        return SharedAlbumNotice(album: album.id, title: "\(album.owner.name) shared “\(album.title)” with you",
                                 body: what + "Click to look through it in PugglePhotos.")
    }

    /// An album shared with you that its owner has added to; nil when nothing was added.
    public static func added(from old: SharedAlbum, to new: SharedAlbum, formatting: Formatting) -> SharedAlbumNotice? {
        let before = Set(old.items.map(\.id))
        let added = new.items.filter { !before.contains($0.id) }
        guard !added.isEmpty else { return nil }
        let counts = Self.counts(added)
        return SharedAlbumNotice(album: new.id, title: "\(new.owner.name) added to “\(new.title)”",
                                 body: "\(formatting.count(photos: counts.photos, videos: counts.videos)) added. Click to see them.")
    }

    private static func counts(_ items: [SharedItem]) -> (photos: Int, videos: Int) {
        let videos = items.filter(\.kind.isVideo).count
        return (items.count - videos, videos)
    }
}
