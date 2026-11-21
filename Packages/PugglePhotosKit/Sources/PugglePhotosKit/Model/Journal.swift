import Foundation

/// What the person wrote about a day, with how it felt.
public struct JournalEntry: Codable, Hashable, Sendable {
    public var text: String
    /// An emoji for the day's mood, or empty.
    public var mood: String
    /// When it was last written, to the second.
    public var edited: Date

    public init(text: String, mood: String = "", edited: Date = Date()) {
        self.text = text
        self.mood = mood
        self.edited = Date(timeIntervalSinceReferenceDate: edited.timeIntervalSinceReferenceDate.rounded(.down))
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mood.isEmpty }

    /// Moods to pick from.
    public static let moods = ["😊", "🥰", "😂", "🥳", "😌", "🤩", "😴", "🥲", "😢", "😤"]
}

extension CivilDay {
    /// A day from its "2025-06-14" form.
    public init?(_ string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]),
              (1...CivilDay.daysIn(year: parts[0], month: parts[1])).contains(parts[2])
        else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }
}

extension Catalog {
    /// The entry for a day, if there is one.
    public func entry(for day: CivilDay) -> JournalEntry? { journal[day.description] }

    /// Writes a day's entry, without blank lines around it; an empty one is removed.
    public mutating func setEntry(_ text: String, mood: String, for day: CivilDay, edited: Date = Date()) {
        let entry = JournalEntry(text: text.trimmingCharacters(in: .whitespacesAndNewlines), mood: mood, edited: edited)
        journal[day.description] = entry.isEmpty ? nil : entry
    }

    /// Every day with an entry, the most recent first.
    public var journalDays: [CivilDay] {
        journal.keys.compactMap(CivilDay.init).sorted(by: >)
    }
}
