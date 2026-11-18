import AppKit
import PugglePhotosKit
import UniformTypeIdentifiers

/// Where photos and videos dropped from outside PugglePhotos go: always into the Photos library, and also…
enum FileDropTarget: Equatable {
    /// …nowhere else (dropped on Library, Videos or Recently Added).
    case library
    /// …into Favorites.
    case favorites
    case album(UUID)
    case label(UUID)
    /// …into a new album (dropped on Albums).
    case newAlbum
}

/// Photos and videos dragged in from other apps: as files (or folders of them), or as files an app promises to
/// write out once they're dropped, as some do for attachments and pictures on web pages.
enum FileDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private enum Dragged {
        case file(URL)
        case promise(NSFilePromiseReceiver)
    }

    /// What's being dragged, one thing per dragged item: its file, or the promise of one.
    private static func dragged(_ pasteboard: NSPasteboard) -> [Dragged] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self, NSFilePromiseReceiver.self],
                                             options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { object in
            if let url = object as? URL { return .file(url) }
            if let receiver = object as? NSFilePromiseReceiver { return .promise(receiver) }
            return nil
        }
    }

    private static func promisesMedia(_ receiver: NSFilePromiseReceiver) -> Bool {
        receiver.fileTypes.contains { UTType($0).flatMap(FileImport.kind(of:)) != nil }
    }

    /// How many of the things dragged are photos or videos, or folders with some in them. Photos dragged inside
    /// PugglePhotos don't count: they're already in the library.
    static func importableCount(_ pasteboard: NSPasteboard) -> Int {
        guard !PhotoDrag.holdsPhotos(pasteboard) else { return 0 }
        return dragged(pasteboard).filter { thing in
            switch thing {
            case let .file(url): FileImport.isFolder(url) ? FileImport.folderHasMedia(url) : FileImport.kind(of: url) != nil
            case let .promise(receiver): promisesMedia(receiver)
            }
        }.count
    }

    /// The count for a drag, worked out once however often the drag moves.
    private static var counted: (drag: Int, count: Int)?

    static func importableCount(_ info: NSDraggingInfo) -> Int {
        if let counted, counted.drag == info.draggingSequenceNumber { return counted.count }
        let count = importableCount(info.draggingPasteboard)
        counted = (info.draggingSequenceNumber, count)
        return count
    }

    /// Where promised files are written: a folder for each drop, cleared at the next launch.
    static var droppedFilesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Dropped Files", isDirectory: true)
    }

    static func clearDroppedFiles() {
        try? FileManager.default.removeItem(at: droppedFilesFolder)
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The files dropped: files and folders as they are, and promised files once their app has written them out.
    /// Call it while the drop happens, before the promises go away.
    static func receive(_ pasteboard: NSPasteboard, completion: @escaping @MainActor ([URL]) -> Void) {
        var urls: [URL] = []
        var promises: [NSFilePromiseReceiver] = []
        for thing in dragged(pasteboard) {
            switch thing {
            case let .file(url): urls.append(url)
            case let .promise(receiver): if promisesMedia(receiver) { promises.append(receiver) }
            }
        }
        guard !promises.isEmpty else {
            completion(urls)
            return
        }
        let folder = droppedFilesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let received = LockedValue<[URL]>([])
        let group = DispatchGroup()
        for receiver in promises {
            // One answer for each file it promises.
            let waiting = LockedValue(max(receiver.fileTypes.count, 1))
            for _ in 0..<waiting.value { group.enter() }
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { @Sendable url, error in
                if error == nil { received.update { $0.append(url) } }
                let left = waiting.update { count -> Int in
                    count -= 1
                    return count
                }
                if left >= 0 { group.leave() }
            }
        }
        // An app that never writes its files out doesn't hold up the rest for long.
        let finished = LockedValue(false)
        let files = urls
        let finish: @Sendable () -> Void = {
            guard !finished.update({ done -> Bool in
                defer { done = true }
                return done
            }) else { return }
            let promised = received.value
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(files + promised) } }
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: finish)
    }
}

/// The middle of the window. Photos and videos dragged in from other apps can be dropped anywhere on it: while
/// they're over it, it lights up and says where they'll go.
final class DropZoneView: NSView {
    /// Where files dropped at a point (in this view) would go, and what to call it; nil where they can't go.
    var target: ((NSPoint) -> (target: FileDropTarget, title: String)?)?
    var onDrop: (([URL], FileDropTarget) -> Void)?
    private let highlight = DropHighlightView()

    /// What the light says while it shows, for the self-test.
    var shownTitle: String? { highlight.isHidden ? nil : highlight.title }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(FileDrop.types)
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows something in the middle, under the light.
    func addContent(_ view: NSView) {
        addSubview(view, positioned: .below, relativeTo: highlight)
    }

    #if DEBUG
    /// Lights up as if files were over it, for screenshots.
    func showHighlight(_ title: String) {
        highlight.title = title
        highlight.isHidden = false
    }
    #endif

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let count = FileDrop.importableCount(sender)
        guard count > 0, let found = target?(convert(sender.draggingLocation, from: nil)) else {
            highlight.isHidden = true
            return []
        }
        sender.numberOfValidItemsForDrop = count
        highlight.title = found.title
        highlight.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.isHidden = true }

    override func draggingEnded(_ sender: NSDraggingInfo) { highlight.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        guard FileDrop.importableCount(sender) > 0, let found = target?(convert(sender.draggingLocation, from: nil)) else { return false }
        FileDrop.receive(sender.draggingPasteboard) { [weak self] urls in self?.onDrop?(urls, found.target) }
        return true
    }
}

/// The light around the middle while files are dragged over it, with a label saying where they'll go. It never
/// takes a click or a drag itself.
private final class DropHighlightView: NSView {
    var title = "" {
        didSet { label.stringValue = title }
    }

    private let border = CAShapeLayer()
    private let badge = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        border.lineWidth = 3
        layer?.addSublayer(border)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 15
        badge.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        let row = NSStackView(views: [icon, label])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(row)
        addSubview(badge)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 30),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
            badge.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        setAccessibilityElement(false)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border.strokeColor = Theme.accent.cgColor
            border.fillColor = Theme.accent.withAlphaComponent(0.07).cgColor
            badge.layer?.backgroundColor = Theme.accent.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
