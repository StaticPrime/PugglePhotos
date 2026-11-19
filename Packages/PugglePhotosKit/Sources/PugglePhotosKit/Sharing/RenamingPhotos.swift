import Foundation

extension BookSpot {
    /// The same spot with its photo named anew; nil when the photo has no new name.
    func renamingPhotos(_ rename: (PhotoID) -> PhotoID?) -> BookSpot? {
        if case let .photo(id) = self { return rename(id).map(BookSpot.photo) }
        return self
    }
}

extension BookAnchor {
    /// The same anchor with its photo named anew; nil when the photo has no new name.
    func renamingPhotos(_ rename: (PhotoID) -> PhotoID?) -> BookAnchor? {
        if case let .photo(id) = self { return rename(id).map(BookAnchor.photo) }
        return self
    }
}

extension BookSettings {
    /// The same book with its photos named anew by `rename`, everything said about them going with them: where each
    /// lies and leans, its sticky note, the page it was carried to, whether it's left out, the writing beside it. What
    /// the book says about a photo `rename` has no name for (one no longer in the album) is left out; a page added
    /// after such a photo keeps its place at the end of the book, where the book puts it anyway.
    public func renamingPhotos(_ rename: (PhotoID) -> PhotoID?) -> BookSettings {
        var book = self
        book.overrides = [:]
        for (id, override) in overrides {
            guard let name = rename(id) else { continue }
            var renamed = override
            // Carried to the page of a photo no longer there, it goes back to its own.
            renamed.page = override.page.flatMap { $0.renamingPhotos(rename) }
            book.overrides[name] = renamed
        }
        book.hidden = hidden.compactMap(rename)
        book.writings = writings.compactMap { writing in
            guard let spot = writing.spot.renamingPhotos(rename) else { return nil }
            var renamed = writing
            renamed.spot = spot
            return renamed
        }
        book.extraPages = extraPages.map { page in
            var renamed = page
            renamed.after = page.after.renamingPhotos(rename) ?? page.after
            return renamed
        }
        return book
    }
}
