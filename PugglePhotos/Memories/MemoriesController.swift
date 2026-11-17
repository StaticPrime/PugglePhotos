import AppKit
import Observation
import PugglePhotosKit

extension Notification.Name {
    /// Posted by `MemoriesController` when the memories change.
    static let memoriesDidChange = Notification.Name("PugglePhotos.memoriesDidChange")
}

/// Settings for memories and slideshows, shared by every window.
enum MemoryPreferences {
    static let notifyKey = "MemoryNotifications"
    /// Minutes after midnight.
    static let timeKey = "MemoryNotificationTime"
    static let secondsPerPhotoKey = "SlideshowSecondsPerPhoto"
    static let musicKey = "SlideshowMusic"
    static let songBookmarkKey = "SlideshowSongBookmark"
    static let songNameKey = "SlideshowSongName"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [notifyKey: true, timeKey: 9 * 60, secondsPerPhotoKey: 4.5, musicKey: "tune"])
    }

    static var notifies: Bool { UserDefaults.standard.bool(forKey: notifyKey) }
    static var minutes: Int { UserDefaults.standard.integer(forKey: timeKey) }
    static var secondsPerPhoto: Double { max(2, UserDefaults.standard.double(forKey: secondsPerPhotoKey)) }
}

/// Finds the memories on the Memories page, keeps them current as the library and the day change, and keeps a
/// month of notifications waiting for the days that have memories, so they arrive even when PugglePhotos isn't open.
@Observable
final class MemoriesController {
    @ObservationIgnored let library: LibraryController
    @ObservationIgnored let notifications: MemoryNotificationCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    private(set) var page = MemoriesPage()
    private(set) var today: CivilDay
    /// When there's nothing today: the next day that has memories, within two months.
    private(set) var nextDay: CivilDay?
    /// True while the memories are being looked for, away from the main thread.
    private(set) var isFinding = false
    /// Counts the searches, so one that finishes after a newer one began is thrown away.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var notifyWork: DispatchWorkItem?
    static let lastShownKey = "LastMemoryNotificationDay"

    init(library: LibraryController, notifications: MemoryNotificationCenter, defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init) {
        self.library = library
        self.notifications = notifications
        self.defaults = defaults
        self.clock = clock
        today = CivilDay(clock(), in: library.formatting.timeZone)
    }

    var finder: MemoryFinder { MemoryFinder(arranger: library.arranger, formatting: library.formatting, today: today) }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .libraryDidChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
        refresh()
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Finds the memories again, away from the main thread so a big library doesn't stall the window, then brings
    /// the notifications up to date.
    func refresh() {
        refreshWork?.cancel()
        today = CivilDay(clock(), in: library.formatting.timeZone)
        guard library.hasLoaded else { return }
        let finder = finder
        generation += 1
        let search = generation
        isFinding = true
        Task {
            let (page, nextDay) = await Self.find(with: finder)
            guard search == generation else { return }
            self.page = page
            self.nextDay = nextDay
            isFinding = false
            NotificationCenter.default.post(name: .memoriesDidChange, object: self)
            scheduleNotifications()
        }
    }

    /// The Memories page, and when there's nothing today, the next day with memories.
    @concurrent
    private nonisolated static func find(with finder: MemoryFinder) async -> (MemoriesPage, CivilDay?) {
        let page = finder.page()
        let next = page.onThisDay.isEmpty
            ? (1...62).lazy.map { finder.today.adding(days: $0) }.first { !finder.photosOnThisDay($0).isEmpty } : nil
        return (page, next)
    }

    /// A memory by its ID: one on the page, or this day in another year's memories (from a notification).
    func memory(_ id: String) -> Memory? {
        page.memory(id) ?? finder.memory(id)
    }

    // MARK: Notifications

    private var lastNotificationSettings: (Bool, Int)?

