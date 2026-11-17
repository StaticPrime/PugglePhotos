import CoreGraphics
import Foundation

/// One step of a slideshow.
public struct Slide: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// The memory's name over its key photo.
        case title(title: String, subtitle: String, photo: PhotoID?)
        case photo(PhotoID)
        /// A video, played for at most `duration` seconds.
        case video(PhotoID)
        /// The last card, which waits for the person.
        case end(title: String)
    }

    public let content: Content
    /// How long it shows, in seconds; zero for the end card, which stays.
    public let duration: TimeInterval

    public init(_ content: Content, duration: TimeInterval) {
        self.content = content
        self.duration = duration
    }

    public var photo: PhotoID? {
        switch content {
        case let .photo(id), let .video(id): id
        case let .title(_, _, photo): photo
        case .end: nil
        }
    }

    /// Whether the progress bar counts it: photos and videos do, the cards don't.
    public var isCounted: Bool {
        switch content {
        case .photo, .video: true
        default: false
        }
    }
}

public enum SlideshowPlan {
    public static let titleDuration: TimeInterval = 3.5
    /// The crossfade between slides.
    public static let transition: TimeInterval = 1.0
    /// The longest a video plays before the slideshow moves on.
    public static let longestVideo: TimeInterval = 15

    /// A title card, every photo and video, and the end card.
    public static func make(_ memory: Memory, items: (PhotoID) -> MediaItem?, secondsPerPhoto: TimeInterval) -> [Slide] {
        var slides = [Slide(.title(title: memory.title, subtitle: memory.subtitle, photo: memory.keyPhoto), duration: titleDuration)]
        for id in memory.items {
            guard let item = items(id) else { continue }
            if item.kind.isVideo {
                let length = item.duration > 0 ? min(item.duration, longestVideo) : longestVideo
                slides.append(Slide(.video(id), duration: max(length, 2)))
            } else {
                slides.append(Slide(.photo(id), duration: max(secondsPerPhoto, 1.5)))
            }
        }
        slides.append(Slide(.end(title: memory.title), duration: 0))
        return slides
    }

    /// How long the whole slideshow runs, up to the end card.
    public static func length(_ slides: [Slide]) -> TimeInterval {
        slides.reduce(0) { $0 + $1.duration }
    }
}

/// The slow pan and zoom across a photo while it's on screen. Rectangles are parts of the photo in unit coordinates
/// (0 to 1 across and down, from the top left).
public struct KenBurns: Hashable, Sendable {
    /// Whether the photo fills the screen (cropped a little), or sits whole over a blurred copy of itself because
    /// its shape is too different from the screen's.
    public let fills: Bool
    public let from: CGRect
    public let to: CGRect

    public init(fills: Bool, from: CGRect, to: CGRect) {
        self.fills = fills
        self.from = from
        self.to = to
    }

    /// The motion for a photo of this shape (width over height) on a screen of that shape. The same seed always
    /// gives the same motion, so a memory plays the same way twice.
    public static func motion(imageAspect: Double, screenAspect: Double, seed: UInt64) -> KenBurns {
        var random = SplitMix(seed: seed)
        let zoomIn = random.next() % 2 == 0
        let zoom = 1.08 + Double(random.next() % 600) / 10_000 // 1.08 to 1.14
        let fills = abs(log(imageAspect / screenAspect)) < log(1.45)
        // The largest part of the photo with the screen's shape (or the whole photo, when it sits whole).
        var width = 1.0, height = 1.0
        if fills {
            if imageAspect > screenAspect { width = screenAspect / imageAspect } else { height = imageAspect / screenAspect }
        }
        func rect(scale: Double, x: Double, y: Double) -> CGRect {
            let w = width / scale, h = height / scale
            // x and y run 0 to 1 across the room there is to move in.
            return CGRect(x: (1 - w) * x, y: (1 - h) * y, width: w, height: h)
        }
        func spot() -> Double { 0.2 + Double(random.next() % 600) / 1000 } // 0.2 to 0.8
        let start = rect(scale: zoomIn ? 1 : (fills ? zoom : 1.05), x: spot(), y: spot())
        let end = rect(scale: zoomIn ? (fills ? zoom : 1.05) : 1, x: spot(), y: spot())
        return KenBurns(fills: fills, from: start, to: end)
    }

    /// A seed from a photo's identifier, the same on every run.
    public static func seed(_ id: PhotoID) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return hash
    }
}

/// A small random number generator that gives the same numbers for the same seed.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
