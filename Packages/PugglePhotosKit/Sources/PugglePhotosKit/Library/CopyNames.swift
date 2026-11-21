import Foundation

/// The names copies of photos and videos get: the original's name with a number in brackets before its extension.
/// "Beach.jpg" becomes "Beach(1).jpg", or "Beach(2).jpg" when that's taken, and so on up; a copy of a copy is
/// numbered again, so "Beach(2).jpg" becomes "Beach(2)(1).jpg".
public enum CopyNames {
    /// The name for a copy of a file called `name`: the lowest number that makes a name not among `taken`.
    public static func name(for name: String, taken: some Sequence<String>) -> String {
        names(for: [name], taken: taken)[0]
    }

    /// Names for copies of several files at once, each different from the others and from everything in `taken`.
    /// Names are the same when they differ only in case, as on a Mac's disk.
    public static func names(for originals: [String], taken: some Sequence<String>) -> [String] {
        var used = Set(taken.map(key))
        return originals.map { original in
            let (stem, suffix) = split(original)
            var number = 1
            var name = "\(stem)(\(number))\(suffix)"
            while used.contains(key(name)) {
                number += 1
                name = "\(stem)(\(number))\(suffix)"
            }
            used.insert(key(name))
            return name
        }
    }

    /// How names are compared: ignoring case, and however an accented letter happens to be written.
    public static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// A name before its extension, and the extension with its dot ("" when there's none). A dot that starts the
    /// name, or ends it, doesn't start an extension.
    static func split(_ name: String) -> (stem: String, suffix: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
