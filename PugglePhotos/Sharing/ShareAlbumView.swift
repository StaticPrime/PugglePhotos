import AppKit
import Observation
import PugglePhotosKit
import SwiftUI

/// What the sharing sheet shows and does: an album of yours (or one about to be made) on its way to being shared, or
/// shared already, with the people in it.
@Observable
final class ShareAlbumModel {
    @ObservationIgnored let sharing: SharingController
    @ObservationIgnored private let library: LibraryController
    /// The album, once there is one; nil while a new shared album is still to be made.
    var albumID: UUID?
    var title: String
    var access: ShareAccess
    var cover: CGImage?
    var isWorking = false
    var problem: String?
    /// How much of the person's iCloud storage the album takes, or will once it's shared; nil until that's known, or
    /// if it can't be.
    var size: Int64?
    /// The photos a new shared album is to be made of, before it's made.
    @ObservationIgnored var pendingItems: [PhotoID] = []
    /// Whom to invite, typed in (where the system doesn't send the invitations).
    var address = ""
    var confirmsStop = false
    @ObservationIgnored var anchor: NSView?
    /// Makes the new album to share, from its name; answers with it.
    @ObservationIgnored var makeAlbum: ((String) -> UUID?)?
    @ObservationIgnored var done: (() -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Bumped as shared albums change, so what's shown keeps up.
    private var version = 0

    init(sharing: SharingController, library: LibraryController, albumID: UUID?) {
        self.sharing = sharing
        self.library = library
        self.albumID = albumID
        let album = albumID.flatMap { library.catalog.album($0) }
        title = album?.title ?? ""
        access = albumID.flatMap { sharing.mine($0)?.access } ?? .invited
        observer = NotificationCenter.default.addObserver(forName: .sharingDidChange, object: sharing, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.version += 1 }
        }
    }

    var shared: SharedAlbum? {
        _ = version
        return albumID.flatMap { sharing.mine($0) }
    }

    var status: SharingStatus { sharing.status }
    var me: ShareParticipant? { status.me }

    /// Why the album isn't up to date for the people it's shared with, while it isn't.
    var stallReason: String? {
        _ = version
        return albumID.flatMap { sharing.stallReason($0) }
    }

    /// Works out how much room the album takes in iCloud.
    func loadSize() {
        let album = albumID, items = pendingItems
        Task { [weak self] in
            guard let self else { return }
            let size: Int64?
            if let album { size = await sharing.size(of: album) } else { size = await library.originalSize(of: items) }
            self.size = size
        }
    }

    // MARK: Doing it

    /// Shares the album, making it first if it's new; the sheet then shows who it's shared with.
    func share() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if albumID == nil {
            albumID = makeAlbum?(name)
        } else if let id = albumID, library.catalog.album(id)?.title != name {
            library.renameAlbum(id, to: name)
        }
        guard let id = albumID else { return }
        isWorking = true
        problem = nil
        sharing.share(id, access: access) { [weak self] error in
            guard let self else { return }
            isWorking = false
            problem = error?.localizedDescription
        }
    }

    func changeAccess(_ access: ShareAccess) {
        self.access = access
        guard let id = albumID, shared != nil else { return }
        run { self.sharing.setAccess(access, of: id, completion: $0) }
    }

    func invite() {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = albumID, !address.isEmpty else { return }
        self.address = ""
        run { self.sharing.invite(address, to: id, completion: $0) }
    }

    func showInvitation() {
        guard let id = albumID, let anchor else { return }
        sharing.showInvitation(for: id, relativeTo: anchor)
    }

    func remove(_ person: ShareParticipant) {
        guard let id = albumID else { return }
        run { self.sharing.remove(person, from: id, completion: $0) }
    }

    func copyLink() {
        guard let id = albumID else { return }
        sharing.copyLink(id)
    }

    func stopSharing() {
        guard let id = albumID else { return }
        run { self.sharing.stopSharing(id, completion: $0) }
    }

    /// Closes the sheet without sharing the album: whatever was sent of it goes back out of iCloud.
    func cancel() {
        if let id = albumID, shared == nil { sharing.abandon(id) }
        done?()
    }

    /// Renames the album as its name is changed here, once it's shared.
    func commitTitle() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = albumID, shared != nil, !name.isEmpty, library.catalog.album(id)?.title != name else { return }
        library.renameAlbum(id, to: name)
    }

    private func run(_ work: (@escaping (Error?) -> Void) -> Void) {
        isWorking = true
        problem = nil
        work { [weak self] error in
            self?.isWorking = false
            self?.problem = error?.localizedDescription
        }
    }
}

