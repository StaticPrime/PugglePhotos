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

    private let background = NSVisualEffectView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let highlight = NSView()

    var section = 0
    var drop: HeaderDrop?
    var onSelect: ((_ section: Int, _ extend: Bool) -> Void)?
    var onDrop: ((_ ids: [PhotoID], _ drop: HeaderDrop, _ header: NSView) -> Bool)?
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
        for field in [titleField, subtitleField, hintField] {
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
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 10),
            subtitleField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: hintField.leadingAnchor, constant: -10),
            hintField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hintField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        registerForDraggedTypes([.photoID])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, subtitle: String, section: Int, drop: HeaderDrop?) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        self.section = section
        self.drop = drop
        hintField.stringValue = drop?.hint ?? ""
        setAccessibilityLabel("\(title), \(subtitle)")
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
        guard drop != nil, !PhotoDrag.ids(from: sender.draggingPasteboard).isEmpty else { return [] }
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

/// The top of an album: its title and its story, both editable where they are, with its dates and size.
final class AlbumBannerView: NSView, NSCollectionViewElement, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("AlbumBanner")

    private let titleField = NSTextField()
    private let subtitleField = NSTextField(labelWithString: "")
    private let noteField = NSTextField()
    var onRename: ((String) -> Void)?
    var onNote: ((String) -> Void)?
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
        for field in [titleField, subtitleField, noteField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
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
