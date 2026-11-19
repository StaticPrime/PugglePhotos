#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// Working ahead: thumbnails got ready around what's showing.
    static func speedSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let source = library.baseSource as! SamplePhotoSource

        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
            window.grid.scrollToStart()
            window.grid.collectionView.layoutSubtreeIfNeeded()
            window.grid.updatePrefetch()
            let showing = Set(window.grid.collectionView.indexPathsForVisibleItems().compactMap(window.content.id(at:)))
            check(!showing.isEmpty && showing.isSubset(of: source.prefetching) && source.prefetching.count > showing.count,
                  "thumbnails beyond the screen are got ready ahead", "\(source.prefetching.count) for \(showing.count) showing")
            window.grid.scrollToEnd()
            window.grid.updatePrefetch()
            check(window.content.allIDs.first.map { !source.prefetching.contains($0) } == true && !source.prefetching.isEmpty,
                  "and let go of once scrolled far past")
            window.setThumbnailSide(window.state.thumbnailSide * 1.25)
            window.grid.collectionView.layoutSubtreeIfNeeded()
            window.grid.updatePrefetch()
            check(!source.prefetching.isEmpty, "a new thumbnail size starts over")
            window.setThumbnailSide(window.state.thumbnailSide / 1.25)
        }
    }
}
#endif
