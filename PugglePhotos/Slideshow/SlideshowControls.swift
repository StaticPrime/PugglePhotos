import AppKit

/// What sits over a slideshow: a bar of segments at the top, one per photo or video, filling as each plays; the
/// memory's name; and, when the mouse moves, buttons to go back, pause, go on, quiet the music and close. On the
/// last card, buttons to play it again, see the photos or finish.
final class SlideshowControlsView: NSView {
    weak var controller: SlideshowController?
    private let progress = SlideshowProgressView()
    private let titleField = NSTextField(labelWithString: "")
    private let bar = NSVisualEffectView()
    private let previousButton = SlideshowButton(symbol: "backward.fill", label: "Previous")
    private let pauseButton = SlideshowButton(symbol: "pause.fill", label: "Pause")
    private let nextButton = SlideshowButton(symbol: "forward.fill", label: "Next")
    private let musicButton = SlideshowButton(symbol: "speaker.wave.2.fill", label: "Music")
    private let closeButton = SlideshowButton(symbol: "xmark", label: "Close")
    private let endButtons = NSStackView()
    private var hideTimer: Timer?
    private var tracking: NSTrackingArea?
    private(set) var areControlsShown = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.9)
        titleField.shadow = Self.shadow
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 26
        bar.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [previousButton, pauseButton, nextButton, musicButton, closeButton])
        buttons.spacing = 14
        buttons.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(buttons)
        addSubview(bar)
        previousButton.action = #selector(previous(_:))
        pauseButton.action = #selector(pause(_:))
        nextButton.action = #selector(next(_:))
        musicButton.action = #selector(music(_:))
        closeButton.action = #selector(close(_:))
        for button in [previousButton, pauseButton, nextButton, musicButton, closeButton] { button.target = self }

        let again = SlideshowPillButton(title: "Play Again", symbol: "arrow.counterclockwise")
        again.target = self
        again.action = #selector(playAgain(_:))
        let photos = SlideshowPillButton(title: "Show Photos", symbol: "photo.on.rectangle")
        photos.target = self
        photos.action = #selector(showPhotos(_:))
        let done = SlideshowPillButton(title: "Done", symbol: "checkmark")
        done.target = self
        done.action = #selector(close(_:))
        for view in [again, photos, done] { endButtons.addArrangedSubview(view) }
        endButtons.spacing = 16
        endButtons.isHidden = true
        endButtons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(endButtons)

        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            progress.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            progress.heightAnchor.constraint(equalToConstant: 4),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            titleField.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36),
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: bar.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            endButtons.centerXAnchor.constraint(equalTo: centerXAnchor),
            endButtons.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 90),
        ])
        scheduleHide()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        return shadow
    }()

    func configure(title: String, subtitle: String, segments: Int) {
        titleField.stringValue = subtitle.isEmpty ? title : "\(title) · \(subtitle)"
        progress.segments = segments
    }

    func update(paused: Bool, musicMuted: Bool, atEnd: Bool) {
        pauseButton.setSymbol(paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause")
        musicButton.setSymbol(musicMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: musicMuted ? "Music Off" : "Music On")
        endButtons.isHidden = !atEnd
        bar.isHidden = atEnd
        if paused || atEnd { show() }
    }

    func setProgress(segment: Int, fraction: Double, finished: Bool) {
        progress.current = segment
        progress.fraction = finished ? 1 : fraction
        progress.finished = finished
    }

    // MARK: Showing and hiding

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { show() }

    func show() {
        hideTimer?.invalidate()
        if !areControlsShown {
            areControlsShown = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                bar.animator().alphaValue = 1
                titleField.animator().alphaValue = 1
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func hide() {
        guard let controller, !controller.isPaused, controller.slide.duration > 0 else { return }
        if let window, bar.frame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            scheduleHide()
            return
        }
        areControlsShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            bar.animator().alphaValue = 0
            titleField.animator().alphaValue = 0
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// Clicks that miss the buttons go to the slideshow underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === progress || hit === titleField ? nil : hit
    }

    @objc private func previous(_ sender: Any?) { controller?.previous() }
    @objc private func pause(_ sender: Any?) { controller?.togglePause() }
    @objc private func next(_ sender: Any?) { controller?.next() }
    @objc private func music(_ sender: Any?) { controller?.toggleMusic() }
    @objc private func close(_ sender: Any?) { controller?.close() }
    @objc private func playAgain(_ sender: Any?) { controller?.playAgain() }
    @objc private func showPhotos(_ sender: Any?) { controller?.close(showPhotos: true) }
}

/// The bar of segments at the top: finished ones full, the current one filling, the rest faint. With very many
/// photos it becomes one bar.
final class SlideshowProgressView: NSView {
    var segments = 1 { didSet { needsDisplay = true } }
    var current = 0 { didSet { if current != oldValue { needsDisplay = true } } }
    var fraction = 0.0 { didSet { if abs(fraction - oldValue) > 0.001 { needsDisplay = true } } }
    var finished = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let faint = NSColor.white.withAlphaComponent(0.3), full = NSColor.white.withAlphaComponent(0.95)
        let count = max(segments, 1)
        if count > 60 {
            faint.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
            full.setFill()
            let done = finished ? 1 : (Double(current) + fraction) / Double(count)
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * done, height: bounds.height), xRadius: 2, yRadius: 2).fill()
            return
        }
        let gap: CGFloat = 4
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for segment in 0..<count {
            let rect = NSRect(x: CGFloat(segment) * (width + gap), y: 0, width: width, height: bounds.height)
            faint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            let amount = finished || segment < current ? 1 : (segment == current ? fraction : 0)
            guard amount > 0 else { continue }
            full.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: 0, width: rect.width * amount, height: rect.height), xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// A round white symbol button for the slideshow's bar.
final class SlideshowButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .white
        setSymbol(symbol, label: label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        toolTip = label
        setAccessibilityLabel(label)
    }
}

/// A big rounded button for the end of a slideshow.
final class SlideshowPillButton: NSButton {
    init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .white
        font = .systemFont(ofSize: 16, weight: .semibold)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = 22
        attributedTitle = NSAttributedString(string: "  \(title)", attributes: [.foregroundColor: NSColor.white,
                                                                                .font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
