#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// VoiceOver descriptions, the calendar from the keyboard, and Reduce Motion.
    static func accessibilitySteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        guard let nsWindow = window.window else { return }
        let calendar = window.sidebar.calendar!
        var book: BookView { window.book.bookView }
        let fourth = CivilDay(year: 2019, month: 7, day: 4)

        // MARK: VoiceOver
        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
            window.calendarSelect(fourth)
            window.grid.collectionView.layoutSubtreeIfNeeded()
        }
        step {
            let cells = window.grid.collectionView.visibleItems().compactMap { $0 as? PhotoCell }
            let favorite = cells.first { $0.photoID.flatMap(library.snapshot.item)?.isFavorite == true }
            let label = favorite?.view.accessibilityLabel() ?? ""
            check(label.contains("2019") && label.contains("favorite"), "VoiceOver hears when a photo was taken and that it's a favorite", label)
            let captioned = library.catalog.photos.first { !$0.value.caption.isEmpty }?.key
            check(captioned.map(library.spokenDescription(of:))?.contains(library.catalog.details(captioned!).caption) == true,
                  "and its caption")
            calendar.show(fourth)
            let spots = calendar.accessibilityChildren() as? [AccessibleSpot] ?? []
            check(spots.count == 2 + 31 && spots[0].accessibilityLabel() == "Previous Month", "VoiceOver finds each day of the month and the arrows",
                  "\(spots.count)")
            let day = spots.first { $0.accessibilityLabel()?.hasPrefix("Thursday, July 4") == true }
            check(day?.accessibilityLabel()?.contains("\(calendar.counts[fourth] ?? 0) photos") == true && day?.accessibilityFrame().width ?? 0 > 0,
                  "a day says how many photos it has, where it is", day?.accessibilityLabel() ?? "none")
            let fifth = spots.first { $0.accessibilityLabel()?.hasPrefix("Friday, July 5") == true }
            check(fifth?.accessibilityPerformPress() == true && calendar.selectedDay == CivilDay(year: 2019, month: 7, day: 5),
                  "pressing a day goes to it")
        }

        // MARK: The calendar from the keyboard
        step {
            calendar.show(fourth)
            calendar.selectedDay = fourth
            nsWindow.makeFirstResponder(calendar)
            key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), to: calendar, window: nsWindow)
            key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), to: calendar, window: nsWindow)
            check(calendar.keyDay == CivilDay(year: 2019, month: 7, day: 12), "arrow keys move between days",
                  "\(String(describing: calendar.keyDay))")
            key(121, String(UnicodeScalar(NSPageDownFunctionKey)!), to: calendar, window: nsWindow)
            check(calendar.month == 8 && calendar.keyDay?.month == 8, "Page Down turns the month")
            key(36, "\r", to: calendar, window: nsWindow)
            check(calendar.selectedDay == calendar.keyDay && window.state.source == .library, "Return goes to the day")
            nsWindow.makeFirstResponder(window.grid.collectionView)
        }

        // MARK: Reduce Motion
        step {
            UserDefaults.standard.set(true, forKey: "PHReduceMotion")
            guard let album = library.catalog.albums.first(where: { $0.title == "Beach Trips" }) else { return }
            window.go(to: .album(album.id))
            window.setViewMode(.book)
            book.go(to: 0, animated: false)
            check(book.accessibilityValue() as? String == "Cover", "VoiceOver hears where the book is open")
            book.next()
            check(!book.isTurning && book.state == 1, "with Reduce Motion, pages fade instead of turning")
            check(book.accessibilityValue() as? String == "Title Page", "and VoiceOver hears the new place")
            book.next()
            let photos = book.accessibilityChildren() as? [AccessibleSpot] ?? []
            check(!photos.isEmpty && photos.allSatisfy { $0.accessibilityRole() == .image && $0.accessibilityFrame().width > 0 },
                  "VoiceOver finds the photos on the open pages", "\(photos.count)")
            let layout = window.book.layout
            let first = layout.state(book.state).left.flatMap { layout.pages[$0].placements.first?.id }
            check(first != nil && photos.first?.accessibilityLabel() == library.spokenDescription(of: first!), "and hears each one",
                  photos.first?.accessibilityLabel() ?? "")
            let actions = book.accessibilityCustomActions()?.map(\.name) ?? []
            check(actions == ["Next Page", "Previous Page"], "the book can be turned from VoiceOver", "\(actions)")
            window.setViewMode(.gallery)
        }
        step {
            guard let memory = app.memories.finder.selection(Array(library.snapshot.allIDs.prefix(3)), title: "Still") else { return }
            window.play(memory)
            let show = SlideshowController.current
            check((show?.stage.accessibilityValue() as? String)?.hasPrefix("Still. ") == true, "VoiceOver hears the slideshow's title",
                  show?.stage.accessibilityValue() as? String ?? "none")
            show?.next()
            check((show?.stage.accessibilityValue() as? String)?.hasPrefix("1 of 3: ") == true, "and which photo is showing")
            check(show?.lastMotion.map { $0.from == $0.to } == true, "with Reduce Motion, photos hold still in a slideshow")
            show?.close()
            UserDefaults.standard.removeObject(forKey: "PHReduceMotion")
        }
    }
}
#endif
