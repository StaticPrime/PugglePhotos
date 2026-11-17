import AppKit
import SwiftUI
import PugglePhotosKit

/// PugglePhotos' colors, taken from its logo: hot pink, teal, sunshine yellow and the pug's tan, with the navy
/// outline for text on light paper. The window chrome uses the system's own colors so Light and Dark Mode both work.
nonisolated enum Theme {
    static let pink = NSColor(srgbRed: 0xE8 / 255, green: 0x2A / 255, blue: 0x7B / 255, alpha: 1)
    static let pinkLight = NSColor(srgbRed: 0xFF / 255, green: 0x4D / 255, blue: 0x93 / 255, alpha: 1)
    static let teal = NSColor(srgbRed: 0x00 / 255, green: 0x9E / 255, blue: 0xA2 / 255, alpha: 1)
    static let sun = NSColor(srgbRed: 0xFE / 255, green: 0xC1 / 255, blue: 0x38 / 255, alpha: 1)
    static let tan = NSColor(srgbRed: 0xFE / 255, green: 0xCB / 255, blue: 0x77 / 255, alpha: 1)
    static let navy = NSColor(srgbRed: 0x05 / 255, green: 0x0D / 255, blue: 0x28 / 255, alpha: 1)

    /// The accent: pink, a little brighter in Dark Mode.
    static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pinkLight : pink
    }

    /// Behind the photos in the grid: the window's own background.
    static let gridBackground = NSColor.textBackgroundColor
    /// Behind a photo in the viewer: nearly black, so photos look their best.
    static let viewerBackground = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    /// The highlight around a section heading or calendar day that photos are being dragged onto.
    static let dropHighlight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? pinkLight.withAlphaComponent(0.28) : pink.withAlphaComponent(0.14)
    }

    /// The square placeholder shown while a thumbnail loads.
    static let placeholder = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.9, alpha: 1)
    }

    /// The paper of the album cover cards.
    static let paper = NSColor(srgbRed: 0.99, green: 0.99, blue: 0.97, alpha: 1)

    /// Thumbnail sizes, in points, for the zoom slider.
    static let minimumThumbnail: CGFloat = 72
    static let maximumThumbnail: CGFloat = 360
    static let defaultThumbnail: CGFloat = 150

    static func color(_ label: LabelColor) -> NSColor {
        let rgb = label.rgb
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension Color {
    static let pugglePink = Color(nsColor: Theme.accent)

    init(_ label: LabelColor) {
        self.init(nsColor: Theme.color(label))
    }
}
