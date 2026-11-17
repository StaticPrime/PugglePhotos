#if DEBUG
import AppKit
import PugglePhotosKit
import SwiftUI

extension SelfTest {
    /// Clicks a point in the grid as a person would: down, then up.
    static func gridClick(_ point: NSPoint, in window: LibraryWindowController, modifiers: NSEvent.ModifierFlags = []) {
        guard let view = window.grid.collectionView, let nsWindow = view.window else { return }
        let location = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Through the window, as a real click comes: the up waits in line, for the collection view to take if it
        // follows the mouse, or to arrive next if it doesn't.
        NSApp.postEvent(up, atStart: false)
        nsWindow.sendEvent(down)
    }

    /// The middle of the thumbnail of a photo in the grid.
    static func gridPoint(_ id: PhotoID, in window: LibraryWindowController) -> NSPoint? {
        guard let path = window.content.indexPaths(of: [id]).min() else { return nil }
        let frame = window.grid.layout.frameForItem(at: path)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    static func isTurnedOver(_ id: PhotoID, in window: LibraryWindowController) -> Bool {
        window.content.indexPaths(of: [id]).compactMap { window.grid.collectionView.item(at: $0) as? PhotoCell }.first?.isTurnedOver == true
    }

    /// Turning photos over in the grid to read and write on their backs.
    static func backSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let fourth = CivilDay(year: 2019, month: 7, day: 4)
        var first: PhotoID { library.snapshot.ids(on: fourth)[2] }
        var second: PhotoID { library.snapshot.ids(on: fourth)[3] }
        var editor: NoteEditorView? { (window.activePopover?.contentViewController as? NSHostingController<NoteEditorView>)?.rootView }

        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
        }
        step {
            window.window?.makeKeyAndOrderFront(nil)
            window.grid.collectionView.layoutSubtreeIfNeeded()
            window.grid.scroll(to: first, animated: false)
            window.grid.collectionView.layoutSubtreeIfNeeded()
            window.window?.makeFirstResponder(window.grid.collectionView)
            window.grid.select([])
            if let point = gridPoint(first, in: window) { gridClick(point, in: window) }
            wait(upTo: 1) { false }
        }
        step {
            check(window.state.selection == [first] && !isTurnedOver(first, in: window), "the first click chooses a photo")
            if let point = gridPoint(first, in: window) { gridClick(point, in: window) }
            wait(upTo: 2) { isTurnedOver(first, in: window) }
        }
        step {
            check(isTurnedOver(first, in: window) && window.grid.turnedOver == first, "a click on the photo chosen turns it over")
            if let point = gridPoint(second, in: window) { gridClick(point, in: window) }
            wait(upTo: 2) { !isTurnedOver(first, in: window) }
        }
        step {
            check(window.state.selection == [second] && !isTurnedOver(first, in: window) && !isTurnedOver(second, in: window),
                  "choosing another photo turns the first back")
            if let point = gridPoint(second, in: window) { gridClick(point, in: window) }
            wait(upTo: 2) { isTurnedOver(second, in: window) }
        }
        step {
            check(isTurnedOver(second, in: window), "and a second click turns that one over")
            if let point = gridPoint(second, in: window) { gridClick(point, in: window) }
            wait(upTo: 2) { !isTurnedOver(second, in: window) }
        }
        step {
            check(!isTurnedOver(second, in: window) && window.grid.turnedOver == nil, "clicking it again turns it back")
            if let point = gridPoint(first, in: window) { gridClick(point, in: window, modifiers: .shift) }
            wait(upTo: 1) { false }
        }
        step {
            check(!isTurnedOver(first, in: window) && window.state.selection.count == 2, "Shift-click only chooses")
            window.grid.turnOver(first)
            key(53, "\u{1B}", to: window.grid.collectionView, window: window.window)
            check(window.grid.turnedOver == nil, "Esc turns it back")
            UserDefaults.standard.set(false, forKey: Preferences.flipsOnClickKey)
            window.grid.select([first])
            if let point = gridPoint(first, in: window) { gridClick(point, in: window) }
            wait(upTo: 1) { false }
        }
        step {
            check(window.grid.turnedOver == nil, "Settings can stop clicks turning photos over")
            UserDefaults.standard.removeObject(forKey: Preferences.flipsOnClickKey)
            window.grid.turnOver(first)
            // The pencil in the corner of the back.
            guard let cell = window.grid.cellView(for: first) else { return }
            let pencil = PhotoBack.pencilRect(in: cell.bounds.size)
            let target = window.grid.collectionView.convert(NSPoint(x: pencil.midX, y: pencil.midY), from: cell)
            gridClick(target, in: window)
            wait(upTo: 2) { editor != nil }
        }
        step {
            check(editor?.title == library.snapshot.day(of: first).map(library.formatting.longDay), "the pencil on the back opens it to write on")
            editor?.draft.text = "  Grandpa built that dock in 1971.\n"
            window.activePopover?.close()
            wait { library.catalog.details(first).note == "Grandpa built that dock in 1971." }
        }
        step {
            check(library.catalog.details(first).note == "Grandpa built that dock in 1971.", "what's written is kept when the popover closes")
            check(window.grid.turnedOver == first && isTurnedOver(first, in: window), "and the photo stays turned over to show it")
            window.setSelection([second])
            window.grid.select([second])
            check(choose("Photo", "Write on the Back…"), "Photo ▸ Write on the Back")
            wait(upTo: 2) { editor != nil }
        }
        step {
            check(window.grid.turnedOver == second && editor != nil, "turns the chosen photo over to write on it")
            let before = library.catalog.details(second).note
            editor?.draft.text = "Not this."
            editor?.draft.isCancelled = true
            window.activePopover?.close()
            wait(upTo: 1) { window.activePopover?.isShown != true }
            check(library.catalog.details(second).note == before, "Cancel keeps the back as it was")
        }
        step {
            window.grid.turnOver(nil)
            let back = PhotoBack.content(of: first, library: library)
            check(back.note.hasPrefix("Grandpa") && back.day == "July 4, 2019", "the back has the day and the note", "\(back)")
            check(Handwriting.font(nil, size: 20).familyName == Handwriting.family, "notes are in the Settings handwriting")
        }
    }
}
#endif