/// The sheet for sharing an album, and for seeing and changing who it's shared with.
struct ShareAlbumView: View {
    @Bindable var model: ShareAlbumModel

    var body: some View {
        let shared = model.shared
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Text(shared != nil ? "Manage Shared Album" : (model.albumID == nil ? "New Shared Album" : "Share Album"))
                        .font(.headline)
                    cover
                    TextField("Shared Album Name", text: $model.title)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        .onSubmit { shared == nil ? model.share() : model.commitTitle() }
                    if case let .unavailable(reason) = model.status {
                        Label(reason, systemImage: "exclamationmark.icloud")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let shared {
                        participants(shared)
                    }
                    accessRow
                    Text(accessExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if shared != nil {
                        HStack {
                            Button { model.copyLink() } label: { Label("Copy Link", systemImage: "link") }
                            Spacer()
                            Button("Stop Sharing…", role: .destructive) { model.confirmsStop = true }
                        }
                    }
                    if let problem = model.problem ?? model.stallReason {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                if shared == nil {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Share") { model.share() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking || model.me == nil)
                } else {
                    Button("Done") {
                        model.commitTitle()
                        model.done?()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: shared == nil ? 470 : 600)
        .alert("Stop sharing “\(model.title)”?", isPresented: $model.confirmsStop) {
            Button("Stop Sharing", role: .destructive) { model.stopSharing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes from everyone it’s shared with. The album stays in your library.")
        }
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 120, height: 120)
            .overlay {
                if let image = model.cover {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
    }

    private var accessRow: some View {
        HStack {
            Text("Who Can Access")
            Spacer()
            Picker("Who Can Access", selection: Binding(get: { model.access }, set: { model.changeAccess($0) })) {
                ForEach(ShareAccess.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var accessExplanation: String {
        let storage = SharingSpace.storage(bytes: model.size, shared: model.shared != nil)
        return switch model.access {
        case .invited: "Only people you invite can join, to look through it in PugglePhotos. " + storage
        case .anyoneWithLink: "Anyone with the link can join, to look through it in PugglePhotos. " + storage
        }
    }

    private func participants(_ shared: SharedAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shared.participants.count == 1 ? "1 Participant" : "\(shared.participants.count) Participants")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(shared.participants) { person in
                    participantRow(person, isMe: person.id == model.me?.id)
                    Divider().padding(.leading, 52)
                }
                inviteRow
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private func participantRow(_ person: ShareParticipant, isMe: Bool) -> some View {
        HStack(spacing: 10) {
            Text(person.initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.gray))
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name.isEmpty ? (person.address ?? "Someone") : person.name)
                Text(person.isOwner ? "Owner" : (person.status == .invited ? "Invited" : "Joined"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isMe {
                Text("You").foregroundStyle(.secondary)
            } else if !person.isOwner {
                Button { model.remove(person) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Stop sharing with \(person.name)")
                    .accessibilityLabel("Remove \(person.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var inviteRow: some View {
        if model.sharing.backend.invitesThroughSystem {
            Button { model.showInvitation() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").frame(width: 34, height: 34).background(Circle().fill(Color.primary.opacity(0.08)))
                    Text("Invite Participants")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ShareAnchor { model.anchor = $0 })
        } else {
            HStack(spacing: 10) {
                Image(systemName: "plus").frame(width: 34, height: 34).background(Circle().fill(Color.primary.opacity(0.08)))
                TextField("Invite by email or phone", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.invite() }
                Button("Invite") { model.invite() }
                    .disabled(model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }
}

/// Hands the view behind it to whoever asks, for the system's invitation to show beside.
private struct ShareAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
