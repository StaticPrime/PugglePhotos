#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// Writing anywhere in a photo book: on the title page, the endpapers, the covers, added pages and the blank
    /// page at the end; finishing it, changing it, moving, widening, coloring, sizing and erasing it.
    static func writingSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        var book: BookViewController { window.book }
        var view: BookView { window.book.bookView }
        var albumID: UUID?
        var settings: BookSettings { library.catalog.book(albumID!) }
        var typing: WritingTextView? { window.window?.firstResponder as? WritingTextView }
        func type(_ text: String) { typing?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        func click(_ point: CGPoint, onPage page: Int, count: Int = 1) {
            let at = view.viewPoint(point, onLeft: book.layout.state(view.state).left == page)
            bookMouse(.leftMouseDown, at: at, in: view, clickCount: count)
            bookMouse(.leftMouseUp, at: at, in: view, clickCount: count)
        }
        func page(_ spot: BookSpot) -> Int? { book.layout.page(of: spot) }
        func writing(_ text: String) -> BookWriting? { settings.writings.first { $0.text == text } }

        step {
            guard let album = library.catalog.albums.first(where: { $0.title == "Snow Days" }) else {
                check(false, "the Snow Days album is there")
                return
            }
            albumID = album.id
            window.go(to: .album(album.id))
            window.setViewMode(.book)
            view.go(to: 1, animated: false)
            check(choose("View", "Write on Pages") && view.isWriting && book.controls.isWriting, "View ▸ Write on Pages")
            click(CGPoint(x: 90, y: 700), onPage: page(.title)!)
            check(typing != nil && view.editingWriting != nil, "a click on a page starts writing there")
            type("Snow day!")
            // A click on the other page finishes it, and starts writing there.
            click(CGPoint(x: 120, y: 120), onPage: page(.insideFront)!)
            check(writing("Snow day!")?.spot == .title && library.undoManager.undoMenuItemTitle == "Undo Write on Page",
                  "a click elsewhere keeps what was written, on its page")
            type("First snowman of the year")
            typing?.cancelOperation(nil)
            check(writing("First snowman of the year")?.spot == .insideFront, "Esc finishes it too: endpapers can be written on")
            let count = settings.writings.count
            click(CGPoint(x: 300, y: 600), onPage: page(.title)!)
            click(CGPoint(x: 300, y: 650), onPage: page(.title)!)
            typing?.cancelOperation(nil)
            check(settings.writings.count == count, "nothing written, nothing kept")
            book.setWriting(false)
        }
        step {
            guard let title = writing("Snow day!"), let at = page(.title) else { return }
            click(title.center, onPage: at, count: 2)
            check(typing?.string == "Snow day!", "a double-click on writing writes on it again")
            typing?.string = "Snow day, no school!"
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.window?.windowNumber ?? 0,
                                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                typing?.keyDown(with: event)
            }
            check(writing("Snow day, no school!") != nil && library.undoManager.undoMenuItemTitle == "Undo Change Writing", "⌘Return finishes it")
        }
        step {
            guard let title = writing("Snow day, no school!"), let at = page(.title) else { return }
            let start = view.viewPoint(title.center, onLeft: false)
            bookMouse(.leftMouseDown, at: start, in: view)
            check(view.selectedWriting == title.id, "a click picks writing")
            bookMouse(.leftMouseDragged, at: CGPoint(x: start.x + 30, y: start.y - 40), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: start.x + 30, y: start.y - 40), in: view)
            let moved = writing("Snow day, no school!")
            check(moved.map { $0.center.x > title.center.x && $0.center.y < title.center.y } == true
                  && library.undoManager.undoMenuItemTitle == "Undo Move Writing", "dragging moves it")
            guard let moved else { return }
            let size = book.bookWritingSize(moved)
            let bar = view.viewPoint(moved.page(CGPoint(x: size.width / 2 + 4, y: 0)), onLeft: false)
            bookMouse(.leftMouseDown, at: bar, in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: bar.x - 60, y: bar.y), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: bar.x - 60, y: bar.y), in: view)
            check(writing("Snow day, no school!").map { $0.width < moved.width } == true, "the bar on its side narrows its lines")
            _ = at
        }
        step {
            guard let title = writing("Snow day, no school!"), let menu = book.bookWritingMenu(title.id),
                  let blue = menu.item(withTitle: "Ink")?.submenu?.item(withTitle: "Blue"),
                  let large = menu.item(withTitle: "Size")?.submenu?.item(withTitle: "Large") else {
                check(false, "writing has a menu with its ink and size")
                return
            }
            _ = NSApp.sendAction(blue.action!, to: blue.target, from: blue)
            check(writing("Snow day, no school!")?.ink == .blue, "writing can be in another ink")
            if let large = book.bookWritingMenu(title.id)?.item(withTitle: "Size")?.submenu?.item(withTitle: "Large") {
                _ = NSApp.sendAction(large.action!, to: large.target, from: large)
            }
            _ = large
            check(writing("Snow day, no school!")?.size == 38, "and bigger")
            view.pick(.writing(title.id))
            key(51, "\u{7F}", to: view, window: window.window)
            check(writing("Snow day, no school!") == nil && library.undoManager.undoMenuItemTitle == "Undo Erase Writing", "Delete erases it")
            library.undoManager.undo()
            check(writing("Snow day, no school!") != nil, "and Undo brings it back")
        }
        step {
            // The covers.
            view.go(to: 0, animated: false)
            book.setWriting(true)
            click(CGPoint(x: 120, y: 720), onPage: 0)
            type("For Grandma")
            typing?.cancelOperation(nil)
            let onCover = writing("For Grandma")
            check(onCover?.spot == .cover, "the cover can be written on")
            let light = onCover.map { book.bookWritingLook($0, onPage: 0).color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0 } ?? 0
            check(light > 0.8, "in light ink on the cloth", "\(light)")
            view.go(to: book.layout.stateCount - 1, animated: false)
            click(CGPoint(x: 150, y: 150), onPage: book.layout.pages.count - 1)
            type("The end (for now)")
            typing?.cancelOperation(nil)
            check(writing("The end (for now)")?.spot == .back, "and the back cover")
            book.setWriting(false)
        }
        step {
            // Pages added to write on.
            view.go(to: 2, animated: false)
            let pages = settings.extraPages.count
            book.addPage()
            guard let added = book.openAddedPage, let at = page(.page(added)) else {
                check(false, "Add Page adds a page among the open ones")
                return
            }
            check(settings.extraPages.count == pages + 1, "Add Page adds a blank page")
            book.setWriting(true)
            click(CGPoint(x: 100, y: 200), onPage: at)
            type("Sledding hill: 14 runs")
            typing?.cancelOperation(nil)
            book.setWriting(false)
            check(writing("Sledding hill: 14 runs")?.spot == .page(added), "and it can be written on")
        }
        step {
            let pages = settings.extraPages.count
            check(choose("View", "Remove This Page") && settings.extraPages.count == pages - 1 && writing("Sledding hill: 14 runs") == nil,
                  "View ▸ Remove This Page takes it out, writing and all")
        }
        step {
            library.undoManager.undo()
            check(writing("Sledding hill: 14 runs") != nil && book.openAddedPage != nil, "and Undo puts it back")
        }
        step {
            // The blank page at the end, there to finish the last sheet, is kept once it's written on.
            if !book.layout.pages.contains(where: { $0.kind == .blank }) { book.addPage() }
            guard let blank = book.layout.pages.firstIndex(where: { $0.kind == .blank }) else {
                check(false, "a book with an odd number of pages ends with a blank one")
                return
            }
            view.go(to: book.layout.state(showing: blank), animated: false)
            let pages = settings.extraPages.count
            book.setWriting(true)
            click(CGPoint(x: 200, y: 300), onPage: blank)
            type("Still snowing.")
            typing?.cancelOperation(nil)
            book.setWriting(false)
            let kept = writing("Still snowing.")
            check(settings.extraPages.count == pages + 1 && kept.map { if case .page = $0.spot { true } else { false } } == true,
                  "writing on the blank page at the end keeps that page")
        }
        step {
            book.setWriting(true)
            click(CGPoint(x: 100, y: 100), onPage: book.layout.state(view.state).left ?? 0)
            type("Half-written")
            window.setViewMode(.gallery)
            check(!view.isWriting && view.editingWriting == nil && writing("Half-written") != nil,
                  "leaving the book keeps what was being written and puts the pen down")
        }
    }
}
#endif
