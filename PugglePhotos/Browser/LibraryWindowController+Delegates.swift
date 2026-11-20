import AppKit
import PugglePhotosKit
import SwiftUI

// MARK: The grid and the list

extension LibraryWindowController: PhotoBrowserDelegate {
    func browserSelectionDidChange(_ ids: [PhotoID]) { setSelection(ids) }

    func browserOpen(_ id: PhotoID) { openViewer(id) }

    func browserMenu(for ids: [PhotoID]) -> NSMenu? { photoMenu(for: ids) }

    func browserDeleteSelection() {
        guard let album = currentAlbum, !state.selection.isEmpty else {
            NSSound.beep()
            return
        }
        remove(state.selection, fromAlbum: album.id)
    }

    func browserDrop(_ ids: [PhotoID], before indexPath: IndexPath, anchor: NSRect, in view: NSView) -> Bool {
        guard content.sections.indices.contains(indexPath.section) else { return false }
        let section = content.sections[indexPath.section].items
        let gap = min(indexPath.item, section.count)
        // An album in its own order: the photos move (or join) at that spot.
        if let album = currentAlbum, arrangement.sort == .custom {
            let anchorID = section[gap...].first { !ids.contains($0) }
            let index = anchorID.flatMap { album.items.firstIndex(of: $0) } ?? album.items.count
            library.moveInAlbum(ids, album: album.id, toIndex: index)
            reveal(ids)
            return true
        }
        guard content.dropsBetween else { return false }
        // In date order: the photos take a moment between their new neighbors.
        let moving = Set(ids)
        let before = section[..<gap].last { !moving.contains($0) }.flatMap { library.snapshot.item($0)?.date }
        let after = section[gap...].first { !moving.contains($0) }.flatMap { library.snapshot.item($0)?.date }
        let (previous, next) = arrangement.ascending ? (before, after) : (after, before)
        let items = ids.compactMap { library.snapshot.item($0) }.map { (id: $0.id, date: $0.date) }
        let changes = Redate.place(items, after: previous, before: next)
        guard let first = changes.first else { return false }
        if changes.allSatisfy({ abs($0.to.timeIntervalSince($0.from)) < 1.5 }) { return false }
        let moment = library.formatting.dateAndTime(first.to)
        confirm(changes, .between(moment), actionName: ids.count == 1 ? "Move Photo" : "Move Photos", anchor: anchor, of: view)
        return true
    }

    func browserHeaderDrop(_ ids: [PhotoID], _ drop: HeaderDrop, anchor: NSView) -> Bool {
        switch drop {
        case let .day(day):
            move(ids, to: day, anchor: anchor.bounds, of: anchor)
        case let .album(album):
            add(ids, toAlbum: album)
        case let .label(label):
            library.edit("Add Label") { $0.setLabel(label, on: ids, true) }
        }
        return true
    }

    func browserRenameAlbum(_ title: String) {
        guard let album = currentAlbum else { return }
        library.renameAlbum(album.id, to: title)
    }

    func browserSetAlbumNote(_ note: String) {
        guard let album = currentAlbum else { return }
        library.edit("Album Description") { $0.setAlbumNote(album.id, to: note) }
    }

    func browserOpenBook() { setViewMode(.book) }

    func browserPlayAlbum() {
        guard let album = currentAlbum, let memory = memories.finder.album(album.id) else { return }
        play(memory)
    }

    func browserWriteNote(for id: PhotoID, anchor: NSView) { writeNote(for: id, anchor: anchor) }

    /// The pencil on a day's heading: a popover under it to write in. A click elsewhere keeps what was written;
    /// only Cancel (or Esc) throws it away.
    func browserWriteJournal(for day: CivilDay, anchor: NSView) {
        let draft = JournalDraft(library.catalog.entry(for: day))
        let title = library.formatting.longDay(day), count = photoCountLine(for: day)
        presentPopover(at: anchor.bounds, of: anchor, edge: anchor.isFlipped ? .maxY : .minY, onClose: { [weak self] in
            guard !draft.isCancelled else { return }
            self?.journalSave(draft.text, mood: draft.mood, for: day)
        }) { close in
            JournalEditorView(draft: draft, dayTitle: title, photoCount: count, onCancel: close, onSave: close)
        }
    }
}

// MARK: The journal

extension LibraryWindowController: JournalActions {
    /// Saves what was written about a day, if it changed; writing nothing deletes the entry. Undo puts it back.
    func journalSave(_ text: String, mood: String, for day: CivilDay) {
        let entry = library.catalog.entry(for: day)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (entry?.text ?? "") || mood != (entry?.mood ?? "") else { return }
        let deleting = trimmed.isEmpty && mood.isEmpty
        library.edit(deleting ? "Delete Journal Entry" : "Journal Entry") { $0.setEntry(trimmed, mood: mood, for: day) }
    }

