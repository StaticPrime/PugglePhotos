import CoreGraphics
import Foundation
import Testing
@testable import PugglePhotosKit

/// The elements of an XML document, and its text, if it reads as XML at all.
private final class XMLReading: NSObject, XMLParserDelegate {
    var elements: [(name: String, attributes: [String: String])] = []
    var text = ""

    static func read(_ data: Data) -> XMLReading? {
        let parser = XMLParser(data: data)
        let reading = XMLReading()
        parser.delegate = reading
        return parser.parse() ? reading : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elements.append((elementName, attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func all(_ name: String) -> [[String: String]] { elements.filter { $0.name == name }.map(\.attributes) }
}

@Suite struct EPUBTests {
    @Test func checksumIsZIPs() {
        #expect(ZipArchive.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.checksum(Data()) == 0)
    }

    @Test func archiveKeepsItsFilesAsTheyAre() throws {
        var archive = ZipArchive(modified: Date(timeIntervalSince1970: 1_790_000_000))
        try archive.add("mimetype", Data("application/epub+zip".utf8))
        try archive.add("EPUB/Fotos día.txt", Data("¡hola!".utf8))
        let picture = Data((0..<5000).map { UInt8($0 % 251) })
        try archive.add("EPUB/images/a.jpg", picture)
        let data = archive.data
        let files = try #require(ZipArchive.files(in: data))
        #expect(files.map(\.path) == ["mimetype", "EPUB/Fotos día.txt", "EPUB/images/a.jpg"])
        #expect(files.map(\.contents) == [Data("application/epub+zip".utf8), Data("¡hola!".utf8), picture])
        #expect(files.allSatisfy { $0.method == 0 && $0.extra.isEmpty })
        // A reader tells an EPUB from its first bytes: the first file, stored, named mimetype, saying what it is.
        #expect(files[0].offset == 0)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: data[38..<58], as: UTF8.self) == "application/epub+zip")
        // A damaged picture is found out.
        var damaged = data
        damaged[files[2].offset + 30 + "EPUB/images/a.jpg".utf8.count + 10] ^= 0xFF
        #expect(ZipArchive.files(in: damaged) == nil)
        #expect(ZipArchive.files(in: Data("not an archive".utf8)) == nil)
    }

    func items(_ count: Int) -> [BookItem] {
        (0..<count).map { BookItem(id: PhotoID("p\($0)"), aspect: 4.0 / 3, isVideo: $0 == 5) }
    }

    func ebook(_ layout: BookLayout, title: String = "Beach & “Sun” <2025>", language: String = "en-US") -> EPUBBook {
        let pages = layout.pages.indices.map { index in
            EPUBBook.Page(picture: Data([0xFF, 0xD8, UInt8(index), 0xFF, 0xD9]), side: layout.ebookSide(index), contentsTitle: layout.contentsTitle(index),
                          number: layout.pages[index].number, description: layout.spokenPage(index, title: title, subtitle: "June 2025", story: "We went to the sea."))
        }
        return EPUBBook(title: title, language: language, identifier: UUID(uuidString: "6D2B1C88-0B5D-4F55-9C5E-2E2B6C0D7A10")!,
                        modified: Date(timeIntervalSince1970: 1_790_000_000), pixelWidth: 1800, pixelHeight: 2340, pages: pages)
    }

    @Test func anEPUBIsABookOfPictures() throws {
        let layout = BookLayout(items: items(7), captions: ["p0": "Sandcastle"], settings: BookSettings(perPage: .two), coverPhoto: "p1")
        let data = try ebook(layout).data()
        let files = try #require(ZipArchive.files(in: data))
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        #expect(files.first?.path == "mimetype" && files.first?.contents == Data("application/epub+zip".utf8))

        // Where the package is.
        let container = try #require(byPath["META-INF/container.xml"].flatMap(XMLReading.read))
        let packagePath = try #require(container.all("rootfile").first?["full-path"])
        let package = try #require(byPath[packagePath].flatMap(XMLReading.read), "the package reads as XML")
        #expect(package.text.contains("pre-paginated"), "pages of a fixed size")
        #expect(package.text.contains("Beach & “Sun” <2025>"), "the title, its & and <> kept")
        #expect(package.text.contains("urn:uuid:6d2b1c88-0b5d-4f55-9c5e-2e2b6c0d7a10"))

        // Every page, in order, with its picture, set out as in the book: the covers alone, then left beside right.
        let manifest = Dictionary(uniqueKeysWithValues: package.all("item").map { ($0["id"] ?? "", $0) })
        let spine = package.all("itemref")
        #expect(spine.count == layout.pages.count)
        let sides = spine.map { $0["properties"] ?? "" }
        #expect(sides.first == "rendition:page-spread-center" && sides.last == "rendition:page-spread-center")
        #expect(sides.dropFirst().dropLast().enumerated().allSatisfy { $1 == ($0 % 2 == 0 ? "page-spread-left" : "page-spread-right") })
        #expect(manifest.values.filter { $0["properties"] == "cover-image" }.map { $0["href"] } == ["images/page-001.jpg"])
        for (index, item) in spine.enumerated() {
            let page = try #require(manifest[item["idref"] ?? ""])
            let href = try #require(page["href"])
            let document = try #require(byPath["EPUB/" + href].flatMap(XMLReading.read), "page \(index + 1) reads as XML")
            let viewport = document.all("meta").first { $0["name"] == "viewport" }
            #expect(viewport?["content"] == "width=1800, height=2340")
            let image = try #require(document.all("img").first)
            #expect(byPath["EPUB/" + (image["src"] ?? "")] == Data([0xFF, 0xD8, UInt8(index), 0xFF, 0xD9]), "page \(index + 1) shows its own picture")
            #expect(!(image["alt"] ?? "").isEmpty, "page \(index + 1) is told in words")
            #expect(manifest.values.contains { $0["href"] == image["src"] && $0["media-type"] == "image/jpeg" })
        }

        // A table of contents, the page numbers and where things begin.
        let navigation = try #require(manifest.values.first { $0["properties"] == "nav" }?["href"])
        let nav = try #require(byPath["EPUB/" + navigation].flatMap(XMLReading.read))
        #expect(nav.all("nav").map { $0["epub:type"] } == ["toc", "page-list", "landmarks"])
        for title in ["Cover", "Title Page", "Page 1", "Page 4", "Back Cover"] { #expect(nav.text.contains(title)) }
        #expect(byPath["EPUB/toc.ncx"].flatMap(XMLReading.read) != nil)
        #expect(byPath["EPUB/style.css"].map { String(decoding: $0, as: UTF8.self) }?.contains("width: 1800px; height: 2340px") == true)
    }

    @Test func aBadLanguageTagFallsBackToEnglish() throws {
        let layout = BookLayout(items: items(2), captions: [:], settings: BookSettings(), coverPhoto: nil)
        let package = try #require(XMLReading.read(Data(ebook(layout, language: "en US\"").packageDocument.utf8)))
        #expect(package.elements.first { $0.name == "package" }?.attributes["xml:lang"] == "en")
    }

    @Test func pagesToldInWords() {
        var settings = BookSettings(perPage: .two)
        settings.writings = [BookWriting(text: "Best day", spot: .title, center: CGPoint(x: 300, y: 700))]
        let layout = BookLayout(items: items(7), captions: ["p0": "Sandcastle", "p1": "Waves"], notes: ["p0": "Mia built it"],
                                settings: settings, coverPhoto: "p1")
        let words = layout.pages.indices.map { layout.spokenPage($0, title: "Beach", subtitle: "June 2025", story: "We went to the sea.") }
        #expect(words[0] == "The front cover: Beach. June 2025.")
        #expect(words[1] == "The inside of the front cover.")
        #expect(words[2] == "The title page: Beach. June 2025. We went to the sea. Written on the page: “Best day”.")
        #expect(words[3].hasPrefix("Page 1: 2 photos. Captions: “Sandcastle”, “Waves”."))
        #expect(words[3].contains("“Mia built it”") == (layout.pages[3].placements.first { $0.id == "p0" }?.showsNote == true))
        #expect(words[5] == "Page 3: a photo and a video.")
        #expect(words.last == "The back cover.")
        #expect(layout.pages.indices.compactMap(layout.contentsTitle) == ["Cover", "Title Page", "Page 1", "Page 2", "Page 3", "Page 4", "Back Cover"])
    }
}
