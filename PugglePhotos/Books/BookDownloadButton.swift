import AppKit

/// The pink button over the book's top right corner, for saving the book: clicked, it drops down a menu of what to save
/// it as, a PDF or an EPUB. It's drawn here rather than as a standard button, which turns grey whenever the window
/// isn't the active one; this one stays pink. While the book is being saved, a spinner turns on it instead.
final class BookDownloadButton: NSView {
    static let side: CGFloat = 32

    /// What it offers.
    let choices = NSMenu()
    var onPDF: (() -> Void)?
    var onEPUB: (() -> Void)?

    var isBusy = false {
        didSet {
            arrow.isHidden = isBusy
            spinner.isHidden = !isBusy
            if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            setAccessibilityEnabled(!isBusy)
            needsDisplay = true
        }
    }

    private let arrow = NSImageView()
    private let spinner = NSProgressIndicator()
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        // A soft shadow, so it floats over the desk.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        arrow.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        arrow.contentTintColor = .white
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        // Light, to show on pink.
        spinner.appearance = NSAppearance(named: .darkAqua)
        for view in [arrow, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: centerXAnchor), view.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }

        choices.addItem(NSMenuItem.sectionHeader(title: "Save the Book As"))
        for (title, action) in [("PDF…", #selector(choosePDF(_:))), ("EPUB…", #selector(chooseEPUB(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            choices.addItem(item)
        }

        toolTip = "Save the book as a PDF or an EPUB"
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel("Download")
        setAccessibilityHelp("Save the book as a PDF or an EPUB")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var color = Theme.accent
        if pressed {
            color = color.blended(withFraction: 0.18, of: .black) ?? color
        } else if hovering, !isBusy {
            color = color.blended(withFraction: 0.12, of: .white) ?? color
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { dropDown() }

    override func accessibilityPerformPress() -> Bool {
        dropDown()
        return true
    }

    /// Drops the menu down under the button, its right edge under the button's.
    func dropDown() {
        guard !isBusy else { return }
        pressed = true
        choices.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - choices.size.width, y: -6), in: self)
        pressed = false
        hovering = false
    }

    @objc private func choosePDF(_ sender: Any?) { onPDF?() }
    @objc private func chooseEPUB(_ sender: Any?) { onEPUB?() }
}