    func journalShowDay(_ day: CivilDay) {
        sidebar.calendar.show(day)
        sidebar.calendar.selectedDay = day
        calendarSelect(day)
    }

    func journalPlayDay(_ day: CivilDay) {
        guard let memory = memories.finder.day(day) else {
            NSSound.beep()
            return
        }
        play(memory)
    }

    /// Write in the journal about a day, in a sheet: File ▸ Write in Journal and the info panel.
    func writeJournal(about day: CivilDay) {
        let draft = JournalDraft(library.catalog.entry(for: day))
        let title = library.formatting.longDay(day), count = photoCountLine(for: day)
        presentSheet { [weak self] dismiss in
            JournalEditorView(draft: draft, dayTitle: title, photoCount: count, onCancel: dismiss) {
                dismiss()
                self?.journalSave(draft.text, mood: draft.mood, for: day)
            }
        }
    }

    /// "12 photos and 2 videos", or "No photos" for a day.
    func photoCountLine(for day: CivilDay) -> String {
        let ids = library.snapshot.ids(on: day)
        guard !ids.isEmpty else { return "No photos from this day" }
        let counts = library.snapshot.counts(of: ids)
        return library.formatting.count(photos: counts.photos, videos: counts.videos)
    }
}

// MARK: Memories and slideshows

extension LibraryWindowController: MemoriesActions {
    var memoriesToday: Int { memories.page.onThisDay.filter { if case .onThisDay = $0.kind { true } else { false } }.count }

    /// Plays a memory full screen on this window's screen. Show Photos at the end opens its photos here.
    func play(_ memory: Memory) {
        guard !memory.items.isEmpty else {
            NSSound.beep()
            return
        }
        closeViewer(refreshing: false)
        SlideshowController.play(memory, library: library, on: window?.screen) { [weak self] wantsPhotos in
            guard let self else { return }
            window?.makeKeyAndOrderFront(nil)
            if wantsPhotos { showPhotos(of: memory) }
        }
    }

    func showPhotos(of memory: Memory) {
        switch memory.kind {
        case let .album(id): go(to: .album(id))
        case let .label(id): go(to: .label(id))
        default: go(to: .memory(memory.id))
        }
    }

    /// The memory View ▸ Play Slideshow plays: the album, the memory or the selection showing, today's memory on
    /// the Memories page, or else the photos showing, from the selected one on.
    func slideshowForCurrentPlace() -> Memory? {
        let finder = memories.finder
        if state.source == .memories { return memories.page.onThisDay.first ?? memories.page.highlights.first ?? memories.page.years.first }
        if state.source == .journal {
            return finder.day(journalComposer.day ?? CivilDay(Date(), in: library.formatting.timeZone)) ?? finder.journal(minimum: 1)
        }
        if state.selection.count > 1 { return finder.selection(state.selection, title: "Selected Photos") }
        if let album = currentAlbum { return finder.album(album.id) }
        if let memory = currentMemory { return memory }
        var ids = viewerSequence
        if let start = state.viewerID ?? state.selection.first, let index = ids.firstIndex(of: start) { ids = Array(ids[index...]) }
        return finder.selection(Array(ids.prefix(200)), title: window?.title ?? "Slideshow")
    }
}

// MARK: Moving photos in time

extension LibraryWindowController {
    /// Moves photos to a day, asking first unless the person turned that off.
    func move(_ ids: [PhotoID], to day: CivilDay, anchor: NSRect, of view: NSView) {
        let items = ids.compactMap { library.snapshot.item($0) }.map { (id: $0.id, date: $0.date) }
        guard !items.isEmpty else { return }
        let actionName = items.count == 1 ? "Move Photo to Another Day" : "Move Photos to Another Day"
        let apply = { [weak self] (choice: Redate.TimeChoice) in
            guard let self else { return }
            let changes = Redate.move(items, to: day, time: choice, calendar: library.formatting.calendar)
            changeDates(changes, actionName: actionName)
        }
        guard Preferences.askBeforeChangingDates else {
            apply(.keepTimes)
            return
        }
        // Beside the calendar rather than over it; under a heading.
        let edge: NSRectEdge = view is MiniCalendarView ? .maxX : (view.isFlipped ? .maxY : .minY)
        presentPopover(at: anchor, of: view, edge: edge) { close in
            RedateConfirmView(count: items.count, kind: .day(library.formatting.longDay(day)), onCancel: close) { choice in
                close()
                apply(choice)
            }
        }
    }

