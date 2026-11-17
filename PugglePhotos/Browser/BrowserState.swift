import AppKit
import PugglePhotosKit

enum ViewMode: String {
    case gallery, list
    /// An album as a photo book.
    case book
}

/// Where a window is and how it shows things: the place in the sidebar, gallery or list, the thumbnail size,
/// the search, the selection, and each place's grouping and sorting (remembered between launches).
final class BrowserState {
    var source: LibrarySource = .library
    var viewMode: ViewMode { didSet { save() } }
    var thumbnailSide: CGFloat { didSet { save() } }
    var albumSort: AlbumSort { didSet { save() } }
    var albumSortAscending: Bool { didSet { save() } }
    var searchText = ""
    var selection: [PhotoID] = []
    /// The photo open in the viewer, if any.
    var viewerID: PhotoID?
    private var arrangements: [String: Arrangement]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        viewMode = ViewMode(rawValue: defaults.string(forKey: "ViewMode") ?? "") ?? .gallery
        let side = defaults.double(forKey: "ThumbnailSize")
        thumbnailSide = side > 0 ? min(max(CGFloat(side), Theme.minimumThumbnail), Theme.maximumThumbnail) : Theme.defaultThumbnail
        albumSort = AlbumSort(rawValue: defaults.string(forKey: "AlbumSort") ?? "") ?? .date
        albumSortAscending = defaults.object(forKey: "AlbumSortAscending") as? Bool ?? false
        if let data = defaults.data(forKey: "Arrangements"),
           let saved = try? JSONDecoder().decode([String: Arrangement].self, from: data) {
            arrangements = saved
        } else {
            arrangements = [:]
        }
    }

    /// One arrangement per kind of place: every album shares one (its own order comes from the album), as does
    /// every label.
    static func key(_ source: LibrarySource) -> String {
        switch source {
        case .memories: "memories"
        case .memory: "memory"
        case .journal: "journal"
        case .library: "library"
        case .favorites: "favorites"
        case .videos: "videos"
        case .recentlyAdded: "recent"
        case .allAlbums: "albums"
        case .album: "album"
        case .label: "label"
        }
    }

    static func defaultArrangement(_ source: LibrarySource) -> Arrangement {
        switch source {
        case .library: Arrangement(grouping: .day, sort: .dateTaken, ascending: true)
        case .recentlyAdded: Arrangement(grouping: .none, sort: .dateAdded, ascending: true)
        case .label: Arrangement(grouping: .month, sort: .dateTaken, ascending: true)
        default: Arrangement(grouping: .none, sort: .dateTaken, ascending: true)
        }
    }

    /// How a place shows its photos. An album's sort is the album's own order.
    func arrangement(for source: LibrarySource, album: Album? = nil) -> Arrangement {
        var arrangement = arrangements[Self.key(source)] ?? Self.defaultArrangement(source)
        if let album {
            arrangement.sort = album.order == .custom ? .custom : .dateTaken
            arrangement.ascending = album.order != .newestFirst
        }
        if arrangement.sort == .custom, !source.hasOwnOrder { arrangement.sort = .dateTaken }
        return arrangement
    }

    func setArrangement(_ arrangement: Arrangement, for source: LibrarySource) {
        arrangements[Self.key(source)] = arrangement
        save()
    }

    private func save() {
        defaults.set(viewMode.rawValue, forKey: "ViewMode")
        defaults.set(Double(thumbnailSide), forKey: "ThumbnailSize")
        defaults.set(albumSort.rawValue, forKey: "AlbumSort")
        defaults.set(albumSortAscending, forKey: "AlbumSortAscending")
        if let data = try? JSONEncoder().encode(arrangements) { defaults.set(data, forKey: "Arrangements") }
    }
}

extension LibrarySource {
    /// Places whose photos have an order of their own, which "Album Order" shows.
    var hasOwnOrder: Bool {
        if case .album = self { return true }
        return false
    }

    var album: UUID? {
        if case let .album(id) = self { return id }
        return nil
    }

    var label: UUID? {
        if case let .label(id) = self { return id }
        return nil
    }

    /// False for the places with a page of their own (Memories, the Journal and the album covers) instead of photos.
    var showsPhotos: Bool {
        switch self {
        case .memories, .journal, .allAlbums: false
        default: true
        }
    }
}
