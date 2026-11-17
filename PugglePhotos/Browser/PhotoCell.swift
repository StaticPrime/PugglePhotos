import AppKit
import PugglePhotosKit

/// What a thumbnail shows besides the picture.
struct CellBadges: Equatable {
    var isFavorite = false
    var isVideo = false
    var duration: TimeInterval = 0
    var kind: MediaKind = .photo
    var labelColors: [LabelColor] = []
    var hasNote = false
}

/// One thumbnail in the grid: the photo cropped to a square, with small badges for favorites, videos, labels and
/// notes, and a pink ring when selected.
final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCell")

    private(set) var photoID: PhotoID?
    private var request: ImageRequest?
    private var cellView: PhotoCellView { view as! PhotoCellView }

    override func loadView() {
        view = PhotoCellView()
    }

    override var isSelected: Bool {
        didSet { cellView.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { cellView.isHighlighted = highlightState == .forSelection }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        photoID = nil
        cellView.image = nil
    }

    /// Shows a photo: `title` is its tooltip, `spoken` what VoiceOver says for it.
    func configure(_ id: PhotoID, badges: CellBadges, title: String, spoken: String, thumbnails: ThumbnailCache, side: CGFloat,
                   scale: CGFloat) {
        let pixels = side * scale
        cellView.setAccessibilityLabel(spoken)
        if photoID == id, cellView.image != nil {
            cellView.badges = badges
            return
        }
        request?.cancel()
        photoID = id
        cellView.badges = badges
        cellView.toolTip = title.isEmpty ? nil : title
        if let cached = thumbnails.cached(id, pixels: pixels) {
            cellView.image = cached
            return
        }
        cellView.image = nil
        request = thumbnails.request(id, pixels: pixels) { [weak self] image in
            guard let self, photoID == id else { return }
            cellView.image = image
        }
    }
}

final class PhotoCellView: NSView {
    private let imageLayer = CALayer()
    private let selectionLayer = CALayer()
    private let shadeLayer = CAGradientLayer()
    private let favoriteView = NSImageView()
    private let durationField = NSTextField(labelWithString: "")
    private let kindView = NSImageView()
    private let labelStack = NSStackView()
    private let noteView = NSImageView()

    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = image
            imageLayer.backgroundColor = image == nil ? Theme.placeholder.cgColor : nil
            CATransaction.commit()
        }
    }

    var badges = CellBadges() { didSet { if badges != oldValue { updateBadges() } } }
    var isSelected = false { didSet { updateSelection() } }
    var isHighlighted = false { didSet { updateSelection() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 4
        imageLayer.backgroundColor = Theme.placeholder.cgColor
        layer?.addSublayer(imageLayer)
        shadeLayer.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.45).cgColor]
        shadeLayer.cornerRadius = 4
        shadeLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        shadeLayer.isHidden = true
        layer?.addSublayer(shadeLayer)
        selectionLayer.borderWidth = 3
        selectionLayer.cornerRadius = 6
        selectionLayer.isHidden = true
        layer?.addSublayer(selectionLayer)

        favoriteView.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite")
        favoriteView.contentTintColor = .white
        favoriteView.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        durationField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationField.textColor = .white
        kindView.contentTintColor = .white
        kindView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        noteView.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Has a note")
        noteView.contentTintColor = .white
        noteView.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        labelStack.orientation = .horizontal
        labelStack.spacing = 3
        for view in [favoriteView, durationField, kindView, noteView, labelStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.shadow = {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 3
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                return shadow
            }()
            addSubview(view)
        }
        labelStack.shadow = nil
        NSLayoutConstraint.activate([
            favoriteView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            favoriteView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            durationField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            durationField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            kindView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            kindView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            noteView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            noteView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            labelStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            labelStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        ])
        updateBadges()
        setAccessibilityRole(.image)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        selectionLayer.frame = bounds.insetBy(dx: -3, dy: -3)
        let shadeHeight = min(34, bounds.height * 0.4)
        shadeLayer.frame = NSRect(x: 0, y: bounds.height - shadeHeight, width: bounds.width, height: shadeHeight)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.borderColor = Theme.accent.cgColor
            if image == nil { imageLayer.backgroundColor = Theme.placeholder.cgColor }
        }
    }

    private func updateSelection() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.borderColor = Theme.accent.cgColor
        }
        selectionLayer.isHidden = !(isSelected || isHighlighted)
        imageLayer.opacity = isHighlighted && !isSelected ? 0.85 : 1
        setAccessibilitySelected(isSelected)
    }

    private func updateBadges() {
        favoriteView.isHidden = !badges.isFavorite
        durationField.isHidden = !badges.isVideo
        durationField.stringValue = Formatting.duration(badges.duration)
        let symbol: String? = switch badges.kind {
        case .livePhoto: "livephoto"
        case .panorama: "pano"
        default: nil
        }
        kindView.isHidden = symbol == nil || badges.isVideo
        kindView.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: badges.kind.displayName) }
        noteView.isHidden = !badges.hasNote
        shadeLayer.isHidden = !(badges.isFavorite || badges.isVideo || symbol != nil)
        labelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for color in badges.labelColors.prefix(4) {
            let dot = LabelDot(color: Theme.color(color))
            labelStack.addArrangedSubview(dot)
        }
        labelStack.isHidden = badges.labelColors.isEmpty
    }
}

/// A small colored dot with a white ring, for a label on a thumbnail.
final class LabelDot: NSView {
    private let color: NSColor

    init(color: NSColor, size: CGFloat = 10) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
    }
}
