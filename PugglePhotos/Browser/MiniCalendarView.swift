import AppKit
import PugglePhotosKit

/// The calendar at the bottom of the sidebar. Days with photos are tinted, more strongly the more there are.
/// Click a day to go to it; drop photos on a day to move them there. While dragging, hover over the arrows to turn
/// the month.
final class MiniCalendarView: NSView {
    private(set) var year: Int
    private(set) var month: Int
    var counts: [CivilDay: Int] = [:] { didSet { needsDisplay = true } }
    var today: CivilDay { didSet { needsDisplay = true } }
    var selectedDay: CivilDay? { didSet { needsDisplay = true } }
    var firstWeekday = Calendar.current.firstWeekday { didSet { needsDisplay = true } }
    var formatting = Formatting()

    var onSelectDay: ((CivilDay) -> Void)?
    var onDrop: ((_ ids: [PhotoID], _ day: CivilDay, _ rect: NSRect) -> Bool)?
    /// Years that have photos, for the month menu.
    var years: [Int] = []

    private var dropDay: CivilDay? { didSet { needsDisplay = true } }
    private var springTimer: Timer?
    private var springDirection = 0

    static let height: CGFloat = 222
    private let headerHeight: CGFloat = 30
    private let weekdayHeight: CGFloat = 20
    private let sideInset: CGFloat = 10

