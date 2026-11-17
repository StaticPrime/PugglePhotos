import AppKit
import AVFoundation
import Observation
import PugglePhotosKit
import SwiftUI
import UniformTypeIdentifiers

/// What the book's control bar shows.
@Observable
final class BookControlsModel {
    var place = ""
    var canGoBack = false
    var canGoOn = false
    var settings = BookSettings()
    var hiddenCount = 0
    var hasSelection = false
    var isBusy = false
    var choosingHandwriting = false
    @ObservationIgnored weak var controller: BookViewController?
}

/// Settings for photo books.
enum BookPreferences {
    static let alwaysPlayKey = "BookAlwaysPlaysVideos"
    static let soundKey = "BookPlaysVideoSound"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [alwaysPlayKey: false, soundKey: true])
    }
}

/// An album as a photo book: the book itself, and the bar beneath it for turning pages and choosing the paper,
/// frames, tilt, layout and cover. Every change to the book is saved with the album and can be undone.
final class BookViewController: NSViewController, BookViewDelegate {
    let library: LibraryController
    let bookView = BookView()
    let controls = BookControlsModel()
    private(set) var album: UUID?
    private(set) var layout = BookLayout(items: [], captions: [:], settings: BookSettings(), coverPhoto: nil)
    private var renderer: BookRenderer?
    private var pageImages: [Int: CGImage] = [:]
    private var pixelWidth: CGFloat = 0
    private var images: [PhotoID: CGImage] = [:]
    private var imageOrder: [PhotoID] = []
    private var requests: [PhotoID: ImageRequest] = [:]
    private var draft: (id: PhotoID, override: BookPlacementOverride)?
    /// The photo showing its back, and the one left off its page while it turns over.
    private var turnedOver: PhotoID?
    private var hiding: PhotoID?
    /// Where each album's book was left open.
    private var places: [UUID: Int] = [:]
    /// Called to open a photo in the viewer.
    var onOpenPhoto: ((PhotoID) -> Void)?
    /// Called to show a problem.
    var onProblem: ((String, String) -> Void)?
    /// Called to write a photo's note, beside a rectangle of the book view, in the book's handwriting.
    var onWriteNote: ((PhotoID, NSRect, String?) -> Void)?

