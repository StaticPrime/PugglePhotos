import Foundation

/// How much of someone's iCloud storage an album of theirs takes when it's shared, in words. iCloud doesn't tell apps
/// how much room is left in it, so when an album doesn't fit, what went up before iCloud said it was full is the best
/// measure there is of the room there was.
public enum SharingSpace {
    /// A size as the Finder writes it: "1.2 GB".
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// What the sharing sheet says of where an album's photos and videos are kept, with how much room they take (or,
    /// before it's shared, will take) when that's known.
    public static func storage(bytes: Int64?, shared: Bool) -> String {
        let kept = "Its photos and videos are kept at full size in your iCloud storage"
        guard let bytes else { return kept + "." }
        return kept + (shared ? ", where they take about \(size(bytes))." : ", where they’ll take about \(size(bytes)).")
    }

    /// Why an album couldn't be shared: iCloud filled up partway, and what had gone up was taken out again. `needed` is
    /// the whole album and `fit` what went up before iCloud filled; either is nil when it isn't known.
    public static func full(title: String, needed: Int64?, fit: Int64?) -> String {
        let start = "Your iCloud storage is full, so “\(title)” couldn’t be shared."
        let end = ", or choose more storage in System Settings, then share it again. Nothing of it was left in your iCloud storage."
        guard let needed else { return start + " Free up some space" + end }
        guard let fit, fit > 0 else { return start + " It needs about \(size(needed)). Free up that much" + end }
        guard needed > fit else { return start + " It needs about \(size(needed)), a little more than there was room for. Free up some space" + end }
        return start + " It needs about \(size(needed)), and only about \(size(fit)) fit. Free up about \(size(needed - fit)) more" + end
    }

    /// Why what's new in an album already shared didn't reach the people it's shared with: iCloud is full. `remaining`
    /// is what's still to go, nil when that isn't known.
    public static func fullUpdating(remaining: Int64?) -> String {
        let what = remaining.map { " The photos and videos still to go need about \(size($0))." } ?? ""
        return "Your iCloud storage is full." + what
            + " Free up some space, or choose more storage in System Settings, and they’ll go when PugglePhotos next comes to the front."
    }
}
