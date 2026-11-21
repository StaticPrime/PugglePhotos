import AppKit
import PugglePhotosKit

/// Builds the menu bar: PugglePhotos, File, Edit, View, Photo, Go, Window and Help. Commands travel the responder
/// chain to the library window.
enum MenuBuilder {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                     tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    static func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        main.addItem(appItem)
        for (title, items) in [("File", fileItems()), ("Edit", editItems()), ("View", [NSMenuItem]()), ("Photo", [NSMenuItem]()),
                               ("Go", goItems())] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            // View and Photo change with the window and the library, so they're filled in as they open.
            if title == "View" || title == "Photo" {
                menu.delegate = DynamicMenus.shared
                DynamicMenus.shared.fill(menu)
            }
            item.submenu = menu
            main.addItem(item)
        }
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = makeWindowMenu()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Keyboard Shortcuts", #selector(LibraryWindowController.phShowShortcuts(_:)), "/", symbol: "keyboard"))
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }

    static func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: "PugglePhotos")
        menu.addItem(item("About PugglePhotos", #selector(AppDelegate.showAboutWindow(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide PugglePhotos", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PugglePhotos", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Library", #selector(AppDelegate.showLibraryWindow(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func fileItems() -> [NSMenuItem] {
        [
            item("New Album", #selector(LibraryWindowController.phNewAlbum(_:)), "n"),
            item("New Album with Selection", #selector(LibraryWindowController.phNewAlbumWithSelection(_:)), "n", [.command, .shift]),
            item("New Shared Album…", #selector(LibraryWindowController.phNewSharedAlbum(_:)), symbol: "person.2"),
            item("Share Album…", #selector(LibraryWindowController.phShareAlbum(_:)), symbol: "person.crop.circle.badge.plus"),
            item("Leave Shared Album…", #selector(LibraryWindowController.phLeaveSharedAlbum(_:))),
            item("New Label…", #selector(LibraryWindowController.phNewLabel(_:)), "n", [.command, .option]),
            item("Write in Journal…", #selector(LibraryWindowController.phWriteJournal(_:)), "j", symbol: "square.and.pencil"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Export Book as PDF…", #selector(LibraryWindowController.phExportBookPDF(_:)), "e", [.command, .shift]),
            item("Export Book as EPUB…", #selector(LibraryWindowController.phExportBookEPUB(_:))),
            item("Print Book…", #selector(LibraryWindowController.phPrintBook(_:)), "p"),
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find", #selector(LibraryWindowController.phFind(_:)), "f"),
            .separator(),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ]
    }

    private static func goItems() -> [NSMenuItem] {
        func place(_ title: String, _ key: String, _ symbol: String, _ shortcut: String) -> NSMenuItem {
            let menuItem = item(title, #selector(LibraryWindowController.phGo(_:)), shortcut, [.command, .option], symbol: symbol)
            menuItem.representedObject = key
            return menuItem
        }
        return [
            item("Back", #selector(LibraryWindowController.phBack(_:)), "["),
            .separator(),
            place("Memories", "memories", "sparkles", "0"),
            place("Library", "library", "photo.on.rectangle", "1"),
            place("Favorites", "favorites", "heart", "2"),
            place("Videos", "videos", "video", "3"),
            place("Recently Added", "recent", "clock.arrow.circlepath", "4"),
            item("All Albums", #selector(LibraryWindowController.phShowAllAlbums(_:)), "5", [.command, .option], symbol: "rectangle.stack"),
            place("Journal", "journal", "book.closed", "6"),
            place("Map", "map", "map", "7"),
            .separator(),
            item("Today", #selector(LibraryWindowController.phGoToToday(_:)), "t"),
            .separator(),
            item("Previous Photo", #selector(LibraryWindowController.phPreviousPhoto(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command]),
            item("Next Photo", #selector(LibraryWindowController.phNextPhoto(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command]),
        ]
    }

    /// The View menu: how photos show, then the window's panels.
    static func viewItems() -> [NSMenuItem] {
        var items = [
            item("as Gallery", #selector(LibraryWindowController.phShowGallery(_:)), "1"),
            item("as List", #selector(LibraryWindowController.phShowList(_:)), "2"),
            item("as Book", #selector(LibraryWindowController.phShowBook(_:)), "3"),
            .separator(),
            item("Play Slideshow", #selector(LibraryWindowController.phPlaySlideshow(_:)), "p", [.command, .option], symbol: "play.rectangle"),
            .separator(),
        ]
        if let owner = (NSApp.mainWindow ?? NSApp.keyWindow)?.windowController as? LibraryWindowController
            ?? NSApp.windows.compactMap({ $0.windowController as? LibraryWindowController }).first, owner.isShowingBook {
            items += bookItems()
            items.append(.separator())
        }
        if let owner = (NSApp.mainWindow ?? NSApp.keyWindow)?.windowController as? LibraryWindowController
            ?? NSApp.windows.compactMap({ $0.windowController as? LibraryWindowController }).first {
            items += ArrangeMenu.items(for: owner)
            items.append(.separator())
        }
        items += [
            item("Bigger Thumbnails", #selector(LibraryWindowController.phZoomIn(_:)), "+"),
            hiddenAlternate(item("Bigger Thumbnails", #selector(LibraryWindowController.phZoomIn(_:)), "=")),
            item("Smaller Thumbnails", #selector(LibraryWindowController.phZoomOut(_:)), "-"),
            .separator(),
            item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Show Info", #selector(NSSplitViewController.toggleInspector(_:)), "i"),
            item("Hide Calendar", #selector(LibraryWindowController.phToggleCalendar(_:))),
            item("Hide Filmstrip", #selector(LibraryWindowController.phToggleFilmstrip(_:))),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
        return items
    }

    /// The book's choices: its paper, frames, tilt, layout, cover, binding, notes and handwriting, then writing, pages and
    /// putting it back as it was laid out.
    static func bookItems() -> [NSMenuItem] {
        func choices<T: RawRepresentable & CaseIterable>(_ title: String, _ key: String, _ cases: [T], _ name: (T) -> String) -> NSMenuItem
            where T.RawValue == String {
            submenu(title, cases.map { value in
                let menuItem = item(name(value), #selector(LibraryWindowController.phBookStyle(_:)))
                menuItem.representedObject = (key, value.rawValue)
                return menuItem
            })
        }
        return [
            choices("Paper", "paper", BookPaper.allCases, \.displayName),
            choices("Frames", "frame", BookFrame.allCases, \.displayName),
            choices("Tilt", "tilt", BookTilt.allCases, \.displayName),
            choices("Layout", "perPage", BookPerPage.allCases, \.displayName),
            choices("Cover", "cover", BookCover.allCases, \.displayName),
            choices("Binding", "binding", BookBinding.allCases, \.displayName),
            choices("Rings", "rings", BookRingFinish.allCases, \.displayName),
            choices("Notes", "notes", BookNoteStyle.allCases, \.displayName),
            submenu("Handwriting", ([("As in Settings", "")] + Handwriting.styles.map { ($0.name, $0.family) }).map { name, family in
                let menuItem = item(name, #selector(LibraryWindowController.phBookStyle(_:)))
                menuItem.representedObject = ("handwriting", family)
                return menuItem
            }),
            item("Write on Pages", #selector(LibraryWindowController.phToggleBookWriting(_:)), symbol: "pencil.line"),
            item("Add a Blank Page", #selector(LibraryWindowController.phAddBookPage(_:)), symbol: "doc.badge.plus"),
            item("Remove This Page", #selector(LibraryWindowController.phRemoveBookPage(_:))),
            item("Reset Book Layout", #selector(LibraryWindowController.phResetBookLayout(_:))),
            item("Put Back Left-Out Photos", #selector(LibraryWindowController.phPutBackInBook(_:))),
        ]
    }

    /// The Photo menu: what can be done to the selected photos.
    static func photoItems() -> [NSMenuItem] {
        let library = (NSApp.delegate as? AppDelegate)?.library
        return [
            item("Open", #selector(LibraryWindowController.phOpen(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command]),
            item("Get Info", #selector(LibraryWindowController.phGetInfo(_:)), "i", [.command, .option], symbol: "info.circle"),
            .separator(),
            item("Favorite", #selector(LibraryWindowController.phToggleFavorite(_:)), ".", [], symbol: "heart"),
            item("Change Date and Time…", #selector(LibraryWindowController.phChangeDate(_:)), "d", [.command, .shift], symbol: "calendar"),
            item("Write on the Back…", #selector(LibraryWindowController.phWriteNote(_:)), "b", [.command, .option], symbol: "square.and.pencil"),
            .separator(),
            item("Duplicate", #selector(LibraryWindowController.phDuplicate(_:)), "d", symbol: "plus.square.on.square"),
            item("Delete…", #selector(LibraryWindowController.phDelete(_:)), "\u{8}", [.command], symbol: "trash"),
            .separator(),
            submenu("Add to Album", symbol: "rectangle.stack.badge.plus", library.map(addToAlbumItems) ?? []),
            submenu("Labels", symbol: "tag", library.map { labelItems($0, selection: []) } ?? []),
            .separator(),
            item("Make Album Cover", #selector(LibraryWindowController.phMakeCover(_:))),
            item("Remove from Album", #selector(LibraryWindowController.phRemoveFromAlbum(_:)), "\u{8}", []),
            .separator(),
            item("Tilt Left", #selector(LibraryWindowController.phTiltLeft(_:)), "[", []),
            item("Tilt Right", #selector(LibraryWindowController.phTiltRight(_:)), "]", []),
            item("Straighten", #selector(LibraryWindowController.phStraighten(_:))),
            item("Original Size", #selector(LibraryWindowController.phOriginalSize(_:))),
            item("Leave Out of Book", #selector(LibraryWindowController.phLeaveOutOfBook(_:))),
        ]
    }

    /// A second shortcut for a command (⌘= as well as ⌘+), kept out of sight.
    static func hiddenAlternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    static func addToAlbumItems(_ library: LibraryController) -> [NSMenuItem] {
        var items = library.catalog.albums.map { album -> NSMenuItem in
            let menuItem = item(album.title, #selector(LibraryWindowController.phAddToAlbum(_:)))
            menuItem.representedObject = album.id
            return menuItem
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(item("New Album with Selection", #selector(LibraryWindowController.phNewAlbumWithSelection(_:))))
        return items
    }

    /// Each label, ⌃1 to ⌃9 for the first nine, with a check when every selected photo has it.
    static func labelItems(_ library: LibraryController, selection: [PhotoID]) -> [NSMenuItem] {
        var items = library.catalog.labels.enumerated().map { index, label -> NSMenuItem in
            let key = index < 9 ? "\(index + 1)" : ""
            let menuItem = item(label.displayName, #selector(LibraryWindowController.phToggleLabel(_:)), key, .control)
            menuItem.representedObject = label.id
            menuItem.image = labelImage(Theme.color(label.color))
            if !selection.isEmpty {
                let count = selection.filter { library.catalog.details($0).labels.contains(label.id) }.count
                menuItem.state = count == selection.count ? .on : (count > 0 ? .mixed : .off)
            }
            return menuItem
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(item("New Label…", #selector(LibraryWindowController.phNewLabel(_:))))
        return items
    }

    static func labelImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Fills the View and Photo menus each time they open (and once at launch, so their shortcuts work).
final class DynamicMenus: NSObject, NSMenuDelegate {
    static let shared = DynamicMenus()

    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = menu.title == "View" ? MenuBuilder.viewItems() : MenuBuilder.photoItems()
        items.forEach(menu.addItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    /// Rebuilds both menus, after labels or albums change, so the label shortcuts stay right.
    static func refresh() {
        for title in ["View", "Photo"] {
            if let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu { shared.fill(menu) }
        }
    }
}
