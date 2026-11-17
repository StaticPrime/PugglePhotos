import Foundation

/// Reads and writes the catalog: `Catalog.json` in a folder, written whole and atomically, with a copy of the
/// previous day's file kept in `Backups` for two weeks.
public struct CatalogStore: Sendable {
    public enum StoreError: Error, LocalizedError {
        /// The file couldn't be read. It was moved aside, to the URL given, so nothing is lost.
        case damaged(movedTo: URL?)
        /// The file comes from a newer PugglePhotos.
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .damaged: "Your albums, labels and notes couldn’t be read."
            case let .newerVersion(version): "Your albums, labels and notes were saved by a newer PugglePhotos (catalog version \(version))."
            }
        }
    }

    public let folder: URL
    public static let backupDays = 14

    public init(folder: URL) { self.folder = folder }

    public var fileURL: URL { folder.appendingPathComponent("Catalog.json") }
    public var backupsFolder: URL { folder.appendingPathComponent("Backups", isDirectory: true) }

    /// The saved catalog, or an empty one the first time.
    public func load() throws -> Catalog {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Catalog()
        }
        do {
            return try Self.decode(data)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.damaged(movedTo: moveAside())
        }
    }

    /// Saves the catalog. The first save of a day keeps yesterday's file as a backup.
    public func save(_ catalog: Catalog, now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if manager.fileExists(atPath: fileURL.path) {
            try backUp(now: now)
        }
        try Self.encode(catalog).write(to: fileURL, options: .atomic)
    }

    public static func encode(_ catalog: Catalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    public static func decode(_ data: Data) throws -> Catalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(Catalog.self, from: data)
        if catalog.version > Catalog.currentVersion { throw StoreError.newerVersion(catalog.version) }
        return catalog
    }

    /// The backups, newest first.
    public func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Catalog ") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func backUp(now: Date) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let target = backupsFolder.appendingPathComponent("Catalog \(formatter.string(from: now)).json")
        if !manager.fileExists(atPath: target.path) {
            try manager.copyItem(at: fileURL, to: target)
        }
        for old in backups().dropFirst(Self.backupDays) {
            try? manager.removeItem(at: old)
        }
    }

    /// Renames a file that can't be read so the next save doesn't overwrite it.
    private func moveAside() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let target = folder.appendingPathComponent("Catalog (unreadable \(formatter.string(from: Date()))).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            return target
        } catch {
            return nil
        }
    }
}
