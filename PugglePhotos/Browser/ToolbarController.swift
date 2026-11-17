import AppKit
import PugglePhotosKit

/// The window's toolbar: Back, gallery or list, the thumbnail size, grouping and sorting, the favorite heart,
/// search, and the sidebar and info panel buttons.
final class ToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    private unowned let owner: LibraryWindowController
    let toolbar = NSToolbar(identifier: "LibraryToolbar")
    private var backItem: NSToolbarItem?
    private var modeGroup: NSToolbarItemGroup?
    private var zoomSlider: NSSlider?
    private var arrangeItem: NSMenuToolbarItem?
    private var favoriteItem: NSToolbarItem?
    private(set) var searchItem: NSSearchToolbarItem?

    static let back = NSToolbarItem.Identifier("Back")
    static let mode = NSToolbarItem.Identifier("ViewMode")
    static let zoom = NSToolbarItem.Identifier("Zoom")
    static let arrange = NSToolbarItem.Identifier("Arrange")
    static let favorite = NSToolbarItem.Identifier("Favorite")
    static let search = NSToolbarItem.Identifier("Search")

    init(window: LibraryWindowController) {
        owner = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.back, .flexibleSpace, Self.mode, Self.zoom, Self.arrange, Self.favorite,
         Self.search, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.back:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            item.label = "Back"
            item.toolTip = "Back (⌘[)"
            item.isNavigational = true
            item.target = self
            item.action = #selector(back(_:))
            backItem = item
            return item
        case Self.mode:
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier,
                                           images: [NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Gallery")!,
                                                    NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
                                                    NSImage(systemSymbolName: "book", accessibilityDescription: "Book")!],
                                           selectionMode: .selectOne, labels: ["Gallery", "List", "Book"], target: self,
                                           action: #selector(modeChanged(_:)))
            group.label = "View"
            group.toolTip = "Show as a gallery (⌘1), a list (⌘2) or, for an album, a photo book (⌘3)"
            modeGroup = group
            return group
        case Self.zoom:
            let slider = NSSlider(value: Double(owner.state.thumbnailSide), minValue: Double(Theme.minimumThumbnail),
                                  maxValue: Double(Theme.maximumThumbnail), target: self, action: #selector(zoomChanged(_:)))
            slider.controlSize = .small
            slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
            slider.setAccessibilityLabel("Thumbnail size")
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = slider
            item.label = "Size"
            item.toolTip = "Thumbnail size (⌘+ and ⌘−)"
            zoomSlider = slider
            return item
        case Self.arrange:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Group and sort")
            item.label = "Arrange"
            item.toolTip = "Group and sort"
            item.showsIndicator = true
            item.menu = NSMenu()
            arrangeItem = item
            return item
        case Self.favorite:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "heart", accessibilityDescription: "Favorite")
            item.label = "Favorite"
            item.toolTip = "Favorite (.)"
            item.target = self
            item.action = #selector(favorite(_:))
            favoriteItem = item
            return item
        case Self.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = false
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        default:
            return nil
        }
    }

    /// Brings every control up to date with the window.
    func update() {
        let state = owner.state
        // Memories and the Journal are pages of their own: no way of showing photos is chosen there.
        let onPage = state.source == .memories || state.source == .journal
        let isBook = state.viewMode == .book && owner.currentAlbum != nil
        modeGroup?.selectedIndex = onPage ? -1 : (isBook ? 2 : (state.viewMode == .list ? 1 : 0))
        modeGroup?.isEnabled = owner.library.access == .authorized
        if let modeGroup, modeGroup.subitems.count == 3 { modeGroup.subitems[2].isEnabled = owner.currentAlbum != nil }
        zoomSlider?.doubleValue = Double(state.thumbnailSide)
        zoomSlider?.isEnabled = !onPage && (state.viewMode == .gallery || state.source == .allAlbums)
        arrangeItem?.isEnabled = !onPage
        backItem?.isEnabled = owner.canGoBack
        let ids = owner.state.viewerID.map { [$0] } ?? state.selection
        let allFavorites = !ids.isEmpty && ids.allSatisfy { owner.library.snapshot.item($0)?.isFavorite == true }
        favoriteItem?.image = NSImage(systemSymbolName: allFavorites ? "heart.fill" : "heart", accessibilityDescription: "Favorite")
        favoriteItem?.isEnabled = !ids.isEmpty
        if let menu = arrangeItem?.menu {
            menu.removeAllItems()
            for item in ArrangeMenu.items(for: owner) { menu.addItem(item) }
        }
    }

    func clearSearch() {
        searchItem?.searchField.stringValue = ""
    }

    func focusSearch() {
        guard let searchItem else { return }
        searchItem.beginSearchInteraction()
    }

    @objc private func back(_ sender: Any?) { owner.goBack() }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) {
        owner.setViewMode([ViewMode.gallery, .list, .book][max(0, min(2, sender.selectedIndex))])
        update()
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        owner.setThumbnailSide(CGFloat(sender.doubleValue))
    }

    @objc private func favorite(_ sender: Any?) { owner.phToggleFavorite(sender) }

    @objc private func searchChanged(_ sender: NSSearchField) { owner.search(sender.stringValue) }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        owner.search(field.stringValue)
    }
}