    /// Asks before applying date changes (unless the person turned that off).
    func confirm(_ changes: [Redate.Change], _ kind: RedateConfirmView.Kind, actionName: String, anchor: NSRect, of view: NSView) {
        guard Preferences.askBeforeChangingDates else {
            changeDates(changes, actionName: actionName)
            return
        }
        presentPopover(at: anchor, of: view) { [weak self] close in
            RedateConfirmView(count: changes.count, kind: kind, onCancel: close) { _ in
                close()
                self?.changeDates(changes, actionName: actionName)
            }
        }
    }

    /// Writes new dates to the library, then shows the photos where they landed.
    func changeDates(_ changes: [Redate.Change], actionName: String) {
        let ids = changes.map(\.id)
        library.changeDates(changes, actionName: actionName) { [weak self] success in
            guard let self, success else { return }
            setSelection(ids)
            reveal(ids)
            if let first = changes.map(\.to).min() { sidebar.calendar.show(CivilDay(first, in: library.formatting.timeZone)) }
        }
    }
}

// MARK: The sidebar

extension LibraryWindowController: SidebarDelegate {
    // MARK: Sidebar

    func sidebarSelect(_ source: LibrarySource) {
        guard source != state.source || state.viewerID != nil else { return }
        go(to: source)
    }

    func sidebarNewAlbum() { newAlbum(with: []) }
    func sidebarNewSharedAlbum() { presentShareSheet(album: nil) }
    func sidebarNewLabel() { newLabel(for: []) }

