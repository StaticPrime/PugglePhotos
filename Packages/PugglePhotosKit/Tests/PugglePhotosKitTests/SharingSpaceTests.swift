import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct SharingSpaceTests {
    let gigabyte: Int64 = 1_200_000_000
    let some: Int64 = 300_000_000

    @Test func theSheetSaysHowMuchRoomAnAlbumTakesWhenThatsKnown() {
        let size = SharingSpace.size(gigabyte)
        #expect(SharingSpace.storage(bytes: gigabyte, shared: false)
                == "Its photos and videos are kept at full size in your iCloud storage, where they’ll take about \(size).")
        #expect(SharingSpace.storage(bytes: gigabyte, shared: true)
                == "Its photos and videos are kept at full size in your iCloud storage, where they take about \(size).")
        #expect(SharingSpace.storage(bytes: nil, shared: false) == "Its photos and videos are kept at full size in your iCloud storage.")
        #expect(SharingSpace.size(gigabyte) == ByteCountFormatter.string(fromByteCount: gigabyte, countStyle: .file))
    }

    @Test func anAlbumThatDidntFitSaysHowMuchMoreRoomItNeeds() {
        let full = SharingSpace.full(title: "Lake Days", needed: gigabyte, fit: some)
        #expect(full.hasPrefix("Your iCloud storage is full, so “Lake Days” couldn’t be shared."))
        #expect(full.contains("It needs about \(SharingSpace.size(gigabyte)), and only about \(SharingSpace.size(some)) fit."))
        #expect(full.contains("Free up about \(SharingSpace.size(gigabyte - some)) more, or choose more storage in System Settings"))
        #expect(full.hasSuffix("Nothing of it was left in your iCloud storage."))
    }

    @Test func whatIsntKnownIsLeftUnsaid() {
        let nothingFit = SharingSpace.full(title: "Lake Days", needed: gigabyte, fit: 0)
        #expect(nothingFit.contains("It needs about \(SharingSpace.size(gigabyte)). Free up that much, or choose more storage"))
        #expect(SharingSpace.full(title: "Lake Days", needed: gigabyte, fit: nil) == nothingFit)
        let unknown = SharingSpace.full(title: "Lake Days", needed: nil, fit: some)
        #expect(unknown.contains("couldn’t be shared. Free up some space, or choose more storage"))
        #expect(!unknown.contains("about"))
        let almost = SharingSpace.full(title: "Lake Days", needed: some, fit: some)
        #expect(almost.contains("a little more than there was room for. Free up some space"))
    }

    @Test func anAlbumAlreadySharedSaysWhatsStillToGo() {
        let remaining = SharingSpace.fullUpdating(remaining: some)
        #expect(remaining.hasPrefix("Your iCloud storage is full. The photos and videos still to go need about \(SharingSpace.size(some))."))
        #expect(remaining.hasSuffix("they’ll go when PugglePhotos next comes to the front."))
        #expect(SharingSpace.fullUpdating(remaining: nil).hasPrefix("Your iCloud storage is full. Free up some space"))
    }
}