/// The grouping and sorting choices, shared by the toolbar's Arrange menu and View in the menu bar.
enum ArrangeMenu {
    static func items(for owner: LibraryWindowController) -> [NSMenuItem] {
        if owner.state.source == .memories { return [] }
        if owner.state.source == .allAlbums {
            var items = [header("Sort Albums By")]
            for sort in AlbumSort.allCases {
                let item = MenuBuilder.item(sort.displayName, #selector(LibraryWindowController.phSortAlbums(_:)))
                item.representedObject = sort.rawValue
                item.state = owner.state.albumSort == sort ? .on : .off
                items.append(item)
            }
            items.append(.separator())
            let ascending = owner.state.albumSortAscending
            let (up, down) = owner.state.albumSort == .name ? ("A to Z", "Z to A")
                : (owner.state.albumSort == .count ? ("Fewest First", "Most First") : ("Oldest First", "Newest First"))
            items.append(order(up, ascending: true, on: ascending, action: #selector(LibraryWindowController.phAlbumOrder(_:))))
            items.append(order(down, ascending: false, on: !ascending, action: #selector(LibraryWindowController.phAlbumOrder(_:))))
            return items
        }
        let arrangement = owner.arrangement
        var items = [header("Group By")]
        for grouping in Grouping.allCases {
            let item = MenuBuilder.item(grouping.displayName, #selector(LibraryWindowController.phGroupBy(_:)))
            item.representedObject = grouping.rawValue
            item.state = arrangement.grouping == grouping ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        items.append(header("Sort By"))
        let sorts: [SortKey] = owner.currentAlbum != nil ? [.custom, .dateTaken]
            : (owner.state.source.hasOwnOrder ? [.custom, .dateTaken, .dateAdded, .title, .kind] : [.dateTaken, .dateAdded, .title, .kind])
        for sort in sorts {
            let item = MenuBuilder.item(sort.displayName, #selector(LibraryWindowController.phSortBy(_:)))
            item.representedObject = sort.rawValue
            item.state = arrangement.sort == sort ? .on : .off
            items.append(item)
        }
        if arrangement.sort != .custom {
            items.append(.separator())
            let (up, down) = arrangement.sort == .title ? ("A to Z", "Z to A")
                : (arrangement.sort == .kind ? ("Photos First", "Videos First") : ("Oldest First", "Newest First"))
            items.append(order(up, ascending: true, on: arrangement.ascending, action: #selector(LibraryWindowController.phOrder(_:))))
            items.append(order(down, ascending: false, on: !arrangement.ascending, action: #selector(LibraryWindowController.phOrder(_:))))
        }
        return items
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func order(_ title: String, ascending: Bool, on: Bool, action: Selector) -> NSMenuItem {
        let item = MenuBuilder.item(title, action)
        item.tag = ascending ? 1 : 0
        item.state = on ? .on : .off
        return item
    }
}
