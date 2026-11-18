import Foundation

/// A book of pictures as an EPUB file, for e-book readers on phones, tablets and computers. Every page is a picture,
/// all the same size, set out as a printed book's pages are: the front cover on its own, then the pages that face each
/// other side by side where there's room for two, and the back cover on its own. A table of contents, the page numbers,
/// and each page told in words for readers who listen rather than look come with it.
public struct EPUBBook: Sendable {
    /// Where a page shows when two show side by side.
    public enum Side: Sendable {
        case left, right
        /// On its own, in the middle, like a closed book's cover.
        case alone
    }

    public struct Page: Sendable {
        /// The picture of the page, as JPEG data.
        public var picture: Data
        public var side: Side
        /// The page's name in the table of contents, if it's listed there.
        public var contentsTitle: String?
        /// The number printed on the page, if any.
        public var number: Int?
        /// What's on the page, in words.
        public var description: String

        public init(picture: Data, side: Side, contentsTitle: String? = nil, number: Int? = nil, description: String) {
            self.picture = picture
            self.side = side
            self.contentsTitle = contentsTitle
            self.number = number
            self.description = description
        }
    }

    public var title: String
    /// The language its words are in, as a language tag ("en-US").
    public var language: String
    /// Names the book for good: every book saved from the same album has the same name, so a reader can tell it's the
    /// same book.
    public var identifier: UUID
    public var modified: Date
    /// How big every page's picture is, in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pages: [Page]

    public init(title: String, language: String, identifier: UUID, modified: Date, pixelWidth: Int, pixelHeight: Int, pages: [Page]) {
        self.title = title
        self.language = language
        self.identifier = identifier
        self.modified = modified
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pages = pages
    }

    /// The EPUB file: what kind of file it is, stored first, then where its package is, the package, its tables, its
    /// style, and each page with its picture.
    public func data() throws -> Data {
        var archive = ZipArchive(modified: modified)
        try archive.add("mimetype", Data("application/epub+zip".utf8))
        try archive.add("META-INF/container.xml", Data(Self.container.utf8))
        try archive.add("EPUB/package.opf", Data(packageDocument.utf8))
        try archive.add("EPUB/nav.xhtml", Data(navigationDocument.utf8))
        try archive.add("EPUB/toc.ncx", Data(oldContents.utf8))
        try archive.add("EPUB/style.css", Data(style.utf8))
        for (index, page) in pages.enumerated() {
            try archive.add("EPUB/\(name(index)).xhtml", Data(document(for: page, at: index).utf8))
            try archive.add("EPUB/images/\(name(index)).jpg", page.picture)
        }
        return archive.data
    }

    // MARK: The files

    /// What each page and its picture are called.
    func name(_ index: Int) -> String { String(format: "page-%03d", index + 1) }

    /// The language tag, or English if it isn't one.
    private var tag: String {
        let valid = !language.isEmpty && language.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return valid ? language : "en"
    }

