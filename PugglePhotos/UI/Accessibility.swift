import AppKit
import PugglePhotosKit

/// Whether to keep things still: the Reduce Motion setting in Accessibility (or `-PHReduceMotion YES` in a debug
/// run). Slideshow photos then stay put instead of panning, and book pages fade instead of turning.
enum Motion {
    static var isReduced: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PHReduceMotion") { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension LibraryController {
    /// What VoiceOver says for a photo: what it is, when it was taken, its caption, and whether it's a favorite or
    /// has labels or a note.
    func spokenDescription(of id: PhotoID) -> String {
        guard let item = snapshot.item(id) else { return "Photo" }
        let details = catalog.details(id)
        var parts = [item.kind.isVideo && item.duration > 0 ? "\(item.kind.displayName), \(Formatting.duration(item.duration))"
                                                            : item.kind.displayName,
                     formatting.dateAndTime(item.date)]
        if !details.caption.isEmpty { parts.append(details.caption) }
        if item.isFavorite { parts.append("favorite") }
        let labels = details.labels.compactMap { catalog.label($0)?.name }
        if !labels.isEmpty { parts.append((labels.count == 1 ? "label " : "labels ") + ListFormatter.localizedString(byJoining: labels)) }
        if !details.note.isEmpty { parts.append("has a note") }
        return parts.joined(separator: ", ")
    }
}

/// A part of a drawn view that VoiceOver can find and press: a day in the calendar, a photo in a book. Its name
/// and place are asked for each time, so they stay right as the view changes. VoiceOver asks on the main thread.
nonisolated final class AccessibleSpot: NSAccessibilityElement {
    private weak var view: NSView?
    private let name: @MainActor () -> String
    private let rect: @MainActor () -> NSRect?
    private let press: (@MainActor () -> Void)?

    @MainActor
    init(in view: NSView, role: NSAccessibility.Role, name: @escaping @MainActor () -> String, rect: @escaping @MainActor () -> NSRect?,
         press: (@MainActor () -> Void)? = nil) {
        self.view = view
        self.name = name
        self.rect = rect
        self.press = press
        super.init()
        setAccessibilityRole(role)
        setAccessibilityParent(view)
    }

    override func accessibilityLabel() -> String? {
        let name = self.name
        return MainActor.assumeIsolated { name() }
    }

    override func accessibilityFrame() -> NSRect {
        let view = self.view, rect = self.rect
        return MainActor.assumeIsolated {
            guard let view, let frame = rect() else { return .zero }
            return NSAccessibility.screenRect(fromView: view, rect: frame)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        selector == #selector(accessibilityPerformPress) ? press != nil : super.isAccessibilitySelectorAllowed(selector)
    }
}
