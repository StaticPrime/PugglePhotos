import Foundation

/// A photo or video copied in the library: the one it's a copy of, and the copy.
public struct CopiedPhoto: Hashable, Sendable {
    public let original: PhotoID
    public let copy: PhotoID

    public init(original: PhotoID, copy: PhotoID) {
        self.original = original
        self.copy = copy
    }
}

extension Catalog {
    /// Writes on each copy what's written about the photo it's a copy of: its caption, its note and its labels.
    public mutating func copyDetails(_ copies: [CopiedPhoto]) {
        for pair in copies where pair.copy != pair.original {
            let written = self.details(pair.original)
            setDetails(pair.copy) { $0 = written }
        }
    }

    /// Puts copies in an album, each right after the photo it's a copy of when that's in the album, and the rest at
    /// its end. Copies already in the album stay where they are.
    public mutating func add(_ copies: [CopiedPhoto], besideOriginalsIn id: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let items = albums[index].items
        let present = Set(items)
        var placed = present
        var following: [PhotoID: [PhotoID]] = [:]
        var atEnd: [PhotoID] = []
        for pair in copies where !SharedAlbum.isShared(pair.copy) && placed.insert(pair.copy).inserted {
            if present.contains(pair.original) {
                following[pair.original, default: []].append(pair.copy)
            } else {
                atEnd.append(pair.copy)
            }
        }
        var result: [PhotoID] = []
        result.reserveCapacity(items.count + following.count + atEnd.count)
        for item in items {
            result.append(item)
            if let copies = following.removeValue(forKey: item) { result += copies }
        }
        albums[index].items = result + atEnd
    }

    /// Forgets photos deleted from the library: what's written about them, their places in albums, as album covers,
    /// and in books (where they were moved, turned or left out). Writing in a book stays where it is.
    public mutating func forget(_ ids: Set<PhotoID>) {
        guard !ids.isEmpty else { return }
        for id in ids { photos[id] = nil }
        for index in albums.indices {
            albums[index].items.removeAll { ids.contains($0) }
            if let cover = albums[index].cover, ids.contains(cover) { albums[index].cover = nil }
            guard var book = albums[index].book else { continue }
            book.overrides = book.overrides.filter { !ids.contains($0.key) }
            book.hidden.removeAll { ids.contains($0) }
            albums[index].book = book == BookSettings() ? nil : book
        }
    }
}
