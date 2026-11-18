import AppKit
import PugglePhotosKit

extension NSPasteboard.PasteboardType {
    /// Photos dragged inside PugglePhotos: one pasteboard item per photo, holding its ID.
    static let photoID = NSPasteboard.PasteboardType("com.pugglesoft.pugglephotos.photo-id")
}

enum PhotoDrag {
    static func ids(from pasteboard: NSPasteboard) -> [PhotoID] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .photoID) }.map { PhotoID($0) }
    }

    /// Whether a drag carries photos, without reading their IDs: targets ask this every time the pointer moves, and
    /// a whole library selected and dragged holds tens of thousands of them.
    static func holdsPhotos(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.photoID]) != nil
    }

    static func item(_ id: PhotoID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(id.rawValue, forType: .photoID)
        return item
    }
}

/// What dropping photos on a heading does.
enum HeaderDrop: Equatable {
    /// Moves them to this day.
    case day(CivilDay)
    case album(UUID)
    case label(UUID)

    var hint: String {
        switch self {
        case .day: "Drop to move to this day"
        case .album: "Drop to add to this album"
        case .label: "Drop to add this label"
        }
    }
}

/// A section's heading: the day (or album, or label), with how many photos it holds. Click it to select the
/// section's photos; drop photos on it to move them to that day, or add them to that album or label.
final class SectionHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
    static let noteFont = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
    private static let noteLeading: CGFloat = 19, noteTrailing: CGFloat = 60

    /// How much a journal line makes a heading of this width taller: one line, or two for a longer entry.
    static func noteHeight(_ note: String, width: CGFloat) -> CGFloat {
        let line = ceil(noteFont.ascender - noteFont.descender + noteFont.leading)
        // Labels keep two points clear at each end of a line.
        let available = max(width - noteLeading - noteTrailing - 4, 60)
        let height = (note as NSString).boundingRect(with: NSSize(width: available, height: 1000), options: [.usesLineFragmentOrigin],
                                                     attributes: [.font: noteFont]).height
        return (height > line * 1.5 ? 2 : 1) * line + 2
    }

    private let background = NSVisualEffectView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let journalField = NSTextField(wrappingLabelWithString: "")
    let writeButton = NSButton()
    private let highlight = NSView()

    var section = 0
    var drop: HeaderDrop?
    var onSelect: ((_ section: Int, _ extend: Bool) -> Void)?
    var onDrop: ((_ ids: [PhotoID], _ drop: HeaderDrop, _ header: NSView) -> Bool)?
    /// Write in the journal about this heading's day.
    var onWrite: ((_ day: CivilDay, _ button: NSView) -> Void)?
    private var isTargeted = false { didSet { updateHighlight() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        titleField.font = .systemFont(ofSize: 15, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.textColor = .secondaryLabelColor
        hintField.font = .systemFont(ofSize: 12, weight: .semibold)
        hintField.textColor = Theme.accent
        hintField.isHidden = true
        journalField.font = Self.noteFont
        journalField.textColor = .secondaryLabelColor
        journalField.maximumNumberOfLines = 2
        journalField.lineBreakMode = .byWordWrapping
        journalField.cell?.truncatesLastVisibleLine = true
        journalField.isHidden = true
        writeButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Write about this day")
        writeButton.isBordered = false
        writeButton.bezelStyle = .regularSquare
        writeButton.contentTintColor = .secondaryLabelColor
        writeButton.toolTip = "Write about this day in the journal"
        writeButton.target = self
        writeButton.action = #selector(write(_:))
        writeButton.setAccessibilityLabel("Write about this day")
        for field in [titleField, subtitleField, hintField, journalField, writeButton] as [NSView] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            journalField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.noteLeading),
            journalField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.noteTrailing),
            journalField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            writeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            writeButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 10),
            subtitleField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: hintField.leadingAnchor, constant: -10),
            hintField.trailingAnchor.constraint(equalTo: writeButton.leadingAnchor, constant: -14),
            hintField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        registerForDraggedTypes([.photoID])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, subtitle: String, section: Int, drop: HeaderDrop?, journal: String? = nil) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        self.section = section
        self.drop = drop
        hintField.stringValue = drop?.hint ?? ""
        let entry = journal ?? ""
        journalField.stringValue = entry
        journalField.toolTip = entry.isEmpty ? nil : entry
        journalField.isHidden = entry.isEmpty
        if case .day = drop { writeButton.isHidden = false } else { writeButton.isHidden = true }
        writeButton.image = NSImage(systemSymbolName: entry.isEmpty ? "square.and.pencil" : "pencil.line",
                                    accessibilityDescription: entry.isEmpty ? "Write about this day" : "Edit what you wrote")
        setAccessibilityLabel(entry.isEmpty ? "\(title), \(subtitle)" : "\(title), \(subtitle), journal: \(entry)")
    }

    @objc private func write(_ sender: NSButton) {
        if case let .day(day) = drop { onWrite?(day, sender) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isTargeted = false
        drop = nil
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(section, event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard drop != nil, PhotoDrag.holdsPhotos(sender.draggingPasteboard) else { return [] }
        isTargeted = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        drop == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard let drop else { return false }
        let ids = PhotoDrag.ids(from: sender.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        return onDrop?(ids, drop, self) ?? false
    }

    private func updateHighlight() {
        highlight.isHidden = !isTargeted
        hintField.isHidden = !isTargeted
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.layer?.backgroundColor = Theme.dropHighlight.cgColor
            highlight.layer?.borderColor = Theme.accent.cgColor
        }
        highlight.layer?.borderWidth = isTargeted ? 2 : 0
    }
}

/// The line in the gap where photos dragged over the grid will land when dropped between others.
final class DropGapView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("DropGap")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accent.cgColor
    }
}

