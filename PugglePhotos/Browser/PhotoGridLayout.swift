import AppKit

/// A grid of square thumbnails in sections, each under a heading that stays pinned to the top while its section
/// scrolls by. Positions are worked out with arithmetic per section, so a library of 100,000 photos lays out as
/// fast as a hundred, and only what's on screen is ever asked for.
final class PhotoGridLayout: NSCollectionViewLayout {
    static let headerKind = "PhotoGridHeader"
    static let bannerKind = "PhotoGridBanner"

    /// The thumbnail size asked for; the real size stretches a little so the columns fill the width.
    var targetSide: CGFloat = Theme.defaultThumbnail { didSet { if targetSide != oldValue { invalidateGeometry() } } }
    var spacing: CGFloat = 4 { didSet { if spacing != oldValue { invalidateGeometry() } } }
    /// Zero for a grid without headings.
    var headerHeight: CGFloat = 46 { didSet { if headerHeight != oldValue { invalidateGeometry() } } }
    /// The album banner above everything, or zero.
    var bannerHeight: CGFloat = 0 { didSet { if bannerHeight != oldValue { invalidateGeometry() } } }
    var sideInset: CGFloat = 16 { didSet { if sideInset != oldValue { invalidateGeometry() } } }
    var sectionGap: CGFloat = 14
    var bottomInset: CGFloat = 24

    private(set) var columns = 1
    private(set) var side: CGFloat = 100
    private var width: CGFloat = 0
    /// For each section: where its heading starts, and where it ends.
    private var sectionTops: [CGFloat] = []
    private var sectionBottoms: [CGFloat] = []
    private var counts: [Int] = []
    private var contentHeight: CGFloat = 0
    private var needsGeometry = true

    private func invalidateGeometry() {
        needsGeometry = true
        invalidateLayout()
    }

