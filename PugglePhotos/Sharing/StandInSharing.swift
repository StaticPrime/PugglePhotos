#if DEBUG
import AppKit
import PugglePhotosKit
import UniformTypeIdentifiers

/// Stands in for iCloud on the sample library, for the self-test and screenshots. Albums shared from here are kept
/// in memory with a link that leads nowhere, everyone invited joins a moment later, and Gran shares an album of her
/// garden with you, its pictures drawn like the sample library's.
final class StandInSharing: SharingBackend {
    static let me = ShareParticipant(id: "me", name: "Alex Morgan", address: "alex@example.com", isOwner: true)
    static let gran = ShareParticipant(id: "gran", name: "Gran", address: "gran@example.com", isOwner: true)
    static let gardenID = UUID(uuidString: "6A8D6F31-2D59-4B0E-9C4A-3A1F0C9E2B71")!

    let store: SharedAlbumsStore
    var onReceive: ((SharedAlbum) -> Void)?
    var onGone: ((UUID) -> Void)?
    var onUpdate: ((SharedAlbum) -> Void)?
    var onStatus: (() -> Void)?
    /// Whether Gran's album comes when sharing starts.
    var delivers = true
    /// Albums of yours as the stand-in "iCloud" holds them.
    private(set) var shared: [UUID: SharedAlbum] = [:]
    /// The photos of each album of yours whose pictures were sent, for the self-test.
    private(set) var sentPictures: [UUID: Set<UUID>] = [:]
    /// How many times albums of yours were sent.
    private(set) var publishes = 0
    private var garden: SharedAlbum?

    init(store: SharedAlbumsStore) { self.store = store }

    var status: SharingStatus { .ready(me: Self.me) }
    var invitesThroughSystem: Bool { false }

    func start() {
        guard delivers else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.granShares(photos: 6) }
    }

    // MARK: Gran's album, shared with you

    /// Gran shares her garden album with `photos` photos in it, or adds that many more to it; their pictures are
    /// written where the store keeps them before the album comes.
    func granShares(photos count: Int) {
        let store = store
        let start = garden?.items.count ?? 0
        let items = (start..<(start + count)).map { index in
            SharedItem(id: UUID(uuidString: String(format: "6A8D6F31-0000-4000-8000-%012d", index))!, kind: .photo,
                       date: Date(timeIntervalSinceReferenceDate: 790_000_000 + Double(index) * 86_400 * 3),
                       pixelWidth: index % 4 == 3 ? 1200 : 1600, pixelHeight: index % 4 == 3 ? 1600 : 1200, fileName: "IMG_\(4100 + index).JPG",
                       caption: index == 0 ? "The first roses" : (index == 2 ? "Tomatoes!" : ""),
                       note: index == 0 ? "Grandpa planted these in 1987." : "", layoutSeed: UInt64(7919 * index + 13))
        }
        Task {
            for item in items {
                let url = store.pictureURL(album: Self.gardenID, item: item)
                _ = await Self.drawGarden(seed: 500 + Int(item.layoutSeed % 97), width: item.pixelWidth, height: item.pixelHeight, to: url)
            }
            var album = garden ?? SharedAlbum(id: Self.gardenID, title: "Gran’s Garden", story: "The roses came back this year, and the tomatoes never stopped.",
                                              created: Date(timeIntervalSinceReferenceDate: 789_000_000), modified: Date(), items: [],
                                              book: BookSettings(paper: .linen, frame: .print, tilt: .playful, perPage: .two, cover: .sage),
                                              owner: Self.gran, participants: [Self.gran, ShareParticipant(id: Self.me.id, name: Self.me.name)],
                                              url: URL(string: "https://share.pugglesoft.invalid/gran-garden"), isMine: false)
            album.items += items
            album.cover = album.cover ?? album.items.first?.id
            album.modified = Date()
            garden = album
            onReceive?(album)
        }
    }

    @concurrent nonisolated private static func drawGarden(seed: Int, width: Int, height: Int, to url: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let image = SampleScene.render(.garden, seed: seed, maxPixels: CGFloat(max(width, height)), aspect: CGFloat(width) / CGFloat(height)),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: Your albums, shared

    func publish(_ album: SharedAlbum, picture: @escaping @MainActor (SharedItem) async -> URL?,
                 completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        publishes += 1
        Task {
            var sent = sentPictures[album.id] ?? []
            for item in album.items where !sent.contains(item.id) {
                guard await picture(item) != nil else {
                    completion(.failure(SharingError.failed("A photo couldn’t be read to send.")))
                    return
                }
                sent.insert(item.id)
            }
            sentPictures[album.id] = sent
            var result = album
            result.url = shared[album.id]?.url ?? URL(string: "https://share.pugglesoft.invalid/\(album.id.uuidString.lowercased())")
            result.participants = shared[album.id]?.participants ?? [Self.me]
            shared[album.id] = result
            completion(.success(result))
        }
    }

    private func change(_ id: UUID, _ completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void,
                        _ change: (inout SharedAlbum) -> Void) {
        guard var album = shared[id] else { return completion(.failure(SharingError.notShared)) }
        change(&album)
        shared[id] = album
        DispatchQueue.main.async { completion(.success(album)) }
    }

    func setAccess(_ access: ShareAccess, of album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        change(album, completion) { $0.access = access }
    }

    /// Someone invited joins a moment later.
    func invite(_ address: String, to album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        let name = address.split(separator: "@").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? address
        let person = ShareParticipant(id: address.lowercased(), name: name, address: address, status: .invited)
        change(album, completion) { shared in
            if !shared.participants.contains(where: { $0.id == person.id }) { shared.participants.append(person) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, var shared = shared[album], let index = shared.participants.firstIndex(where: { $0.id == person.id }) else { return }
            shared.participants[index].status = .joined
            self.shared[album] = shared
            onUpdate?(shared)
        }
    }

    func showInvitation(for album: UUID, relativeTo view: NSView) {}

    func remove(_ participant: ShareParticipant, from album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        change(album, completion) { $0.participants.removeAll { $0.id == participant.id } }
    }

    func stopSharing(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        shared[album] = nil
        sentPictures[album] = nil
        DispatchQueue.main.async { completion(nil) }
    }

    func leave(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        if album == Self.gardenID { garden = nil }
        DispatchQueue.main.async { completion(nil) }
    }
}
#endif
