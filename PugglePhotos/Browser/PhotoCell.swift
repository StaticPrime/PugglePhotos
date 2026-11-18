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
/// notes, and a pink ring when selected. Turned over, it shows the photo's back.
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
        cellView.turnOver(false, back: nil, animated: false)
    }

    var isTurnedOver: Bool { cellView.isTurnedOver }

    /// Whether the photo's picture has arrived.
    var hasPicture: Bool { cellView.image != nil }

    /// Shows the photo's back (drawn by `back`), or its front.
    func turnOver(_ over: Bool, back: CGImage?, animated: Bool) { cellView.turnOver(over, back: back, animated: animated) }

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
    /// The photo's two sides, which turn over together in depth.
    private let stage = CALayer()
    private let card = CATransformLayer()
    private let backLayer = CALayer()
    private(set) var isTurnedOver = false
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
        imageLayer.isDoubleSided = false
        backLayer.masksToBounds = true
        backLayer.cornerRadius = 4
        backLayer.isDoubleSided = false
        backLayer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        card.addSublayer(imageLayer)
        card.addSublayer(backLayer)
        stage.addSublayer(card)
        layer?.addSublayer(stage)
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

    /// The self-test clicks while another app may be in front, so its clicks count even then.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { SelfTestMode.isRunning || super.acceptsFirstMouse(for: event) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(bounds.width * 2.6, 200)
        stage.sublayerTransform = perspective
        for side in [card, imageLayer, backLayer] {
            side.bounds = CGRect(origin: .zero, size: bounds.size)
            side.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
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

    /// Turns the photo over to show its back, or back again: in depth, or with Reduce Motion, a quick fade. The
    /// badges go while the back shows.
    func turnOver(_ over: Bool, back: CGImage?, animated: Bool) {
        if let back {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backLayer.contents = back
            CATransaction.commit()
        }
        guard over != isTurnedOver else { return }
        isTurnedOver = over
        let turned = over ? CATransform3DMakeRotation(.pi, 0, 1, 0) : CATransform3DIdentity
        if animated, !Motion.isReduced {
            let turn = CABasicAnimation(keyPath: "transform")
            turn.fromValue = card.presentation()?.transform ?? card.transform
            turn.toValue = turned
            turn.duration = 0.45
            turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.transform = turned
            CATransaction.commit()
            card.add(turn, forKey: "turn")
        } else {
            if animated {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.25
                stage.add(fade, forKey: "fade")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.transform = turned
            CATransaction.commit()
        }
        updateBadges()
        setAccessibilityValue(over ? "Turned over" : nil)
    }

    private func updateBadges() {
        guard !isTurnedOver else {
            for view in [favoriteView, durationField, kindView, noteView, labelStack] as [NSView] { view.isHidden = true }
            shadeLayer.isHidden = true
            return
        }
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