    private func preferencesChanged() {
        let settings = (MemoryPreferences.notifies, MemoryPreferences.minutes)
        guard lastNotificationSettings.map({ $0 != settings }) ?? true else { return }
        lastNotificationSettings = settings
        notifyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduleNotifications() }
        notifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Notifications for the next 30 days that have memories, at the chosen time. Today's comes at once if its
    /// time has passed and it hasn't been shown yet.
    func scheduleNotifications() {
        guard library.access == .authorized, library.hasLoaded else { return }
        lastNotificationSettings = (MemoryPreferences.notifies, MemoryPreferences.minutes)
        guard MemoryPreferences.notifies else {
            notifications.schedule([], images: [:])
            return
        }
        let minutes = MemoryPreferences.minutes
        let plan = MemoryNotifications.plan(finder: finder, from: today, days: 30, hour: minutes / 60, minute: minutes % 60)
        guard !plan.isEmpty else {
            notifications.schedule([], images: [:])
            return
        }
        notifications.authorize { [weak self] granted in
            guard let self, granted else { return }
            let now = clock()
            if let todays = plan.first(where: { $0.day == self.today }), todays.date <= now,
               defaults.string(forKey: Self.lastShownKey) != today.description {
                defaults.set(today.description, forKey: Self.lastShownKey)
                picture(for: todays) { [weak self] url in self?.notifications.show(todays, image: url) }
            }
            let upcoming = plan.filter { $0.date > now }
            pictures(for: Array(upcoming.prefix(7))) { [weak self] images in
                self?.notifications.schedule(upcoming, images: images)
            }
        }
    }

    /// A picture of a notification's key photo, saved where notifications can pick it up.
    private func picture(for notification: MemoryNotification, completion: @escaping @MainActor (URL?) -> Void) {
        guard let photo = notification.keyPhoto else {
            completion(nil)
            return
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Notification Pictures", isDirectory: true)
        library.source.requestImage(photo, pixels: CGSize(width: 800, height: 800), fit: true) { image, isFinal in
            guard isFinal else { return }
            guard let image else {
                completion(nil)
                return
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                completion(nil)
                return
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(notification.day)-\(UUID().uuidString.prefix(8)).jpg")
            do {
                try data.write(to: url)
                completion(url)
            } catch {
                completion(nil)
            }
        }
    }

    private func pictures(for plan: [MemoryNotification], completion: @escaping @MainActor ([CivilDay: URL]) -> Void) {
        guard !plan.isEmpty else {
            completion([:])
            return
        }
        let gathered = PictureGathering(count: plan.count)
        for notification in plan {
            picture(for: notification) { url in
                gathered.images[notification.day] = url
                gathered.remaining -= 1
                if gathered.remaining == 0 { completion(gathered.images) }
            }
        }
    }

    private final class PictureGathering {
        var images: [CivilDay: URL] = [:]
        var remaining: Int
        init(count: Int) { remaining = count }
    }
}

#if DEBUG
/// Stands in for the system's notification center in debug runs on the sample library, so they never post real
/// notifications or ask for permission.
final class RecordingNotificationCenter: MemoryNotificationCenter {
    var onOpen: ((String) -> Void)?
    private(set) var scheduled: [MemoryNotification] = []
    private(set) var shown: [MemoryNotification] = []
    private(set) var images: [CivilDay: URL] = [:]
    private(set) var authorizations = 0

    func authorize(_ completion: @escaping @MainActor (Bool) -> Void) {
        authorizations += 1
        DispatchQueue.main.async { completion(true) }
    }

    func schedule(_ notifications: [MemoryNotification], images: [CivilDay: URL]) {
        scheduled = notifications
        self.images = images
    }

    func show(_ notification: MemoryNotification, image: URL?) { shown.append(notification) }
}

/// Stands in for the login item in debug runs on the sample library.
final class RecordingLoginItem: LoginItemService {
    var isEnabled = false
    var needsApproval = false
    private(set) var openedSettings = false

    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
    func openLoginItemsSettings() { openedSettings = true }
}
#endif
