#if DEBUG
import AppKit
import PugglePhotosKit

/// `-PHSelfTest YES -PHSweep tour` (or `first:N`, or `list`): does everything there is to click, choose or press, as far
/// as it's enabled, on the sample library, to find anything that stops the app. Each thing is named on a `SWEEP DO` line
/// before it's done, so after a crash the last of those says what did it.
///
/// - `tour` goes to place after place (the library's pages, the biggest album, new albums with no photos and with one,
///   a label, the map, memories and a memory's photos, the journal, an album shared with you, the list, books, the
///   viewer, searches that find nothing) and in each does everything the menu bar, the toolbar, the sidebar's menus,
///   the middle's menus, clicks and keys can do there, going back to the place after each. Then it closes the window
///   and tries the menu bar again.
/// - `first:N` does only the Nth of those things, as soon as the sweep starts, before anything else has been shown;
///   then it asks about every menu item, and again in each place.
/// - `list` prints what `first:N` counts, numbered, and quits.
///
/// Where it starts: `-PHSampleLoadDelay 3` holds the sample library back, so the sweep starts while it's loading;
/// `-PHSavedViewMode list` (or `book`) starts as if the last run had been left showing that; `-PHAccess ask` or
/// `denied` starts on the welcome screen; `-PHLaunchedAtLogin YES` starts in the menu bar, with no window.
extension SelfTest {
    /// A place the sweep goes to, and goes back to after each thing it does there.
    struct SweepPlace {
        var name: String
        var source: LibrarySource
        var mode: ViewMode = .gallery
        var viewer = false
        var search = ""
    }

    /// Something to do, found afresh each time it's done, as a person finds it: says whether it was there, enabled,
    /// and done.
    struct SweepCommand {
        var name: String
        /// Whether it's there and enabled, asked without doing it (clicks and keys always are).
        var isEnabled: () -> Bool = { true }
        var run: () -> Bool
    }

    private static var sweepQueue: [() -> Void] = []
    private static var sweepIndex = 0
    private static var sweepInsertion = 0
    private static var sweepHold: (condition: () -> Bool, deadline: Date)?
    private static var sweepTried = 0
    private static var sweepDone = 0
    /// Windows that were there before the sweep began, which it leaves alone.
    private static var sweepOwnWindows: Set<ObjectIdentifier> = []

    static func runSweep(_ mode: String, app: AppDelegate) {
        sweepOwnWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        if UserDefaults.standard.double(forKey: "PHSampleLoadDelay") == 0 {
            sweepNext([{ sweepWait(upTo: 8) { app.library.hasLoaded || app.library.access != .authorized } }])
        }
        if mode == "tour" {
            sweepTour(app)
        } else {
            sweepNext([{
                let commands = sweepCommands(app)
                if mode == "list" {
                    for (index, command) in commands.enumerated() {
                        print("SWEEP COMMAND \(index) \(command.isEnabled() ? "on" : "off"): \(command.name)")
                    }
                    print("SWEEP COUNT: \(commands.count)")
                    fflush(stdout)
                    exit(0)
                }
                let index = Int(mode.split(separator: ":").last ?? "") ?? -1
                guard commands.indices.contains(index) else {
                    print("SWEEP: there's no command \(index)")
                    fflush(stdout)
                    exit(2)
                }
                let first: [() -> Void] = [{ sweepDo(commands[index]) }, { sweepSettle(app) }]
                sweepNext(first + sweepLookAround(app))
            }])
        }
        sweepRun()
    }

    // MARK: Running