/// The top of an album: its title and its story, both editable where they are, with its dates and size.
final class AlbumBannerView: NSView, NSCollectionViewElement, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("AlbumBanner")

    private let titleField = NSTextField()
    private let subtitleField = NSTextField(labelWithString: "")
    private let noteField = NSTextField()
    private let playButton = NSButton()
    private let bookButton = NSButton()
    var onRename: ((String) -> Void)?
    var onNote: ((String) -> Void)?
    var onPlay: (() -> Void)?
    var onOpenBook: (() -> Void)?
    private var title = ""
    private var note = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for field in [titleField, noteField] {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.isEditable = true
            field.delegate = self
        }
        titleField.font = .systemFont(ofSize: 28, weight: .bold)
        titleField.placeholderString = "Album Name"
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.setAccessibilityLabel("Album name")
        noteField.font = .systemFont(ofSize: 14)
        noteField.textColor = .secondaryLabelColor
        noteField.placeholderString = "Add a description…"
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        noteField.maximumNumberOfLines = 4
        noteField.lineBreakMode = .byWordWrapping
        noteField.setAccessibilityLabel("Album description")
        subtitleField.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleField.textColor = .secondaryLabelColor
        playButton.title = "Play Slideshow"
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.bezelStyle = .push
        playButton.controlSize = .large
        playButton.bezelColor = Theme.accent
        playButton.target = self
        playButton.action = #selector(play(_:))
        playButton.toolTip = "Play the album as a slideshow (⌥⌘P)"
        bookButton.title = "Open Book"
        bookButton.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        bookButton.imagePosition = .imageLeading
        bookButton.bezelStyle = .push
        bookButton.controlSize = .large
        bookButton.target = self
        bookButton.action = #selector(openBook(_:))
        bookButton.toolTip = "See the album as a photo book (⌘3)"
        for field in [titleField, subtitleField, noteField, playButton, bookButton] as [NSView] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            playButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            bookButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -10),
            bookButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: bookButton.leadingAnchor, constant: -16),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            subtitleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            noteField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            noteField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            noteField.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            noteField.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, subtitle: String, note: String) {
        self.title = title
        self.note = note
        if titleField.currentEditor() == nil { titleField.stringValue = title }
        if noteField.currentEditor() == nil { noteField.stringValue = note }
        subtitleField.stringValue = subtitle
    }

    /// The banner's height for a width: room for the title, the dates and the note.
    static func height(note: String, width: CGFloat) -> CGFloat {
        let text = note.isEmpty ? "Add a description…" : note
        let bounds = (text as NSString).boundingRect(with: NSSize(width: min(width - 36, 720), height: 400),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return 18 + 34 + 2 + 18 + 8 + min(ceil(bounds.height), 76) + 22
    }

    @objc private func play(_ sender: Any?) { onPlay?() }
    @objc private func openBook(_ sender: Any?) { onOpenBook?() }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === titleField {
            let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if new.isEmpty { field.stringValue = title } else if new != title { onRename?(new) }
        } else if field === noteField, field.stringValue != note {
            onNote?(field.stringValue)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSTextField)?.stringValue = control === titleField ? title : note
            window?.makeFirstResponder(nil)
            return true
        }
        // Return in the note starts a new line; Return in the title finishes.
        if control === noteField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }
}