    func sidebarMenu(for source: LibrarySource) -> NSMenu? {
        let menu = NSMenu()
        switch source {
        case let .album(id):
            menu.addItem(represented(MenuBuilder.item("Open as Book", #selector(phOpenAlbumAsBook(_:)), symbol: "book"), id))
            menu.addItem(represented(MenuBuilder.item(sharing.mine(id) != nil ? "Manage Shared Album…" : "Share Album…",
                                                      #selector(phShareAlbum(_:)), symbol: "person.crop.circle.badge.plus"), id))
            menu.addItem(.separator())
            menu.addItem(represented(MenuBuilder.item("Rename Album", #selector(phRenameAlbum(_:))), id))
            menu.addItem(represented(MenuBuilder.item("Delete Album…", #selector(phDeleteAlbum(_:))), id))
        case let .label(id):
            menu.addItem(represented(MenuBuilder.item("Edit Label…", #selector(phEditLabel(_:))), id))
            menu.addItem(represented(MenuBuilder.item("Delete Label…", #selector(phDeleteLabel(_:))), id))
        case .allAlbums:
            menu.addItem(MenuBuilder.item("New Album", #selector(phNewAlbum(_:))))
        case let .sharedAlbum(id):
            menu.addItem(represented(MenuBuilder.item("Open as Book", #selector(phOpenAlbumAsBook(_:)), symbol: "book"), id))
            menu.addItem(.separator())
            menu.addItem(represented(MenuBuilder.item("Leave Shared Album…", #selector(phLeaveSharedAlbum(_:))), id))
        default:
            return nil
        }
        for item in menu.items { item.target = self }
        return menu
    }

    func sidebarRenameAlbum(_ id: UUID, to title: String) {
        library.renameAlbum(id, to: title)
    }

    func sidebarDrop(_ ids: [PhotoID], on source: LibrarySource) -> Bool {
        switch source {
        case let .album(album): add(ids, toAlbum: album)
        case let .label(label): library.edit("Add Label") { $0.setLabel(label, on: ids, true) }
        case .favorites: library.setFavorite(ids, true)
        default: return false
        }
        return true
    }

    func sidebarDropOnAlbumsHeading(_ ids: [PhotoID]) -> Bool {
        newAlbum(with: ids)
        return true
    }

    func calendarSelect(_ day: CivilDay) {
        if state.source != .library || !state.searchText.isEmpty { go(to: .library) }
        if arrangement.grouping != .day { setGrouping(.day) }
        closeViewer()
        guard let section = content.sections.firstIndex(where: { $0.key.days.map { $0.contains(day) } ?? false })
            ?? nearestSection(to: day) else { return }
        stayAtChosenPlace()
        if state.viewMode == .gallery { grid.scroll(toSection: section) } else { list.select(content.sections[section].items) }
    }

    private func nearestSection(to day: CivilDay) -> Int? {
        content.sections.indices.min { a, b in
            let da = content.sections[a].key.days.map { abs($0.lowerBound.number - day.number) } ?? .max
            let db = content.sections[b].key.days.map { abs($0.lowerBound.number - day.number) } ?? .max
            return da < db
        }
    }

    func calendarDrop(_ ids: [PhotoID], on day: CivilDay, rect: NSRect, in view: NSView) -> Bool {
        move(ids, to: day, anchor: rect, of: view)
        return true
    }
}

// MARK: Album covers

extension LibraryWindowController: AlbumsViewDelegate {
    func albumsOpen(_ id: UUID) { go(to: .album(id)) }

    func albumsMenu(for id: UUID) -> NSMenu? { sidebarMenu(for: .album(id)) }

    func albumsNewAlbum() { newAlbum(with: []) }

    func albumsDrop(_ ids: [PhotoID], on album: UUID) -> Bool {
        add(ids, toAlbum: album)
        return true
    }
}

// MARK: The map

extension LibraryWindowController: MapViewDelegate {
    func mapOpen(_ id: PhotoID, among photos: [PhotoID]) {
        mapViewerPhotos = photos
        openViewer(id)
    }
}

// MARK: The viewer

extension LibraryWindowController: ViewerDelegate {
    /// The photos the viewer goes through: what's showing, or, opened from the map, the photos in view there.
    var viewerSequence: [PhotoID] {
        if state.source == .map, let mapViewerPhotos { return mapViewerPhotos }
        var seen = Set<PhotoID>()
        return content.allIDs.filter { seen.insert($0).inserted }
    }

    func viewerDidShow(_ id: PhotoID) {
        state.viewerID = id
        setSelection([id])
        let item = library.snapshot.item(id)
        window?.subtitle = item.map { library.formatting.dateAndTime($0.date) } ?? ""
    }

    func viewerClose() { closeViewer() }
}

// MARK: The info panel

extension LibraryWindowController: InspectorActions {
    func inspectorSetCaption(_ caption: String, for ids: [PhotoID]) {
        library.edit("Caption") { $0.setCaption(caption, for: ids) }
    }

    func inspectorSetNote(_ note: String, for id: PhotoID) {
        library.edit("Note") { $0.setNote(note, for: id) }
    }

    func inspectorToggleLabel(_ label: UUID, on ids: [PhotoID]) {
        library.edit("Label") { $0.toggleLabel(label, on: ids) }
    }

    func inspectorNewLabel(for ids: [PhotoID]) { newLabel(for: ids) }

    func inspectorToggleFavorite(_ ids: [PhotoID]) { library.toggleFavorite(ids) }

    func inspectorAdd(_ ids: [PhotoID], toAlbum album: UUID) { add(ids, toAlbum: album) }

    func inspectorRemove(_ ids: [PhotoID], fromAlbum album: UUID) { remove(ids, fromAlbum: album) }

    func inspectorNewAlbum(with ids: [PhotoID]) { newAlbum(with: ids) }

    func inspectorOpenAlbum(_ album: UUID) { go(to: .album(album)) }

    func inspectorChangeDate(_ ids: [PhotoID]) { showChangeDate(for: ids) }

    func inspectorWriteJournal(_ day: CivilDay) { writeJournal(about: day) }
}

// MARK: Shared actions

extension LibraryWindowController {
    func add(_ ids: [PhotoID], toAlbum album: UUID) {
        library.addToAlbum(ids, album: album)
    }

    func remove(_ ids: [PhotoID], fromAlbum album: UUID) {
        library.removeFromAlbum(ids, album: album)
    }

    /// Makes an album (with these photos, if any), then lets the person name it in the sidebar.
    func newAlbum(with ids: [PhotoID]) {
        let created = library.newAlbum(items: ids)
        if ids.isEmpty {
            go(to: .album(created))
        }
        sidebar.reload()
        DispatchQueue.main.async { [weak self] in self?.sidebar.beginRenaming(created) }
    }

    /// Asks for a new label's name, color and emoji, and puts it on these photos.
    func newLabel(for ids: [PhotoID]) {
        let suggested = library.catalog.unusedLabelName()
        presentSheet { [weak self] dismiss in
            LabelEditorView(label: nil, suggestedName: suggested, onCancel: dismiss) { name, color, emoji in
                dismiss()
                self?.library.edit("New Label") { catalog in
                    let id = catalog.addLabel(name: name, color: color, emoji: emoji)
                    catalog.setLabel(id, on: ids, true)
                }
            }
        }
    }

    func editLabel(_ id: UUID) {
        guard let label = library.catalog.label(id) else { return }
        presentSheet { [weak self] dismiss in
            LabelEditorView(label: label, suggestedName: label.name, onCancel: dismiss) { name, color, emoji in
                dismiss()
                self?.library.edit("Edit Label") { $0.updateLabel(PhotoLabel(id: id, name: name, color: color, emoji: emoji)) }
            }
        }
    }

    /// Writing on the back of a photo: in a popover beside it (beside `rect` of `anchor`, or all of it), or a sheet
    /// when it isn't on screen, in a book's handwriting or the one chosen in Settings. A click elsewhere keeps what
    /// was written; only Cancel throws it away.
    func writeNote(for id: PhotoID, anchor: NSView?, rect: NSRect? = nil, family: String? = nil) {
        let draft = NoteDraft(library.catalog.details(id).note)
        let title = library.snapshot.day(of: id).map(library.formatting.longDay) ?? ""
        let save: () -> Void = { [weak self] in
            guard let self, !draft.isCancelled else { return }
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text != library.catalog.details(id).note else { return }
            library.edit(text.isEmpty ? "Erase Note" : "Note") { $0.setNote(text, for: id) }
        }
        if let anchor {
            presentPopover(at: rect ?? anchor.bounds, of: anchor, edge: .maxX, onClose: save) { close in
                NoteEditorView(draft: draft, title: title, family: family, onCancel: close, onSave: close)
            }
        } else {
            presentSheet { dismiss in
                NoteEditorView(draft: draft, title: title, family: family, onCancel: dismiss) {
                    dismiss()
                    save()
                }
            }
        }
    }

    func showChangeDate(for ids: [PhotoID]) {
        let items = ids.compactMap { library.snapshot.item($0) }.map { (id: $0.id, date: $0.date) }
        guard !items.isEmpty else { return }
        let formatting = library.formatting
        presentSheet { [weak self] dismiss in
            ChangeDateView(items: items, formatting: formatting, onCancel: dismiss) { changes in
                dismiss()
                self?.changeDates(changes, actionName: items.count == 1 ? "Change Date" : "Change Dates")
            }
        }
    }

    /// The context menu for selected photos.
    func photoMenu(for ids: [PhotoID]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuBuilder.item("Open", #selector(phOpen(_:))))
        menu.addItem(MenuBuilder.item("Get Info", #selector(phGetInfo(_:)), symbol: "info.circle"))
        let allFavorites = ids.allSatisfy { library.snapshot.item($0)?.isFavorite == true }
        menu.addItem(MenuBuilder.item(allFavorites ? "Unfavorite" : "Favorite", #selector(phToggleFavorite(_:)), symbol: allFavorites ? "heart.slash" : "heart"))
        menu.addItem(.separator())
        menu.addItem(MenuBuilder.submenu("Add to Album", symbol: "rectangle.stack.badge.plus", MenuBuilder.addToAlbumItems(library)))
        menu.addItem(MenuBuilder.submenu("Labels", symbol: "tag", MenuBuilder.labelItems(library, selection: ids)))
        menu.addItem(MenuBuilder.item("Change Date and Time…", #selector(phChangeDate(_:)), symbol: "calendar"))
        if ids.count == 1 { menu.addItem(MenuBuilder.item("Write on the Back…", #selector(phWriteNote(_:)), symbol: "square.and.pencil")) }
        if currentAlbum != nil {
            menu.addItem(.separator())
            if ids.count == 1 { menu.addItem(MenuBuilder.item("Make Album Cover", #selector(phMakeCover(_:)))) }
            menu.addItem(MenuBuilder.item("Remove from Album", #selector(phRemoveFromAlbum(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(MenuBuilder.item("New Album with Selection", #selector(phNewAlbumWithSelection(_:))))
        return menu
    }

    /// The context menu for the photo open in the viewer.
    func viewerMenu(for id: PhotoID) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(MenuBuilder.item("Get Info", #selector(phGetInfo(_:)), symbol: "info.circle"))
        menu.addItem(.separator())
        let favorite = library.snapshot.item(id)?.isFavorite == true
        menu.addItem(MenuBuilder.item(favorite ? "Unfavorite" : "Favorite", #selector(phToggleFavorite(_:)), symbol: favorite ? "heart.slash" : "heart"))
        menu.addItem(MenuBuilder.submenu("Add to Album", symbol: "rectangle.stack.badge.plus", MenuBuilder.addToAlbumItems(library)))
        menu.addItem(MenuBuilder.submenu("Labels", symbol: "tag", MenuBuilder.labelItems(library, selection: [id])))
        menu.addItem(MenuBuilder.item("Change Date and Time…", #selector(phChangeDate(_:)), symbol: "calendar"))
        return menu
    }

    func represented(_ item: NSMenuItem, _ object: Any) -> NSMenuItem {
        item.representedObject = object
        return item
    }
}