    private var heading: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Photo Book" : trimmed
    }

    static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """

    var packageDocument: String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\#(tag)""#
                + #" prefix="rendition: http://www.idpf.org/vocab/rendition/#">"#,
            #"  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">"#,
            #"    <dc:identifier id="book-id">urn:uuid:\#(identifier.uuidString.lowercased())</dc:identifier>"#,
            #"    <dc:title>\#(Self.escaped(heading))</dc:title>"#,
            #"    <dc:language>\#(tag)</dc:language>"#,
            #"    <meta property="dcterms:modified">\#(ISO8601DateFormatter().string(from: modified))</meta>"#,
            // Pages of a fixed size, two side by side where the screen is wide enough.
            #"    <meta property="rendition:layout">pre-paginated</meta>"#,
            #"    <meta property="rendition:spread">auto</meta>"#,
            #"    <meta property="schema:accessMode">visual</meta>"#,
            #"    <meta property="schema:accessModeSufficient">visual</meta>"#,
            #"    <meta property="schema:accessibilityFeature">alternativeText</meta>"#,
            #"    <meta property="schema:accessibilityHazard">none</meta>"#,
            #"    <meta property="schema:accessibilitySummary">Each page is a picture of the book’s page, told in words as well.</meta>"#,
            // For readers that look for the cover the older way.
            #"    <meta name="cover" content="\#(name(0))-picture"/>"#,
            "  </metadata>",
            "  <manifest>",
            #"    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            #"    <item id="style" href="style.css" media-type="text/css"/>"#,
        ]
        for index in pages.indices {
            let name = name(index)
            lines.append(#"    <item id="\#(name)" href="\#(name).xhtml" media-type="application/xhtml+xml"/>"#)
            lines.append(#"    <item id="\#(name)-picture" href="images/\#(name).jpg" media-type="image/jpeg"\#(index == 0 ? #" properties="cover-image""# : "")/>"#)
        }
        lines += ["  </manifest>", #"  <spine toc="ncx">"#]
        for (index, page) in pages.enumerated() {
            let side = switch page.side {
            case .left: "page-spread-left"
            case .right: "page-spread-right"
            case .alone: "rendition:page-spread-center"
            }
            lines.append(#"    <itemref idref="\#(name(index))" properties="\#(side)"/>"#)
        }
        lines += ["  </spine>", "</package>", ""]
        return lines.joined(separator: "\n")
    }

    /// The table of contents, the page numbers, and where the cover and the pages begin.
    var navigationDocument: String {
        var contents = pages.indices.compactMap { index in
            pages[index].contentsTitle.map { #"<li><a href="\#(name(index)).xhtml">\#(Self.escaped($0))</a></li>"# }
        }
        if contents.isEmpty, !pages.isEmpty { contents = [#"<li><a href="\#(name(0)).xhtml">\#(Self.escaped(heading))</a></li>"#] }
        let numbers = pages.indices.compactMap { index in
            pages[index].number.map { #"<li><a href="\#(name(index)).xhtml">\#($0)</a></li>"# }
        }
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<!DOCTYPE html>",
            #"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\#(tag)" lang="\#(tag)">"#,
            "<head>",
            #"<meta charset="UTF-8"/>"#,
            "<title>\(Self.escaped(heading))</title>",
            "</head>",
            "<body>",
            #"<nav epub:type="toc" id="toc">"#,
            "<h1>\(Self.escaped(heading))</h1>",
            "<ol>",
        ] + contents + ["</ol>", "</nav>"]
        if !numbers.isEmpty {
            lines += [#"<nav epub:type="page-list" id="page-list" hidden="hidden">"#, "<ol>"] + numbers + ["</ol>", "</nav>"]
        }
        if !pages.isEmpty {
            let first = pages.firstIndex { $0.number != nil } ?? 0
            lines += [#"<nav epub:type="landmarks" id="landmarks" hidden="hidden">"#, "<ol>",
                      #"<li><a epub:type="cover" href="\#(name(0)).xhtml">Cover</a></li>"#,
                      #"<li><a epub:type="bodymatter" href="\#(name(first)).xhtml">Pages</a></li>"#,
                      "</ol>", "</nav>"]
        }
        lines += ["</body>", "</html>", ""]
        return lines.joined(separator: "\n")
    }

    /// The table of contents as readers from before the navigation document look for it.
    var oldContents: String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="\#(tag)">"#,
            "<head>",
            #"<meta name="dtb:uid" content="urn:uuid:\#(identifier.uuidString.lowercased())"/>"#,
            #"<meta name="dtb:depth" content="1"/>"#,
            #"<meta name="dtb:totalPageCount" content="0"/>"#,
            #"<meta name="dtb:maxPageNumber" content="0"/>"#,
            "</head>",
            "<docTitle><text>\(Self.escaped(heading))</text></docTitle>",
            "<navMap>",
        ]
        var entries = pages.indices.compactMap { index in pages[index].contentsTitle.map { (index, $0) } }
        if entries.isEmpty, !pages.isEmpty { entries = [(0, heading)] }
        for (order, (index, title)) in entries.enumerated() {
            lines.append(#"<navPoint id="point-\#(order + 1)" playOrder="\#(order + 1)"><navLabel><text>\#(Self.escaped(title))</text></navLabel>"#
                + #"<content src="\#(name(index)).xhtml"/></navPoint>"#)
        }
        lines += ["</navMap>", "</ncx>", ""]
        return lines.joined(separator: "\n")
    }

    /// Every page exactly as big as its picture, the picture filling it.
    var style: String {
        """
        @page { margin: 0; }
        html, body { margin: 0; padding: 0; }
        body { width: \(pixelWidth)px; height: \(pixelHeight)px; overflow: hidden; }
        img { display: block; width: \(pixelWidth)px; height: \(pixelHeight)px; margin: 0; padding: 0; border: 0; }

        """
    }

    /// A page: its picture, at its size, and in words for anyone who listens.
    func document(for page: Page, at index: Int) -> String {
        let title = page.contentsTitle.map { "\(heading): \($0)" } ?? heading
        return [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<!DOCTYPE html>",
            #"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\#(tag)" lang="\#(tag)">"#,
            "<head>",
            #"<meta charset="UTF-8"/>"#,
            #"<meta name="viewport" content="width=\#(pixelWidth), height=\#(pixelHeight)"/>"#,
            "<title>\(Self.escaped(title))</title>",
            #"<link rel="stylesheet" type="text/css" href="style.css"/>"#,
            "</head>",
            index == 0 ? #"<body epub:type="cover">"# : "<body>",
            #"<img src="images/\#(name(index)).jpg" alt="\#(Self.escaped(page.description))"/>"#,
            "</body>",
            "</html>",
            "",
        ].joined(separator: "\n")
    }

    /// Text as it can go into XML, in an element or an attribute: on one line, with the characters XML can't hold left out.
    static func escaped(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            case "\n", "\r", "\t", "\u{2028}", "\u{2029}": escaped += " "
            default:
                guard scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF else { continue }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

// MARK: A photo book as an EPUB

extension BookLayout {
    /// Where a page shows in an e-book when two show side by side: as in the book itself, the closed covers on their own,
    /// then each left page beside the right page it faces.
    public func ebookSide(_ index: Int) -> EPUBBook.Side {
        if index == 0 || index == pages.count - 1 { return .alone }
        return index % 2 == 1 ? .left : .right
    }

    /// A page's name in an e-book's table of contents, if it's listed there: the covers, the title page and the numbered
    /// pages.
    public func contentsTitle(_ index: Int) -> String? {
        let page = pages[index]
        switch page.kind {
        case .cover: return "Cover"
        case .title: return "Title Page"
        case .back: return "Back Cover"
        case .photos, .added: return page.number.map { "Page \($0)" }
        case .insideCover, .blank: return nil
        }
    }

    /// What a page shows, in words, for whoever listens to the book rather than looks at it: the album's name and story,
    /// how many photos a page has, their captions, the notes that show, and what's written on it.
    public func spokenPage(_ index: Int, title: String, subtitle: String, story: String) -> String {
        let page = pages[index]
        func quoted(_ texts: [String]) -> String { texts.map { "“\($0)”" }.joined(separator: ", ") }
        func counted(_ count: Int, _ thing: String) -> String? {
            count == 0 ? nil : count == 1 ? "a \(thing)" : "\(count) \(thing)s"
        }
        var words: [String]
        switch page.kind {
        case .cover:
            words = ["The front cover: \(title)."] + (subtitle.isEmpty ? [] : ["\(subtitle)."])
        case .back:
            words = ["The back cover."]
        case .insideCover:
            words = [index == 1 ? "The inside of the front cover." : "The inside of the back cover."]
        case .title:
            words = ["The title page: \(title)."] + (subtitle.isEmpty ? [] : ["\(subtitle)."]) + (story.isEmpty ? [] : [story])
        case .blank:
            words = ["A blank page."]
        case .photos, .added:
            let videos = page.placements.filter(\.isVideo).count
            let shown = [counted(page.placements.count - videos, "photo"), counted(videos, "video")].compactMap { $0 }.joined(separator: " and ")
            let name = page.number.map { "Page \($0)" } ?? "A page"
            words = [shown.isEmpty ? "\(name)." : "\(name): \(shown)."]
            let captions = page.placements.map(\.caption).filter { !$0.isEmpty }
            if !captions.isEmpty { words.append("Captions: \(quoted(captions)).") }
            let notes = page.placements.filter(\.showsNote).map(\.note)
            if !notes.isEmpty { words.append("Notes: \(quoted(notes)).") }
        }
        let written = page.writings.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !written.isEmpty { words.append("Written on the page: \(quoted(written)).") }
        return words.joined(separator: " ")
    }
}