    init(today: CivilDay) {
        self.today = today
        year = today.year
        month = today.month
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: Self.height))
        registerForDraggedTypes([.photoID])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Calendar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var grid: MonthGrid { MonthGrid(year: year, month: month, firstWeekday: firstWeekday) }

    func show(year: Int, month: Int) {
        self.year = year
        self.month = month
        needsDisplay = true
        setAccessibilityValue(formatting.monthTitle(year: year, month: month))
    }

    func show(_ day: CivilDay) { show(year: day.year, month: day.month) }

    func turn(_ offset: Int) {
        let next = MonthGrid.month(year, month, offset: offset)
        show(year: next.year, month: next.month)
    }

    // MARK: Geometry

    private var cellWidth: CGFloat { (bounds.width - sideInset * 2) / 7 }
    private var cellHeight: CGFloat { (bounds.height - headerHeight - weekdayHeight - 8) / 6 }

    private var previousRect: NSRect { NSRect(x: bounds.width - 62, y: 4, width: 24, height: 22) }
    private var nextRect: NSRect { NSRect(x: bounds.width - 34, y: 4, width: 24, height: 22) }
    private var titleRect: NSRect { NSRect(x: sideInset + 2, y: 4, width: bounds.width - 84, height: 22) }

    func rect(for day: CivilDay) -> NSRect? {
        guard let index = grid.days.firstIndex(of: day) else { return nil }
        return NSRect(x: sideInset + CGFloat(index % 7) * cellWidth, y: headerHeight + weekdayHeight + CGFloat(index / 7) * cellHeight,
                      width: cellWidth, height: cellHeight)
    }

    private func day(at point: NSPoint) -> CivilDay? {
        let top = headerHeight + weekdayHeight
        guard point.y >= top, point.x >= sideInset, point.x < bounds.width - sideInset else { return nil }
        let column = Int((point.x - sideInset) / cellWidth), row = Int((point.y - top) / cellHeight)
        guard (0..<7).contains(column), (0..<6).contains(row) else { return nil }
        return grid.days[row * 7 + column]
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let title = formatting.monthTitle(year: year, month: month)
        (title as NSString).draw(at: NSPoint(x: titleRect.minX, y: titleRect.minY + 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        drawArrow("chevron.left", in: previousRect, active: springDirection < 0)
        drawArrow("chevron.right", in: nextRect, active: springDirection > 0)

        let symbols = formatting.calendar.veryShortStandaloneWeekdaySymbols
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        for column in 0..<7 {
            let symbol = symbols[(firstWeekday - 1 + column) % 7]
            (symbol as NSString).draw(in: NSRect(x: sideInset + CGFloat(column) * cellWidth, y: headerHeight + 2, width: cellWidth, height: 16),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                       .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: centered])
        }

        let grid = grid
        let maxCount = max(1, counts.values.max() ?? 1)
        for (index, day) in grid.days.enumerated() {
            let cell = NSRect(x: sideInset + CGFloat(index % 7) * cellWidth, y: headerHeight + weekdayHeight + CGFloat(index / 7) * cellHeight,
                              width: cellWidth, height: cellHeight)
            let side = min(cell.width, cell.height) - 3
            let circle = NSRect(x: cell.midX - side / 2, y: cell.midY - side / 2, width: side, height: side)
            let inMonth = grid.contains(day)
            let count = counts[day] ?? 0
            var textColor: NSColor = inMonth ? .labelColor : .tertiaryLabelColor
            if day == dropDay {
                Theme.accent.setFill()
                NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: -2)).fill()
                textColor = .white
            } else if day == selectedDay {
                Theme.accent.setFill()
                NSBezierPath(ovalIn: circle).fill()
                textColor = .white
            } else if count > 0 {
                let strength = 0.14 + 0.36 * log(Double(count) + 1) / log(Double(maxCount) + 1)
                Theme.accent.withAlphaComponent(inMonth ? strength : strength * 0.4).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            if day == today, day != selectedDay, day != dropDay {
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                Theme.accent.setStroke()
                ring.stroke()
            }
            let weight: NSFont.Weight = day == today || count > 0 ? .semibold : .regular
            let text = "\(day.day)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight),
                                                             .foregroundColor: textColor, .paragraphStyle: centered]
            let height = text.size(withAttributes: attributes).height
            text.draw(in: NSRect(x: cell.minX, y: cell.midY - height / 2, width: cell.width, height: height), withAttributes: attributes)
        }
    }

    private func drawArrow(_ symbol: String, in rect: NSRect, active: Bool) {
        if active {
            Theme.dropHighlight.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?.tinted(active ? Theme.accent : .secondaryLabelColor) else { return }
        image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }

    // MARK: Clicking

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if previousRect.contains(point) {
            turn(-1)
        } else if nextRect.contains(point) {
            turn(1)
        } else if titleRect.contains(point) {
            monthMenu().popUp(positioning: nil, at: NSPoint(x: titleRect.minX, y: titleRect.maxY + 4), in: self)
        } else if let day = day(at: point) {
            selectedDay = day
            if !grid.contains(day) { show(day) }
            onSelectDay?(day)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), event.phase == .began || event.phase == [] else { return }
        if event.scrollingDeltaY != 0 { turn(event.scrollingDeltaY > 0 ? -1 : 1) }
    }

    /// Years with photos, each with its months, plus Today.
    private func monthMenu() -> NSMenu {
        let menu = NSMenu()
        let todayItem = NSMenuItem(title: "Today", action: #selector(goToToday(_:)), keyEquivalent: "")
        todayItem.target = self
        menu.addItem(todayItem)
        menu.addItem(.separator())
        let names = formatting.monthNames
        var allYears = Set(years)
        allYears.insert(today.year)
        for year in allYears.sorted(by: >) {
            let yearItem = NSMenuItem(title: formatting.yearTitle(year), action: nil, keyEquivalent: "")
            let months = NSMenu()
            for month in 1...12 {
                let item = NSMenuItem(title: names[month - 1].full, action: #selector(goToMonth(_:)), keyEquivalent: "")
                item.target = self
                item.tag = year * 100 + month
                item.state = year == self.year && month == self.month ? .on : .off
                let hasPhotos = counts.keys.contains { $0.year == year && $0.month == month }
                if hasPhotos {
                    item.attributedTitle = NSAttributedString(string: names[month - 1].full,
                                                              attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
                }
                months.addItem(item)
            }
            yearItem.submenu = months
            menu.addItem(yearItem)
        }
        return menu
    }

    @objc private func goToToday(_ sender: Any?) {
        show(today)
        selectedDay = today
        onSelectDay?(today)
    }

    @objc private func goToMonth(_ sender: NSMenuItem) {
        show(year: sender.tag / 100, month: sender.tag % 100)
    }

    // MARK: Dropping photos on a day

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !PhotoDrag.ids(from: sender.draggingPasteboard).isEmpty else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let direction = previousRect.insetBy(dx: -4, dy: -4).contains(point) ? -1 : (nextRect.insetBy(dx: -4, dy: -4).contains(point) ? 1 : 0)
        if direction != springDirection {
            springDirection = direction
            springTimer?.invalidate()
            springTimer = nil
            if direction != 0 {
                springTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.springDirection != 0 else { return }
                        self.turn(self.springDirection)
                    }
                }
            }
            needsDisplay = true
        }
        dropDay = day(at: point)
        return dropDay == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDrag() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let ids = PhotoDrag.ids(from: sender.draggingPasteboard)
        let target = day(at: point)
        endDrag()
        guard let target, !ids.isEmpty, let rect = rect(for: target) else { return false }
        return onDrop?(ids, target, rect) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { endDrag() }

    private func endDrag() {
        springTimer?.invalidate()
        springTimer = nil
        springDirection = 0
        dropDay = nil
        needsDisplay = true
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
