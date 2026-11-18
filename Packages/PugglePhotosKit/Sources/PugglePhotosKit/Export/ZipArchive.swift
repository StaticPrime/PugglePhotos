import Foundation
import zlib

/// A ZIP archive with its files stored as they are, not compressed: the container an EPUB file is. Its first file must
/// be stored that way so a reader can tell what the file is from its first bytes; the rest are pictures, compressed
/// already, and a few small text files not worth squeezing.
public struct ZipArchive: Sendable {
    /// A file in an archive, as it was found there.
    public struct File: Equatable, Sendable {
        public let path: String
        public let contents: Data
        /// How it was packed: 0 is stored as it is.
        public let method: Int
        /// Bytes some tools put after a file's name in its header; an EPUB's first file must have none.
        public let extra: Data
        /// Where its header starts in the archive.
        public let offset: Int
    }

    public enum Problem: Error {
        /// Past what an archive's 32-bit sizes, places and 16-bit file count can hold.
        case tooBig
    }

    private var body = Data()
    private var directory = Data()
    private var count = 0
    private let time: UInt16
    private let date: UInt16

    /// An empty archive whose files are dated `modified`, in the local time ZIP keeps.
    public init(modified: Date = Date(), timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        // MS-DOS time, in two-second steps; dates count years from 1980.
        time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        date = UInt16(min(max((parts.year ?? 1980) - 1980, 0), 127) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }

    /// Adds a file, after those already in the archive.
    public mutating func add(_ path: String, _ contents: Data) throws {
        let name = Data(path.utf8)
        guard count < Int(UInt16.max), name.count < Int(UInt16.max),
              body.count + 30 + name.count + contents.count < Int(UInt32.max) else { throw Problem.tooBig }
        let crc = Self.checksum(contents)
        let offset = UInt32(body.count), size = UInt32(contents.count)
        // Names beyond plain ASCII are flagged as UTF-8.
        let flags: UInt16 = path.utf8.contains { $0 >= 0x80 } ? 1 << 11 : 0

        body.append(little: UInt32(0x0403_4B50))
        body.append(little: UInt16(10))  // Needs ZIP 1.0 to read: stored files.
        body.append(little: flags)
        body.append(little: UInt16(0))  // Stored.
        body.append(little: time)
        body.append(little: date)
        body.append(little: crc)
        body.append(little: size)
        body.append(little: size)
        body.append(little: UInt16(name.count))
        body.append(little: UInt16(0))  // No extra field.
        body.append(name)
        body.append(contents)

        directory.append(little: UInt32(0x0201_4B50))
        directory.append(little: UInt16(3 << 8 | 20))  // Made on Unix, to ZIP 2.0.
        directory.append(little: UInt16(10))
        directory.append(little: flags)
        directory.append(little: UInt16(0))
        directory.append(little: time)
        directory.append(little: date)
        directory.append(little: crc)
        directory.append(little: size)
        directory.append(little: size)
        directory.append(little: UInt16(name.count))
        directory.append(little: UInt16(0))  // Extra field.
        directory.append(little: UInt16(0))  // Comment.
        directory.append(little: UInt16(0))  // Disk.
        directory.append(little: UInt16(0))  // Internal attributes.
        directory.append(little: UInt32(0o100644) << 16)  // A plain file anyone may read.
        directory.append(little: offset)
        directory.append(name)
        count += 1
    }

    /// The whole archive: its files, then the directory of them and the record that ends it.
    public var data: Data {
        var data = body
        data.append(directory)
        data.append(little: UInt32(0x0605_4B50))
        data.append(little: UInt16(0))
        data.append(little: UInt16(0))
        data.append(little: UInt16(count))
        data.append(little: UInt16(count))
        data.append(little: UInt32(directory.count))
        data.append(little: UInt32(body.count))
        data.append(little: UInt16(0))
        return data
    }

    /// The CRC-32 a ZIP archive keeps for each file.
    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
    }

    /// The files in an archive of stored files, in the order they're kept, each checked against its checksum; nil if it
    /// isn't such an archive, or anything in it is amiss.
    public static func files(in archive: Data) -> [File]? {
        let bytes = [UInt8](archive)
        func number(_ at: Int, _ size: Int) -> Int? {
            guard at >= 0, at + size <= bytes.count else { return nil }
            return (0..<size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        // The record that ends the archive, with no comment after it.
        let end = bytes.count - 22
        guard number(end, 4) == 0x0605_4B50, let entries = number(end + 10, 2), var at = number(end + 16, 4) else { return nil }
        var files: [File] = []
        for _ in 0..<entries {
            guard number(at, 4) == 0x0201_4B50, let method = number(at + 10, 2), let crc = number(at + 16, 4),
                  let packed = number(at + 20, 4), let size = number(at + 24, 4), let nameLength = number(at + 28, 2),
                  let extraLength = number(at + 30, 2), let commentLength = number(at + 32, 2), let offset = number(at + 42, 4),
                  at + 46 + nameLength <= bytes.count else { return nil }
            let path = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            // The file's own header, then its bytes.
            guard number(offset, 4) == 0x0403_4B50, let ownName = number(offset + 26, 2), let ownExtra = number(offset + 28, 2) else { return nil }
            let start = offset + 30 + ownName + ownExtra
            guard method == 0, packed == size, start + size <= bytes.count else { return nil }
            let contents = Data(bytes[start..<(start + size)])
            guard checksum(contents) == UInt32(crc) else { return nil }
            files.append(File(path: path, contents: contents, method: method, extra: Data(bytes[(offset + 30 + ownName)..<start]), offset: offset))
            at += 46 + nameLength + extraLength + commentLength
        }
        return files
    }
}

private extension Data {
    mutating func append<Number: FixedWidthInteger>(little number: Number) {
        Swift.withUnsafeBytes(of: number.littleEndian) { append(contentsOf: $0) }
    }
}
