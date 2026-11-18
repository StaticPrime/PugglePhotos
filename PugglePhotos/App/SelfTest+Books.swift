#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// Sends a mouse event to the book at a point in its view.
    static func bookMouse(_ type: NSEvent.EventType, at point: CGPoint, in view: BookView, clickCount: Int = 1) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                                             pressure: 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    /// Photo books: opening one, turning pages by click, key and drag, picking, moving and turning photos, the
    /// paper and frames, shuffling, leaving photos out, videos on the page, the viewer, PDF and printing.
    static func bookSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        var book: BookViewController { window.book }
        var view: BookView { window.book.bookView }
        var albumID: UUID?
        var settings: BookSettings { library.catalog.book(albumID!) }
        var windowFrame: NSRect?

        step {
            guard let album = library.catalog.albums.first(where: { $0.title == "Beach Trips" }) else {
                check(false, "the Beach Trips album is there")
                return
            }
            albumID = album.id
            window.go(to: .album(album.id))
            window.setViewMode(.book)
            check(window.isShowingBook, "an album opens as a book")
            check(view.state == 0 && book.controls.place == "Cover", "a book opens closed, on its cover")
            let photos = book.layout.pages.filter { $0.kind == .photos }.flatMap(\.placements).count
            check(photos == album.items.count, "every photo in the album is in the book", "\(photos) of \(album.items.count)")
            check(book.layout.pages.count % 2 == 0 && book.layout.pages.first?.kind == .cover && book.layout.pages.last?.kind == .back,
                  "a book runs from its cover to its back")
            // The window changes size while the book is closed (slid over to center its cover), so the book is laid
            // out again there; once open, it must still be drawn where it's clicked.
            if let nsWindow = window.window {
                windowFrame = nsWindow.frame
                nsWindow.setFrame(nsWindow.frame.insetBy(dx: -40, dy: -20), display: true)
                nsWindow.layoutIfNeeded()
            }
            view.next()
            wait { !view.isTurning && view.state == 1 }
        }
        step {
            check(view.state == 1 && book.controls.place == "Title Page", "the cover turns to the title page")
            key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), to: view, window: window.window)
            wait { !view.isTurning && view.state == 2 }
        }
        step {
            check(view.state == 2 && book.controls.place.hasPrefix("Pages 1–2"), "→ turns the page", book.controls.place)
            // Drag the right page over by hand.
            let right = view.pageRect(left: false)
            let start = CGPoint(x: right.maxX - 12, y: right.maxY - 12)
            bookMouse(.leftMouseDown, at: start, in: view)
            for step in 1...6 { bookMouse(.leftMouseDragged, at: CGPoint(x: start.x - CGFloat(step) * right.width * 0.25, y: start.y), in: view) }
            check(view.isTurning, "dragging the paper lifts the page")
            bookMouse(.leftMouseUp, at: CGPoint(x: start.x - right.width * 1.5, y: start.y), in: view)
            wait { !view.isTurning && view.state == 3 }
        }
        step {
            check(view.state == 3, "a page dragged most of the way over turns", "\(view.state)")
            view.previous()
            wait { !view.isTurning && view.state == 2 }
        }
        var picked: BookPlacement?
        var pickedPage = 0
        step {
            check(view.state == 2, "← turns back")
            guard let page = book.layout.state(2).right, let placement = book.layout.pages[page].placements.first else { return }
            picked = placement
            pickedPage = page
            let point = view.viewPoint(placement.center, onLeft: false)
            bookMouse(.leftMouseDown, at: point, in: view)
            bookMouse(.leftMouseUp, at: point, in: view)
            check(view.selected == placement.id && book.controls.hasSelection, "clicking a photo picks it")
            // Its knob and corner are drawn right where they take hold, though the window changed size while the book
            // was closed.
            let drawn = view.drawnHandlesForTesting
            func same(_ a: CGPoint?, _ b: CGPoint?) -> Bool { a.flatMap { a in b.map { hypot(a.x - $0.x, a.y - $0.y) < 0.5 } } ?? false }
            check(same(drawn.knob, view.knobForTesting?.turn) && same(drawn.stretch, view.photoCornerForTesting),
                  "a picked photo's handles are drawn right where they take hold",
                  "knob drawn at \(String(describing: drawn.knob)), taken hold of at \(String(describing: view.knobForTesting?.turn))")
            if let windowFrame { window.window?.setFrame(windowFrame, display: true) }
        }
        step {
            guard let placement = picked else { return }
            let from = view.viewPoint(placement.center, onLeft: false)
            bookMouse(.leftMouseDown, at: from, in: view)
            for step in 1...4 { bookMouse(.leftMouseDragged, at: CGPoint(x: from.x + CGFloat(step) * 10, y: from.y + CGFloat(step) * 5), in: view) }
            bookMouse(.leftMouseUp, at: CGPoint(x: from.x + 40, y: from.y + 20), in: view)
            let moved = settings.overrides[placement.id]?.center
            let scale = BookLayout.pageSize.width / view.pageSize.width
            check(moved.map { abs($0.x - (placement.center.x + 40 * scale)) < 1 && abs($0.y - (placement.center.y + 20 * scale)) < 1 } == true,
                  "dragging a photo moves it on the page", "\(String(describing: moved))")
            check(book.layout.find(placement.id)?.placement.center == moved, "the page shows it where it was dropped")
            check(library.undoManager.undoActionName == "Move Photo", "moving a photo can be undone", library.undoManager.undoActionName)
        }
        step {
            library.undoManager.undo()
            check(settings.overrides[picked!.id] == nil, "undo puts the photo back in its place")
            check(choose("Photo", "Tilt Right"), "Photo ▸ Tilt Right is there for a picked photo")
            let tilted = settings.overrides[picked!.id]?.angle
            check(tilted.map { abs($0 - (picked!.angle + 3)) < 0.11 } == true, "] tilts the photo", "\(String(describing: tilted))")
            choose("Photo", "Straighten")
            check(settings.overrides[picked!.id]?.angle == 0, "Straighten stands it upright")
        }
        step {
            // Turn it with its handle.
            guard let placement = book.layout.find(picked!.id)?.placement else { return }
            let frame = settings.frame
            let handle = view.viewPoint(placement.page(CGPoint(x: 0, y: placement.frameRect(frame).minY - 28)), onLeft: false)
            let center = view.viewPoint(placement.center, onLeft: false)
            bookMouse(.leftMouseDown, at: handle, in: view)
            // A quarter turn clockwise: from above the middle to its right.
            let radius = hypot(handle.x - center.x, handle.y - center.y)
            bookMouse(.leftMouseDragged, at: CGPoint(x: center.x + radius * 0.7, y: center.y - radius * 0.7), in: view)
            bookMouse(.leftMouseUp, at: CGPoint(x: center.x + radius, y: center.y), in: view)
            let angle = settings.overrides[placement.id]?.angle ?? 0
            check(abs(angle - 90) < 2, "dragging the handle turns the photo", "\(angle)")
        }
        // Where a photo's corners are in the view: the one that stays put while it's resized, and the one that resizes it.
        func photoCorners(_ id: PhotoID) -> (fixed: CGPoint, corner: CGPoint)? {
            guard let placement = book.layout.find(id)?.placement else { return nil }
            let corners = placement.corners(settings.frame).map { view.viewPoint($0, onLeft: false) }
            return (corners[0], corners[2])
        }
        step {
            // Resize it by its corner (it's on its side now, so the corner is wherever its bottom right went).
            guard let id = picked?.id, let before = book.layout.find(id)?.placement, let (fixed, corner) = photoCorners(id) else { return }
            check(view.cursorForTesting(at: corner) == .pointingHand, "the pointer is a hand over a picked photo's corner")
            // Taken hold of a little inside the corner, and pulled a fifth further along its diagonal.
            let grab = CGPoint(x: corner.x - 5, y: corner.y + 4)
            let to = CGPoint(x: grab.x + (corner.x - fixed.x) * 0.2, y: grab.y + (corner.y - fixed.y) * 0.2)
            bookMouse(.leftMouseDown, at: grab, in: view)
            bookMouse(.leftMouseDragged, at: CGPoint(x: (grab.x + to.x) / 2, y: (grab.y + to.y) / 2), in: view)
            bookMouse(.leftMouseDragged, at: to, in: view)
            bookMouse(.leftMouseUp, at: to, in: view)
            let scale = settings.overrides[id]?.scale ?? 1
            check(abs(scale - 1.2) < 0.01, "dragging a photo's corner makes it bigger", "\(scale)")
            check(library.undoManager.undoActionName == "Resize Photo", "resizing a photo can be undone", library.undoManager.undoActionName)
            guard let after = book.layout.find(id)?.placement, let (newFixed, newCorner) = photoCorners(id) else { return }
            check(hypot(newFixed.x - fixed.x, newFixed.y - fixed.y) < 1, "its opposite corner stays put")
            check(hypot(newCorner.x - (to.x + 5), newCorner.y - (to.y - 4)) < 1.5, "the spot taken hold of stays under the pointer")
            check(abs(after.imageSize.width / after.imageSize.height - before.imageSize.width / before.imageSize.height) < 0.001,
                  "and the photo keeps its shape")
            check(book.bookMenu(for: id, sticky: false)?.item(withTitle: "Original Size") != nil, "its menu offers its original size back")
        }
        step {
            // As small as it goes.
            guard let id = picked?.id, let (fixed, corner) = photoCorners(id) else { return }
            bookMouse(.leftMouseDown, at: corner, in: view)
            bookMouse(.leftMouseDragged, at: fixed, in: view)
            bookMouse(.leftMouseUp, at: fixed, in: view)
            let size = book.layout.find(id)?.placement.frameSize(settings.frame)
            check(size.map { abs(max($0.width, $0.height) - BookPlacement.smallestFrameSide) < 0.5 } == true, "but never smaller than a small print",
                  "\(String(describing: size))")
        }
        step {
            guard let id = picked?.id, let (fixed, _) = photoCorners(id) else { return }
            check(choose("Photo", "Original Size") && settings.overrides[id]?.scale == nil, "Photo ▸ Original Size gives it back the size the book gave it")
            check(photoCorners(id).map { hypot($0.fixed.x - fixed.x, $0.fixed.y - fixed.y) < 1 } == true, "where it is")
            check(book.bookMenu(for: id, sticky: false)?.item(withTitle: "Original Size") == nil, "after which there's no size to give back")
        }

        // MARK: Carrying photos to other pages
        // Where to press on a photo so that it's the one taken hold of: its middle, or if another photo lies over that,
        // a spot of its own nearer an edge. In the view.
        func pressPoint(_ id: PhotoID, onLeft: Bool) -> CGPoint? {
            guard let found = book.layout.find(id) else { return nil }
            let rect = found.placement.frameRect(settings.frame)
            let spots: [(CGFloat, CGFloat)] = [(0, 0), (-0.3, -0.3), (0.3, -0.3), (-0.3, 0.3), (0.3, 0.3), (0, -0.35), (0, 0.35), (-0.35, 0), (0.35, 0)]
            for (x, y) in spots {
                let point = found.placement.page(CGPoint(x: rect.width * x, y: rect.height * y))
                if book.layout.placement(at: point, onPage: found.page)?.id == id, book.layout.sticky(at: point, onPage: found.page) == nil {
                    return view.viewPoint(point, onLeft: onLeft)
                }
            }
            return nil
        }
        // A drag that takes hold of a photo and carries it toward `to` in steps, not letting go. Answers how far its
        // middle is from the pointer, to work out where it lands.
        @discardableResult
        func carry(_ id: PhotoID, onLeft: Bool, to: CGPoint) -> CGPoint {
            guard let placement = book.layout.find(id)?.placement, let start = pressPoint(id, onLeft: onLeft) else { return .zero }
            let middle = view.viewPoint(placement.center, onLeft: onLeft)
            bookMouse(.leftMouseDown, at: start, in: view)
            for fraction in [0.05, 0.5, 1] as [CGFloat] {
                bookMouse(.leftMouseDragged, at: CGPoint(x: start.x + (to.x - start.x) * fraction, y: start.y + (to.y - start.y) * fraction), in: view)
            }
            return CGPoint(x: middle.x - start.x, y: middle.y - start.y)
        }
        var carried: PhotoID?
        var stayed: (id: PhotoID, center: CGPoint, offset: CGPoint)?
        step {
            // Across the spread: put down on the other page, where it was let go.
            guard let id = picked?.id, let from = book.layout.find(id), let left = book.layout.state(view.state).left else { return }
            let others = book.layout.pages[from.page].placements.filter { $0.id != id }.map { ($0.id, $0.center) }
            let target = view.viewPoint(CGPoint(x: 300, y: 420), onLeft: true)
            let offset = carry(id, onLeft: false, to: target)
            check(view.isCarryingPhoto && settings.overrides[id]?.page == nil, "a photo dragged in a book is lifted off its page")
            bookMouse(.leftMouseUp, at: target, in: view)
            let now = book.layout.find(id)
            let landed = now.map { view.viewPoint($0.placement.center, onLeft: true) }
            check(now?.page == left && landed.map { hypot($0.x - (target.x + offset.x), $0.y - (target.y + offset.y)) < 1 } == true,
                  "and can be put down on the other page, right where it's let go", "\(String(describing: now?.page)) \(String(describing: landed))")
            check(others.allSatisfy { other in book.layout.find(other.0)?.placement.center == other.1 }, "the photos left on its page stay where they were")
            check(view.selected == id && !view.isCarryingPhoto && library.undoManager.undoActionName == "Move Photo",
                  "it's still picked, and the move can be undone", library.undoManager.undoActionName)
        }
        step {
            library.undoManager.undo()
            guard let id = picked?.id else { return }
            check(book.layout.find(id)?.page == book.layout.homePages[id] && settings.overrides[id]?.page == nil, "Undo puts it back on its own page")
            view.go(to: 3, animated: false)
            // Held at the left page's outer edge, the page turns back.
            guard let page = book.layout.state(3).left, let placement = book.layout.pages[page].placements.first else { return }
            carried = placement.id
            let start = view.viewPoint(placement.center, onLeft: true)
            carry(placement.id, onLeft: true, to: CGPoint(x: view.pageRect(left: true).minX + 6, y: start.y))
            wait(upTo: 4) { view.state == 2 && !view.isTurning }
        }
        step {
            check(view.state == 2 && view.isCarryingPhoto, "held at the book's left edge, a photo turns the page back, still in hand")
            guard let id = carried, let right = book.layout.state(2).right else { return }
            let target = view.viewPoint(CGPoint(x: 360, y: 330), onLeft: false)
            bookMouse(.leftMouseDragged, at: target, in: view)
            bookMouse(.leftMouseUp, at: target, in: view)
            check(book.layout.find(id)?.page == right && book.layout.homePages[id] != right, "and goes down on the page before")
            // At the first page of photos there's no page to turn back to.
            guard let first = book.layout.state(2).left, let placement = book.layout.pages[first].placements.first else { return }
            let start = view.viewPoint(placement.center, onLeft: true)
            let offset = carry(placement.id, onLeft: true, to: CGPoint(x: view.pageRect(left: true).minX + 6, y: start.y))
            stayed = (placement.id, placement.center, offset)
            wait(upTo: 1.6) { view.state != 2 }
        }
        step {
            check(view.state == 2 && view.isCarryingPhoto, "at the first page of photos, the page doesn't turn back")
            guard let stayed else { return }
            let middle = view.viewPoint(stayed.center, onLeft: true)
            let home = CGPoint(x: middle.x - stayed.offset.x, y: middle.y - stayed.offset.y)
            bookMouse(.leftMouseDragged, at: home, in: view)
            bookMouse(.leftMouseUp, at: home, in: view)
            check(book.layout.find(stayed.id)?.placement.center == stayed.center && settings.overrides[stayed.id] == nil,
                  "put down where it was, nothing changes")
            // Held at the right page's outer edge, the page turns forward.
            guard let right = book.layout.state(2).right, let placement = book.layout.pages[right].placements.first else { return }
            carried = placement.id
            let start = view.viewPoint(placement.center, onLeft: false)
            carry(placement.id, onLeft: false, to: CGPoint(x: view.pageRect(left: false).maxX - 6, y: start.y))
            wait(upTo: 4) { view.state == 3 && !view.isTurning }
        }
        step {
            check(view.state == 3 && view.isCarryingPhoto, "held at the book's right edge, a photo turns the page forward")
            guard let id = carried, let left = book.layout.state(3).left else { return }
            let target = view.viewPoint(CGPoint(x: 260, y: 520), onLeft: true)
            bookMouse(.leftMouseDragged, at: target, in: view)
            bookMouse(.leftMouseUp, at: target, in: view)
            check(book.layout.find(id)?.page == left && book.layout.homePages[id] != left, "and goes down on the next page",
                  "on \(String(describing: book.layout.find(id)?.page)), its own \(String(describing: book.layout.homePages[id])), left \(left), state \(view.state), carrying \(view.isCarryingPhoto), kept \(String(describing: settings.overrides[id]?.page))")
            // Let go off the pages, on the desk, it goes back where it was.
            guard let right = book.layout.state(3).right, let placement = book.layout.pages[right].placements.first else { return }
            stayed = (placement.id, placement.center, .zero)
            let below = CGPoint(x: view.pageRect(left: false).midX, y: view.pageRect(left: false).maxY + 14)
            let offset = carry(placement.id, onLeft: false, to: below)
            // The photo's middle and the pointer both off the page.
            let pointer = CGPoint(x: below.x - offset.x, y: max(below.y, below.y - offset.y))
            bookMouse(.leftMouseDragged, at: pointer, in: view)
            bookMouse(.leftMouseUp, at: pointer, in: view)
            wait(upTo: 1) { view.selected == placement.id }
        }
        step {
            guard let stayed else { return }
            check(!view.isCarryingPhoto && book.layout.find(stayed.id)?.placement.center == stayed.center
                  && book.layout.find(stayed.id)?.page == book.layout.homePages[stayed.id], "let go off the pages, a photo goes back where it was")
            book.resetLayout()
            let moved = settings.overrides.values.contains { $0.page != nil }
            let pages = book.layout.pages
            check(!moved && pages.indices.filter { pages[$0].holdsPhotos }.allSatisfy { index in pages[index].placements.allSatisfy { book.layout.homePages[$0.id] == index } },
                  "Reset Book Layout puts every photo back on its own page")
        }
        step {
            library.undoManager.undo()
            check(settings.overrides.values.contains { $0.page != nil }, "and Undo carries them back")
            // Every photo on its own page again for what follows.
            book.resetLayout()
            view.go(to: 2, animated: false)
            if let id = picked?.id { view.select(id) }
        }
        step {
            choose("Photo", "Leave Out of Book")
            check(settings.hidden == [picked!.id] && book.layout.find(picked!.id) == nil, "a photo can be left out of the book")
            check(library.catalog.album(albumID!)?.items.contains(picked!.id) == true, "and it stays in the album")
            check(book.controls.hiddenCount == 1, "the bar offers to put it back")
            book.putBackLeftOut()
            check(settings.hidden.isEmpty && book.layout.find(picked!.id) != nil, "Put Back brings it back")
        }
        step {
            book.change("Paper") { $0.paper = .black }
            book.change("Frames") { $0.frame = .print }
            check(book.layout.settings.paper == .black && book.layout.settings.frame == .print, "the paper and frames can change")
            check(library.catalog.album(albumID!)?.book?.paper == .black, "a book's look is saved with its album")
            let print = book.layout.pages.first { $0.kind == .photos }?.placements.first
            check(print.map { abs($0.imageSize.width / $0.imageSize.height - $0.aspect) < 0.01 } == true, "prints keep each photo's shape")
            let before = book.layout.pages
            let seed = settings.seed
            book.shuffle()
            check(settings.seed != seed && settings.overrides.isEmpty && book.layout.pages != before, "Shuffle lays the book out afresh")
            library.undoManager.undo()
            check(settings.seed == seed, "and can be undone")
        }
        step {
            // The PDF: the closed covers on pages of their own, the spreads two pages wide.
            let data = book.pdfData()
            let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
            check(document?.numberOfPages == book.layout.stateCount, "a book saves as a PDF, a page for each spread",
                  "\(document?.numberOfPages ?? 0) of \(book.layout.stateCount)")
            check(document?.page(at: 1)?.getBoxRect(.mediaBox).width == 600 && document?.page(at: 2)?.getBoxRect(.mediaBox).width == 1200,
                  "covers are a page wide, spreads two")
            var range = NSRange()
            _ = BookPrintView(controller: book).knowsPageRange(&range)
            check(range.length == book.layout.stateCount, "printing prints every spread")
        }
        step {
            // Double-click a photo to see it on its own, then come back to the book.
            guard let page = book.layout.state(view.state).right, let placement = book.layout.pages[page].placements.first else { return }
            let point = view.viewPoint(placement.center, onLeft: false)
            bookMouse(.leftMouseDown, at: point, in: view, clickCount: 2)
            check(window.state.viewerID == placement.id, "double-clicking a photo in the book opens it")
            window.closeViewer()
            check(window.isShowingBook && view.state == 2, "closing it goes back to the same pages")
        }
        // Videos on the page.
        var video: PhotoID?
        step {
            guard let party = library.catalog.albums.first(where: { $0.title == "Mia’s 7th Birthday" }) else { return }
            window.go(to: .album(party.id))
            window.setViewMode(.book)
            guard let found = book.layout.pages.enumerated().lazy.compactMap({ index, page in
                page.placements.first(where: \.isVideo).map { (index, $0) }
            }).first else {
                check(false, "the birthday book has a video")
                return
            }
            video = found.1.id
            view.go(to: book.layout.state(showing: found.0), animated: false)
            view.hover(found.1.id)
            wait(upTo: 8) { view.playingVideos.contains(found.1.id) }
        }
        step {
            check(view.playingVideos.contains(video ?? ""), "a video plays when the pointer is over it")
            view.hover(nil)
            check(view.playingVideos.isEmpty, "and stops when the pointer leaves")
            UserDefaults.standard.set(true, forKey: BookPreferences.alwaysPlayKey)
            view.reload()
            wait(upTo: 8) { view.playingVideos.contains(video ?? "") }
        }
        step {
            check(view.playingVideos.contains(video ?? ""), "with Always Play, the open pages' videos play by themselves")
            UserDefaults.standard.set(false, forKey: BookPreferences.alwaysPlayKey)
            view.reload()
            check(view.playingVideos.isEmpty, "and stop when it's turned off")
            window.setViewMode(.gallery)
            check(!window.isShowingBook, "the gallery comes back from the toolbar")
        }
        _ = pickedPage
    }
}
#endif
