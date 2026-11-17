import AppKit
import Observation
import PugglePhotosKit
import SwiftUI

/// What the inspector asks the window to do.
protocol InspectorActions: AnyObject {
    func inspectorSetCaption(_ caption: String, for ids: [PhotoID])
    func inspectorSetNote(_ note: String, for id: PhotoID)
    func inspectorToggleLabel(_ label: UUID, on ids: [PhotoID])
    func inspectorNewLabel(for ids: [PhotoID])
    func inspectorToggleFavorite(_ ids: [PhotoID])
    func inspectorAdd(_ ids: [PhotoID], toAlbum album: UUID)
    func inspectorRemove(_ ids: [PhotoID], fromAlbum album: UUID)
    func inspectorNewAlbum(with ids: [PhotoID])
    func inspectorOpenAlbum(_ album: UUID)
    func inspectorChangeDate(_ ids: [PhotoID])
    func inspectorWriteJournal(_ day: CivilDay)
}

/// The selection the inspector describes.
@Observable
final class InspectorModel {
    var ids: [PhotoID] = []
    @ObservationIgnored let library: LibraryController
    @ObservationIgnored weak var actions: InspectorActions?

    init(library: LibraryController) { self.library = library }
}

/// The info panel on the right: a photo's caption, date, favorite, labels, albums, note and details; or, for
/// several photos, what they have in common and what can be done to all of them at once.
struct InspectorView: View {
    @Bindable var model: InspectorModel

