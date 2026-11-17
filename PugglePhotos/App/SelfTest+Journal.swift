#if DEBUG
import AppKit
import PugglePhotosKit
import SwiftUI

extension SelfTest {
    /// The journal: writing from a day's heading, from the Journal page and with ⌘J; search, undo, playing a day,
    /// and the memories that quote it.
    static func journalSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let memories = app.memories!
        let undo = library.undoManager
        guard let nsWindow = window.window else { return }
        var catalog: Catalog { library.catalog }
        let firstDay = CivilDay(year: 2019, month: 7, day: 4)
        let homecoming = CivilDay(year: 2026, month: 2, day: 8)
        let lakeDay = CivilDay(year: 2023, month: 7, day: 21)
        let today = CivilDay(Date(), in: library.formatting.timeZone)
        func section(_ day: CivilDay) -> Int? { window.content.sections.firstIndex { $0.key == .day(day) } }
        var editor: JournalEditorView? { (window.activePopover?.contentViewController as? NSHostingController<JournalEditorView>)?.rootView }

        // MARK: In the timeline
        step {
            window.go(to: .library)
            guard let written = section(homecoming), let plain = section(firstDay) else {
                check(false, "the timeline has the sample days")
                return
            }
            check(window.content.journal[written].hasPrefix("🥰  Waffles came home today!"),
                  "a day's heading shows its journal entry, mood first", window.content.journal[written])
            check(window.content.journal.filter { !$0.isEmpty }.count == 5, "every day written about shows its entry",
                  "\(window.content.journal.filter { !$0.isEmpty }.count)")
            window.grid.collectionView.layoutSubtreeIfNeeded()
            check(window.grid.layout.headerHeight(written) > window.grid.layout.headerHeight(plain), "a heading with an entry is taller",
                  "\(window.grid.layout.headerHeight(written)) and \(window.grid.layout.headerHeight(plain))")
            check(window.content.journal[plain].isEmpty, "a day without an entry has just its name")
        }
        step {
            window.browserWriteJournal(for: firstDay, anchor: window.grid.collectionView)
            check(window.activePopover?.isShown == true && editor?.dayTitle == "Thursday, July 4, 2019",
                  "the pencil on a heading opens the journal for that day")
            editor?.draft.text = "Fireworks over the lake. Everyone said ooh at the same time.\n"
            editor?.draft.mood = "🤩"
            // A click elsewhere closes the popover and keeps the writing.
            window.activePopover?.close()
            wait { catalog.entry(for: firstDay) != nil }
        }
        step {
            check(catalog.entry(for: firstDay)?.text == "Fireworks over the lake. Everyone said ooh at the same time."
                  && catalog.entry(for: firstDay)?.mood == "🤩", "closing the popover saves what was written, trimmed",
                  catalog.entry(for: firstDay)?.text ?? "nothing")
            check(undo.undoMenuItemTitle == "Undo Journal Entry", "writing in the journal can be undone", undo.undoMenuItemTitle)
            check(section(firstDay).map { window.content.journal[$0].hasPrefix("🤩  Fireworks") } == true, "the heading shows it at once")
            window.browserWriteJournal(for: firstDay, anchor: window.grid.collectionView)
            check(editor?.draft.text.hasPrefix("Fireworks") == true, "the popover opens with what's already written")
            editor?.draft.text = "Changed my mind"
            editor?.draft.isCancelled = true
            window.activePopover?.close()
            wait(upTo: 1) { window.activePopover?.isShown != true && catalog.entry(for: firstDay)?.text.hasPrefix("Fireworks") != true }
        }
        step {
            check(catalog.entry(for: firstDay)?.text.hasPrefix("Fireworks") == true, "Cancel throws the changes away")
            undo.undo()
        }
        step {
            check(catalog.entry(for: firstDay) == nil && section(firstDay).map { window.content.journal[$0].isEmpty } == true,
                  "Undo takes the entry away again, heading and all")
            undo.redo()
            check(catalog.entry(for: firstDay)?.mood == "🤩", "Redo brings it back")
        }

        // MARK: Search
        step {
            window.search("cocoa")
            let days = Set(window.content.allIDs.compactMap(library.snapshot.day(of:)))
            check(days.count == 1 && window.content.allIDs.count == 4, "search finds a day's photos by what was written about it",
                  "\(window.content.allIDs.count) photos on \(days)")
            window.search("🤩")
            check(window.content.allIDs.contains { library.snapshot.day(of: $0) == firstDay }, "and by its mood")
            window.search("")
            window.toolbarController.clearSearch()
        }

