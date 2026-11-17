import Foundation

/// The search field: every word typed must match something about a photo — its caption, note or file name, a
/// label or album it's in, what was written in the journal on its day, its kind ("video"), "favorite", a year
/// ("2019") or a month ("june").
public struct PhotoSearch: Sendable {
    public let words: [String]
    private let formatting: Formatting

    public init(_ text: String, formatting: Formatting = Formatting()) {
        words = text.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }.filter { !$0.isEmpty }
        self.formatting = formatting
    }

    public var isEmpty: Bool { words.isEmpty }

    /// The photos that match, in the order given.
    public func filter(_ ids: [PhotoID], using arranger: Arranger) -> [PhotoID] {
        guard !words.isEmpty else { return ids }
        let matchers = words.map { Matcher(word: $0, arranger: arranger, formatting: formatting) }
        return ids.filter { id in
            guard let item = arranger.snapshot.item(id) else { return false }
            let details = arranger.catalog.photos[id]
            return matchers.allSatisfy { $0.matches(item, details: details, day: arranger.snapshot.day(of: id)) }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// What one word can match, worked out once per search.
    private struct Matcher {
        let word: String
        let labels: Set<UUID>
        let albumPhotos: Set<PhotoID>
        let kinds: Set<MediaKind>
        let meansFavorite: Bool
        let year: Int?
        let months: Set<Int>
        /// Days whose journal entry has the word.
        let journalDays: Set<CivilDay>

        init(word: String, arranger: Arranger, formatting: Formatting) {
            self.word = word
            let catalog = arranger.catalog
            labels = Set(catalog.labels.filter { PhotoSearch.fold($0.name).contains(word) || $0.emoji == word }.map(\.id))
            albumPhotos = Set(catalog.albums.filter { PhotoSearch.fold($0.title).contains(word) }.flatMap(\.items))
            kinds = Set(MediaKind.allCases.filter { kind in
                let name = PhotoSearch.fold(kind.displayName)
                return name.hasPrefix(word) || (word.hasPrefix(name) && word.count <= name.count + 1)
            })
            meansFavorite = ["favorite", "favorites", "favourite", "favourites", "loved"].contains { $0.hasPrefix(word) && word.count >= 3 }
            year = word.count == 4 ? Int(word) : nil
            var months = Set<Int>()
            if word.count >= 3 {
                for (index, names) in formatting.monthNames.enumerated() {
                    let full = PhotoSearch.fold(names.full), short = PhotoSearch.fold(names.short)
                    if full.hasPrefix(word) || word == short.trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
                        months.insert(index + 1)
                    }
                }
            }
            self.months = months
            journalDays = Set(catalog.journal.compactMap { key, entry in
                PhotoSearch.fold(entry.text).contains(word) || entry.mood == word ? CivilDay(key) : nil
            })
        }

        func matches(_ item: MediaItem, details: PhotoDetails?, day: CivilDay?) -> Bool {
            if let details {
                if !labels.isEmpty, details.labels.contains(where: labels.contains) { return true }
                if !details.caption.isEmpty, PhotoSearch.fold(details.caption).contains(word) { return true }
                if !details.note.isEmpty, PhotoSearch.fold(details.note).contains(word) { return true }
            }
            if albumPhotos.contains(item.id) { return true }
            if kinds.contains(item.kind) { return true }
            if meansFavorite, item.isFavorite { return true }
            if let day {
                if journalDays.contains(day) { return true }
                if let year, day.year == year { return true }
                if months.contains(day.month) { return true }
            }
            if let name = item.fileName, PhotoSearch.fold(name).contains(word) { return true }
            return false
        }
    }
}
