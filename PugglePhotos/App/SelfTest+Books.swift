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

    /// An image's pixels as sRGB, `width` × `height`, four bytes each: the image filling them, or drawn in `rect`.
    static func sRGBPixels(_ image: CGImage, width: Int, height: Int, in rect: CGRect? = nil) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: rect ?? CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    /// How far apart two pictures the same size are: the mean difference of their most different channel (out of 255),
    /// and the share of pixels off by more than 24.
    static func difference(_ a: [UInt8], _ b: [UInt8], count: Int) -> (mean: Double, off: Double) {
        var total = 0, off = 0
        for i in 0..<count {
            let d = max(abs(Int(a[i * 4]) - Int(b[i * 4])), abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])), abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2])))
            total += d
            if d > 24 { off += 1 }
        }
        return (Double(total) / Double(max(count, 1)), Double(off) / Double(max(count, 1)))
    }

    /// Just this window as the window server shows it, whatever is in front of it, at its full resolution.
    static func windowPicture(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: Create.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    /// The book as the window server shows it, against the same place drawn as a PDF page draws it: how far apart they
    /// are over every pixel (edges differ a little: the window stretches pictures of the pages, the PDF draws them
    /// sharp), and along the book's shadow, just under its bottom edge.
    static func bookParity(_ book: BookViewController) -> (mean: Double, off: Double, shadow: Double)? {
        let view = book.bookView
        guard let window = view.window, let scene = book.sceneImageForTesting(), let shot = windowPicture(window) else { return nil }
        let scale = CGFloat(shot.width) / window.frame.width
        let frame = view.convert(view.bounds, to: nil)
        let crop = CGRect(x: frame.minX * scale, y: (window.frame.height - frame.maxY) * scale, width: frame.width * scale, height: frame.height * scale)
        guard let screen = shot.cropping(to: crop.integral) else { return nil }
        let width = min(scene.width, screen.width), height = min(scene.height, screen.height)
        let a = sRGBPixels(screen, width: width, height: height), b = sRGBPixels(scene, width: width, height: height)
        let whole = difference(a, b, count: width * height)
        // The shadow: the rows under what casts it, across its middle.
        let stage = view.stage, pages = book.layout.state(view.state)
        let caster = stage.shadow(open: pages.left != nil && pages.right != nil, closedOnLeft: pages.left != nil).rect
            .offsetBy(dx: stage.offset(state: view.state, stateCount: book.layout.stateCount), dy: 0)
        var total = 0, count = 0
        for y in Int((caster.maxY + 1) * scale)..<min(height, Int((caster.maxY + 44) * scale)) {
            for x in stride(from: Int((caster.minX + 20) * scale), to: min(width, Int((caster.maxX - 20) * scale)), by: 3) {
                let i = (y * width + x) * 4
                total += abs(Int(a[i]) - Int(b[i]))
                count += 1
            }
        }
        return (whole.mean, whole.off, Double(total) / Double(max(count, 1)))
    }

    /// A page of an EPUB against the same page open in the window: how far apart they are, all over but for a few points
    /// around the edge, where the window rounds the page's corners. The EPUB's page is drawn just where the window draws
    /// it, to a fraction of a pixel, and both are averaged over squares four points across: the EPUB draws its page
    /// three times as sharp, so edges and the paper's grain come out a little different pixel by pixel.
    static func ebookParity(_ book: BookViewController, page picture: CGImage, left: Bool) -> (mean: Double, off: Double)? {
        let view = book.bookView
        guard let window = view.window, let shot = windowPicture(window) else { return nil }
        let scale = CGFloat(shot.width) / window.frame.width
        let corner = view.viewPoint(.zero, onLeft: left)
        let across = view.viewPoint(CGPoint(x: BookLayout.pageSize.width, y: BookLayout.pageSize.height), onLeft: left)
        let inWindow = view.convert(CGRect(x: min(corner.x, across.x), y: min(corner.y, across.y), width: abs(across.x - corner.x),
                                           height: abs(across.y - corner.y)), to: nil)
        // The page in the window's picture, in its pixels from the top left, and the part of it compared.
        let page = CGRect(x: inWindow.minX * scale, y: (window.frame.height - inWindow.maxY) * scale, width: inWindow.width * scale,
                          height: inWindow.height * scale)
        let crop = page.insetBy(dx: 4 * scale, dy: 4 * scale).integral
        guard let screen = shot.cropping(to: crop) else { return nil }
        let width = screen.width, height = screen.height
        // Where the page lies in that part, from its bottom left.
        let placed = CGRect(x: page.minX - crop.minX, y: crop.maxY - page.maxY, width: page.width, height: page.height)
        let block = Int((4 * scale).rounded())
        let a = blocks(sRGBPixels(screen, width: width, height: height), width: width, height: height, block: block)
        let b = blocks(sRGBPixels(picture, width: width, height: height, in: placed), width: width, height: height, block: block)
        return difference(a, b, count: a.count / 4)
    }

    /// Pixels averaged over square blocks `block` pixels on a side, whole blocks only.
    static func blocks(_ pixels: [UInt8], width: Int, height: Int, block: Int) -> [UInt8] {
        let across = width / block, down = height / block
        var averaged = [UInt8](repeating: 0, count: across * down * 4)
        for row in 0..<down {
            for column in 0..<across {
                var sums = [0, 0, 0, 0]
                for y in (row * block)..<((row + 1) * block) {
                    for x in (column * block)..<((column + 1) * block) {
                        for channel in 0..<4 { sums[channel] += Int(pixels[(y * width + x) * 4 + channel]) }
                    }
                }
                for channel in 0..<4 { averaged[(row * across + column) * 4 + channel] = UInt8(sums[channel] / (block * block)) }
            }
        }
        return averaged
    }

    /// Photo books: opening one, turning pages by click, key and drag, picking, moving and turning photos, the
    /// paper and frames, leaving photos out, videos on the page, the viewer, PDF, EPUB and printing.
    static func bookSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        var book: BookViewController { window.book }
        var view: BookView { window.book.bookView }
        var albumID: UUID?
        var settings: BookSettings { library.catalog.book(albumID!) }
        var windowFrame: NSRect?

        // A little after the window updates, the toolbar checks the items that check themselves, which once turned on
        // every button with an action.
        func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
            window.window?.toolbar?.items.first { $0.itemIdentifier == identifier }
        }
        var bookButton: NSToolbarItem? { (toolbarItem(ToolbarController.mode) as? NSToolbarItemGroup)?.subitems.last }
        var heart: NSToolbarItem? { toolbarItem(ToolbarController.favorite) }
        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
            window.grid.select([])
            window.window?.update()
            wait(upTo: 1) { bookButton?.isEnabled != false || heart?.isEnabled != false }
        }
        step {
            check(bookButton?.label == "Book" && bookButton?.isEnabled == false, "the toolbar's Book button is off outside an album")
            check(heart?.isEnabled == false, "and the heart, with nothing chosen")
            if let first = window.content.allIDs.first { window.grid.select([first]) }
            check(heart?.isEnabled == true, "which comes on for a chosen photo")
            if let album = library.catalog.albums.first {
                window.go(to: .album(album.id))
                check(bookButton?.isEnabled == true, "Book is on in an album")
            }
            window.go(to: .allAlbums)
            window.window?.update()
            wait(upTo: 1) { bookButton?.isEnabled != false }
        }
        step {
            check(bookButton?.isEnabled == false, "and off again among the album covers")
        }

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
        }

        // MARK: Bindings
        // The color of a page's picture at a point on the page (a cover's picture is its whole board, the page within).
        func color(ofPage page: Int, at point: CGPoint) -> [CGFloat] {
            guard let image = book.pageImage(page) else { return [] }
            let kind = book.layout.pages[page].kind
            let area = kind == .cover || kind == .back ? BookRenderer.board(front: kind == .cover) : CGRect(origin: .zero, size: BookLayout.pageSize)
            let x = Int((point.x - area.minX) / area.width * CGFloat(image.width))
            let y = Int((point.y - area.minY) / area.height * CGFloat(image.height))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return pixel.prefix(3).map { CGFloat($0) / 255 }
        }
        // How light a cover is so far in from its spine, halfway down: the front's spine is on its left, the back's on its right.
        func light(ofCover page: Int, inFromSpine x: CGFloat) -> CGFloat {
            let at = page == 0 ? x : BookLayout.pageSize.width - x
            return color(ofPage: page, at: CGPoint(x: at, y: BookLayout.pageSize.height * 0.5)).reduce(0, +)
        }
        var glued: [CGFloat] = []
        // How far the rings strayed from the holes they go through, at most, through a turn, and how often they were seen.
        var ringsStrayed: CGFloat = 0, ringsSeen = 0
        step {
            guard let right = book.layout.state(view.state).right else { return }
            let hole = CGPoint(x: BookBinding.holeInset, y: BookLayout.pageSize.height * 0.5)
            glued = color(ofPage: right, at: hole)
            check(view.ringCountForTesting == 0 && abs(view.pageRect(left: false).minX - view.pageRect(left: true).maxX) < 0.01,
                  "a glued book's pages meet in the middle, with no rings")
            check(view.coverShowsForTesting, "and its cover shows around them")
            // Closed, its cover rounds over the spine into shade, the joint pressed in beside it, on the front cover's
            // left and the back's right.
            let back = book.layout.pages.count - 1
            let spines = [0, back].map { cover in
                (edge: light(ofCover: cover, inFromSpine: 2), joint: light(ofCover: cover, inFromSpine: 31.9),
                 board: light(ofCover: cover, inFromSpine: 60), beside: light(ofCover: cover, inFromSpine: 45))
            }
            check(spines.allSatisfy { $0.edge < $0.board - 0.4 && $0.joint < $0.beside - 0.2 },
                  "closed, a glued book's cover rounds over its spine like a hardback's, the joint pressed in beside it, front and back",
                  "\(spines)")
            check(menuItem("View", "Gold").map { !window.validateMenuItem($0) } == true && settings.rings == .silver,
                  "the rings' metal can't be chosen for a glued book")
            check(choose("View", "3 Rings") && settings.binding == .threeRing && view.ringCountForTesting == 3,
                  "View ▸ Binding ▸ 3 Rings holds the pages on three rings")
            let left = view.pageRect(left: true), rightRect = view.pageRect(left: false)
            check(rightRect.minX - left.maxX > 10 && abs((left.minX + rightRect.maxX) / 2 - view.bounds.midX) < 0.5,
                  "the pages part for the binder's spine, the spread still in the middle")
            let punched = color(ofPage: right, at: hole)
            check(punched.count == 3 && glued.count == 3 && zip(punched, glued).map { abs($0 - $1) }.reduce(0, +) > 0.3,
                  "the pages are punched for the rings", "\(punched) where glued was \(glued)")
            check(choose("View", "Gold") && settings.rings == .gold, "and the rings can be gold")
            check(choose("View", "4 Rings") && view.ringCountForTesting == 4, "or there can be four")
            // Photos are still picked where they're drawn.
            guard let placement = book.layout.pages[right].placements.first else { return }
            let point = view.viewPoint(placement.center, onLeft: false)
            bookMouse(.leftMouseDown, at: point, in: view)
            bookMouse(.leftMouseUp, at: point, in: view)
            let drawn = view.drawnHandlesForTesting
            check(view.selected == placement.id && drawn.knob.map { knob in view.knobForTesting.map { hypot($0.turn.x - knob.x, $0.turn.y - knob.y) < 0.5 } ?? false } == true,
                  "on rings, a photo is picked where it's drawn, its handles where they take hold")
            // A page held partway over: the rings go through its holes, over it from the pages it's leaving, and on
            // under it to the pages it's going to; past upright, the other way about.
            view.holdTurn(at: 0.3)
            let lifting = view.ringsThroughHolesForTesting()
            view.holdTurn(at: 0.7)
            let over = view.ringsThroughHolesForTesting()
            check(lifting.map { $0.miss < 0.5 && $0.overFromLeft } == true && over.map { $0.miss < 0.5 && !$0.overFromLeft } == true,
                  "as a page turns on rings, they go on through its holes, over it from the pages it lifts from and under it to the others",
                  "\(String(describing: lifting)) then \(String(describing: over))")
            view.holdTurn(at: 0.1)
            view.letGoOfTurn(at: 0.1)
            wait { !view.isTurning }
        }
        step {
            check(view.ringsThroughHolesForTesting() == nil && view.ringCountForTesting == 4, "let go early, the page lies back down on the rings")
            // Turned all the way, watched as it goes.
            let state = view.state
            view.next()
            wait(upTo: 4) {
                // Looked at only partway over, as drawn then.
                if let shown = view.shownTurnForTesting, shown > 0.1, shown < 0.9, let through = view.ringsThroughHolesForTesting(presented: true) {
                    ringsStrayed = max(ringsStrayed, through.miss)
                    ringsSeen += 1
                }
                return !view.isTurning && view.state == state + 1
            }
        }
        // A PDF page draws the book as the window shows it: laid over the window, it matches but for a little at the
        // edges (the window stretches pictures of the pages; the PDF draws them sharp), its shadow and all.
        func matches(_ parity: (mean: Double, off: Double, shadow: Double)) -> Bool {
            parity.mean < 2.5 && parity.off < 0.02 && parity.shadow < 3
        }
        func looksAsShown(_ what: String) {
            guard let parity = bookParity(book) else {
                check(false, "a PDF page draws \(what) as the window shows it", "no picture of the window")
                return
            }
            check(matches(parity), "a PDF page draws \(what) as the window shows it",
                  String(format: "%.2f apart, %.2f%% far off, shadow %.2f apart", parity.mean, parity.off * 100, parity.shadow))
        }
        // The window server shows a change a moment after it's made, or longer on a busy Mac: looking too soon saw the
        // pages before it.
        func shown() -> Bool { bookParity(book).map(matches) ?? false }
        step {
            check(ringsSeen >= 4 && ringsStrayed < 1, "the rings keep through the holes all the way over", "\(ringsSeen) looks, \(ringsStrayed) pt off at most")
            check(view.ringCountForTesting == 4, "the pages turn on the rings")
            view.select(nil)
            view.hover(nil)
            view.go(to: 0, animated: false)
            let closed = view.closedCoverForTesting ?? .zero
            check(abs(closed.midX - view.bounds.midX) < 0.5 && view.ringCountForTesting == 0, "closed, the binder sits in the middle, its rings out of sight")
            check(closed.size == view.stage.rightBoard.size && closed.width > view.pageSize.width,
                  "and its cover is a whole board, reaching past the pages as an open board does", "\(closed.size)")
            wait(upTo: 4) { shown() }
        }
        step {
            looksAsShown("a binder closed on its front cover")
            // Opening, the cover is the whole board, its border showing all the way over, and inside it the endpaper
            // with the board's border round it; the spine and rings show from under it as it lifts.
            view.holdTurn(at: 0.02)
            let lifting = view.spineShowsForTesting
            view.holdTurn(at: 0.5)
            let board = view.stage.rightBoard.size, margin = view.stage.boardMargin
            let face = view.turningFaceForTesting
            check(face.map { abs($0.face.width - board.width) < 0.5 && abs($0.face.height - board.height) < 0.5 } == true,
                  "a cover turns as its whole board, its border showing all the way over", "\(String(describing: face?.face)) for a board \(board)")
            check(face?.endpaper.map { abs($0.minX - margin) < 0.5 && abs($0.minY - margin) < 0.5 && abs($0.width - view.pageSize.width) < 0.5 } == true,
                  "and inside it, the endpaper lies on the board, its border round it", "\(String(describing: face?.endpaper))")
            check(lifting < 0.2 && view.spineShowsForTesting == 1, "a binder's spine and rings show from under its cover as it lifts",
                  "\(lifting) as it starts, \(view.spineShowsForTesting) halfway")
            view.letGoOfTurn(at: 0.1)
            wait(upTo: 2) { !view.isTurning }
        }
        step {
            check(view.state == 0 && view.closedCoverForTesting != nil, "let go early, the cover closes again")
            view.go(to: 2, animated: false)
            wait(upTo: 4) { shown() }
        }
        step {
            looksAsShown("a binder open on four gold rings")
            check(choose("View", "Glued") && settings.binding == .glued && abs(view.pageRect(left: false).minX - view.pageRect(left: true).maxX) < 0.01,
                  "Glued puts the pages back together")
            view.go(to: 2, animated: false)
            wait(upTo: 4) { shown() }
        }
        step {
            looksAsShown("a glued book open, its cover around the pages")
            // The PDF: a page for each place in the book, every one the book lying on the desk, the same size and wide
            // like the open book, the closed covers too.
            let data = book.pdfData()
            let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
            check(document?.numberOfPages == book.layout.stateCount, "a book saves as a PDF, a page for each spread",
                  "\(document?.numberOfPages ?? 0) of \(book.layout.stateCount)")
            let full = BookStage.fullSize(for: settings.binding)
            let sizes = (0..<(document?.numberOfPages ?? 0)).compactMap { document?.page(at: $0 + 1)?.getBoxRect(.mediaBox).size }
            check(!sizes.isEmpty && sizes.allSatisfy { $0 == full } && full.width > full.height,
                  "every page of it is the same size and wide, the covers too", "\(sizes.first.map { "\($0)" } ?? "none")")
            // Its page for the open spread, drawn into pixels, is the scene: see-through shading and all, which Quartz
            // once dropped from a PDF's gradients (covers came out grey, sticky notes too).
            if let page = document?.page(at: view.state + 1),
               let scene = book.sceneImageForTesting(view.state, size: full, scale: 1, dark: false),
               let context = CGContext(data: nil, width: scene.width, height: scene.height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.drawPDFPage(page)
                let drawn = context.makeImage().map { sRGBPixels($0, width: scene.width, height: scene.height) } ?? []
                let apart = drawn.isEmpty ? (mean: 255.0, off: 1.0) : difference(drawn, sRGBPixels(scene, width: scene.width, height: scene.height),
                                                                                  count: scene.width * scene.height)
                check(apart.mean < 1.5 && apart.off < 0.005, "and its page for the open spread is that book, see-through shading and all",
                      String(format: "%.2f apart, %.2f%% far off", apart.mean, apart.off * 100))
            } else {
                check(false, "and its page for the open spread is that book", "no page")
            }
            var range = NSRange()
            _ = BookPrintView(controller: book).knowsPageRange(&range)
            check(range.length == book.layout.stateCount, "printing prints every spread")
        }
        // Saved to send: its photos at print size, kept as JPEG data, which a PDF takes as it is (decoded, a photo goes
        // in losslessly, megabytes each).
        let savedPDF = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos self-test book.pdf")
        var saved: Error??
        step {
            try? FileManager.default.removeItem(at: savedPDF)
            book.savePDF(to: savedPDF) { saved = .some($0) }
            wait(upTo: 15) { saved != nil }
        }
        step {
            let photos = Set(book.layout.pages.flatMap { $0.placements.map(\.id) })
            let text = (try? Data(contentsOf: savedPDF)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let jpegs = text.components(separatedBy: "/DCTDecode").count - 1
            check(saved.flatMap { $0 } == nil && !photos.isEmpty && jpegs >= photos.count,
                  "saved, the book's photos go in at print size as JPEG data, small enough to send", "\(jpegs) JPEG pictures for \(photos.count) photos")
            try? FileManager.default.removeItem(at: savedPDF)
        }
        // Saved as an EPUB, for e-book readers: a picture of every page as the window draws it, set out as in the book.
        let savedEPUB = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos self-test book.epub")
        var ebookSaved: Error??
        step {
            try? FileManager.default.removeItem(at: savedEPUB)
            book.saveEPUB(to: savedEPUB) { ebookSaved = .some($0) }
            wait(upTo: 30) { ebookSaved != nil }
        }
        step {
            let files = (try? Data(contentsOf: savedEPUB)).flatMap(ZipArchive.files) ?? []
            check(ebookSaved.flatMap { $0 } == nil && files.first?.path == "mimetype" && files.first?.method == 0 && files.first?.extra.isEmpty == true,
                  "a book saves as an EPUB, saying what it is in its first bytes", "\(files.count) files")
            let pages = book.layout.pages
            let pictures = files.filter { $0.path.hasPrefix("EPUB/images/") }.sorted { $0.path < $1.path }
                .compactMap { CGImageSourceCreateWithData($0.contents as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
            check(pictures.count == pages.count && pictures.allSatisfy { $0.width == 1800 && $0.height == 2340 },
                  "a picture for every page of the book, three pixels to a point and within what e-book readers take",
                  "\(pictures.count) pictures for \(pages.count) pages, the first \(pictures.first.map { "\($0.width) × \($0.height)" } ?? "missing")")
            let package = files.first { $0.path.hasSuffix(".opf") }.map { String(decoding: $0.contents, as: UTF8.self) } ?? ""
            let sides = package.components(separatedBy: "<itemref ").dropFirst()
                .map { $0.components(separatedBy: #"properties=""#).dropFirst().first?.components(separatedBy: "\"").first ?? "" }
            let inBook = pages.indices.map { index in
                index == 0 || index == pages.count - 1 ? "rendition:page-spread-center" : index % 2 == 1 ? "page-spread-left" : "page-spread-right"
            }
            check(sides == inBook, "its covers show alone and each left page beside the right page it faces, as in the book")
            let titlePage = files.first { $0.path == "EPUB/page-003.xhtml" }.map { String(decoding: $0.contents, as: UTF8.self) } ?? ""
            let title = book.album.flatMap { library.catalog.album($0)?.title } ?? "?"
            check(pages[2].kind == .title && titlePage.contains(#"alt="The title page: \#(title)."#),
                  "each page is told in words too, for readers who listen", title)
            // The open pages, laid over the window: the same drawing, but for its photos at print size and a little lost
            // to JPEG.
            let open = book.layout.state(view.state)
            for (index, left) in [(open.left, true), (open.right, false)] {
                guard let index, pictures.indices.contains(index), let parity = ebookParity(book, page: pictures[index], left: left) else {
                    check(false, "an EPUB page is the page as the window shows it", "no picture")
                    continue
                }
                check(parity.mean < 2 && parity.off < 0.005, "an EPUB's \(left ? "left" : "right") page is the page as the window shows it",
                      String(format: "%.2f apart, %.2f%% far off", parity.mean, parity.off * 100))
            }
            try? FileManager.default.removeItem(at: savedEPUB)
            // Saving starts from the pink button over the desk's top right corner: just below the toolbar, clear of the
            // pages.
            let button = book.downloadButtonForTesting
            let buttonFrame = button.convert(button.bounds, to: nil)
            let corner = view.viewPoint(.zero, onLeft: true)
            let across = view.viewPoint(CGPoint(x: BookLayout.pageSize.width, y: BookLayout.pageSize.height), onLeft: false)
            let pagesFrame = view.convert(CGRect(x: min(corner.x, across.x), y: min(corner.y, across.y), width: abs(across.x - corner.x),
                                                 height: abs(across.y - corner.y)), to: nil)
            let bookFrame = book.view.convert(book.view.bounds, to: nil)
            let underToolbar = window.window?.contentLayoutRect.maxY ?? 0
            check(buttonFrame.width > 20 && buttonFrame.maxY <= underToolbar && buttonFrame.maxY > underToolbar - 50
                  && bookFrame.maxX - buttonFrame.maxX < 30 && !buttonFrame.intersects(pagesFrame),
                  "the download button sits in the top right corner, just below the toolbar and clear of the pages",
                  "\(buttonFrame) under a toolbar ending at \(underToolbar), pages at \(pagesFrame)")
            check(button.choices.items.filter { !$0.isSectionHeader }.map(\.title) == ["PDF…", "EPUB…"], "it offers a PDF or an EPUB")
            var pink = false
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                let fill = button.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB)
                let accent = Theme.accent.usingColorSpace(.sRGB)
                if let fill, let accent {
                    pink = abs(fill.redComponent - accent.redComponent) < 0.02 && abs(fill.greenComponent - accent.greenComponent) < 0.02
                        && abs(fill.blueComponent - accent.blueComponent) < 0.02
                }
            }
            check(pink, "and it's pink, the window active or not")
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