    var body: some View {
        Group {
            if model.ids.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a photo to see its caption, notes, labels and albums.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.ids.count == 1, let id = model.ids.first {
                SingleInspector(model: model, id: id).id(id)
            } else {
                MultipleInspector(model: model, ids: model.ids)
            }
        }
        .frame(minWidth: 250, idealWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SingleInspector: View {
    let model: InspectorModel
    let id: PhotoID
    @State private var caption = ""
    @State private var note = ""
    @FocusState private var focus: Field?

    enum Field { case caption, note }

    private var library: LibraryController { model.library }

    var body: some View {
        let item = library.snapshot.item(id)
        let details = library.catalog.details(id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Add a caption", text: $caption, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1...3)
                    .focused($focus, equals: .caption)
                    .onSubmit(commitCaption)
                    .accessibilityLabel("Caption")

                if let item {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "calendar").foregroundStyle(Color.pugglePink).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.formatting.longDay(CivilDay(item.date, in: library.formatting.timeZone)))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(library.formatting.time(item.date)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Change…") { model.actions?.inspectorChangeDate([id]) }
                                    .buttonStyle(.link)
                                    .help("Change the date and time (⇧⌘D)")
                            }
                        }
                    }
                    Button {
                        model.actions?.inspectorToggleFavorite([id])
                    } label: {
                        Label(item.isFavorite ? "Favorite" : "Add to Favorites", systemImage: item.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(item.isFavorite ? Color.pugglePink : .primary)
                    }
                    .buttonStyle(.plain)
                }

                InspectorSection("Labels") {
                    let labels = details.labels.compactMap { library.catalog.label($0) }
                    FlowLayout(spacing: 6) {
                        ForEach(labels) { label in
                            LabelChip(label: label) { model.actions?.inspectorToggleLabel(label.id, on: [id]) }
                        }
                        AddLabelMenu(model: model, ids: [id], applied: Set(details.labels))
                    }
                }

                InspectorSection("Albums") {
                    let albums = library.membership.albums(containing: id).compactMap { library.catalog.album($0) }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(albums) { album in
                            HStack {
                                Button {
                                    model.actions?.inspectorOpenAlbum(album.id)
                                } label: {
                                    Label(album.title, systemImage: "rectangle.stack").lineLimit(1)
                                }
                                .buttonStyle(.link)
                                Spacer()
                                Button {
                                    model.actions?.inspectorRemove([id], fromAlbum: album.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from \(album.title)")
                                .accessibilityLabel("Remove from \(album.title)")
                            }
                        }
                        AddToAlbumMenu(model: model, ids: [id], excluded: Set(albums.map(\.id)))
                    }
                }

                InspectorSection("Note") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $note)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .focused($focus, equals: .note)
                            .frame(minHeight: 90)
                            .accessibilityLabel("Note")
                        if note.isEmpty {
                            Text("Write about this moment…")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                }

                if let item {
                    let day = CivilDay(item.date, in: library.formatting.timeZone)
                    InspectorSection("Journal") {
                        JournalPeek(entry: library.catalog.entry(for: day)) { model.actions?.inspectorWriteJournal(day) }
                    }
                }

                if let item {
                    InspectorSection("Details") {
                        VStack(alignment: .leading, spacing: 4) {
                            DetailRow("Kind", item.kind.isVideo ? "Video, \(Formatting.duration(item.duration))" : item.kind.displayName)
                            DetailRow("Size", "\(item.pixelWidth) × \(item.pixelHeight)")
                            if let name = item.fileName { DetailRow("File", name) }
                            if let added = item.addedDate { DetailRow("Added", library.formatting.mediumDate(added)) }
                            if let location = item.location {
                                DetailRow("Place", String(format: "%.4f, %.4f", location.latitude, location.longitude))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            caption = details.caption
            note = details.note
        }
        .onChange(of: library.catalog.details(id)) { _, new in
            if focus != .caption { caption = new.caption }
            if focus != .note { note = new.note }
        }
        .onChange(of: focus) { old, _ in
            if old == .caption { commitCaption() }
            if old == .note { commitNote() }
        }
        .onDisappear {
            commitCaption()
            commitNote()
        }
    }

    private func commitCaption() {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != library.catalog.details(id).caption { model.actions?.inspectorSetCaption(trimmed, for: [id]) }
    }

    private func commitNote() {
        if note != library.catalog.details(id).note { model.actions?.inspectorSetNote(note, for: id) }
    }
}

private struct MultipleInspector: View {
    let model: InspectorModel
    let ids: [PhotoID]

    var body: some View {
        let library = model.library
        let counts = library.snapshot.counts(of: ids)
        let dates = ids.compactMap { library.snapshot.item($0)?.date }
        let allFavorites = ids.allSatisfy { library.snapshot.item($0)?.isFavorite == true }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.formatting.count(photos: counts.photos, videos: counts.videos))
                        .font(.system(size: 17, weight: .semibold))
                    if let range = library.formatting.dateRange(from: dates.min(), to: dates.max()) {
                        Text(range).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        model.actions?.inspectorToggleFavorite(ids)
                    } label: {
                        Label(allFavorites ? "Unfavorite" : "Favorite", systemImage: allFavorites ? "heart.slash" : "heart")
                    }
                    Button("Change Date…") { model.actions?.inspectorChangeDate(ids) }
                }
                .controlSize(.small)

                InspectorSection("Labels") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(library.catalog.labels) { label in
                            let applied = ids.filter { library.catalog.details($0).labels.contains(label.id) }.count
                            Button {
                                model.actions?.inspectorToggleLabel(label.id, on: ids)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: applied == ids.count ? "checkmark.circle.fill" : (applied > 0 ? "minus.circle.fill" : "circle"))
                                        .foregroundStyle(applied > 0 ? Color(label.color) : .secondary)
                                    Text(label.displayName)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(applied == ids.count ? "On all" : (applied > 0 ? "On some" : "Off"))
                        }
                        Button("New Label…") { model.actions?.inspectorNewLabel(for: ids) }
                            .buttonStyle(.link)
                    }
                }

                InspectorSection("Albums") {
                    VStack(alignment: .leading, spacing: 8) {
                        AddToAlbumMenu(model: model, ids: ids, excluded: [])
                        Button("New Album with These \(ids.count) Items") { model.actions?.inspectorNewAlbum(with: ids) }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(16)
        }
    }
}

/// What the journal says about the photo's day, with a way to write it.
private struct JournalPeek: View {
    let entry: JournalEntry?
    let onWrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let entry {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !entry.mood.isEmpty { Text(entry.mood).accessibilityLabel("Mood \(entry.mood)") }
                    Text(entry.text)
                        .font(.system(size: 13, design: .serif).italic())
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Button(entry == nil ? "Write About This Day…" : "Edit…", action: onWrite)
                .buttonStyle(.link)
                .help("Write in the journal about the day this was taken (⌘J)")
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct DetailRow: View {
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
        .font(.system(size: 12))
    }
}

/// A label on a photo: its color, emoji and name, with an × to take it off.
struct LabelChip: View {
    let label: PhotoLabel
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(label.color)).frame(width: 8, height: 8)
            Text(label.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(label.name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(label.color).opacity(0.16)))
    }
}

private struct AddLabelMenu: View {
    let model: InspectorModel
    let ids: [PhotoID]
    let applied: Set<UUID>

    var body: some View {
        Menu {
            ForEach(model.library.catalog.labels.filter { !applied.contains($0.id) }) { label in
                Button(label.displayName) { model.actions?.inspectorToggleLabel(label.id, on: ids) }
            }
            if !model.library.catalog.labels.isEmpty { Divider() }
            Button("New Label…") { model.actions?.inspectorNewLabel(for: ids) }
        } label: {
            Label("Add Label", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
    }
}

private struct AddToAlbumMenu: View {
    let model: InspectorModel
    let ids: [PhotoID]
    let excluded: Set<UUID>

    var body: some View {
        Menu {
            ForEach(model.library.catalog.albums.filter { !excluded.contains($0.id) }) { album in
                Button(album.title) { model.actions?.inspectorAdd(ids, toAlbum: album.id) }
            }
            if !model.library.catalog.albums.isEmpty { Divider() }
            Button("New Album…") { model.actions?.inspectorNewAlbum(with: ids) }
        } label: {
            Label("Add to Album", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
