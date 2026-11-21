import AppKit
import MapKit
import PugglePhotosKit

/// What the map asks of the window it's in.
protocol MapViewDelegate: AnyObject {
    var library: LibraryController { get }
    /// Opens the viewer on a photo, to go on through `photos` from there.
    func mapOpen(_ id: PhotoID, among photos: [PhotoID])
}

/// The photos and videos that say where they were taken, on a map: each one small, where it was taken, and those close
/// together at the scale the map's shown at gathered under one, with how many there are. Clicking a cluster zooms in
/// on it; clicking a photo, or photos all taken in one spot, opens it, to go through the photos in view.
final class MapViewController: NSViewController, MKMapViewDelegate {
    weak var delegate: MapViewDelegate?
    let mapView = MKMapView()
    /// Clusters at least this far apart, in points.
    static let spacing: CGFloat = 78

    /// The photos on the map, oldest first.
    private(set) var photos: [MapPhoto] = []
    private var places: [PhotoID: GeoPoint] = [:]
    /// The clusters on the map, by name.
    private(set) var shown: [String: PhotoAnnotation] = [:]
    /// The side of the squares photos are gathered by, at the scale the map's shown at.
    private(set) var cell: Double = 0
    /// The search the map was last fitted to; nil before it's shown anything.
    private var fittedSearch: String?
    private var needsFit = false

    override func loadView() {
        mapView.delegate = self
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.register(PhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoAnnotationView.identifier)
        view = mapView
    }

    /// Shows these photos, those that say where they were taken. The map is zoomed to show them all the first time,
    /// and when the search changes what's shown; otherwise it stays where it was left.
    func show(_ ids: [PhotoID], search: String) {
        guard let library = delegate?.library else { return }
        var photos: [MapPhoto] = []
        var places: [PhotoID: GeoPoint] = [:]
        for id in ids {
            // A place that isn't one on Earth isn't shown.
            guard let item = library.snapshot.item(id), let place = item.location, MapPoint(place).isOnMap else { continue }
            photos.append(MapPhoto(id: id, point: MapPoint(place), isFavorite: item.isFavorite))
            places[id] = place
        }
        self.photos = photos
        self.places = places
        if fittedSearch != search {
            fittedSearch = search
            needsFit = true
        }
        fitIfReady()
        recluster()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitIfReady()
    }

    /// Zooms the map out to show every photo, once it has a size to fit them in.
    private func fitIfReady() {
        guard needsFit, mapView.bounds.width > 0, mapView.bounds.height > 0, var rect = MapRect(around: photos.map(\.point)) else { return }
        needsFit = false
        // Photos all in one town still show the town around them.
        let least = 0.000_2
        if rect.width < least || rect.height < least {
            let middle = MapPoint(x: (rect.minX + rect.maxX) / 2, y: (rect.minY + rect.maxY) / 2)
            rect = MapRect(minX: middle.x - least / 2, minY: middle.y - least / 2, maxX: middle.x + least / 2, maxY: middle.y + least / 2)
        }
        let margin = Self.spacing / 2 + 20
        mapView.setVisibleMapRect(Self.mapKitRect(rect), edgePadding: NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin), animated: false)
        recluster()
    }

    /// Gathers the photos in view (and a little around it) into clusters at the map's scale, adding and taking away
    /// only the clusters that changed, so those that didn't stay put.
    private func recluster() {
        let visible = Self.rect(mapView.visibleMapRect)
        guard mapView.bounds.width > 0, visible.width > 0 else { return }
        cell = PhotoMap.cellSize(visibleWidth: visible.width, viewWidth: mapView.bounds.width, spacing: Self.spacing)
        var next: [String: PhotoAnnotation] = [:]
        var adding: [PhotoAnnotation] = []
        for cluster in PhotoMap.clusters(photos, cell: cell, in: visible.outset(by: cell * 2)) {
            if let existing = shown[cluster.id], existing.cluster == cluster {
                next[cluster.id] = existing
            } else if let place = places[cluster.cover] {
                let annotation = PhotoAnnotation(cluster, at: place)
                next[cluster.id] = annotation
                adding.append(annotation)
            }
        }
        let removing = shown.filter { next[$0.key] !== $0.value }.map(\.value)
        mapView.removeAnnotations(removing)
        mapView.addAnnotations(adding)
        shown = next
    }

    /// What a click on a cluster does: zooms in to part its photos, or, for a photo or photos taken in one spot,
    /// opens it among the photos in view.
    func open(_ cluster: MapCluster) {
        guard cluster.isOnePlace else {
            let margin = Self.spacing + 20
            mapView.setVisibleMapRect(Self.mapKitRect(cluster.bounds), edgePadding: NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin),
                                      animated: !Motion.isReduced)
            return
        }
        let visible = Self.rect(mapView.visibleMapRect)
        let inView = photos.filter { visible.contains($0.point) }.map(\.id)
        delegate?.mapOpen(cluster.cover, among: inView.contains(cluster.cover) ? inView : cluster.photos)
    }

    /// The photos in view, oldest first.
    var photosInView: [PhotoID] {
        let visible = Self.rect(mapView.visibleMapRect)
        return photos.filter { visible.contains($0.point) }.map(\.id)
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        recluster()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let annotation = annotation as? PhotoAnnotation,
              let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoAnnotationView.identifier, for: annotation) as? PhotoAnnotationView
        else { return nil }
        view.show(annotation.cluster, library: delegate?.library)
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let annotation = view.annotation as? PhotoAnnotation else { return }
        mapView.deselectAnnotation(annotation, animated: false)
        open(annotation.cluster)
    }

    // MARK: Between the map's measures and MapKit's

    private static var world: MKMapSize { MKMapSize.world }

    static func rect(_ rect: MKMapRect) -> MapRect {
        MapRect(minX: rect.minX / world.width, minY: rect.minY / world.height, maxX: rect.maxX / world.width, maxY: rect.maxY / world.height)
    }

    static func mapKitRect(_ rect: MapRect) -> MKMapRect {
        MKMapRect(x: rect.minX * world.width, y: rect.minY * world.height, width: rect.width * world.width, height: rect.height * world.height)
    }

    static func mapKitPoint(_ point: MapPoint) -> MKMapPoint { MKMapPoint(x: point.x * world.width, y: point.y * world.height) }
}

