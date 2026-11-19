#if DEBUG
import AppKit
import MapKit
import PugglePhotosKit

extension SelfTest {
    /// The map: every photo and video that says where it was taken, small where it was taken, and none that doesn't;
    /// those together gathered under one, which parts as it's zoomed in on; a click on a cluster zooming in and on a
    /// photo opening it among those in view, and back; and a search narrowing it.
    static func mapSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let map = window.map
        func onMap() -> [PhotoAnnotation] { map.mapView.annotations.compactMap { $0 as? PhotoAnnotation } }
        func views() -> [PhotoAnnotationView] { onMap().compactMap { map.mapView.view(for: $0) as? PhotoAnnotationView } }
        func inView(_ ids: [PhotoID]) -> Bool {
            let visible = MapViewController.rect(map.mapView.visibleMapRect)
            return ids.allSatisfy { id in library.snapshot.item(id)?.location.map { visible.contains(MapPoint($0)) } ?? false }
        }
        var located: [PhotoID] = []
        var width = 0.0
        var target: MapCluster?
        var chosen: PhotoID?
        var sequence: [PhotoID] = []
        var opening: PhotoID?
        var region = MKMapRect.null
        var found: [PhotoID] = []

        step {
            located = library.snapshot.items.filter { $0.location != nil }.map(\.id)
            let outline = window.sidebar.outlineView!
            let sources = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNode)?.source }
            check(sources.firstIndex(of: .map).map { $0 - 1 } == sources.firstIndex(of: .videos), "Map is in the sidebar, just under Videos")
            window.go(to: .map)
            wait(upTo: 5) { !onMap().isEmpty && views().count == onMap().count && views().allSatisfy(\.hasPicture) }
        }
        step {
            let counts = library.snapshot.counts(of: Set(located))
            check(window.window?.title == "Map" && window.window?.subtitle == library.formatting.count(photos: counts.photos, videos: counts.videos)
                  && map.view.window != nil, "Map shows the map, saying how many photos and videos are on it", window.window?.subtitle ?? "")
            let placeless = library.snapshot.items.filter { $0.location == nil }.map(\.id)
            check(Set(map.photos.map(\.id)) == Set(located) && !located.isEmpty, "every photo and video that says where it was taken is on it")
            check(!placeless.isEmpty && Set(map.photos.map(\.id)).isDisjoint(with: placeless), "and those that don't, screenshots and scans, aren't")
            let shown = onMap().flatMap(\.cluster.photos)
            check(shown.count == Set(shown).count && Set(shown) == Set(located), "it opens on all of them, each photo in one place")
            check(onMap().contains { $0.cluster.photos.count > 1 }, "photos taken together are gathered under one")
            check(views().allSatisfy(\.hasPicture), "each shows its cover, small")
            check(views().allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false && $0.toolTip != nil }, "and says what it holds, to VoiceOver and as a tip")
            let toolbar = window.toolbarController!
            let picked = toolbar.modeGroup.map { group in group.subitems.indices.filter { group.isSelected(at: $0) } } ?? [9]
            check(picked.isEmpty && toolbar.zoomSlider?.isEnabled == false && toolbar.arrangeItem?.isEnabled == false,
                  "the toolbar offers no gallery, list, size or arranging there",
                  "view \(picked), size \(toolbar.zoomSlider?.isEnabled == true), arrange \(toolbar.arrangeItem?.isEnabled == true)")
            // A click on the biggest cluster zooms in on it.
            target = onMap().max { $0.cluster.photos.count < $1.cluster.photos.count }?.cluster
            width = map.mapView.visibleMapRect.size.width
            let cell = map.cell
            guard let annotation = onMap().first(where: { $0.cluster == target }) else { return }
            map.mapView.selectAnnotation(annotation, animated: false)
            // Once it has stopped, its photos are gathered afresh at the new scale.
            wait(upTo: 5) { map.mapView.visibleMapRect.size.width < width / 2 && map.cell < cell }
        }
        step {
            guard let target else { return }
            check(map.mapView.visibleMapRect.size.width < width / 2 && inView(target.photos), "clicking a cluster zooms in on it",
                  "\(map.mapView.visibleMapRect.size.width) from \(width)")
            let parts = onMap().filter { !Set($0.cluster.photos).isDisjoint(with: target.photos) }
            check(parts.count > 1 && parts.flatMap(\.cluster.photos).count == target.photos.count, "and its photos part", "\(parts.count) parts")
            // Close in on one photo, until it stands alone.
            chosen = target.photos.first
            guard let chosen, let place = library.snapshot.item(chosen)?.location else { return }
            let point = MapViewController.mapKitPoint(MapPoint(place))
            map.mapView.setVisibleMapRect(MKMapRect(x: point.x - 400, y: point.y - 300, width: 800, height: 600), animated: false)
            wait(upTo: 5) { onMap().contains { $0.cluster.photos.contains(chosen) && $0.cluster.isOnePlace } }
        }
        step {
            guard let chosen, let annotation = onMap().first(where: { $0.cluster.photos.contains(chosen) }) else {
                check(false, "a photo can be closed in on")
                return
            }
            check(annotation.cluster.isOnePlace, "close in, a photo stands alone", "\(annotation.cluster.photos.count) together")
            sequence = map.photosInView
            region = map.mapView.visibleMapRect
            opening = annotation.cluster.cover
            map.mapView.selectAnnotation(annotation, animated: false)
            wait(upTo: 3) { window.state.viewerID != nil }
        }
        step {
            check(window.state.viewerID != nil && window.state.viewerID == opening, "clicking a photo opens it",
                  "\(window.state.viewerID?.rawValue ?? "nothing")")
            check(window.viewerSequence == sequence && !sequence.isEmpty, "to go through the photos in view", "\(window.viewerSequence.count) of \(sequence.count)")
            window.closeViewer()
            wait(upTo: 3) { map.view.window != nil }
        }
        step {
            let now = map.mapView.visibleMapRect
            check(map.view.window != nil && abs(now.minX - region.minX) < 1 && abs(now.size.width - region.size.width) < 1,
                  "closing it goes back to the map, just where it was")
            found = PhotoSearch("lake", formatting: library.formatting).filter(located, using: library.arranger)
            window.search("lake")
            wait(upTo: 3) { Set(map.photos.map(\.id)) == Set(found) }
        }
        step {
            check(!found.isEmpty && found.count < located.count && Set(map.photos.map(\.id)) == Set(found) && inView(found),
                  "a search narrows the map to the photos it finds, and shows them all", "\(map.photos.count) of \(found.count)")
            window.search("")
            window.go(to: .library)
        }
    }
}
#endif
