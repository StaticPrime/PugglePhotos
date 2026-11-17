#if DEBUG
import AppKit
import PugglePhotosKit
import SwiftUI

extension SelfTest {
    /// Notes in photo books: written in an instant photo's white space, on sticky notes moved, stretched, turned and
    /// colored by hand, hidden photo by photo, photos turned over by clicking them twice, and each book's handwriting.
    static func bookNoteSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        var book: BookViewController { window.book }
        var view: BookView { window.book.bookView }
        var albumID: UUID?
        var settings: BookSettings { library.catalog.book(albumID!) }
        var noted: BookPlacement? {
            let showing = book.layout.state(view.state)
            return [showing.left, showing.right].compactMap { $0 }.flatMap { book.layout.pages[$0].placements }.first { !$0.note.isEmpty }
        }
        func left(_ placement: BookPlacement) -> Bool { book.layout.find(placement.id).map { $0.page == book.layout.state(view.state).left } ?? false }
        var editor: NoteEditorView? { (window.activePopover?.contentViewController as? NSHostingController<NoteEditorView>)?.rootView }

        step {
            guard let album = library.catalog.albums.first(where: { $0.title == "Beach Trips" }) else {
                check(false, "the Beach Trips album is there")
                return
            }
            albumID = album.id
            window.go(to: .album(album.id))
            window.setViewMode(.book)
            book.change("Frames") { $0 = BookSettings(frame: .instant) }
            view.go(to: 2, animated: false)
            check(noted?.noteStyle == .onPhoto && noted?.showsNote == true, "an instant photo's note is written in its white space")
            book.change("Notes") { $0.notes = .sticky }
            check(noted?.hasSticky == true && settings.notes == .sticky, "notes can go on sticky notes instead")
        }
        step {
            guard let placement = noted else { return }
            let start = view.viewPoint(placement.stickyPage(.zero), onLeft: left(placement))
            bookMouse(.leftMouseDown, at: start, in: view)
            check(view.selectedSticky == placement.id, "a click picks a sticky note")
            bookMouse(.leftMouseDragged, at: CGPoint(x: start.x - 20, y: start.y + 10), in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: start.x - 40, y: start.y + 30), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: start.x - 40, y: start.y + 30), in: view)
            let moved = settings.overrides[placement.id]?.sticky
            check(moved != nil && moved!.center != placement.sticky.center && library.undoManager.undoMenuItemTitle == "Undo Move Sticky Note",
                  "dragging moves it, and can be undone")
            let after = book.layout.find(placement.id)!.placement
            let middle = view.viewPoint(after.stickyPage(.zero), onLeft: left(after))
            check(hypot(middle.x - (start.x - 40), middle.y - (start.y + 30)) < 2, "it lands where it was dropped")
        }
        step {
            guard let placement = noted else { return }
            let rect = placement.sticky.rect
            let corner = view.viewPoint(placement.stickyPage(CGPoint(x: rect.maxX, y: rect.maxY)), onLeft: left(placement))
            bookMouse(.leftMouseDown, at: corner, in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: corner.x + 30, y: corner.y + 20), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: corner.x + 30, y: corner.y + 20), in: view)
            let stretched = settings.overrides[placement.id]?.sticky
            check(stretched.map { $0.size.width > placement.sticky.size.width && $0.size.height > placement.sticky.size.height } == true
                  && library.undoManager.undoMenuItemTitle == "Undo Resize Sticky Note", "its corner stretches it")
        }
        step {
            guard let placement = noted else { return }
            let rect = placement.sticky.rect
            let corner = view.viewPoint(placement.stickyPage(CGPoint(x: rect.maxX, y: rect.maxY)), onLeft: left(placement))
            bookMouse(.leftMouseDown, at: corner, in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: corner.x - 400, y: corner.y - 400), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: corner.x - 400, y: corner.y - 400), in: view)
            let squeezed = settings.overrides[placement.id]?.sticky
            check(squeezed.map { $0.size == BookSticky.smallest } == true, "but no smaller than a sticky note", "\(String(describing: squeezed?.size))")
        }
        step {
            guard let placement = noted, let menu = book.bookMenu(for: placement.id, sticky: true),
                  let colors = menu.item(withTitle: "Sticky Note Color")?.submenu, let pink = colors.item(withTitle: "Pink") else {
                check(false, "a sticky note's menu has its colors")
                return
            }
            _ = pink.target.map { NSApp.sendAction(pink.action!, to: $0, from: pink) }
            check(settings.overrides[placement.id]?.sticky?.color == .pink, "a sticky note can be another color")
            let middle = view.viewPoint(book.layout.find(placement.id)!.placement.stickyPage(.zero), onLeft: left(placement))
            bookMouse(.leftMouseDown, at: middle, in: view, clickCount: 2)
            bookMouse(.leftMouseUp, at: middle, in: view, clickCount: 2)
            check(editor?.draft.text == placement.note, "a double-click on a sticky note writes on it")
            window.activePopover?.close()
        }
        step {
            guard let placement = noted else { return }
            book.setNoteStyle(.hidden, for: placement.id)
            let hidden = book.layout.find(placement.id)!.placement
            check(!hidden.showsNote && !hidden.hasSticky, "each photo can hide its note")
            book.setNoteStyle(nil, for: placement.id)
            check(book.layout.find(placement.id)!.placement.hasSticky, "or show it as the book does")
            book.resetLayout()
            check(settings.overrides[placement.id]?.sticky == nil, "Reset Book Layout puts sticky notes back")
        }
        step {
            // A photo: the first click picks it, a click on it picked turns it over.
            guard let placement = noted else { return }
            let frame = placement.frameRect(book.layout.settings.frame)
            let inside = view.viewPoint(placement.page(CGPoint(x: frame.minX + 20, y: frame.maxY - 20)), onLeft: left(placement))
            view.select(nil)
            bookMouse(.leftMouseDown, at: inside, in: view)
            bookMouse(.leftMouseUp, at: inside, in: view)
            check(view.selected == placement.id && view.turnedOver == nil, "the first click on a photo in a book picks it")
            bookMouse(.leftMouseDown, at: inside, in: view)
            bookMouse(.leftMouseUp, at: inside, in: view)
            wait(upTo: 2) { view.turnedOver == placement.id }
        }
        step {
            guard let placement = noted else { return }
            check(view.turnedOver == placement.id, "a click on the photo picked turns it over to read its back")
            check(book.bookPhotoSide(placement.id, back: true, scale: 1) != nil, "its back is drawn")
            view.turnOver(placement.id)
            wait(upTo: 2) { view.turnedOver == nil }
        }
        step {
            check(view.turnedOver == nil, "and again turns it back")
            if let placement = noted { view.turnOver(placement.id) }
            wait(upTo: 2) { view.turnedOver != nil }
        }
        step {
            view.next()
            wait { !view.isTurning }
        }
        step {
            check(view.turnedOver == nil, "turning the page puts it back")
            book.change("Handwriting") { $0.handwriting = "Marker Felt" }
            check(settings.handwriting == "Marker Felt", "each book can have its own handwriting")
            book.change("Handwriting") { $0.handwriting = nil }
            book.change("Frames") { $0 = BookSettings() }
            window.setViewMode(.gallery)
        }
    }
}
#endif