/// A cluster of photos on the map, pinned where its cover was taken.
final class PhotoAnnotation: NSObject, MKAnnotation {
    let cluster: MapCluster
    let coordinate: CLLocationCoordinate2D

    init(_ cluster: MapCluster, at place: GeoPoint) {
        self.cluster = cluster
        coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }
}

/// A cluster on the map: its cover small, framed in white, with how many photos there are in a pink badge when there's
/// more than one.
final class PhotoAnnotationView: MKAnnotationView {
    static let identifier = "PhotoAnnotation"
    static let side: CGFloat = 58
    private let picture = CALayer()
    private let badge = CALayer()
    private var request: ImageRequest?
    /// The photo it shows, for the self-test.
    private(set) var cover: PhotoID?
    var hasPicture: Bool { picture.contents != nil }
    private(set) var count = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let side = Self.side
        frame = NSRect(x: 0, y: 0, width: side + 16, height: side + 16)
        wantsLayer = true
        layer?.masksToBounds = false
        picture.frame = CGRect(x: 8, y: 8, width: side, height: side)
        picture.cornerRadius = 9
        picture.masksToBounds = true
        picture.borderWidth = 2.5
        picture.borderColor = NSColor.white.cgColor
        picture.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        picture.contentsGravity = .resizeAspectFill
        let shadow = CALayer()
        shadow.frame = picture.frame
        shadow.cornerRadius = picture.cornerRadius
        shadow.backgroundColor = NSColor.white.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.35
        shadow.shadowRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1.5)
        layer?.addSublayer(shadow)
        layer?.addSublayer(picture)
        layer?.addSublayer(badge)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        picture.contents = nil
        cover = nil
    }

    func show(_ cluster: MapCluster, library: LibraryController?) {
        request?.cancel()
        picture.contents = nil
        cover = cluster.cover
        count = cluster.photos.count
        showBadge(count > 1 ? (library?.formatting.number(count) ?? "\(count)") : nil)
        guard let library else { return }
        let cover = cluster.cover
        request = library.thumbnails.request(cover, pixels: Self.side * 2) { [weak self] image in
            guard let self, self.cover == cover else { return }
            picture.contents = image
        }
        let first = library.snapshot.item(cluster.photos[0])?.date, last = library.snapshot.item(cluster.photos[count - 1])?.date
        let when = first.flatMap { first in last.flatMap { library.formatting.dateRange(from: first, to: $0) } } ?? ""
        let what = count == 1 ? library.spokenDescription(of: cover) : "\(library.formatting.number(count)) photos and videos"
        toolTip = [what, when].filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityLabel(toolTip)
        setAccessibilityHelp(cluster.isOnePlace ? "Opens it" : "Zooms in on them")
    }

    /// The count in a pink badge at the top right corner, or none.
    private func showBadge(_ text: String?) {
        guard let text else {
            badge.contents = nil
            badge.isHidden = true
            return
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let words = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = CGSize(width: max(20, ceil(words.size().width) + 10), height: 18)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = NSImage(size: size, flipped: false) { rect in
            Theme.pink.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: rect.height / 2 - 0.75, yRadius: rect.height / 2 - 0.75)
            ring.lineWidth = 1.5
            ring.stroke()
            let textSize = words.size()
            words.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        var proposed = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        badge.contents = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        badge.frame = CGRect(x: bounds.width - size.width, y: bounds.height - size.height - 1, width: size.width, height: size.height)
        badge.isHidden = false
    }
}
