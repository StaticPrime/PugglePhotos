import AppKit
import MapKit
import PugglePhotosKit
import SwiftUI

/// What an Info window shows of one photo or video, and the changes made in it: its caption, note, labels and
/// favorite (PugglePhotos' own), and when and where it was taken (written to the Photos library). A photo from an
/// album shared with you is shown, not changed.
@Observable
final class InfoModel {
    let id: PhotoID
    @ObservationIgnored let library: LibraryController
    @ObservationIgnored let places: PlaceLookup
    /// Bumped as the library changes, so what's shown keeps up.
    private var version = 0
    /// What the file says, once it's been read.
    private(set) var metadata: PhotoMetadata?
    private(set) var readingFile = true
    /// The place's name, once it's been looked up.
    private(set) var placeName: String?
    @ObservationIgnored private var namedPlace: GeoPoint?
    var caption: String
    var note: String
    /// The fields typed in: only those are saved, so a stale copy never overwrites what was written elsewhere.
    @ObservationIgnored private var edited: Set<String> = []
    var adjustingDate = false
    var pendingDate = Date()
    var choosingPlace = false
    var searchText = ""
    private(set) var results: [FoundPlace] = []
    private(set) var searching = false
    /// Where a click on the map put the pin, before it's set.
    var pendingPlace: GeoPoint?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(id: PhotoID, library: LibraryController, places: PlaceLookup) {
        self.id = id
        self.library = library
        self.places = places
        let details = library.details(id)
        caption = details.caption
        note = details.note
    }

    var item: MediaItem? {
        _ = version
        return library.snapshot.item(id)
    }

    /// Photos shared with you can be looked at, not changed.
    var canChange: Bool { !SharedAlbum.isShared(id) }

    var labels: [PhotoLabel] {
        _ = version
        let applied = library.catalog.details(id).labels
        return library.catalog.labels.filter { applied.contains($0.id) }
    }

    var otherLabels: [PhotoLabel] {
        let applied = Set(labels.map(\.id))
        return library.catalog.labels.filter { !applied.contains($0.id) }
    }

    /// Reads the file and looks up the place.
    func load() {
        Task { [weak self] in
            guard let self else { return }
            let metadata = await library.metadata(id)
            self.metadata = metadata
            readingFile = false
        }
        lookUpPlace()
    }

    func libraryChanged() {
        version += 1
        let details = library.details(id)
        if !edited.contains("caption") { caption = details.caption }
        if !edited.contains("note") { note = details.note }
        lookUpPlace()
    }

    private func lookUpPlace() {
        let place = item?.location
        guard place != namedPlace else { return }
        namedPlace = place
        placeName = nil
        guard let place else { return }
        Task { [weak self] in
            guard let self else { return }
            let name = await places.name(of: place)
            if namedPlace == place { placeName = name }
        }
    }

    // MARK: Changes

    func typed(_ field: String) { edited.insert(field) }

    /// What's typed in a field. A field handing back what it already showed (as one does when it starts or stops
    /// being typed in) hasn't been typed in.
    func type(_ text: String, into keyPath: ReferenceWritableKeyPath<InfoModel, String>, field: String) {
        guard self[keyPath: keyPath] != text else { return }
        self[keyPath: keyPath] = text
        typed(field)
    }

    func saveCaption() {
        guard edited.remove("caption") != nil, canChange else { return }
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != library.details(id).caption else { return }
        library.edit("Caption") { $0.setCaption(text, for: [id]) }
    }

    func saveNote() {
        guard edited.remove("note") != nil, canChange else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != library.details(id).note else { return }
        library.edit("Note") { $0.setNote(text, for: id) }
    }

    func saveAll() {
        saveCaption()
        saveNote()
    }

    func toggleFavorite() {
        guard canChange else { return }
        library.toggleFavorite([id])
    }

    func toggleLabel(_ label: UUID) {
        guard canChange else { return }
        let on = !library.catalog.details(id).labels.contains(label)
        library.edit(on ? "Add Label" : "Remove Label") { $0.setLabel(label, on: [id], on) }
    }

    func startAdjustingDate() {
        pendingDate = item?.date ?? Date()
        adjustingDate = true
    }

    /// Changes when it was taken, in the Photos library.
    func adjustDate() {
        adjustingDate = false
        guard canChange, let item, pendingDate != item.date else { return }
        library.changeDates([Redate.Change(id: id, from: item.date, to: pendingDate)], actionName: "Adjust Date and Time")
    }

