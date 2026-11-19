import AppKit
import PugglePhotosKit

/// Whether albums can be shared from this copy of PugglePhotos, and as whom.
enum SharingStatus: Equatable {
    /// Signed in to iCloud: albums are shared as this person.
    case ready(me: ShareParticipant)
    /// Sharing can't be done here, and why, in words for the person.
    case unavailable(String)

    var me: ShareParticipant? {
        if case let .ready(me) = self { return me }
        return nil
    }
}

nonisolated enum SharingError: LocalizedError {
    case unavailable(String)
    case notShared
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case .notShared: "The album isn’t shared any longer."
        case let .failed(reason): reason
        }
    }
}

/// Where shared albums are kept and passed between people: iCloud, or a stand-in for it on the sample library.
/// Every callback arrives on the main thread.
protocol SharingBackend: AnyObject {
    var status: SharingStatus { get }
    /// Whether people are invited through the system's own invitation (Messages, Mail, AirDrop or a link it sends),
    /// rather than by an address typed into PugglePhotos.
    var invitesThroughSystem: Bool { get }
    /// An album shared with you, as it first comes and as it changes, its pictures already where the store keeps them.
    var onReceive: ((SharedAlbum) -> Void)? { get set }
    /// An album no longer shared with you, or one of yours no longer shared.
    var onGone: ((UUID) -> Void)? { get set }
    /// An album of yours, changed there: someone joined, its link.
    var onUpdate: ((SharedAlbum) -> Void)? { get set }
    /// `status` changed: signed in or out of iCloud, say.
    var onStatus: (() -> Void)? { get set }

    /// Starts looking for what's changed, and keeps on.
    func start()
    /// Starts sharing an album of yours, or brings what's shared of it up to date. `picture` gives the original file of
    /// a photo or video new to it, to send. Answers with the album as it's now shared.
    func publish(_ album: SharedAlbum, picture: @escaping @MainActor (SharedItem) async -> URL?,
                 completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void)
    func setAccess(_ access: ShareAccess, of album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void)
    /// Asks someone to join, at an email address or phone number.
    func invite(_ address: String, to album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void)
    /// Shows the system's invitation to an album of yours, by `view`.
    func showInvitation(for album: UUID, relativeTo view: NSView)
    func remove(_ participant: ShareParticipant, from album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void)
    /// Stops sharing an album of yours: it goes from everyone it was shared with.
    func stopSharing(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void)
    /// Leaves an album shared with you.
    func leave(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void)
}

/// Sharing in a copy of PugglePhotos that can't reach iCloud for it: every request is turned down, saying why.
final class UnavailableSharing: SharingBackend {
    let reason: String
    var onReceive: ((SharedAlbum) -> Void)?
    var onGone: ((UUID) -> Void)?
    var onUpdate: ((SharedAlbum) -> Void)?
    var onStatus: (() -> Void)?

    init(reason: String) { self.reason = reason }

    var status: SharingStatus { .unavailable(reason) }
    var invitesThroughSystem: Bool { true }

    func start() {}

    func publish(_ album: SharedAlbum, picture: @escaping @MainActor (SharedItem) async -> URL?,
                 completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        completion(.failure(SharingError.unavailable(reason)))
    }

    func setAccess(_ access: ShareAccess, of album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        completion(.failure(SharingError.unavailable(reason)))
    }

    func invite(_ address: String, to album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        completion(.failure(SharingError.unavailable(reason)))
    }

    func showInvitation(for album: UUID, relativeTo view: NSView) {}

    func remove(_ participant: ShareParticipant, from album: UUID, completion: @escaping @MainActor (Result<SharedAlbum, Error>) -> Void) {
        completion(.failure(SharingError.unavailable(reason)))
    }

    func stopSharing(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) { completion(SharingError.unavailable(reason)) }
    func leave(_ album: UUID, completion: @escaping @MainActor (Error?) -> Void) { completion(SharingError.unavailable(reason)) }
}