        // MARK: The Journal page
        step {
            check(choose("Go", "Journal"), "Go ▸ Journal")
            check(window.journalHost?.view.window != nil && nsWindow.title == "Journal" && nsWindow.subtitle == "6 entries",
                  "the Journal page lists the entries", "\(nsWindow.title) — \(nsWindow.subtitle)")
            let requests = window.journalComposer.focusRequests
            check(choose("File", "Write in Journal…") && window.journalComposer.focusRequests == requests + 1 && nsWindow.attachedSheet == nil,
                  "⌘J on the Journal page goes to its writing box")
            window.journalComposer.text = "Wrote the self-test."
            window.journalComposer.mood = "😌"
            window.journalSave(window.journalComposer.text, mood: window.journalComposer.mood, for: today)
            check(catalog.entry(for: today)?.text == "Wrote the self-test." && catalog.journalDays.first == today,
                  "writing about today puts it at the top")
            check(nsWindow.subtitle == "7 entries", "the page counts it", nsWindow.subtitle)
        }
        step {
            window.journalSave("", mood: "", for: today)
            check(catalog.entry(for: today) == nil && undo.undoMenuItemTitle == "Undo Delete Journal Entry",
                  "Delete Entry removes it, and can be undone", undo.undoMenuItemTitle)
            let count = catalog.journal.count
            window.journalSave(catalog.entry(for: firstDay)?.text ?? "", mood: "🤩", for: firstDay)
            check(catalog.journal.count == count && undo.undoMenuItemTitle == "Undo Delete Journal Entry",
                  "saving without a change adds no undo step")
            window.journalComposer.write(about: homecoming, catalog: catalog, today: today)
            check(window.journalComposer.day == homecoming && window.journalComposer.text.hasPrefix("Waffles came home"),
                  "Edit on an entry brings it up to write in")
            window.journalComposer.write(about: nil, catalog: catalog, today: today)
            window.journalComposer.text = "Written, then wandered off."
            window.go(to: .favorites)
            wait(upTo: 2) { catalog.entry(for: today) != nil }
        }
        step {
            check(catalog.entry(for: today)?.text == "Written, then wandered off.", "leaving the Journal page keeps what was being written",
                  catalog.entry(for: today)?.text ?? "nothing")
            window.journalSave("", mood: "", for: today)
        }
        step {
            window.go(to: .journal)
            window.journalShowDay(lakeDay)
        }
        step {
            window.grid.collectionView.layoutSubtreeIfNeeded()
            let showing = window.grid.collectionView.indexPathsForVisibleItems().compactMap(window.content.id(at:))
            check(window.state.source == .library && window.sidebar.calendar.selectedDay == lakeDay
                  && showing.contains { library.snapshot.day(of: $0) == lakeDay },
                  "an entry's photos open in the library, on that day", "\(Set(showing.compactMap(library.snapshot.day(of:))).sorted())")
            window.journalPlayDay(homecoming)
            let show = SlideshowController.current
            check(show?.memory.id == "day-2026-02-08" && show?.memory.note.hasPrefix("Waffles came home") == true,
                  "an entry's day plays as a slideshow, with what was written")
            check((show?.slides.first?.duration ?? 0) > SlideshowPlan.titleDuration, "its title card stays long enough to read")
            show?.close()
        }

        // MARK: ⌘J and the info panel
        step {
            let lake = library.snapshot.ids(on: CivilDay(year: 2023, month: 7, day: 21))
            window.grid.select([lake[1]])
            window.setSelection([lake[1]])
            check(choose("File", "Write in Journal…") && nsWindow.attachedSheet != nil, "⌘J writes about the chosen photo's day")
            let sheet = (nsWindow.attachedSheet?.contentViewController as? NSHostingController<JournalEditorView>)?.rootView
            check(sheet?.dayTitle == "Friday, July 21, 2023" && sheet?.draft.text.hasPrefix("Lake day.") == true,
                  "with that day's entry in it", sheet?.dayTitle ?? "none")
            if let open = nsWindow.attachedSheet { nsWindow.endSheet(open) }
        }

        // MARK: Memories
        step {
            memories.refresh()
            wait { !memories.isFinding }
        }
        step {
            let page = memories.page
            check(page.collections.map(\.title) == ["Your Favorites", "Days You Wrote About"], "favorites and the journal are collections",
                  "\(page.collections.map(\.title))")
            check(page.onThisDay.first?.note.hasPrefix("Waffles discovered the leaf pile") == true, "a year-ago memory quotes the journal")
        }
    }
}
#endif
