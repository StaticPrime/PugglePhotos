#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// The filmstrip under the viewer.
    static func filmstripSteps(_ app: AppDelegate, window: LibraryWindowController) {
        var strip: FilmstripView { window.viewer.filmstrip }

        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
            let ids = window.viewerSequence
            window.openViewer(ids[10])
            window.window?.layoutIfNeeded()
            check(!strip.isHidden && strip.ids == ids && strip.current == 10, "the viewer has a filmstrip of the photos it steps through")
            check(strip.visibleIDs.contains(ids[10]) && strip.visibleIDs.count < ids.count, "showing the photos around the one open",
                  "\(strip.visibleIDs.count) of \(ids.count)")
            window.viewer.step(1)
            check(strip.current == 11, "stepping moves the ring along")
            strip.onChoose?(ids[14])
            check(window.state.viewerID == ids[14] && strip.current == 14, "clicking a thumbnail opens that photo")
            check(choose("View", "Hide Filmstrip") && strip.isHidden && !window.state.showsFilmstrip, "View ▸ Hide Filmstrip")
            check(choose("View", "Hide Filmstrip") && !strip.isHidden && window.state.showsFilmstrip, "and Show Filmstrip")
            window.closeViewer()
        }
    }
}
#endif