    /// Runs the sweep's steps one to a turn of the run loop, as clicks and key presses come.
    private static func sweepRun() {
        if let hold = sweepHold, !hold.condition(), Date() < hold.deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sweepRun() }
            return
        }
        sweepHold = nil
        guard sweepIndex < sweepQueue.count else {
            print("SWEEP DONE: \(sweepTried) things tried, \(sweepDone) of them there, enabled and done")
            fflush(stdout)
            // Whatever was left waiting to happen gets a moment to happen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return
        }
        let index = sweepIndex
        sweepInsertion = index + 1
        sweepQueue[index]()
        sweepIndex = index + 1
        // An empty application event ends the turn as a click or key press would, closing its undo group.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { sweepRun() }
    }

    /// Puts steps next, after any already put next by the step running now.
    private static func sweepNext(_ steps: [() -> Void]) {
        sweepQueue.insert(contentsOf: steps, at: sweepInsertion)
        sweepInsertion += steps.count
    }

    /// Holds the next step until `condition` holds or `timeout` seconds pass.
    private static func sweepWait(upTo timeout: Double, until condition: @escaping () -> Bool) {
        sweepHold = (condition, Date().addingTimeInterval(timeout))
    }

    /// Does one thing, named first, so a crash can be put down to it. A modal window that would hold the sweep up is
    /// stopped, as a person would cancel it.
    private static func sweepDo(_ command: SweepCommand) {
        print("SWEEP DO: \(command.name)")
        fflush(stdout)
        sweepTried += 1
        let watchdog = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        if command.run() { sweepDone += 1 }
        watchdog.invalidate()
    }

    /// Puts away what the last thing left open (a slideshow, a popover, sheets, other windows, a name being typed),
    /// as a person would before going on.
    private static func sweepSettle(_ app: AppDelegate) {
        SlideshowController.current?.close()
        let window = app.windowController
        window?.activePopover?.close()
        if let nsWindow = window?.window {
            for _ in 0..<4 {
                guard let sheet = nsWindow.attachedSheet else { break }
                if let panel = sheet as? NSSavePanel { panel.cancel(nil) } else { nsWindow.endSheet(sheet) }
            }
            if nsWindow.firstResponder is NSText { nsWindow.makeFirstResponder(nil) }
            nsWindow.toolbar?.isVisible = true
        }
        for other in NSApp.windows where other.isVisible && other !== window?.window && other.sheetParent == nil
            && !sweepOwnWindows.contains(ObjectIdentifier(other)) {
            let kind = NSStringFromClass(type(of: other))
            if ["Popover", "ToolTip", "StatusBar", "Menu"].contains(where: { kind.contains($0) }) { continue }
            other.close()
        }
    }

    /// Goes back to a place, as far as the last thing moved away from it.
    private static func sweepRestore(_ place: SweepPlace, _ app: AppDelegate) {
        guard let window = app.windowController else { return }
        if window.window?.isVisible != true { app.showLibraryWindow(nil) }
        if !place.viewer, window.state.viewerID != nil { window.closeViewer() }
        if window.state.source != place.source { window.go(to: place.source, remember: false) }
        if place.source.showsGallery, window.state.viewMode != place.mode { window.setViewMode(place.mode) }
        if window.state.searchText != place.search { window.search(place.search) }
        if place.viewer, window.state.viewerID == nil, let first = window.content.allIDs.first { window.openViewer(first) }
    }

    // MARK: Places

    /// The tour: Gran's album comes in, an album with no photos and one with a single photo are made, then every
    /// place in turn, then the window closed.
    private static func sweepTour(_ app: AppDelegate) {
        sweepNext([
            {
                (app.sharing.backend as? StandInSharing)?.granShares(photos: 6)
                sweepWait(upTo: 3) { !app.sharing.sharedWithMe.isEmpty }
            },
            { app.windowController?.newAlbum(with: []) },
            { sweepSettle(app) },
            { if let window = app.windowController, let first = window.library.snapshot.allIDs.first { window.newAlbum(with: [first]) } },
            { sweepSettle(app) },
            { sweepNext(sweepPlaces(app).map { place -> () -> Void in { sweepArrive(place, app) } } + [{ sweepClosedWindow(app) }]) },
        ])
    }

    /// Every kind of place, with photos and without, in each way of showing them.
    private static func sweepPlaces(_ app: AppDelegate) -> [SweepPlace] {
        guard let window = app.windowController else { return [] }
        let catalog = window.library.catalog
        var places = [
            SweepPlace(name: "Library", source: .library),
            SweepPlace(name: "Library as a list", source: .library, mode: .list),
            SweepPlace(name: "Library, searched for something not there", source: .library, search: "zzzz"),
            SweepPlace(name: "Library, a photo in the viewer", source: .library, viewer: true),
            SweepPlace(name: "Memories", source: .memories),
            SweepPlace(name: "Journal", source: .journal),
            SweepPlace(name: "Favorites", source: .favorites),
            SweepPlace(name: "Videos", source: .videos),
            SweepPlace(name: "Map", source: .map),
            SweepPlace(name: "Map, searched for something not there", source: .map, search: "zzzz"),
            SweepPlace(name: "Recently Added", source: .recentlyAdded),
            SweepPlace(name: "All Albums", source: .allAlbums),
        ]
        let page = window.memories.page
        if let memory = (page.onThisDay + page.highlights + page.years + page.collections).first {
            places.append(SweepPlace(name: "A memory's photos", source: .memory(memory.id)))
        }
        let bySize = catalog.albums.sorted { $0.items.count > $1.items.count }
        var seen: Set<UUID> = []
        for album in [bySize.first, bySize.last { $0.items.isEmpty }, bySize.last { $0.items.count == 1 }].compactMap({ $0 })
            where seen.insert(album.id).inserted {
            let name = "Album “\(album.title)” (\(album.items.count) photos)"
            places += [
                SweepPlace(name: name, source: .album(album.id)),
                SweepPlace(name: name + " as a list", source: .album(album.id), mode: .list),
                SweepPlace(name: name + " as a book", source: .album(album.id), mode: .book),
                SweepPlace(name: name + ", a photo in the viewer", source: .album(album.id), viewer: true),
            ]
        }
        if let label = catalog.labels.first { places.append(SweepPlace(name: "Label “\(label.name)”", source: .label(label.id))) }
        if let shared = window.sharing.sharedWithMe.first {
            places += [
                SweepPlace(name: "Album shared with you", source: .sharedAlbum(shared.id)),
                SweepPlace(name: "Album shared with you, as a book", source: .sharedAlbum(shared.id), mode: .book),
            ]
        }
        return places
    }

    /// Goes to a place, then does everything there is to do there, going back to the place after each.
    private static func sweepArrive(_ place: SweepPlace, _ app: AppDelegate) {
        print("SWEEP PLACE: \(place.name)")
        sweepDo(SweepCommand(name: "go to \(place.name)") { sweepRestore(place, app); return true })
        sweepNext([{
            let commands = sweepCommands(app)
            print("SWEEP PLACE: \(commands.count) things to try in \(place.name)")
            sweepNext(commands.flatMap { command -> [() -> Void] in
                [{ sweepDo(command) }, { sweepSettle(app); sweepRestore(place, app) }]
            })
        }])
    }

    /// The window closed (PugglePhotos stays open in the menu bar): every menu item, then the window again.
    private static func sweepClosedWindow(_ app: AppDelegate) {
        print("SWEEP PLACE: the window closed")
        sweepDo(SweepCommand(name: "close the window") { app.windowController?.window?.performClose(nil); return true })
        sweepNext([{
            let closeAgain = { if app.windowController?.window?.isVisible == true { app.windowController?.window?.performClose(nil) } }
            sweepNext(sweepMenuCommands(app).flatMap { command -> [() -> Void] in [{ sweepDo(command) }, { sweepSettle(app); closeAgain() }] }
                      + [{ sweepDo(SweepCommand(name: "Window ▸ Library") { app.showLibraryWindow(nil); return true }) }])
        }])
    }

    /// After `first:N`'s one thing: asks about every menu item, then waits for the library and does the same in each
    /// place.
    private static func sweepLookAround(_ app: AppDelegate) -> [() -> Void] {
        [
            { sweepDo(SweepCommand(name: "ask about every menu item") { sweepValidateAll(app); return true }) },
            { sweepWait(upTo: 8) { app.library.hasLoaded || app.library.access != .authorized } },
            {
                if app.windowController?.window?.isVisible != true {
                    sweepDo(SweepCommand(name: "Window ▸ Library") { app.showLibraryWindow(nil); return true })
                }
            },
            {
                let places = sweepPlaces(app).filter { $0.search.isEmpty && !$0.viewer && $0.mode != .list }
                sweepNext(places.flatMap { place -> [() -> Void] in
                    [{ sweepDo(SweepCommand(name: "go to \(place.name)") { sweepRestore(place, app); return true }) },
                     { sweepDo(SweepCommand(name: "ask about every menu item in \(place.name)") { sweepValidateAll(app); return true }) }]
                })
            },
        ]
    }

    // MARK: What there is to do

    /// Everything to do where the window is now: the menu bar, then the toolbar, the sidebar's menus, the middle's
    /// clicks and menus, and keys. Without a window, the menu bar and the menu bar paw's menu.
    private static func sweepCommands(_ app: AppDelegate) -> [SweepCommand] {
        var commands = sweepMenuCommands(app)
        if let window = app.windowController, window.window?.isVisible == true {
            commands += sweepToolbarCommands(window) + sweepSidebarCommands(window) + sweepMiddleCommands(window)
                + sweepKeyCommands(window)
        } else {
            commands += sweepPawCommands(app)
        }
        return commands
    }

    /// The window things are done in: the library window, if it's showing.
    private static func sweepWindow(_ app: AppDelegate) -> NSWindow? {
        app.windowController?.window.flatMap { $0.isVisible ? $0 : nil }
    }

    private static func sweepMenuCommands(_ app: AppDelegate) -> [SweepCommand] {
        guard let main = NSApp.mainMenu else { return [] }
        return sweepPaths(in: main).map { path in
            SweepCommand(name: "Menu ▸ " + path.joined(separator: " ▸ "), isEnabled: {
                guard let main = NSApp.mainMenu, let item = sweepItem(path, in: main) else { return false }
                return sweepCanChoose(item, window: sweepWindow(app))
            }) {
                guard let main = NSApp.mainMenu, let item = sweepItem(path, in: main) else { return false }
                return sweepChoose(item, window: sweepWindow(app))
            }
        }
    }

    /// Asks about every item in the menu bar, as macOS does when a menu opens, or on its own.
    private static func sweepValidateAll(_ app: AppDelegate) {
        guard let main = NSApp.mainMenu else { return }
        for path in sweepPaths(in: main) {
            guard let item = sweepItem(path, in: main), let action = item.action else { continue }
            _ = sweepIsEnabled(item, target: item.target ?? sweepTarget(for: action, in: sweepWindow(app)))
        }
    }

    private static func sweepToolbarCommands(_ window: LibraryWindowController) -> [SweepCommand] {
        window.toolbarController.update()
        guard let toolbar = window.window?.toolbar else { return [] }
        func current(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
            window.toolbarController.update()
            return window.window?.toolbar?.items.first { $0.itemIdentifier == id }
        }
        var commands: [SweepCommand] = []
        for item in toolbar.items {
            let id = item.itemIdentifier
            let label = item.label.isEmpty ? id.rawValue : item.label
            if let group = item as? NSToolbarItemGroup {
                for (index, subitem) in group.subitems.enumerated() {
                    commands.append(SweepCommand(name: "Toolbar ▸ \(label) ▸ \(subitem.label)", isEnabled: {
                        guard let group = current(id) as? NSToolbarItemGroup, group.subitems.indices.contains(index) else { return false }
                        return group.isEnabled && group.subitems[index].isEnabled
                    }) {
                        guard let group = current(id) as? NSToolbarItemGroup, group.isEnabled, group.subitems.indices.contains(index),
                              group.subitems[index].isEnabled, let action = group.action else { return false }
                        group.selectedIndex = index
                        return NSApp.sendAction(action, to: group.target, from: group)
                    })
                }
            } else if item is NSSearchToolbarItem {
                for text in ["lake", "zzzz", ""] {
                    commands.append(SweepCommand(name: "Toolbar ▸ search for “\(text)”", isEnabled: {
                        (current(id) as? NSSearchToolbarItem)?.searchField.isEnabled == true
                    }) {
                        guard let field = (current(id) as? NSSearchToolbarItem)?.searchField, field.isEnabled, let action = field.action else { return false }
                        field.stringValue = text
                        return NSApp.sendAction(action, to: field.target, from: field)
                    })
                }
            } else if let menuItem = item as? NSMenuToolbarItem {
                for path in sweepPaths(in: menuItem.menu) {
                    func entry() -> NSMenuItem? {
                        guard let toolbarItem = current(id) as? NSMenuToolbarItem, toolbarItem.isEnabled else { return nil }
                        return sweepItem(path, in: toolbarItem.menu)
                    }
                    commands.append(SweepCommand(name: "Toolbar ▸ \(label) ▸ " + path.joined(separator: " ▸ "), isEnabled: {
                        entry().map { sweepCanChoose($0, window: window.window) } ?? false
                    }) {
                        entry().map { sweepChoose($0, window: window.window) } ?? false
                    })
                }
            } else if item.view is NSSlider {
                for (name, end) in [("smallest", 0.0), ("largest", 1.0)] {
                    commands.append(SweepCommand(name: "Toolbar ▸ \(label) ▸ \(name)", isEnabled: {
                        current(id).map { $0.isEnabled && ($0.view as? NSSlider)?.isEnabled == true } ?? false
                    }) {
                        guard let toolbarItem = current(id), toolbarItem.isEnabled, let slider = toolbarItem.view as? NSSlider,
                              slider.isEnabled, let action = slider.action else { return false }
                        slider.doubleValue = slider.minValue + (slider.maxValue - slider.minValue) * end
                        return NSApp.sendAction(action, to: slider.target, from: slider)
                    })
                }
            } else if item.action != nil {
                commands.append(SweepCommand(name: "Toolbar ▸ \(label)", isEnabled: { current(id)?.isEnabled == true }) {
                    guard let toolbarItem = current(id), toolbarItem.isEnabled, let action = toolbarItem.action,
                          let target = toolbarItem.target ?? sweepTarget(for: action, in: window.window) else { return false }
                    return NSApp.sendAction(action, to: target, from: toolbarItem)
                })
            }
        }
        return commands
    }

    /// Right-clicking a row of each kind in the sidebar, and the row of the place showing, then choosing each item.
    private static func sweepSidebarCommands(_ window: LibraryWindowController) -> [SweepCommand] {
        let catalog = window.library.catalog
        var sources: [LibrarySource] = [window.state.source, .allAlbums]
        if let album = catalog.albums.first { sources.append(.album(album.id)) }
        if let label = catalog.labels.first { sources.append(.label(label.id)) }
        if let shared = window.sharing.sharedWithMe.first { sources.append(.sharedAlbum(shared.id)) }
        var seen: Set<LibrarySource> = []
        var commands: [SweepCommand] = []
        for source in sources where seen.insert(source).inserted {
            guard let menu = window.sidebarMenu(for: source) else { continue }
            let name = sweepName(source, window)
            for path in sweepPaths(in: menu) {
                func item() -> NSMenuItem? { window.sidebarMenu(for: source).flatMap { sweepItem(path, in: $0) } }
                commands.append(SweepCommand(name: "Sidebar ▸ right-click \(name) ▸ " + path.joined(separator: " ▸ "), isEnabled: {
                    item().map { sweepCanChoose($0, window: window.window) } ?? false
                }) {
                    item().map { sweepChoose($0, window: window.window) } ?? false
                })
            }
        }
        return commands
    }

    private static let sweepSpots: [(name: String, x: CGFloat, y: CGFloat)] = [
        ("near the top left", 0.08, 0.9), ("in the middle", 0.5, 0.5), ("near the bottom right", 0.92, 0.1),
        ("near the top right", 0.9, 0.88), ("near the bottom left", 0.1, 0.12),
    ]

    /// Clicking, double-clicking and right-clicking around the middle of the window, then choosing each item of the
    /// menu a right-click brings up.
    private static func sweepMiddleCommands(_ window: LibraryWindowController) -> [SweepCommand] {
        var commands: [SweepCommand] = []
        // The menus at different spots are mostly the same menu: the tour right-clicks three spots, `first:N` one.
        let menuSpots = UserDefaults.standard.string(forKey: "PHSweep") == "tour" ? 3 : 1
        for (number, spot) in sweepSpots.enumerated() {
            let point = { () -> NSPoint in
                let area = window.dropZone.safeAreaRect
                return NSPoint(x: area.minX + area.width * spot.x, y: area.minY + area.height * spot.y)
            }
            commands.append(SweepCommand(name: "click \(spot.name)") { sweepClick(point(), count: 1, window) })
            commands.append(SweepCommand(name: "double-click \(spot.name)") { sweepClick(point(), count: 2, window) })
            guard number < menuSpots, let menu = sweepContextMenu(at: point(), window) else { continue }
            for path in sweepPaths(in: menu) {
                func item() -> NSMenuItem? { sweepContextMenu(at: point(), window).flatMap { sweepItem(path, in: $0) } }
                commands.append(SweepCommand(name: "right-click \(spot.name) ▸ " + path.joined(separator: " ▸ "), isEnabled: {
                    item().map { sweepCanChoose($0, window: window.window) } ?? false
                }) {
                    item().map { sweepChoose($0, window: window.window) } ?? false
                })
            }
        }
        return commands
    }

    private static let sweepKeys: [(name: String, code: UInt16, characters: String, flags: NSEvent.ModifierFlags)] = [
        ("Return", 36, "\r", []), ("Space", 49, " ", []), ("Escape", 53, "\u{1B}", []), ("Delete", 51, "\u{7F}", []),
        ("Forward Delete", 117, "\u{F728}", .function), ("Left Arrow", 123, "\u{F702}", [.function, .numericPad]),
        ("Right Arrow", 124, "\u{F703}", [.function, .numericPad]), ("Up Arrow", 126, "\u{F700}", [.function, .numericPad]),
        ("Down Arrow", 125, "\u{F701}", [.function, .numericPad]), ("Home", 115, "\u{F729}", .function),
        ("End", 119, "\u{F72B}", .function), ("Page Up", 116, "\u{F72C}", .function), ("Page Down", 121, "\u{F72D}", .function),
        ("Tab", 48, "\t", []), ("[", 33, "[", []), ("]", 30, "]", []), (".", 47, ".", []), ("1", 18, "1", []), ("a", 0, "a", []),
    ]

    /// Pressing keys, as they come: the menu bar's shortcuts first, then whatever has the focus in the window.
    private static func sweepKeyCommands(_ window: LibraryWindowController) -> [SweepCommand] {
        sweepKeys.map { key in
            SweepCommand(name: "press \(key.name)") {
                guard let nsWindow = window.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                                   context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                                                   isARepeat: false, keyCode: key.code) else { return false }
                if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
                nsWindow.sendEvent(event)
                return true
            }
        }
    }

    /// The menu bar paw's menu, after a login launch: everything but Quit.
    private static func sweepPawCommands(_ app: AppDelegate) -> [SweepCommand] {
        let menu = NSMenu()
        app.menuNeedsUpdate(menu)
        return menu.items.filter { $0.action != nil && $0.action != #selector(NSApplication.terminate(_:)) }.map(\.title).map { title in
            SweepCommand(name: "menu bar paw ▸ \(title)") {
                let menu = NSMenu()
                app.menuNeedsUpdate(menu)
                guard let item = menu.items.first(where: { $0.title == title }) else { return false }
                return sweepChoose(item, window: nil)
            }
        }
    }

    // MARK: Menus, clicks and keys

    /// Never done: quitting, hiding, closing or minimizing the window (the tour closes it itself, at the end), full
    /// screen, printing (the system's print panel), Help, and what macOS puts in menus itself.
    private static func sweepSkips(_ action: Selector) -> Bool {
        let name = NSStringFromSelector(action)
        return name.hasPrefix("_") || [
            "terminate:", "hide:", "hideOtherApplications:", "unhideAllApplications:", "performClose:", "performMiniaturize:",
            "toggleFullScreen:", "phPrintBook:", "showHelp:", "orderFrontCharacterPalette:", "startDictation:",
        ].contains(name)
    }

    /// What macOS adds to the menus itself, which the sweep leaves alone too.
    private static let sweepSkippedTitles: Set<String> = ["Close All", "Emoji & Symbols", "Start Dictation…"]
    private static let sweepSkippedMenus: Set<String> = ["Writing Tools", "AutoFill"]

    /// Fills a menu that's filled as it opens.
    private static func sweepFill(_ menu: NSMenu) {
        if menu.delegate === DynamicMenus.shared { DynamicMenus.shared.menuNeedsUpdate(menu) }
    }

    /// The title paths of a menu's items that do something, through its submenus (not the system's Services).
    private static func sweepPaths(in menu: NSMenu, prefix: [String] = []) -> [[String]] {
        sweepFill(menu)
        var paths: [[String]] = []
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                if submenu !== NSApp.servicesMenu, !sweepSkippedMenus.contains(item.title) {
                    paths += sweepPaths(in: submenu, prefix: prefix + [item.title])
                }
            } else if item.action != nil, !sweepSkippedTitles.contains(item.title) {
                paths.append(prefix + [item.title])
            }
        }
        return paths
    }

    /// A menu item found by its path of titles, its menus filled as they are when they open.
    private static func sweepItem(_ path: [String], in menu: NSMenu) -> NSMenuItem? {
        sweepFill(menu)
        guard let first = path.first, let item = menu.items.first(where: { $0.title == first }) else { return nil }
        if path.count == 1 { return item }
        guard let submenu = item.submenu else { return nil }
        return sweepItem(Array(path.dropFirst()), in: submenu)
    }

    /// Who would answer an action, as AppKit finds them: along the window's responder chain, its delegate, then the
    /// application and its delegate.
    private static func sweepTarget(for action: Selector, in window: NSWindow?) -> AnyObject? {
        var responder = window?.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = window?.delegate, delegate.responds(to: action) { return delegate as AnyObject }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate as AnyObject }
        return nil
    }

    private static func sweepIsEnabled(_ item: NSMenuItem, target: AnyObject?) -> Bool {
        if item.menu?.autoenablesItems == false { return item.isEnabled }
        guard let target else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Whether a click would choose a menu item: it isn't one the sweep leaves alone, someone answers it, and it's enabled.
    private static func sweepCanChoose(_ item: NSMenuItem, window: NSWindow?) -> Bool {
        guard let action = item.action, !sweepSkips(action), !sweepSkippedTitles.contains(item.title),
              let target = item.target ?? sweepTarget(for: action, in: window) else { return false }
        return sweepIsEnabled(item, target: target)
    }

    /// Chooses a menu item as a click does: asks whoever would answer it and, if it's enabled, sends its action.
    @discardableResult
    private static func sweepChoose(_ item: NSMenuItem, window: NSWindow?) -> Bool {
        guard sweepCanChoose(item, window: window), let action = item.action,
              let target = item.target ?? sweepTarget(for: action, in: window) else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    /// Clicks (or double-clicks) a point in the middle of the window: each down goes through the window, its up waiting
    /// in line, as a real click comes.
    private static func sweepClick(_ point: NSPoint, count: Int, _ window: LibraryWindowController) -> Bool {
        guard let nsWindow = window.window else { return false }
        let location = window.dropZone.convert(point, to: nil)
        for click in 1...count {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 1)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
            NSApp.postEvent(up, atStart: false)
            nsWindow.sendEvent(down)
        }
        return true
    }

    /// The menu a right-click at a point brings up, from the view under it or the nearest one above it with a menu,
    /// filled as it is when it opens (it isn't shown).
    private static func sweepContextMenu(at point: NSPoint, _ window: LibraryWindowController) -> NSMenu? {
        guard let nsWindow = window.window, let frame = nsWindow.contentView?.superview else { return nil }
        let location = window.dropZone.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        var view = frame.hitTest(location)
        while let current = view {
            if let menu = current.menu(for: event) {
                menu.delegate?.menuNeedsUpdate?(menu)
                return menu
            }
            view = current.superview
        }
        return nil
    }

    private static func sweepName(_ source: LibrarySource, _ window: LibraryWindowController) -> String {
        switch source {
        case let .album(id): "album “\(window.library.catalog.album(id)?.title ?? "gone")”"
        case let .label(id): "label “\(window.library.catalog.label(id)?.name ?? "gone")”"
        case let .sharedAlbum(id): "shared album “\(window.sharing.sharedWithMe(id)?.title ?? "gone")”"
        default: "\(source)"
        }
    }
}
#endif
