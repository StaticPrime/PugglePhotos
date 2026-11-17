#if DEBUG
import AppKit
import PugglePhotosKit

/// `-PHSelfTest YES`: drives the library window on the sample library and prints SELFTEST PASS/FAIL lines.
/// Each step runs in its own turn of the run loop, so each edit is its own undo step, as for a person.
@MainActor
enum SelfTest {
    static func runIfRequested(_ app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "PHSelfTest") else { return }
        SelfTestMode.isRunning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { run(app) }
    }

    private static var failures = 0
    private static var steps: [() -> Void] = []
    private static var holding: (condition: () -> Bool, deadline: Date)?

    static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("SELFTEST PASS: \(name)")
        } else {
            failures += 1
            print("SELFTEST FAIL: \(name) — \(detail())")
        }
        fflush(stdout)
    }

    static func step(_ body: @escaping () -> Void) { steps.append(body) }

    /// Holds the next step until `condition` holds or `timeout` seconds pass, for work that finishes later.
    static func wait(upTo timeout: Double = 5, until condition: @escaping () -> Bool) {
        holding = (condition, Date().addingTimeInterval(timeout))
    }

    private static func continueSteps(from index: Int) {
        if let hold = holding, !hold.condition(), Date() < hold.deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continueSteps(from: index) }
            return
        }
        holding = nil
        runSteps(from: index)
    }

    private static func runSteps(from index: Int = 0) {
        guard index < steps.count else {
            UserDefaults.standard.removeObject(forKey: Preferences.askBeforeChangingDatesKey)
            UserDefaults.standard.removeObject(forKey: MemoryPreferences.timeKey)
            UserDefaults.standard.removeObject(forKey: MemoryPreferences.notifyKey)
            print(failures == 0 ? "SELFTEST DONE: all passed" : "SELFTEST DONE: \(failures) failed")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        steps[index]()
        // An empty application event ends the step as a key press or click would, closing its undo group.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { continueSteps(from: index + 1) }
    }

    static func key(_ code: UInt16, _ characters: String, to responder: NSResponder?, window: NSWindow?) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        responder?.keyDown(with: event)
    }

    /// A menu item from the menu bar, found by its menu's title and its own.
    static func menuItem(_ menu: String, _ title: String) -> NSMenuItem? {
        guard let submenu = NSApp.mainMenu?.item(withTitle: menu)?.submenu else { return nil }
        DynamicMenus.shared.menuNeedsUpdate(submenu)
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title { return item }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        return find(submenu)
    }

    /// Sends a menu item's action down the responder chain, as choosing it does.
    @discardableResult
    static func choose(_ menu: String, _ title: String) -> Bool {
        guard let item = menuItem(menu, title), let action = item.action else { return false }
        // A run started from Terminal may not be the active app, so there may be no key window to start from.
        let target = item.target ?? (NSApp.keyWindow == nil ? NSApp.windows.compactMap { $0.windowController as? LibraryWindowController }.first : nil)
        if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    private static func run(_ app: AppDelegate) {
        guard let window = app.windowController, let nsWindow = window.window else {
            print("SELFTEST FAIL: no library window")
            exit(1)
        }
        let library = app.library!
        let source = library.source as! SamplePhotoSource
        let undo = library.undoManager
        nsWindow.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(false, forKey: Preferences.askBeforeChangingDatesKey)
        var snapshot: LibrarySnapshot { library.snapshot }
        var catalog: Catalog { library.catalog }
        func date(_ id: PhotoID) -> Date { snapshot.item(id)?.date ?? .distantPast }
        func ids(_ prefix: String) -> [PhotoID] { snapshot.allIDs.filter { $0.rawValue.hasPrefix("sample-\(prefix)-") } }
        let calendar = library.formatting.calendar

        // MARK: Loading
        step { wait { library.hasLoaded } }
        step {
            check(snapshot.count >= 120, "the sample library loads", "\(snapshot.count) items")
            check(catalog.albums.count == 9 && catalog.labels.count == 5, "the sample albums and labels load",
                  "\(catalog.albums.count) albums, \(catalog.labels.count) labels")
            check(window.sidebar.outlineView.numberOfRows >= 20, "the sidebar lists the library, albums and labels",
                  "\(window.sidebar.outlineView.numberOfRows) rows")
            let first = window.content.sections.first
            check(first?.key == .day(CivilDay(year: 2019, month: 7, day: 4)), "the timeline starts with the oldest day",
                  "\(String(describing: first?.key))")
            check(window.content.titles.first == "Thursday, July 4, 2019", "day headings name the day", window.content.titles.first ?? "")
            check(window.content.subtitles.first == "12 photos", "day headings count the photos", window.content.subtitles.first ?? "")
            check(window.content.dropsBetween && window.content.drops.first == .day(CivilDay(year: 2019, month: 7, day: 4)),
                  "the timeline takes drops on days and between photos")
            check(window.sidebar.calendar.counts[CivilDay(year: 2019, month: 7, day: 4)] == 12, "the calendar counts each day's photos")
        }
        step { wait(upTo: 4) { window.grid.collectionView.visibleItems().contains { ($0 as? PhotoCell)?.view.layer?.sublayers?.first?.contents != nil } } }
        step {
            let loaded = window.grid.collectionView.visibleItems().filter { ($0 as? PhotoCell)?.view.layer?.sublayers?.first?.contents != nil }
            check(!loaded.isEmpty, "thumbnails load", "\(loaded.count) of \(window.grid.collectionView.visibleItems().count)")
        }

        // MARK: Selecting and favorites
        let lake = ids("lake19")
        step {
            window.grid.select(Array(lake.prefix(2)))
            check(window.state.selection == Array(lake.prefix(2)), "selecting in the grid selects photos", "\(window.state.selection)")
            check(window.inspectorModel.ids == Array(lake.prefix(2)), "the info panel follows the selection")
        }
        step {
            check(choose("Photo", "Favorite"), "Photo ▸ Favorite is available with a selection")
            wait { lake.prefix(2).allSatisfy { snapshot.item($0)?.isFavorite == true } }
        }
        step {
            check(lake.prefix(2).allSatisfy { snapshot.item($0)?.isFavorite == true }, "Favorite marks every selected photo in the library")
            check(window.sidebar.outlineView.numberOfRows > 0 && window.arrangement.grouping == .day, "the view stays put after a change")
            undo.undo()
            wait { snapshot.item(lake[0])?.isFavorite == false }
        }
        step {
            check(snapshot.item(lake[0])?.isFavorite == false && snapshot.item(lake[1])?.isFavorite == false,
                  "undo puts favorites back as they were")
            source.refuseNextChange = true
            library.setFavorite([lake[4]], true)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            check(nsWindow.attachedSheet != nil, "a refused change says so")
            check(snapshot.item(lake[4])?.isFavorite == false, "a refused change changes nothing")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet) }
        }

        // MARK: Albums, mirrored in the Photos library
        func libraryAlbum(_ id: UUID) -> LibraryAlbum? {
            guard let photosID = catalog.album(id)?.photosAlbumID else { return nil }
            return source.albums.first { $0.id == photosID }
        }
        var newAlbum: UUID?
        step {
            let imported = catalog.albums.filter { ["Imported Photos", "Scanned Prints"].contains($0.title) }
            check(imported.count == 2, "albums made in the Photos library arrive as albums", "\(imported.map(\.title))")
            check(catalog.albums.allSatisfy { $0.photosAlbumID != nil }, "every album has its twin in the Photos library")
            window.setSelection(Array(lake.prefix(3)))
            window.phNewAlbumWithSelection(nil)
            newAlbum = catalog.albums.last?.id
            check(catalog.albums.count == 10 && catalog.albums.last?.items == Array(lake.prefix(3)),
                  "New Album with Selection makes an album of the selection")
            check(catalog.albums.last?.title == "Untitled Album", "a new album gets a fresh name", catalog.albums.last?.title ?? "")
            wait { libraryAlbum(newAlbum!) != nil }
        }
        step {
            check(libraryAlbum(newAlbum!)?.items == Array(lake.prefix(3)), "a new album is made in the Photos library too")
            // Finish the name the sidebar offered to edit, then rename it.
            nsWindow.makeFirstResponder(window.grid.collectionView)
            library.renameAlbum(newAlbum!, to: "Dock Day")
            check(catalog.album(newAlbum!)?.title == "Dock Day", "albums can be renamed")
            wait { libraryAlbum(newAlbum!)?.title == "Dock Day" }
        }
        step {
            check(libraryAlbum(newAlbum!)?.title == "Dock Day", "renaming renames the album in the Photos library")
            check(window.sidebarDrop(Array(lake[2...5]), on: .album(newAlbum!)), "photos can be dropped on an album in the sidebar")
            check(catalog.album(newAlbum!)?.items == Array(lake.prefix(6)), "dropping adds only photos not already there",
                  "\(catalog.album(newAlbum!)?.items.count ?? 0)")
            let membership = library.membership.albums(containing: lake[2])
            check(membership.count == 2, "a photo can be in more than one album", "\(membership.count)")
            wait { libraryAlbum(newAlbum!)?.items.count == 6 }
        }
        step {
            check(libraryAlbum(newAlbum!)?.items == Array(lake.prefix(6)), "added photos join the album in the Photos library")
            window.go(to: .album(newAlbum!))
            check(window.content.album?.id == newAlbum && window.content.allIDs == Array(lake.prefix(6)),
                  "an album shows its photos with its banner", "\(window.content.allIDs.count)")
            check(window.content.albumSubtitle.contains("6 photos"), "the album banner counts its photos", window.content.albumSubtitle)
            window.grid.select([lake[5]])
            key(51, "\u{7F}", to: window.grid.collectionView, window: nsWindow)
            check(catalog.album(newAlbum!)?.items.count == 5 && snapshot.contains(lake[5]), "Delete removes from the album, not the library")
            wait { libraryAlbum(newAlbum!)?.items.count == 5 }
        }
        step {
            check(libraryAlbum(newAlbum!)?.items == Array(lake.prefix(5)), "removed photos leave the album in the Photos library")
            window.setSelection([lake[3]])
            window.phMakeCover(nil)
            check(library.arranger.cover(of: catalog.album(newAlbum!)!) == lake[3], "Make Album Cover sets the cover")
            window.setSort(.custom)
            check(catalog.album(newAlbum!)?.order == .custom, "an album can be shown in its own order")
        }
        step {
            // Drag the fourth photo to the front of the album.
            window.refresh(keepPosition: true)
            let accepted = window.browserDrop([lake[3]], before: IndexPath(item: 0, section: 0), anchor: .zero, in: window.grid.collectionView)
            check(accepted && catalog.album(newAlbum!)?.items.first == lake[3], "dragging within an album in its own order moves the photo",
                  "\(catalog.album(newAlbum!)?.items ?? [])")
            check(date(lake[3]) < date(lake[4]), "moving within an album leaves dates alone")
            wait { libraryAlbum(newAlbum!)?.items.first == lake[3] }
        }
        step {
            check(libraryAlbum(newAlbum!)?.items == catalog.album(newAlbum!)?.items, "the new order reaches the Photos library")
            undo.undo()
            check(catalog.album(newAlbum!)?.items.first == lake[0], "undo puts the album's order back")
            wait { libraryAlbum(newAlbum!)?.items.first == lake[0] }
        }
        step {
            check(libraryAlbum(newAlbum!)?.items.first == lake[0], "undo puts the order back in the Photos library too")
            window.browserRenameAlbum("Dock Day, Again")
            check(catalog.album(newAlbum!)?.title == "Dock Day, Again", "the album banner renames the album")
        }
        step {
            window.browserSetAlbumNote("Cannonballs all afternoon.")
            check(catalog.album(newAlbum!)?.note == "Cannonballs all afternoon.", "the album banner keeps its story")
        }
        step {
            undo.undo()
            check(catalog.album(newAlbum!)?.note == "" && catalog.album(newAlbum!)?.title == "Dock Day, Again",
                  "undoing the story leaves the album's name alone")
            undo.redo()
            check(catalog.album(newAlbum!)?.note == "Cannonballs all afternoon.", "redo puts the story back")
        }
        step {
            window.go(to: .allAlbums)
            check(window.albums.summaries.count == 10 && window.albums.collectionView.numberOfItems(inSection: 0) == 11,
                  "All Albums shows every cover and a New Album card", "\(window.albums.summaries.count)")
            window.setAlbumSort(.name, ascending: true)
            check(window.albums.summaries.map(\.title) == window.albums.summaries.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                  "album covers sort by name")
            window.setAlbumSort(.date, ascending: false)
            let dates = window.albums.summaries.map { $0.firstDate ?? $0.created }
            check(dates == dates.sorted(by: >), "album covers sort by date, newest first")
            check(window.albumsDrop([lake[11]], on: newAlbum!) && catalog.album(newAlbum!)!.items.contains(lake[11]),
                  "dropping photos on an album cover adds them")
        }
        // Changes made to the albums in the Photos library show here.
        var scansAlbum: Album?
        step {
            scansAlbum = catalog.albums.first { $0.title == "Scanned Prints" }
            source.changeAlbumElsewhere(scansAlbum!.photosAlbumID!) { album in
                album?.title = "Old Prints"
                album?.items.append(lake[0])
            }
            wait { catalog.album(scansAlbum!.id)?.title == "Old Prints" }
        }
        step {
            check(catalog.album(scansAlbum!.id)?.title == "Old Prints" && catalog.album(scansAlbum!.id)?.items.last == lake[0],
                  "renaming and adding to an album in the Photos library shows here")
            source.changeAlbumElsewhere(scansAlbum!.photosAlbumID!) { $0 = nil }
            wait { catalog.album(scansAlbum!.id) == nil }
        }
        var deletedTwin = ""
        step {
            check(catalog.album(scansAlbum!.id) == nil, "an album deleted in the Photos library goes here too")
            deletedTwin = catalog.album(newAlbum!)?.photosAlbumID ?? ""
            library.deleteAlbum(newAlbum!)
            check(catalog.album(newAlbum!) == nil, "albums can be deleted")
            wait { !source.albums.contains { $0.id == deletedTwin } }
        }
        step {
            check(!source.albums.contains { $0.id == deletedTwin }, "deleting an album deletes it in the Photos library")
            undo.undo()
            check(catalog.album(newAlbum!)?.note == "Cannonballs all afternoon.", "undo brings a deleted album back, story and all")
            wait { libraryAlbum(newAlbum!) != nil }
        }
        step {
            check(libraryAlbum(newAlbum!)?.items == catalog.album(newAlbum!)?.items, "the album comes back in the Photos library too")
            source.refuseNextChange = true
            library.renameAlbum(newAlbum!, to: "Never Mind")
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            check(nsWindow.attachedSheet != nil, "a refused album change says so")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet) }
            wait { catalog.album(newAlbum!)?.title == "Dock Day, Again" }
        }
        step {
            check(catalog.album(newAlbum!)?.title == "Dock Day, Again", "after a refused change, the album keeps the library's name")
        }

        // MARK: Labels, captions and notes
        let family = catalog.labels[0].id
        step {
            window.go(to: .library)
            window.setSelection([lake[6], lake[7]])
            let shortcut = menuItem("Photo", catalog.labels[1].displayName)
            check(shortcut?.keyEquivalent == "2" && shortcut?.keyEquivalentModifierMask == .control, "the second label is ⌃2")
            choose("Photo", catalog.labels[1].displayName)
            check([lake[6], lake[7]].allSatisfy { catalog.details($0).labels.contains(catalog.labels[1].id) }, "⌃2 puts the label on the selection")
            choose("Photo", catalog.labels[1].displayName)
            check([lake[6], lake[7]].allSatisfy { !catalog.details($0).labels.contains(catalog.labels[1].id) }, "⌃2 again takes it off")
        }
        step {
            window.inspectorSetCaption("Dock jump, take two", for: [lake[6]])
            window.inspectorSetNote("Grandpa counted to three in Swedish.", for: lake[6])
            check(catalog.details(lake[6]).caption == "Dock jump, take two" && catalog.details(lake[6]).note.contains("Swedish"),
                  "captions and notes save from the info panel")
            check(window.sidebarDrop([lake[6]], on: .label(family)), "photos can be dropped on a label")
            check(catalog.details(lake[6]).labels.contains(family), "dropping on a label adds it")
        }
        step {
            window.go(to: .label(family))
            check(window.content.allIDs.contains(lake[6]) && window.arrangement.grouping == .month, "a label shows its photos by month")
            window.search("swedish")
            check(window.content.allIDs == [lake[6]], "search finds words in notes", "\(window.content.allIDs)")
            window.search("dock jump")
            check(window.content.allIDs == [lake[6]], "search finds captions, every word counting")
            window.search("")
        }
        step {
            library.edit("Delete Label") { $0.deleteLabel(family) }
            check(catalog.label(family) == nil && !catalog.details(lake[6]).labels.contains(family), "deleting a label takes it off every photo")
            undo.undo()
            check(catalog.label(family) != nil && catalog.details(lake[6]).labels.contains(family), "undo brings a deleted label back")
        }

        // MARK: Moving photos in time
        let scans = ids("scans")
        let summer1998 = CivilDay(year: 1998, month: 8, day: 9)
        step {
            window.go(to: .library)
            check(window.browserHeaderDrop(Array(scans.prefix(3)), .day(summer1998), anchor: window.grid.collectionView),
                  "photos can be dropped on a day")
            wait { scans.prefix(3).allSatisfy { snapshot.day(of: $0) == summer1998 } }
        }
        var before: [Date] = []
        step {
            check(scans.prefix(3).allSatisfy { snapshot.day(of: $0) == summer1998 }, "dropping on a day moves every photo to that day")
            let clock = scans.prefix(3).map { calendar.dateComponents([.hour, .minute, .second], from: date($0)) }
            check(clock.allSatisfy { $0.hour == 14 && $0.minute == 2 }, "photos keep their times of day", "\(clock)")
            check(source.items[scans[0]]?.date == date(scans[0]), "the new dates are written to the library")
            check(window.content.sections.first?.key == .day(summer1998), "the timeline moves them to their new day")
            check(window.state.selection == Array(scans.prefix(3)), "the moved photos stay selected")
            before = scans.prefix(3).map(date)
            undo.undo()
            wait { snapshot.day(of: scans[0]) != summer1998 }
        }
        step {
            check(scans.prefix(3).allSatisfy { snapshot.day(of: $0) != summer1998 }, "undo moves them back to their old dates")
            undo.redo()
            wait { snapshot.day(of: scans[0]) == summer1998 }
        }
        step {
            check(scans.prefix(3).map(date) == before, "redo moves them again")
            // Drop the next scan between the first two photos of July 4, 2019.
            window.refresh(keepPosition: true)
            guard let section = window.content.sections.firstIndex(where: { $0.key == .day(CivilDay(year: 2019, month: 7, day: 4)) }) else {
                check(false, "the July 4 section is there")
                return
            }
            let first = window.content.sections[section].items[0], second = window.content.sections[section].items[1]
            check(window.browserDrop([scans[3]], before: IndexPath(item: 1, section: section), anchor: .zero, in: window.grid.collectionView),
                  "photos can be dropped between two photos")
            wait { date(scans[3]) > date(first) && date(scans[3]) < date(second) }
        }
        step {
            guard let section = window.content.sections.firstIndex(where: { $0.key == .day(CivilDay(year: 2019, month: 7, day: 4)) }) else { return }
            check(window.content.sections[section].items[1] == scans[3], "a photo dropped between two lands right there",
                  "\(window.content.sections[section].items.prefix(3))")
            // Drop two more on a calendar day.
            let christmas = CivilDay(year: 2019, month: 12, day: 25)
            window.sidebar.calendar.show(christmas)
            check(window.calendarDrop([scans[4], scans[5]], on: christmas, rect: .zero, in: window.sidebar.calendar),
                  "photos can be dropped on the calendar")
            wait { snapshot.day(of: scans[4]) == christmas && snapshot.day(of: scans[5]) == christmas }
        }
        step {
            check(snapshot.day(of: scans[4]) == CivilDay(year: 2019, month: 12, day: 25), "dropping on the calendar moves them to that day")
            check(date(scans[4]) < date(scans[5]), "a moved batch keeps its order")
            check(window.sidebar.calendar.counts[CivilDay(year: 2019, month: 12, day: 25)] == 8, "the calendar updates its counts",
                  "\(window.sidebar.calendar.counts[CivilDay(year: 2019, month: 12, day: 25)] ?? 0)")
            // Asking first: the question appears next to where they were dropped.
            UserDefaults.standard.set(true, forKey: Preferences.askBeforeChangingDatesKey)
            window.move([scans[6]], to: CivilDay(year: 2020, month: 1, day: 1), anchor: NSRect(x: 30, y: 30, width: 20, height: 20),
                        of: window.sidebar.calendar)
            check(window.activePopover?.isShown == true, "dropping asks first when that's turned on")
            check(date(scans[6]) > Date().addingTimeInterval(-10 * 86_400), "nothing moves until the person agrees")
            window.activePopover?.close()
            UserDefaults.standard.set(false, forKey: Preferences.askBeforeChangingDatesKey)
        }
        step {
            window.setSelection([scans[6], scans[7]])
            choose("Photo", "Change Date and Time…")
            check(nsWindow.attachedSheet != nil, "Change Date and Time opens a sheet")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet) }
            let changes = Redate.shift(scans[6...7].map { (id: $0, date: date($0)) }, firstTo: calendar.date(from: DateComponents(year: 2001, month: 5, day: 5, hour: 9))!)
            window.changeDates(changes, actionName: "Change Dates")
            wait { snapshot.day(of: scans[6]) == CivilDay(year: 2001, month: 5, day: 5) }
        }
        step {
            check(snapshot.day(of: scans[6]) == CivilDay(year: 2001, month: 5, day: 5) && date(scans[7]).timeIntervalSince(date(scans[6])) == 9,
                  "Change Date and Time can move a batch by the same amount")
            check(undo.undoActionName == "Change Dates", "date changes are named for Undo", undo.undoActionName)
        }

        // MARK: Arranging and views
        step {
            window.setGrouping(.year)
            check(window.content.sections.map(\.key).allSatisfy { if case .year = $0 { true } else { false } }, "photos group by year")
            window.setGrouping(.album)
            let keys = window.content.sections.map(\.key)
            check(keys.last == .noAlbum && keys.contains(.album(newAlbum!)), "photos group by album, with the rest at the end")
            window.setGrouping(.label)
            check(window.content.sections.map(\.key).last == .noLabel, "photos group by label")
            window.setGrouping(.none)
            window.setSort(.title, ascending: true)
            let firstTitle = library.title(of: window.content.allIDs[0])
            check(firstTitle == "Cake first, presents later", "photos sort by title", firstTitle)
            window.setGrouping(.day)
            window.setSort(.dateTaken, ascending: false)
            check(window.content.sections.first.map { $0.key.days!.lowerBound > window.content.sections.last!.key.days!.lowerBound } == true,
                  "newest first puts the newest day on top")
            window.setSort(.dateTaken, ascending: true)
        }
        step {
            window.setViewMode(.list)
            check(window.list.tableView.numberOfRows > snapshot.count, "the list shows every photo under its day's heading",
                  "\(window.list.tableView.numberOfRows)")
            window.list.select([lake[2]])
            check(window.state.selection == [lake[2]], "selecting in the list selects photos")
            window.setViewMode(.gallery)
            window.setThumbnailSide(240)
            window.grid.collectionView.layoutSubtreeIfNeeded()
            check(window.grid.layout.side >= 200, "the size slider makes thumbnails bigger", "\(window.grid.layout.side)")
            window.setThumbnailSide(Theme.defaultThumbnail)
        }

        // MARK: The viewer
        step {
            window.grid.select([lake[2]])
            key(36, "\r", to: window.grid.collectionView, window: nsWindow)
            check(window.state.viewerID == lake[2], "Return opens the selected photo")
            key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), to: window.viewer.view, window: nsWindow)
            check(window.state.viewerID == window.viewerSequence[window.viewerSequence.firstIndex(of: lake[2])! + 1], "→ shows the next photo")
            key(53, "\u{1B}", to: window.viewer.view, window: nsWindow)
            check(window.state.viewerID == nil && window.state.selection.count == 1, "Esc goes back to the photos, keeping the selection")
        }
        step {
            let video = ids("birthday23").first { snapshot.item($0)?.kind == .video }!
            window.openViewer(video)
            wait(upTo: 8) { window.viewerPlayerReady }
        }
        step {
            check(window.viewerPlayerReady, "videos play in the viewer")
            window.goBack()
            check(window.state.viewerID == nil, "Back closes the viewer")
        }

        // MARK: Saving
        step { wait(upTo: 3) { (try? DebugLaunchOptions.sampleStore?.load()) == catalog } }
        step {
            let saved = try? DebugLaunchOptions.sampleStore?.load()
            check(saved == catalog, "albums, labels, captions and notes are saved")
            check(DebugLaunchOptions.sampleStore?.fileURL.path.contains("PugglePhotos Sample Catalog") == true,
                  "the self-test saves to a scratch catalog, never the real one")
        }
        runSteps()
    }
}

extension LibraryWindowController {
    /// Whether the viewer has a video ready to play, for the self-test.
    var viewerPlayerReady: Bool { viewer.hasPlayer }
}
#endif
