import CoreGraphics
import PugglePhotosKit

/// Where a photo book lies on the desk, in a space `size` points big, from the top left: its pages, the binder's spine
/// between them, the open cover's boards around them, the rings over them and its shadow under it. The window and a
/// PDF page work it out the same way, so the book looks the same in both.
struct BookStage {
    var size: CGSize
    var binding: BookBinding

    /// The room left around the book, for its boards and its shadow.
    static let inset = CGSize(width: 62, height: 52)
    /// How round a page's outer corners are.
    static let pageCornerRadius: CGFloat = 4

    /// The size of the stage that shows pages exactly their size in the book (600 × 780): a PDF page.
    static func fullSize(for binding: BookBinding) -> CGSize {
        CGSize(width: BookLayout.pageSize.width * (2 + binding.spineShare) + inset.width * 2, height: BookLayout.pageSize.height + inset.height * 2)
    }

    /// The size of one page: two pages side by side, and a binder's spine between them, fit the room.
    var pageSize: CGSize {
        let room = CGRect(origin: .zero, size: size).insetBy(dx: Self.inset.width, dy: Self.inset.height)
        let height = max(80, min(room.height, room.width / (2 + binding.spineShare) * BookLayout.pageSize.height / BookLayout.pageSize.width))
        return CGSize(width: height * BookLayout.pageSize.width / BookLayout.pageSize.height, height: height)
    }

    /// How wide a binder's spine shows between the open pages; glued pages meet.
    var spineGap: CGFloat { pageSize.width * binding.spineShare }

    /// The middle of the binding, which the pages turn about.
    var spine: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    /// Points on the stage for each unit of a page.
    var unit: CGFloat { pageSize.width / BookLayout.pageSize.width }

    func pageRect(left: Bool) -> CGRect {
        let page = pageSize
        let half = spineGap / 2
        return CGRect(x: left ? spine.x - half - page.width : spine.x + half, y: spine.y - page.height / 2, width: page.width, height: page.height)
    }

    /// How far the book slides sideways so a closed cover sits in the middle: the front cover lies where the right
    /// board does, the back cover where the left one does.
    func offset(state: Int, stateCount: Int) -> CGFloat {
        let closed = (rightBoard.width + spineGap) / 2
        if state == 0 { return -closed }
        if state == stateCount - 1 { return closed }
        return 0
    }

    // MARK: The open cover

    /// How far the boards reach past the pages, as a share of a page's width.
    static let boardShare: CGFloat = 0.028

    /// How far the boards reach past the pages: at the top, the bottom and the outer edge.
    var boardMargin: CGFloat { pageSize.width * Self.boardShare }

    var leftBoard: CGRect {
        let page = pageRect(left: true), margin = boardMargin
        return CGRect(x: page.minX - margin, y: page.minY - margin, width: page.width + margin, height: page.height + margin * 2)
    }

    var rightBoard: CGRect {
        let page = pageRect(left: false), margin = boardMargin
        return CGRect(x: page.minX, y: page.minY - margin, width: page.width + margin, height: page.height + margin * 2)
    }

    /// How round the boards' outer corners are.
    var boardRadius: CGFloat { BinderArt.boardRadius(leftBoard.size) }

    /// A binder's spine, between the boards.
    var spinePanel: CGRect {
        let page = pageRect(left: true), margin = boardMargin
        return CGRect(x: page.maxX, y: page.minY - margin, width: spineGap, height: page.height + margin * 2)
    }

    /// Where the rings cross the spine, down from the top of the spine panel.
    var spineRingHeights: [CGFloat] { binding.ringPositions.map { $0 * pageSize.height + boardMargin } }

    // MARK: The rings

    /// How thick a ring's rod is.
    var ringThickness: CGFloat { BookBinding.holeRadius * 1.5 * unit }

    /// How far each page's holes are in from its edge along the spine.
    var holeReach: CGFloat { BookBinding.holeInset * unit }

    /// How far the holes are from the middle of the binding.
    var ringReach: CGFloat { spineGap / 2 + holeReach }

    /// The rings' picture: from the left page's holes over to the right page's, with room for their shadows. Its middle
    /// is the middle of the binding.
    var ringBox: CGRect {
        let page = pageRect(left: true), thickness = ringThickness
        return CGRect(x: page.maxX - holeReach - thickness * 2, y: page.minY - thickness * 2,
                      width: spineGap + (holeReach + thickness * 2) * 2, height: page.height + thickness * 4)
    }

    /// Where the rings are, down from the top of the rings' picture.
    var ringHeights: [CGFloat] { binding.ringPositions.map { $0 * pageSize.height + ringThickness * 2 } }

    // MARK: The book's shadow

    /// What casts the book's shadow: the open boards, or the closed cover, a whole board itself (the right one in front,
    /// the left at the back), with the same corners.
    func shadow(open: Bool, closedOnLeft: Bool) -> (rect: CGRect, radius: CGFloat) {
        (open ? leftBoard.union(rightBoard) : (closedOnLeft ? leftBoard : rightBoard), boardRadius)
    }

    static let shadowOpacity: Float = 0.45
    static let shadowRadius: CGFloat = 22
    /// Down the page, in points.
    static let shadowDrop: CGFloat = 10
}