    override func invalidateLayout(with context: NSCollectionViewLayoutInvalidationContext) {
        if context.invalidateEverything || context.invalidateDataSourceCounts { needsGeometry = true }
        super.invalidateLayout(with: context)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let newWidth = collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
        guard needsGeometry || newWidth != width else { return }
        needsGeometry = false
        width = newWidth
        let usable = max(width - sideInset * 2, 40)
        columns = max(1, Int((usable + spacing) / (targetSide + spacing)))
        side = max(20, ((usable - CGFloat(columns - 1) * spacing) / CGFloat(columns)).rounded(.down))
        sectionTops.removeAll(keepingCapacity: true)
        sectionBottoms.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
        var y = bannerHeight + (headerHeight == 0 ? 10 : 0)
        for section in 0..<collectionView.numberOfSections {
            let count = collectionView.numberOfItems(inSection: section)
            counts.append(count)
            sectionTops.append(y)
            let rows = (count + columns - 1) / columns
            y += headerHeight + CGFloat(rows) * side + CGFloat(max(rows - 1, 0)) * spacing
            sectionBottoms.append(y)
            y += sectionGap
        }
        contentHeight = y + bottomInset
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: width, height: max(contentHeight, collectionView?.enclosingScrollView?.contentSize.height ?? 0))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        // Scrolling moves the pinned heading; a new width reflows the grid.
        true
    }

    // MARK: Frames

    func frameForItem(at indexPath: IndexPath) -> NSRect {
        let section = indexPath.section, item = indexPath.item
        guard sectionTops.indices.contains(section) else { return .zero }
        let row = item / columns, column = item % columns
        return NSRect(x: sideInset + CGFloat(column) * (side + spacing),
                      y: sectionTops[section] + headerHeight + CGFloat(row) * (side + spacing), width: side, height: side)
    }

    /// The heading's place: at the top of its section, or pinned to the top of the view while the section is
    /// partly scrolled off, pushed up by the next section's heading.
    func frameForHeader(_ section: Int) -> NSRect {
        guard headerHeight > 0, sectionTops.indices.contains(section) else { return .zero }
        var y = sectionTops[section]
        if let visible = collectionView?.visibleRect {
            let pinned = max(y, visible.minY)
            y = min(pinned, sectionBottoms[section] - headerHeight)
            y = max(y, sectionTops[section])
        }
        return NSRect(x: 0, y: y, width: width, height: headerHeight)
    }

    /// The sections that overlap a band of the view.
    private func sections(in rect: NSRect) -> Range<Int> {
        guard !sectionTops.isEmpty else { return 0..<0 }
        var low = 0, high = sectionTops.count
        while low < high {
            let mid = (low + high) / 2
            if sectionBottoms[mid] < rect.minY { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < sectionTops.count, sectionTops[end] <= rect.maxY { end += 1 }
        return low..<end
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        if bannerHeight > 0, rect.minY < bannerHeight,
           let banner = layoutAttributesForSupplementaryView(ofKind: Self.bannerKind, at: IndexPath(item: 0, section: 0)) {
            result.append(banner)
        }
        for section in sections(in: rect) {
            if headerHeight > 0,
               let header = layoutAttributesForSupplementaryView(ofKind: Self.headerKind, at: IndexPath(item: 0, section: section)) {
                result.append(header)
            }
            let top = sectionTops[section] + headerHeight
            let rowHeight = side + spacing
            let firstRow = max(0, Int(((rect.minY - top) / rowHeight).rounded(.down)))
            let lastRow = Int(((rect.maxY - top) / rowHeight).rounded(.down))
            guard lastRow >= firstRow else { continue }
            let first = firstRow * columns
            let last = min(counts[section] - 1, (lastRow + 1) * columns - 1)
            guard first <= last else { continue }
            for item in first...last {
                let indexPath = IndexPath(item: item, section: section)
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
                attributes.frame = frameForItem(at: indexPath)
                result.append(attributes)
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard counts.indices.contains(indexPath.section), indexPath.item < counts[indexPath.section] else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frameForItem(at: indexPath)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                       at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        switch elementKind {
        case Self.headerKind:
            guard headerHeight > 0, sectionTops.indices.contains(indexPath.section) else { return nil }
            attributes.frame = frameForHeader(indexPath.section)
            attributes.zIndex = 10
        case Self.bannerKind:
            guard bannerHeight > 0 else { return nil }
            attributes.frame = NSRect(x: 0, y: 0, width: width, height: bannerHeight)
        case NSCollectionView.elementKindInterItemGapIndicator:
            return layoutAttributesForInterItemGap(before: indexPath)
        default:
            return nil
        }
        return attributes
    }

    // MARK: Dropping between photos

    /// Drops always land between two photos (the gap nearest the pointer), never on one.
    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        guard let indexPath = gapIndexPath(at: pointInCollectionView) else { return nil }
        return layoutAttributesForInterItemGap(before: indexPath)
    }

    /// The gap before the photo at `indexPath` (an item equal to the section's count is the gap after its last).
    func gapIndexPath(at point: NSPoint) -> IndexPath? {
        guard !sectionTops.isEmpty else { return nil }
        let section = sections(in: NSRect(x: 0, y: point.y, width: 1, height: 1)).first ?? (point.y < sectionTops[0] ? 0 : sectionTops.count - 1)
        guard counts.indices.contains(section) else { return nil }
        let count = counts[section]
        let top = sectionTops[section] + headerHeight
        let row = max(0, Int(((point.y - top) / (side + spacing)).rounded(.down)))
        let column = max(0, min(columns, Int(((point.x - sideInset + side / 2 + spacing) / (side + spacing)).rounded(.down))))
        return IndexPath(item: min(count, row * columns + column), section: section)
    }

    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard counts.indices.contains(indexPath.section) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        let count = counts[indexPath.section]
        let item = min(indexPath.item, count)
        let reference: NSRect
        let x: CGFloat
        if count == 0 {
            reference = NSRect(x: sideInset, y: sectionTops[indexPath.section] + headerHeight, width: side, height: side)
            x = reference.minX - 3
        } else if item == count || (item % columns == 0 && item > 0 && indexPath.item == count) {
            reference = frameForItem(at: IndexPath(item: count - 1, section: indexPath.section))
            x = reference.maxX + spacing / 2 - 2
        } else {
            reference = frameForItem(at: IndexPath(item: item, section: indexPath.section))
            x = reference.minX - spacing / 2 - 2
        }
        attributes.frame = NSRect(x: x, y: reference.minY, width: 4, height: reference.height)
        attributes.zIndex = 20
        return attributes
    }
}
