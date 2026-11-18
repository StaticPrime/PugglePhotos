#if DEBUG
import AppKit
import PugglePhotosKit
import SwiftUI

extension SelfTest {
    /// Clicks a point in the book view through the window, as a mouse does.
    static func bookWindowClick(_ point: CGPoint, in view: BookView) {
        guard let window = view.window else { return }
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

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
        var before: BookPlacement?

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
            // Taken hold of a little inside its corner, that spot stays under the pointer: the corner doesn't jump to it.
            guard let placement = noted else { return }
            let rect = placement.sticky.rect
            let corner = view.viewPoint(placement.stickyPage(CGPoint(x: rect.maxX, y: rect.maxY)), onLeft: left(placement))
            let grab = CGPoint(x: corner.x - 6, y: corner.y - 5)
            check(view.cursorForTesting(at: grab) == .pointingHand, "the pointer is a hand over a sticky note's corner")
            bookMouse(.leftMouseDown, at: grab, in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: grab.x + 25, y: grab.y + 15), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: grab.x + 25, y: grab.y + 15), in: view)
            guard let after = book.layout.find(placement.id)?.placement else { return }
            let moved = view.viewPoint(after.stickyPage(CGPoint(x: after.sticky.rect.maxX, y: after.sticky.rect.maxY)), onLeft: left(after))
            check(hypot(moved.x - (corner.x + 25), moved.y - (corner.y + 15)) < 1.5, "the spot taken hold of on its corner stays under the pointer",
                  "\(moved) for \(CGPoint(x: corner.x + 25, y: corner.y + 15))")
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
            // A photo made bigger keeps its sticky note (moved and resized by hand) where it was on it, the same size.
            guard let placement = noted, let sticky = settings.overrides[placement.id]?.sticky else {
                check(false, "a sticky note moved by hand")
                return
            }
            view.select(placement.id)
            let corners = placement.corners(settings.frame).map { view.viewPoint($0, onLeft: left(placement)) }
            let to = CGPoint(x: corners[2].x + (corners[2].x - corners[0].x) * 0.25, y: corners[2].y + (corners[2].y - corners[0].y) * 0.25)
            bookMouse(.leftMouseDown, at: corners[2], in: view)
            bookMouse(.leftMouseDragged, at: to, in: view)
            bookMouse(.leftMouseUp, at: to, in: view)
            let scale = settings.overrides[placement.id]?.scale
            let moved = settings.overrides[placement.id]?.sticky
            check(scale.map { abs($0 - 1.25) < 0.01 } == true
                  && moved.map { abs($0.center.x - sticky.center.x * 1.25) < 0.01 && abs($0.center.y - sticky.center.y * 1.25) < 0.01 && $0.size == sticky.size } == true,
                  "a photo made bigger keeps its sticky note in its place on it, the same size", "\(String(describing: scale))")
        }
        step {
            guard let placement = noted else { return }
            book.setNoteStyle(.hidden, for: placement.id)
            let hidden = book.layout.find(placement.id)!.placement
            check(!hidden.showsNote && !hidden.hasSticky, "each photo can hide its note")
            book.setNoteStyle(nil, for: placement.id)
            check(book.layout.find(placement.id)!.placement.hasSticky, "or show it as the book does")
            book.resetLayout()
            check(settings.overrides[placement.id]?.sticky == nil && settings.overrides[placement.id]?.scale == nil,
                  "Reset Book Layout puts sticky notes back, and photos to their size")
        }
        step {
            // Handles take a click a little off the knob, or on its stalk, without letting go of what's picked.
            guard let placement = noted else { return }
            view.select(placement.id)
            let state = view.state
            guard let knob = view.knobForTesting else {
                check(false, "a picked photo has a knob")
                return
            }
            // The pointer AppKit is given: a hand over the knob and its stalk, nothing beside them, in pieces that
            // never overlap.
            let stalk = CGPoint(x: (knob.top.x + knob.turn.x) / 2, y: (knob.top.y + knob.turn.y) / 2)
            check(view.cursorForTesting(at: knob.turn) == .pointingHand && view.cursorForTesting(at: stalk) == .pointingHand
                  && view.cursorForTesting(at: CGPoint(x: knob.turn.x + 40, y: knob.turn.y)) == nil,
                  "the pointer is a hand over a photo's knob and its stalk, and only there")
            let rects = view.cursorRectsForTesting.map(\.rect)
            check(!rects.indices.contains { i in rects.indices.contains { j in i < j && !rects[i].intersection(rects[j]).isEmpty } },
                  "the places the pointer changes never overlap")
            bookWindowClick(CGPoint(x: knob.turn.x + 8, y: knob.turn.y + 6), in: view)
            check(view.selected == placement.id && view.state == state, "a click just off a photo's knob keeps it picked")
            bookWindowClick(CGPoint(x: (knob.top.x + knob.turn.x) / 2, y: (knob.top.y + knob.turn.y) / 2), in: view)
            check(view.selected == placement.id && view.state == state, "and so does one on its stalk")
            view.pick(.sticky(placement.id))
            if let knob = view.knobForTesting { bookWindowClick(CGPoint(x: knob.turn.x - 7, y: knob.turn.y - 7), in: view) }
            check(view.selectedSticky == placement.id, "a sticky note's knob too")
            // Empty paper, far from anything.
            let paper = book.layout.state(view.state).left.map { _ in view.viewPoint(CGPoint(x: 300, y: 760), onLeft: true) }
            if let paper { bookWindowClick(paper, in: view) }
            check(view.pick == nil && view.state == state, "a click on the paper lets go of what's picked, without turning the page")
            if let paper { bookWindowClick(paper, in: view) }
            wait(upTo: 3) { view.state == state - 1 && !view.isTurning }
        }
        step {
            check(view.state == 1, "with nothing picked, a click on the paper turns the page", "\(view.state)")
            view.go(to: 2, animated: false)
        }
        step {
            // A photo at the very top of its page has its knob standing off the page, over the desk: it turns the
            // photo from where it was, a little, without a jump.
            guard let placement = noted else { return }
            before = placement
            let size = placement.frameSize(book.layout.settings.frame)
            book.bookCommit(placement.id, center: CGPoint(x: placement.center.x, y: size.height / 2 + 4), angle: 0)
            view.select(placement.id)
            guard let knob = view.knobForTesting, view.pagePoint(knob.turn) == nil else {
                check(false, "a photo at the top of its page has its knob off the page")
                return
            }
            bookMouse(.leftMouseDown, at: knob.turn, in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: knob.turn.x + 10, y: knob.turn.y), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: knob.turn.x + 10, y: knob.turn.y), in: view)
            let angle = book.layout.find(placement.id)?.placement.angle ?? 0
            check(angle > 0 && angle < 10, "a knob standing off the page turns its photo a little, from where it was", "\(angle)°")
        }
        step {
            library.undoManager.undo()
            let after = before.flatMap { book.layout.find($0.id)?.placement }
            check(after != nil && after?.center == before?.center && after?.angle == before?.angle, "and Undo puts it back")
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