    init(library: LibraryController) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
        controls.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        bookView.delegate = self
        bookView.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSHostingView(rootView: BookControlsView(model: controls))
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bookView)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bookView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bookView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bookView.topAnchor.constraint(equalTo: root.topAnchor),
            bookView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
        ])
        view = root
    }

    // MARK: The book

    /// Opens an album as a book, where it was left (or closed, the first time).
    func show(album id: UUID) {
        loadViewIfNeeded()
        if album != id {
            if let album { places[album] = bookView.state }
            album = id
            bookView.forgetTurnedOver()
            images = [:]
            imageOrder = []
            requests.values.forEach { $0.cancel() }
            requests = [:]
        }
        rebuild()
        bookView.go(to: places[id] ?? 0, animated: false)
        bookView.reload()
        updateControls()
        view.window?.makeFirstResponder(bookView)
    }

    /// Lays the book out again from the album (after it or its book settings changed), keeping the place.
    func rebuild() {
        guard let album, let albumValue = library.catalog.album(album) else { return }
        let arranger = library.arranger
        var ids = albumValue.items.filter(library.snapshot.contains)
        switch albumValue.order {
        case .custom: break
        case .oldestFirst: ids = arranger.sorted(ids, by: .dateTaken, ascending: true)
        case .newestFirst: ids = arranger.sorted(ids, by: .dateTaken, ascending: false)
        }
        let items = ids.compactMap { id in library.snapshot.item(id).map { BookItem(id: id, aspect: $0.aspectRatio, isVideo: $0.kind.isVideo) } }
        var captions: [PhotoID: String] = [:], notes: [PhotoID: String] = [:]
        for id in ids {
            guard let details = library.catalog.photos[id] else { continue }
            if !details.caption.isEmpty { captions[id] = details.caption }
            if !details.note.isEmpty { notes[id] = details.note }
        }
        var settings = library.catalog.book(album)
        if let draft { settings.overrides[draft.id] = draft.override }
        let cover = arranger.cover(of: albumValue)
        layout = BookLayout(items: items, captions: captions, notes: notes, settings: settings, coverPhoto: cover)
        let summary = arranger.summary(of: albumValue)
        let subtitle = [library.formatting.dateRange(from: summary.firstDate, to: summary.lastDate),
                        library.formatting.count(photos: summary.photos, videos: summary.videos)].compactMap { $0 }.joined(separator: " · ")
        let renderer = BookRenderer(settings: settings, title: albumValue.title, subtitle: subtitle, story: albumValue.note) { [weak self] id in
            self?.images[id]
        }
        renderer.coverPhoto = cover
        renderer.turnedOver = turnedOver
        renderer.hiding = hiding
        let library = library
        renderer.day = { id in library.snapshot.day(of: id).map(library.formatting.writtenDay) ?? "" }
        self.renderer = renderer
        pageImages = [:]
        prefetch()
    }

    /// The library or catalog changed: lay out again and show it.
    func libraryChanged() {
        guard album != nil, isViewLoaded else { return }
        if let album, library.catalog.album(album) == nil { return }
        rebuild()
        bookView.reload()
        updateControls()
    }

    var state: Int { bookView.state }

    // MARK: Pages and pictures

    func pageImage(_ page: Int) -> CGImage? {
        guard layout.pages.indices.contains(page), let renderer else { return nil }
        let width = (bookView.pageSize.width * (view.window?.backingScaleFactor ?? 2)).rounded()
        if width != pixelWidth {
            pixelWidth = width
            pageImages = [:]
        }
        if let cached = pageImages[page] { return cached }
        let pages = layout.state(layout.state(showing: page))
        let isLeft = pages.left == page
        let image = renderer.render(layout.pages[page], index: page, isLeft: isLeft, pixelWidth: width)
        pageImages[page] = image
        return image
    }

    /// Fetches the pictures for the pages around the open place, and lets go of ones far away.
    private func prefetch() {
        let state = bookView.state
        var pages: [Int] = []
        for nearby in (state - 1)...(state + 2) where (0..<layout.stateCount).contains(nearby) {
            let showing = layout.state(nearby)
            pages += [showing.left, showing.right].compactMap { $0 }
        }
        let wanted = Set(pages.flatMap { layout.pages[$0].placements.map(\.id) } + [renderer?.coverPhoto].compactMap { $0 })
        for id in wanted where images[id] == nil && requests[id] == nil {
            requests[id] = library.source.requestImage(id, pixels: CGSize(width: 1000, height: 1000), fit: true) { [weak self] image, isFinal in
                guard let self, let image else { return }
                if isFinal { requests[id] = nil }
                remember(image, for: id)
                imageArrived(id)
            }
        }
    }

    private func remember(_ image: CGImage, for id: PhotoID) {
        images[id] = image
        imageOrder.removeAll { $0 == id }
        imageOrder.append(id)
        // Keep the 60 most recent pictures.
        while imageOrder.count > 60 {
            let old = imageOrder.removeFirst()
            images[old] = nil
        }
    }

    private func imageArrived(_ id: PhotoID) {
        for (index, page) in layout.pages.enumerated() where page.placements.contains(where: { $0.id == id }) || (page.kind == .cover && renderer?.coverPhoto == id) {
            pageImages[index] = nil
            bookView.reloadPage(index)
        }
    }

    // MARK: Book view

    var alwaysPlaysVideos: Bool { UserDefaults.standard.bool(forKey: BookPreferences.alwaysPlayKey) }
    var playsVideoSound: Bool { UserDefaults.standard.bool(forKey: BookPreferences.soundKey) }

    func bookDidChangeState(_ state: Int) {
        if let album { places[album] = state }
        // A photo turned over goes back when its page is turned away.
        if let turned = bookView.turnedOver, let page = layout.find(turned)?.page {
            let showing = layout.state(state)
            if page != showing.left, page != showing.right { bookView.forgetTurnedOver() }
        }
        prefetch()
        updateControls()
    }

    func bookSelectionDidChange(_ id: PhotoID?) { updateControls() }

    func bookOpenPhoto(_ id: PhotoID) { onOpenPhoto?(id) }

    func bookDescription(of id: PhotoID) -> String { library.spokenDescription(of: id) }

    func bookPreview(_ id: PhotoID, center: CGPoint?, angle: Double?) {
        var override = draft?.id == id ? draft!.override : (library.catalog.book(album ?? UUID()).overrides[id] ?? BookPlacementOverride())
        if let center { override.center = center }
        if let angle { override.angle = angle }
        draft = (id, override)
        rebuildKeepingImages()
    }

    func bookCommit(_ id: PhotoID, center: CGPoint?, angle: Double?) {
        draft = nil
        guard let album else { return }
        library.edit(center != nil ? "Move Photo" : "Turn Photo") { catalog in
            var settings = catalog.book(album)
            var override = settings.overrides[id] ?? BookPlacementOverride()
            if let center { override.center = center }
            if let angle { override.angle = angle }
            settings.overrides[id] = override
            catalog.setBook(settings, for: album)
        }
    }

    func bookPreviewSticky(_ id: PhotoID, _ sticky: BookSticky) {
        var override = draft?.id == id ? draft!.override : (library.catalog.book(album ?? UUID()).overrides[id] ?? BookPlacementOverride())
        override.sticky = sticky
        draft = (id, override)
        rebuildKeepingImages()
    }

    func bookCommitSticky(_ id: PhotoID, _ sticky: BookSticky, actionName: String) {
        draft = nil
        change(actionName) { settings in settings.changeOverride(id) { $0.sticky = sticky } }
    }

    func bookWriteNote(_ id: PhotoID, at rect: NSRect) { onWriteNote?(id, rect, layout.settings.handwriting) }

    /// Writes on the back of a photo in the book: beside it, if it's on the open pages.
    func writeNote(_ id: PhotoID) {
        if let rect = bookView.rect(of: id) { onWriteNote?(id, rect, layout.settings.handwriting) }
    }

    func bookSetTurnedOver(_ id: PhotoID?, hiding: PhotoID?) {
        turnedOver = id
        self.hiding = hiding
        renderer?.turnedOver = id
        renderer?.hiding = hiding
        pageImages = [:]
        updateControls()
    }

    func bookPhotoSide(_ id: PhotoID, back: Bool, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard let renderer, let placement = layout.find(id)?.placement else { return nil }
        return renderer.photoSide(placement, back: back, scale: scale)
    }

    /// Right-click on a photo or its sticky note: turn it over, write on it, how its note shows, the sticky note's
    /// color, and leaving it out.
    func bookMenu(for id: PhotoID, sticky: Bool) -> NSMenu? {
        guard let placement = layout.find(id)?.placement else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ value: Any? = nil, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value ?? id
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add(bookView.turnedOver == id ? "Turn Back Over" : "Turn Over", #selector(menuTurnOver(_:)))
        add("Write on the Back…", #selector(menuWriteNote(_:)))
        menu.addItem(.separator())
        let noteMenu = NSMenu()
        let current = layout.settings.overrides[id]?.noteStyle
        let bookStyle = layout.settings.noteStyle.displayName(for: layout.settings.frame)
        for (title, style) in [("As the Book Does (\(bookStyle))", nil)] + BookNoteStyle.allCases.map({ ($0.singularName, Optional($0)) }) {
            let item = NSMenuItem(title: title, action: #selector(menuNoteStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NoteChoice(id: id, style: style)
            item.state = current == style ? .on : .off
            noteMenu.addItem(item)
        }
        let noteItem = NSMenuItem(title: "Note", action: nil, keyEquivalent: "")
        noteItem.submenu = noteMenu
        menu.addItem(noteItem)
        if placement.hasSticky {
            let colors = NSMenu()
            for color in BookStickyColor.allCases {
                let item = NSMenuItem(title: color.displayName, action: #selector(menuStickyColor(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = StickyColorChoice(id: id, color: color)
                item.state = placement.sticky.color == color ? .on : .off
                item.image = MenuBuilder.labelImage(NSColor(cgColor: BookRenderer.color(color.color)) ?? .yellow)
                colors.addItem(item)
            }
            let colorItem = NSMenuItem(title: "Sticky Note Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            menu.addItem(colorItem)
            if layout.settings.overrides[id]?.sticky != nil { add("Put Sticky Note Back", #selector(menuResetSticky(_:))) }
        }
        if !sticky {
            menu.addItem(.separator())
            add("Leave Out of Book", #selector(menuLeaveOut(_:)))
        }
        return menu
    }

    private final class NoteChoice: NSObject {
        let id: PhotoID, style: BookNoteStyle?
        init(id: PhotoID, style: BookNoteStyle?) { self.id = id; self.style = style }
    }

    private final class StickyColorChoice: NSObject {
        let id: PhotoID, color: BookStickyColor
        init(id: PhotoID, color: BookStickyColor) { self.id = id; self.color = color }
    }

    @objc private func menuTurnOver(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? PhotoID { bookView.turnOver(id) }
    }

    @objc private func menuWriteNote(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? PhotoID { writeNote(id) }
    }

    @objc private func menuNoteStyle(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NoteChoice else { return }
        setNoteStyle(choice.style, for: choice.id)
    }

    /// How one photo's note shows; nil to show it as the book does.
    func setNoteStyle(_ style: BookNoteStyle?, for id: PhotoID) {
        change(style == .hidden ? "Hide Note" : "Show Note") { settings in settings.changeOverride(id) { $0.noteStyle = style } }
    }

    @objc private func menuStickyColor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? StickyColorChoice, let placement = layout.find(choice.id)?.placement else { return }
        var sticky = placement.sticky
        sticky.color = choice.color
        change("Sticky Note Color") { settings in settings.changeOverride(choice.id) { $0.sticky = sticky } }
    }

    @objc private func menuResetSticky(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? PhotoID else { return }
        change("Put Sticky Note Back") { settings in settings.changeOverride(id) { $0.sticky = nil } }
    }

    @objc private func menuLeaveOut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? PhotoID else { return }
        bookView.select(id)
        leaveOutSelected()
    }

    /// Lays out again without dropping the pictures, for live previews.
    private func rebuildKeepingImages() {
        let kept = images
        rebuild()
        images = kept
    }

    func bookPlayer(for id: PhotoID, completion: @escaping @MainActor (AVPlayer?) -> Void) {
        library.source.requestPlayerItem(id) { item in
            completion(item.map { AVPlayer(playerItem: $0) })
        }
    }

    // MARK: Commands

    func next() { bookView.next() }
    func previous() { bookView.previous() }

    /// Changes the book's settings as one undoable step.
    func change(_ actionName: String, _ change: (inout BookSettings) -> Void) {
        guard let album else { return }
        var settings = library.catalog.book(album)
        change(&settings)
        library.edit(actionName) { $0.setBook(settings, for: album) }
    }

    func tiltSelected(by degrees: Double) {
        guard let id = bookView.selected, let placement = layout.find(id)?.placement else { return }
        let angle = degrees == 0 ? 0 : BookView.normalized(placement.angle + degrees)
        bookCommit(id, center: nil, angle: angle)
    }

    func leaveOutSelected() {
        guard let id = bookView.selected else { return }
        bookView.select(nil)
        change("Leave Out of Book") { settings in
            if !settings.hidden.contains(id) { settings.hidden.append(id) }
        }
    }

    func putBackLeftOut() { change("Put Back in Book") { $0.hidden = [] } }

    /// Lays the book out afresh. Photos go to new places; their sticky notes and how their notes show stay with them.
    func shuffle() {
        change("Shuffle Book") { settings in
            settings.seed = settings.seed &+ 1
            for id in Array(settings.overrides.keys) {
                settings.changeOverride(id) { override in
                    override.center = nil
                    override.angle = nil
                    override.scale = nil
                }
            }
        }
    }

    /// Puts back every photo and sticky note the person moved, turned or resized; how notes show stays.
    func resetLayout() {
        change("Reset Book Layout") { settings in
            for id in Array(settings.overrides.keys) {
                settings.changeOverride(id) { override in
                    override = BookPlacementOverride(noteStyle: override.noteStyle)
                }
            }
        }
    }

    /// Where in the book a place is: "Cover", "Title Page", "Pages 3–4 of 20", "Back Cover".
    func bookPlace(_ state: Int) -> String {
        let pages = layout.state(state)
        if state == 0 { return "Cover" }
        if state == layout.stateCount - 1 { return "Back Cover" }
        let numbers = [pages.left, pages.right].compactMap { $0 }.compactMap { layout.pages[$0].number }
        let photoPages = layout.pages.filter { $0.kind == .photos }.count
        return numbers.isEmpty ? (state == 1 ? "Title Page" : "End")
            : "Page\(numbers.count > 1 ? "s" : "") \(numbers.map(String.init).joined(separator: "–")) of \(photoPages)"
    }

    private func updateControls() {
        let count = layout.stateCount
        let state = bookView.state
        controls.place = bookPlace(state)
        controls.canGoBack = state > 0
        controls.canGoOn = state < count - 1
        controls.settings = layout.settings
        controls.hiddenCount = layout.settings.hidden.count
        controls.hasSelection = bookView.selected != nil
    }

    // MARK: PDF and printing

    /// Every picture in the book at print size, then `body`.
    private func withPrintPictures(_ body: @escaping @MainActor () -> Void) {
        let ids = Array(Set(layout.pages.flatMap { $0.placements.map(\.id) } + [renderer?.coverPhoto].compactMap { $0 }))
        guard !ids.isEmpty else {
            body()
            return
        }
        controls.isBusy = true
        let gathering = PrintPictures(count: ids.count)
        for id in ids {
            library.source.requestImage(id, pixels: CGSize(width: 1800, height: 1800), fit: true) { [weak self] image, isFinal in
                guard isFinal else { return }
                if let image { gathering.images[id] = image }
                gathering.remaining -= 1
                guard gathering.remaining == 0, let self else { return }
                controls.isBusy = false
                let previous = renderer?.image
                let screen = images
                renderer?.image = { gathering.images[$0] ?? screen[$0] }
                body()
                if let previous { renderer?.image = previous }
            }
        }
    }

    private final class PrintPictures {
        var images: [PhotoID: CGImage] = [:]
        var remaining: Int
        init(count: Int) { remaining = count }
    }

    /// The book as a PDF: the front cover, each spread, the back cover.
    func pdfData() -> Data {
        let data = NSMutableData()
        guard let renderer, let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(origin: .zero, size: CGSize(width: BookLayout.pageSize.width * 2, height: BookLayout.pageSize.height))
        guard let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: renderer.title] as CFDictionary) else { return Data() }
        for state in 0..<layout.stateCount {
            let pages = layout.state(state)
            let single = pages.left == nil || pages.right == nil
            var media = CGRect(origin: .zero, size: CGSize(width: BookLayout.pageSize.width * (single ? 1 : 2), height: BookLayout.pageSize.height))
            context.beginPage(mediaBox: &media)
            drawSpread(state, in: context, height: media.height)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Draws one place in the book with its pages side by side, from the top left of a page `height` tall.
    func drawSpread(_ state: Int, in context: CGContext, height: CGFloat) {
        guard let renderer else { return }
        // On paper, every photo shows its front.
        let turned = renderer.turnedOver, hidden = renderer.hiding
        renderer.turnedOver = nil
        renderer.hiding = nil
        defer {
            renderer.turnedOver = turned
            renderer.hiding = hidden
        }
        let pages = layout.state(state)
        var x: CGFloat = 0
        for (page, left) in [(pages.left, true), (pages.right, false)] {
            guard let page else { continue }
            context.saveGState()
            context.translateBy(x: x, y: height)
            context.scaleBy(x: 1, y: -1)
            renderer.draw(layout.pages[page], index: page, isLeft: left, in: context)
            context.restoreGState()
            x += BookLayout.pageSize.width
        }
    }

    func exportPDF() {
        guard let window = view.window, let album, let title = library.catalog.album(album)?.title else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.withPrintPictures {
                    guard let self else { return }
                    do {
                        try self.pdfData().write(to: url)
                    } catch {
                        self.onProblem?("The book couldn’t be saved as a PDF.", error.localizedDescription)
                    }
                }
            }
        }
    }

    func printBook() {
        guard let window = view.window else { return }
        withPrintPictures { [weak self] in
            guard let self else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.orientation = .landscape
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            let printView = BookPrintView(controller: self)
            let operation = NSPrintOperation(view: printView, printInfo: info)
            operation.jobTitle = renderer?.title ?? "Photo Book"
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

/// Prints a book a spread to a sheet.
final class BookPrintView: NSView {
    private weak var controller: BookViewController?

    init(controller: BookViewController) {
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: BookLayout.pageSize.width * 2, height: BookLayout.pageSize.height)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: controller?.layout.stateCount ?? 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        let page = (NSPrintOperation.current?.currentPage ?? 1) - 1
        context.saveGState()
        // The view is flipped already; the spread drawing flips again, so start from the bottom.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let pages = controller.layout.state(page)
        if pages.left == nil { context.translateBy(x: BookLayout.pageSize.width / 2, y: 0) }
        if pages.right == nil { context.translateBy(x: BookLayout.pageSize.width / 2, y: 0) }
        controller.drawSpread(page, in: context, height: bounds.height)
        context.restoreGState()
    }
}

/// The bar under the book.
struct BookControlsView: View {
    @Bindable var model: BookControlsModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.controller?.previous() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Previous page (←)")
            Text(model.place)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 120)
            Button { model.controller?.next() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoOn)
                .help("Next page (→)")
            Divider().frame(height: 20)
            picker("Paper", BookPaper.allCases, \.paper, \.displayName)
            picker("Frames", BookFrame.allCases, \.frame, \.displayName)
            picker("Tilt", BookTilt.allCases, \.tilt, \.displayName)
            picker("Layout", BookPerPage.allCases, \.perPage, \.displayName)
            picker("Cover", BookCover.allCases, \.cover, \.displayName)
            Menu {
                ForEach(BookNoteStyle.allCases, id: \.self) { style in
                    Button {
                        model.controller?.change("Notes") { $0.notes = style }
                    } label: {
                        let name = style.displayName(for: model.settings.frame)
                        if model.settings.noteStyle == style { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Text("Notes")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How the photos’ notes show in this book")
            Button { model.choosingHandwriting = true } label: { Label("Handwriting", systemImage: "pencil.and.scribble") }
                .help("The handwriting this book is written in")
                .popover(isPresented: $model.choosingHandwriting) {
                    BookHandwritingView(model: model).padding(14).frame(width: 440)
                }
            Button { model.controller?.shuffle() } label: { Label("Shuffle", systemImage: "dice") }
                .help("Lay the book out afresh")
            if model.hiddenCount > 0 {
                Button("Put Back \(model.hiddenCount)") { model.controller?.putBackLeftOut() }
                    .help("Put back the photos left out of the book")
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            Button { model.controller?.exportPDF() } label: { Label("PDF", systemImage: "arrow.down.doc") }
                .help("Save the book as a PDF")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    private func picker<Value: Hashable>(_ title: String, _ values: [Value], _ path: WritableKeyPath<BookSettings, Value>,
                                         _ name: KeyPath<Value, String>) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    model.controller?.change(title) { $0[keyPath: path] = value }
                } label: {
                    if model.settings[keyPath: path] == value { Label(value[keyPath: name], systemImage: "checkmark") } else { Text(value[keyPath: name]) }
                }
            }
        } label: {
            Text(title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A book's handwriting: the one chosen in Settings, or its own.
struct BookHandwritingView: View {
    @Bindable var model: BookControlsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("As in Settings (\(Handwriting.name(of: Handwriting.family)))", isOn: Binding(
                get: { model.settings.handwriting == nil },
                set: { follows in model.controller?.change("Handwriting") { $0.handwriting = follows ? nil : Handwriting.family } }))
            HandwritingPicker(family: Binding(
                get: { model.settings.handwriting ?? Handwriting.family },
                set: { family in model.controller?.change("Handwriting") { $0.handwriting = family } }),
                followsSettings: Binding(get: { model.settings.handwriting == nil }, set: { _ in }))
        }
    }
}
