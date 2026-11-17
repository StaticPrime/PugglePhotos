import AppKit
import PugglePhotosKit
import SwiftUI

/// Menu commands, reached through the responder chain.
extension LibraryWindowController: NSMenuItemValidation {
    /// The photos a command acts on: the one in the viewer, or the selection.
    var targetIDs: [PhotoID] {
        if let id = state.viewerID { return [id] }
        return state.selection
    }

    /// True while the person is typing somewhere, so single-key shortcuts leave the keys alone.
    private var isEditingText: Bool { window?.firstResponder is NSTextView }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasTargets = !targetIDs.isEmpty && library.access == .authorized
        switch menuItem.action {
        case #selector(phToggleFavorite(_:)):
            if isEditingText, menuItem.keyEquivalentModifierMask.isEmpty, !menuItem.keyEquivalent.isEmpty { return false }
            let allFavorites = hasTargets && targetIDs.allSatisfy { library.snapshot.item($0)?.isFavorite == true }
            if menuItem.menu === NSApp.mainMenu?.item(withTitle: "Photo")?.submenu {
                menuItem.title = allFavorites ? "Unfavorite" : "Favorite"
            }
            return hasTargets
        case #selector(phChangeDate(_:)), #selector(phNewAlbumWithSelection(_:)), #selector(phToggleLabel(_:)),
             #selector(phAddToAlbum(_:)):
            if menuItem.action == #selector(phToggleLabel(_:)), let id = menuItem.representedObject as? UUID {
                let count = targetIDs.filter { library.catalog.details($0).labels.contains(id) }.count
                menuItem.state = !targetIDs.isEmpty && count == targetIDs.count ? .on : (count > 0 ? .mixed : .off)
            }
            return hasTargets
        case #selector(phOpen(_:)):
            return state.viewerID == nil && !state.selection.isEmpty
        case #selector(phRemoveFromAlbum(_:)):
            if isEditingText { return false }
            return currentAlbum != nil && hasTargets
        case #selector(phMakeCover(_:)):
            return currentAlbum != nil && targetIDs.count == 1
        case #selector(phBack(_:)):
            return canGoBack
        case #selector(phShowGallery(_:)):
            menuItem.state = state.viewMode == .gallery && state.source != .allAlbums ? .on : .off
            return library.access == .authorized
        case #selector(phShowList(_:)):
            menuItem.state = state.viewMode == .list && state.source != .allAlbums ? .on : .off
            return library.access == .authorized
        case #selector(phShowAllAlbums(_:)):
            menuItem.state = state.source == .allAlbums ? .on : .off
            return true
        case #selector(phGo(_:)):
            if let key = menuItem.representedObject as? String { menuItem.state = BrowserState.key(state.source) == key ? .on : .off }
            return true
        case #selector(phZoomIn(_:)):
            return state.viewerID != nil || state.thumbnailSide < Theme.maximumThumbnail
        case #selector(phZoomOut(_:)):
            return state.viewerID != nil || state.thumbnailSide > Theme.minimumThumbnail
        case #selector(phToggleCalendar(_:)):
            menuItem.title = sidebar.showsCalendar ? "Hide Calendar" : "Show Calendar"
            return true
        case #selector(phRenameAlbum(_:)), #selector(phDeleteAlbum(_:)):
            return (menuItem.representedObject as? UUID ?? currentAlbum?.id ?? albums.selectedAlbum) != nil
        case #selector(phGroupBy(_:)), #selector(phSortBy(_:)), #selector(phOrder(_:)):
            return state.source != .allAlbums && library.access == .authorized
        default:
            return true
        }
    }

    // MARK: File

    @objc func phNewAlbum(_ sender: Any?) { newAlbum(with: []) }

    @objc func phNewAlbumWithSelection(_ sender: Any?) { newAlbum(with: targetIDs) }

    @objc func phNewLabel(_ sender: Any?) { newLabel(for: targetIDs) }

    // MARK: Photo

    @objc func phOpen(_ sender: Any?) {
        if let first = state.selection.first { openViewer(first) }
    }

    @objc func phToggleFavorite(_ sender: Any?) {
        guard !targetIDs.isEmpty else { return }
        library.toggleFavorite(targetIDs)
    }

    @objc func phChangeDate(_ sender: Any?) { showChangeDate(for: targetIDs) }

    @objc func phToggleLabel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID ?? labelForShortcut(sender.tag) else { return }
        library.edit("Label") { $0.toggleLabel(id, on: targetIDs) }
    }

    private func labelForShortcut(_ number: Int) -> UUID? {
        library.catalog.labels.indices.contains(number - 1) ? library.catalog.labels[number - 1].id : nil
    }

    @objc func phAddToAlbum(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        add(targetIDs, toAlbum: id)
    }

    @objc func phRemoveFromAlbum(_ sender: Any?) {
        guard let album = currentAlbum else { return }
        remove(targetIDs, fromAlbum: album.id)
    }

    @objc func phMakeCover(_ sender: Any?) {
        guard let album = currentAlbum, let id = targetIDs.first else { return }
        library.edit("Make Album Cover") { $0.setCover(id, of: album.id) }
    }

    @objc func phRenameAlbum(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID ?? currentAlbum?.id ?? albums.selectedAlbum else { return }
        sidebar.beginRenaming(id)
    }

    @objc func phDeleteAlbum(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID ?? currentAlbum?.id ?? albums.selectedAlbum,
              let album = library.catalog.album(id), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the album “\(album.title)”?"
        alert.informativeText = "It’s deleted from your Photos library too. The photos stay in your library and in any other albums, and Edit ▸ Undo brings the album back."
        alert.addButton(withTitle: "Delete Album")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if state.source == .album(id) { go(to: .allAlbums, remember: false) }
            library.deleteAlbum(id)
        }
    }

    @objc func phEditLabel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { editLabel(id) }
    }

    @objc func phDeleteLabel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let label = library.catalog.label(id), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the label “\(label.name)”?"
        alert.informativeText = "It comes off every photo that has it. The photos themselves stay. Edit ▸ Undo brings it back."
        alert.addButton(withTitle: "Delete Label")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if state.source == .label(id) { go(to: .library, remember: false) }
            library.edit("Delete Label") { $0.deleteLabel(id) }
        }
    }

    // MARK: View

    @objc func phShowGallery(_ sender: Any?) { setViewMode(.gallery) }
    @objc func phShowList(_ sender: Any?) { setViewMode(.list) }
    @objc func phShowAllAlbums(_ sender: Any?) { go(to: .allAlbums) }

    @objc func phGroupBy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let grouping = Grouping(rawValue: raw) { setGrouping(grouping) }
    }

    @objc func phSortBy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let sort = SortKey(rawValue: raw) { setSort(sort) }
    }

    @objc func phOrder(_ sender: NSMenuItem) { setAscending(sender.tag == 1) }

    @objc func phSortAlbums(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let sort = AlbumSort(rawValue: raw) {
            setAlbumSort(sort, ascending: sort == .name)
        }
    }

    @objc func phAlbumOrder(_ sender: NSMenuItem) { setAlbumSort(state.albumSort, ascending: sender.tag == 1) }

    @objc func phZoomIn(_ sender: Any?) {
        if state.viewerID != nil { viewer.zoom(by: 1.5) } else { setThumbnailSide(state.thumbnailSide * 1.25) }
    }

    @objc func phZoomOut(_ sender: Any?) {
        if state.viewerID != nil { viewer.zoom(by: 1 / 1.5) } else { setThumbnailSide(state.thumbnailSide / 1.25) }
    }

    @objc func phToggleCalendar(_ sender: Any?) {
        UserDefaults.standard.set(!sidebar.showsCalendar, forKey: Preferences.showsCalendarKey)
        sidebar.showsCalendar.toggle()
    }

    @objc func phFind(_ sender: Any?) { toolbarController.focusSearch() }

    // MARK: Go

    @objc func phBack(_ sender: Any?) { goBack() }

    @objc func phGo(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "favorites": go(to: .favorites)
        case "videos": go(to: .videos)
        case "recent": go(to: .recentlyAdded)
        default: go(to: .library)
        }
    }

    @objc func phGoToToday(_ sender: Any?) {
        let today = CivilDay(Date(), in: library.formatting.timeZone)
        sidebar.calendar.show(today)
        sidebar.calendar.selectedDay = today
        calendarSelect(today)
    }

    @objc func phPreviousPhoto(_ sender: Any?) { if state.viewerID != nil { viewer.step(-1) } }
    @objc func phNextPhoto(_ sender: Any?) { if state.viewerID != nil { viewer.step(1) } }

    // MARK: Help

    @objc func phShowShortcuts(_ sender: Any?) {
        presentSheet { dismiss in ShortcutsView(onClose: dismiss) }
    }

}