    func startChoosingPlace() {
        choosingPlace = true
        pendingPlace = nil
        searchText = ""
        results = []
    }

    func cancelChoosingPlace() {
        choosingPlace = false
        pendingPlace = nil
        searchTask?.cancel()
    }

    /// Looks for places by name, near where it was taken.
    func search() {
        searchTask?.cancel()
        let words = searchText.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        let near = item?.location
        searchTask = Task { [weak self] in
            guard let self else { return }
            let found = await places.search(words, near: near)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    /// Sets where it was taken, in the Photos library; nil says nowhere.
    func setPlace(_ place: GeoPoint?) {
        choosingPlace = false
        pendingPlace = nil
        results = []
        guard canChange, let item else { return }
        library.changePlaces([PlaceChange(id: id, from: item.location, to: place)], actionName: place == nil ? "Remove Place" : "Change Place")
    }
}

/// The Info window's contents: the caption and favorite, the file's name and when it was taken, what the camera says,
/// the note and labels, and where it was taken on a little map.
struct InfoView: View {
    @Bindable var model: InfoModel
    @FocusState private var focused: String?

    var body: some View {
        Group {
            if let item = model.item {
                ScrollView { content(item).padding(14) }
            } else {
                Text("This photo isn’t in the library any longer.").foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 280, idealWidth: 300)
        .onChange(of: focused) { old, _ in
            if old == "caption" { model.saveCaption() }
            if old == "note" { model.saveNote() }
        }
    }

    private func content(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(item)
            camera(item)
            TextField("Add a Note", text: Binding(get: { model.note }, set: { model.type($0, into: \.note, field: "note") }), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused, equals: "note")
                .onSubmit { model.saveNote() }
                .disabled(!model.canChange)
                .accessibilityLabel("Note")
            Divider()
            labels
            Divider()
            place(item)
        }
    }

    private func header(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Add a Caption", text: Binding(get: { model.caption }, set: { model.type($0, into: \.caption, field: "caption") }))
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($focused, equals: "caption")
                    .onSubmit { model.saveCaption() }
                    .disabled(!model.canChange)
                    .accessibilityLabel("Caption")
                Button { model.toggleFavorite() } label: {
                    Image(systemName: item.isFavorite ? "heart.fill" : "heart").foregroundStyle(item.isFavorite ? Color.pugglePink : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!model.canChange)
                .accessibilityLabel(item.isFavorite ? "Unfavorite" : "Favorite")
            }
            if let name = item.fileName {
                Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            HStack {
                Text(model.library.formatting.dateAndTime(item.date))
                Spacer()
                if model.canChange {
                    Button("Adjust") { model.startAdjustingDate() }
                        .buttonStyle(.link)
                        .popover(isPresented: $model.adjustingDate, arrowEdge: .trailing) { dateAdjuster }
                }
            }
            .font(.callout)
        }
    }

    private var dateAdjuster: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adjust Date and Time").font(.headline)
            DatePicker("Taken", selection: $model.pendingDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.stepperField)
            Text("This changes it in your Photos library too.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.adjustingDate = false }.keyboardShortcut(.cancelAction)
                Button("Adjust") { model.adjustDate() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func camera(_ item: MediaItem) -> some View {
        let metadata = model.metadata
        return VStack(alignment: .leading, spacing: 6) {
            if model.readingFile {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the file…").foregroundStyle(.secondary)
                }
            } else {
                Text(metadata?.camera ?? "No camera information")
                Text(metadata?.lens ?? "No lens information").foregroundStyle(.secondary)
            }
            HStack {
                Text(PhotoMetadata.megapixels(width: item.pixelWidth, height: item.pixelHeight))
                Spacer()
                Text(verbatim: "\(item.pixelWidth) × \(item.pixelHeight)")
                Spacer()
                Text(metadata?.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–")
                if let format = metadata?.format, !format.isEmpty {
                    Text(format)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25)))
                }
            }
            .foregroundStyle(.secondary)
            Divider()
            HStack {
                let settings = item.kind.isVideo
                    ? [Formatting.duration(item.duration)] + (metadata?.frameRate.map { ["\(Int($0.rounded())) fps"] } ?? [])
                    : (metadata?.settings.isEmpty == false ? metadata!.settings : ["–", "–", "–", "–", "–"])
                ForEach(Array(settings.enumerated()), id: \.offset) { index, setting in
                    if index > 0 { Spacer() }
                    Text(setting)
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        FlowLayout {
            ForEach(model.labels) { label in
                if model.canChange {
                    LabelChip(label: label) { model.toggleLabel(label.id) }
                } else {
                    Text(label.displayName).font(.system(size: 12, weight: .medium))
                }
            }
            if model.canChange, !model.otherLabels.isEmpty {
                Menu("Add Label") {
                    ForEach(model.otherLabels) { label in Button(label.displayName) { model.toggleLabel(label.id) } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else if model.labels.isEmpty {
                Text("No Labels").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private func place(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let place = item.location {
                Text(model.placeName ?? PlaceName.coordinates(place)).font(.callout).textSelection(.enabled)
                if model.placeName != nil {
                    Text(PlaceName.coordinates(place)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Text(model.choosingPlace ? "Choose a place" : "No Place").font(.callout).foregroundStyle(.secondary)
            }
            if item.location != nil || model.choosingPlace {
                InfoMap(place: model.pendingPlace ?? item.location, choosing: model.choosingPlace) { model.pendingPlace = $0 }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if model.canChange {
                if model.choosingPlace { chooser } else {
                    HStack {
                        Button(item.location == nil ? "Add a Place…" : "Change Place…") { model.startChoosingPlace() }
                        if item.location != nil { Button("Remove Place") { model.setPlace(nil) } }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search for a place", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.search() }
                .task(id: model.searchText) {
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { model.search() }
                }
            if model.searching { ProgressView().controlSize(.small) }
            ForEach(model.results) { found in
                Button { model.setPlace(found.place) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(found.name)
                        if !found.detail.isEmpty { Text(found.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Or click the map to put the pin there.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelChoosingPlace() }
                Button("Set Place") { model.setPlace(model.pendingPlace) }
                    .disabled(model.pendingPlace == nil)
            }
            .controlSize(.small)
        }
    }
}

/// A little map with a pin where the photo was taken. While a place is being chosen, a click on it moves the pin there.
private struct InfoMap: View {
    let place: GeoPoint?
    let choosing: Bool
    let onChoose: (GeoPoint) -> Void
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let place {
                    Marker("", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)).tint(Color.pugglePink)
                }
            }
            .onTapGesture { point in
                guard choosing, let coordinate = proxy.convert(point, from: .local) else { return }
                onChoose(GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
        .onAppear { centre(animated: false) }
        .onChange(of: place) { centre(animated: true) }
        .accessibilityLabel(place.map { "Map of \(PlaceName.coordinates($0))" } ?? "Map")
    }

    private func centre(animated: Bool) {
        guard let place else { return }
        let region = MapCameraPosition.region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                                                 latitudinalMeters: 3000, longitudinalMeters: 3000))
        if animated, !Motion.isReduced { withAnimation { position = region } } else { position = region }
    }
}

/// A window of its own showing one photo's information, beside the library, which changes in it as it changes.
final class InfoWindowController: NSWindowController, NSWindowDelegate {
    let model: InfoModel
    var onClose: (() -> Void)?
    private var observer: NSObjectProtocol?
    /// Info windows hide while PugglePhotos is behind other apps, as panels do; debug runs that can't come to the
    /// front (screenshots, the self-test) keep them showing.
    static var keepsShowingBehind = false

    init(id: PhotoID, library: LibraryController, places: PlaceLookup) {
        model = InfoModel(id: id, library: library, places: places)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Info"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = !Self.keepsShowingBehind
        // Opened while PugglePhotos is behind, a panel isn't put on the Space being looked at.
        if Self.keepsShowingBehind { panel.collectionBehavior.insert(.canJoinAllSpaces) }
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 280, height: 320)
        panel.contentViewController = NSHostingController(rootView: InfoView(model: model))
        panel.setContentSize(NSSize(width: 300, height: 600))
        super.init(window: panel)
        panel.delegate = self
        observer = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
        model.load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A photo that's left the library takes its window with it.
    private func libraryChanged() {
        guard model.library.snapshot.item(model.id) != nil else {
            close()
            return
        }
        model.libraryChanged()
    }

    func windowWillClose(_ notification: Notification) {
        model.saveAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.library.undoManager }
}
