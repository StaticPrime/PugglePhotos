import Foundation

/// How a shared album is kept in iCloud: a zone of its own holding one record for the album and one for each photo or
/// video, with that photo or video's original file beside it. Each record keeps what's said about it as JSON, so what
/// a shared album carries can grow without the records changing. Who it's shared with, and how, is kept by iCloud on
/// the zone's share.
public enum SharedAlbumRecords {
    public static let albumType = "Album"
    public static let itemType = "Item"
    /// The album record's name; each photo's record is named after it.
    public static let albumName = "album"
    public static let infoKey = "info"
    public static let originalKey = "original"
    static let zonePrefix = "album-"

    /// The name of the zone an album is kept in, the same for its owner and everyone it's shared with.
    public static func zoneName(of album: UUID) -> String { zonePrefix + album.uuidString }

    /// The album a zone holds, if it's one of these.
    public static func album(inZone name: String) -> UUID? {
        guard name.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(zonePrefix.count)))
    }

    /// The album's own record: everything about it but its photos.
    struct AlbumInfo: Codable, Equatable {
        var title: String
        var story: String
        var created: Date
        var modified: Date
        var cover: UUID?
        var book: BookSettings?
        /// Its photos and videos, in order.
        var order: [UUID]
        /// The owner's name as their Mac knows it, for when iCloud doesn't say.
        var ownerName: String
    }

    /// What the album's record holds.
    public static func albumInfo(_ album: SharedAlbum) -> Data {
        encode(AlbumInfo(title: album.title, story: album.story, created: album.created, modified: album.modified, cover: album.cover,
                         book: album.book, order: album.items.map(\.id), ownerName: album.owner.name))
    }

    /// What a photo's record holds: all of it but which photo in the owner's library it is, which stays on their Mac.
    /// The same photo always gives the same, so a photo whose record holds it is up to date.
    public static func itemInfo(_ item: SharedItem) -> Data {
        var item = item
        item.source = nil
        return encode(item)
    }

    /// An album shared with you, from its records as they've come: its photos in the album's order, leaving out any
    /// whose records haven't come. The owner is named as iCloud names them, or else as their Mac does.
    public static func album(id: UUID, info: Data, items: [UUID: Data], owner: ShareParticipant, participants: [ShareParticipant],
                             access: ShareAccess, url: URL?) -> SharedAlbum? {
        guard let info = try? JSONDecoder().decode(AlbumInfo.self, from: info) else { return nil }
        let decoder = JSONDecoder()
        let shared = info.order.compactMap { id in
            items[id].flatMap { try? decoder.decode(SharedItem.self, from: $0) }.flatMap { $0.id == id ? $0 : nil }
        }
        var owner = owner
        if owner.name.isEmpty { owner.name = info.ownerName }
        var participants = participants.map { $0.id == owner.id ? owner : $0 }
        if !participants.contains(where: { $0.id == owner.id }) { participants.insert(owner, at: 0) }
        return SharedAlbum(id: id, title: info.title, story: info.story, created: info.created, modified: info.modified,
                           items: shared, cover: info.cover.flatMap { cover in shared.contains { $0.id == cover } ? cover : nil },
                           book: info.book, owner: owner, participants: participants, access: access, url: url, isMine: false)
    }

    /// Sorted keys and exact dates, so the same thing always encodes the same.
    private static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }
}
