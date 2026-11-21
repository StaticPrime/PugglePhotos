import Foundation

/// How to bring an album in the Photos library in line with the photos wanted in it, in as few changes as can be:
/// which to take out, which to put in, and the moves that put them in order. A photo PugglePhotos doesn't know (one
/// put in the album since the library was last read, or any at all before the library has been read) isn't one it can
/// want gone, so it stays, where it is.
public struct AlbumEditPlan: Equatable, Sendable {
    public struct Move: Equatable, Sendable {
        public var from: Int
        public var to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    /// Where the photos to take out are in the album as it is.
    public var removing: IndexSet
    /// The photos to put in, at the end, in their order.
    public var adding: [String]
    /// Moves, each from one place to another in the album as the moves before it leave it.
    public var moves: [Move]

    public var isEmpty: Bool { removing.isEmpty && adding.isEmpty && moves.isEmpty }

    /// - Parameters:
    ///   - current: the album's photos as it has them, in its order.
    ///   - wanted: the photos it should have, in order.
    ///   - known: the photos the library was read to have.
    ///   - canRearrange: whether the album can be put in order.
    public init(current: [String], wanted: [String], known: Set<String>, canRearrange: Bool) {
        var seen: Set<String> = []
        let wanted = wanted.filter { seen.insert($0).inserted }
        let wantedSet = Set(wanted)
        let currentSet = Set(current)
        removing = IndexSet(current.indices.filter { !wantedSet.contains(current[$0]) && known.contains(current[$0]) })
        adding = wanted.filter { !currentSet.contains($0) }
        moves = []
        guard canRearrange else { return }
        // The album once photos are taken out and put in, then the order wanted: the wanted photos, in their order,
        // in the places wanted photos take, the others staying where they are. A photo the album somehow holds twice
        // keeps its second place.
        var working = current.indices.filter { !removing.contains($0) }.map { current[$0] } + adding
        var next = wanted[...]
        let target = working.map { wantedSet.contains($0) ? next.popFirst() ?? $0 : $0 }
        // Everything before `place` is already where it's wanted.
        for (place, id) in target.enumerated() {
            guard let from = working[place...].firstIndex(of: id), from != place else { continue }
            moves.append(Move(from: from, to: place))
            working.remove(at: from)
            working.insert(id, at: place)
        }
    }

    /// The album's photos once the plan is carried out, for checking a plan.
    public func applied(to current: [String]) -> [String] {
        var album = current.indices.filter { !removing.contains($0) }.map { current[$0] } + adding
        for move in moves {
            let id = album.remove(at: move.from)
            album.insert(id, at: move.to)
        }
        return album
    }
}
