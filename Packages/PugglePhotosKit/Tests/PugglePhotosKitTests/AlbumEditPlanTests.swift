import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct AlbumEditPlanTests {
    @Test func anAlbumComesToHaveThePhotosWantedInTheirOrder() {
        let current = ["a", "b", "c", "d"]
        let plan = AlbumEditPlan(current: current, wanted: ["d", "a", "e"], known: Set(current + ["e"]), canRearrange: true)
        #expect(plan.removing == IndexSet([1, 2]) && plan.adding == ["e"])
        #expect(plan.applied(to: current) == ["d", "a", "e"])
    }

    @Test func beforeTheLibraryHasBeenReadNoPhotoComesOut() {
        // An album renamed as PugglePhotos opens, before it has read the library: it knows no photos yet.
        let current = ["a", "b", "c"]
        let plan = AlbumEditPlan(current: current, wanted: [], known: [], canRearrange: true)
        #expect(plan.isEmpty && plan.applied(to: current) == current)
    }

    @Test func aPhotoPutInSinceTheLibraryWasReadStaysWhereItIs() {
        let current = ["a", "new", "b", "c"]
        let plan = AlbumEditPlan(current: current, wanted: ["c", "a"], known: ["a", "b", "c"], canRearrange: true)
        #expect(plan.applied(to: current) == ["c", "new", "a"], "b out, c and a in the order wanted, the new one kept in its place")
    }

    @Test func eachPhotoOnceAndNothingToDoWhenItsSoAlready() {
        let current = ["a", "b"]
        #expect(AlbumEditPlan(current: current, wanted: ["a", "b"], known: Set(current), canRearrange: true).isEmpty)
        #expect(AlbumEditPlan(current: current, wanted: ["b", "a", "b"], known: Set(current), canRearrange: true).applied(to: current) == ["b", "a"])
    }

    @Test func anAlbumHoldingAPhotoTwiceIsStillPlanned() {
        let current = ["a", "b", "a"]
        let plan = AlbumEditPlan(current: current, wanted: ["b", "a"], known: ["a", "b"], canRearrange: true)
        #expect(plan.applied(to: current) == ["b", "a", "a"])
        #expect(AlbumEditPlan(current: current, wanted: ["b"], known: ["a", "b"], canRearrange: true).applied(to: current) == ["b"])
    }

    @Test func anAlbumThatCantBeRearrangedOnlyGainsAndLoses() {
        let current = ["a", "b", "c"]
        let plan = AlbumEditPlan(current: current, wanted: ["c", "a", "d"], known: Set(current), canRearrange: false)
        #expect(plan.moves.isEmpty && plan.applied(to: current) == ["a", "c", "d"])
    }

    @Test func everyOrderComesOutAsWanted() {
        func orders(_ items: [String]) -> [[String]] {
            items.count <= 1 ? [items] : items.indices.flatMap { index -> [[String]] in
                var rest = items
                let first = rest.remove(at: index)
                return orders(rest).map { [first] + $0 }
            }
        }
        // Every order of four photos to every order of three of them and one more, the one left out taken out.
        for current in orders(["a", "b", "c", "d"]) {
            for wanted in orders(["a", "b", "c", "e"]) {
                let plan = AlbumEditPlan(current: current, wanted: wanted, known: ["a", "b", "c", "d"], canRearrange: true)
                #expect(plan.applied(to: current) == wanted)
            }
        }
        // And with a photo it doesn't know, which keeps its place among the others.
        for current in orders(["a", "b", "x"]) {
            let plan = AlbumEditPlan(current: current, wanted: ["b", "a"], known: ["a", "b"], canRearrange: true)
            let after = plan.applied(to: current)
            #expect(after.filter { $0 != "x" } == ["b", "a"] && after.firstIndex(of: "x") == current.firstIndex(of: "x"))
        }
    }
}
