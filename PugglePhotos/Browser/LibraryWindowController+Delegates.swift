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
    func sidebarSelect(_ source: LibrarySource) {
        guard source != state.source || state.viewerID != nil else { return }
        go(to: source)
    }

    func sidebarNewAlbum() { newAlbum(with: []) }
    func sidebarNewLabel() { newLabel(for: []) }

    func sidebarMenu(for source: LibrarySource) -> NSMenu? {
        let menu = NSMenu()
        switch source {
        case let .album(id):
            menu.addItem(represented(MenuBuilder.item("Rename Album", #selector(phRenameAlbum(_:))), id))
            menu.addItem(represented(MenuBuilder.item("Delete Album…", #selector(phDeleteAlbum(_:))), id))
        case let .label(id):
            menu.addItem(represented(MenuBuilder.item("Edit Label…", #selector(phEditLabel(_:))), id))
            menu.addItem(represented(MenuBuilder.item("Delete Label…", #selector(phDeleteLabel(_:))), id))
        case .allAlbums:
            menu.addItem(MenuBuilder.item("New Album", #selector(phNewAlbum(_:))))
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

// MARK: The viewer

extension LibraryWindowController: ViewerDelegate {
    var viewerSequence: [PhotoID] {
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
        let allFavorites = ids.allSatisfy { library.snapshot.item($0)?.isFavorite == true }
        menu.addItem(MenuBuilder.item(allFavorites ? "Unfavorite" : "Favorite", #selector(phToggleFavorite(_:)), symbol: allFavorites ? "heart.slash" : "heart"))
        menu.addItem(.separator())
        menu.addItem(MenuBuilder.submenu("Add to Album", symbol: "rectangle.stack.badge.plus", MenuBuilder.addToAlbumItems(library)))
        menu.addItem(MenuBuilder.submenu("Labels", symbol: "tag", MenuBuilder.labelItems(library, selection: ids)))
        menu.addItem(MenuBuilder.item("Change Date and Time…", #selector(phChangeDate(_:)), symbol: "calendar"))
        if currentAlbum != nil {
            menu.addItem(.separator())
            if ids.count == 1 { menu.addItem(MenuBuilder.item("Make Album Cover", #selector(phMakeCover(_:)))) }
            menu.addItem(MenuBuilder.item("Remove from Album", #selector(phRemoveFromAlbum(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(MenuBuilder.item("New Album with Selection", #selector(phNewAlbumWithSelection(_:))))
        return menu
    }

    func represented(_ item: NSMenuItem, _ object: Any) -> NSMenuItem {
        item.representedObject = object
        return item
    }
}
