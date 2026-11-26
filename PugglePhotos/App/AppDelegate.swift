import AppKit
import CloudKit
import PugglePhotosKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var library: LibraryController!
    private(set) var memories: MemoriesController!
    private(set) var sharing: SharingController!
    private(set) var notifications: MemoryNotificationCenter!
    private(set) var settings: SettingsModel!
    /// Names places and finds them, for Get Info.
    private(set) lazy var placeLookup: PlaceLookup = {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return SamplePlaceLookup() }
        #endif
        return MapPlaceLookup()
    }()
    private(set) var windowController: LibraryWindowController?
    private var observer: NSObjectProtocol?
    private var initialCatalog: Catalog?
    /// A memory to play once the library has loaded (from a notification clicked before PugglePhotos was open).
    private var pendingMemory: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        MemoryPreferences.registerDefaults()
        BookPreferences.registerDefaults()
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        library = makeLibrary()
        let notifications = makeNotificationCenter()
        self.notifications = notifications
        memories = MemoriesController(library: library, notifications: notifications, defaults: Self.memoryDefaults, clock: Self.memoryClock)
        // A notification clicked while PugglePhotos is still opening (the click that opened it, say) is acted on once
        // it has, or by the new version if it updates itself first.
        notifications.onOpen = { [weak self] id in
            UpdateController.shared.whenLaunched(handoff: LaunchHandoff.memory(id).encoded) { self?.openMemory(id) }
        }
        let sharedStore = Self.sharedAlbumsStore
        sharing = SharingController(library: library, backend: makeSharingBackend(store: sharedStore), store: sharedStore,
                                    notifications: notifications, defaults: Self.memoryDefaults)
        notifications.onOpenSharedAlbum = { [weak self] id in
            UpdateController.shared.whenLaunched(handoff: LaunchHandoff.sharedAlbum(id).encoded) { self?.openSharedAlbum(id) }
        }
        settings = SettingsModel()
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
        // The splash screen and the update check, before the library window opens.
        let updates = UpdateController.shared
        updates.onHandoff = { [weak self] in LaunchHandoff($0)?.perform(self) }
        updates.beforeRestart = { [weak self] in self?.saveForNextLaunch() }
        updates.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PHDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        #endif
        library.start(catalog: initialCatalog)
        memories.start()
        sharing.start()
        // Files other apps wrote out for drops last time are in the library by now, or were never wanted.
        FileDrop.clearDroppedFiles()
        // The window waits for the splash screen and the update check, so a new version is installed before the
        // library shows. The library is read meanwhile, so it's ready sooner. (Its reading isn't held back too: the
        // catalog must be read before PugglePhotos quits, which saves it, and an update quits PugglePhotos as it opens.)
        UpdateController.shared.whenLaunched { [weak self] in self?.showLibraryWindow(nil) }
        stopOpeningAtLogin()
        observer = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: library, queue: .main) { [weak self] note in
            let change = note.userInfo?["change"] as? LibraryController.Change
            MainActor.assumeIsolated {
                if change == .catalog { DynamicMenus.refresh() }
                self?.playPendingMemory()
            }
        }
        #if DEBUG
        DebugLaunchOptions.runIfRequested(self)
        SelfTest.runIfRequested(self)
        #endif
    }

    // MARK: The library and its services

    /// The Photos library, or (in debug builds, with `-PHSampleLibrary YES`) the sample library.
    private func makeLibrary() -> LibraryController {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary {
            let source = DebugLaunchOptions.makeSampleSource()
            initialCatalog = source.catalog
            return LibraryController(source: source, store: DebugLaunchOptions.sampleStore)
        }
        #endif
        return LibraryController(source: SystemPhotoSource(), store: CatalogStore(folder: Self.catalogFolder))
    }

    /// iCloud, where albums are shared; on the sample library, a stand-in for it.
    private func makeSharingBackend(store: SharedAlbumsStore) -> SharingBackend {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary {
            let standIn = StandInSharing(store: store)
            // The self-test brings Gran's album in itself, when it's ready for it.
            standIn.delivers = !UserDefaults.standard.bool(forKey: "PHSelfTest")
            return standIn
        }
        #endif
        if CloudKitSharing.isEntitled { return CloudKitSharing(store: store) }
        return UnavailableSharing(reason: "Sharing albums goes through iCloud, which this copy of PugglePhotos isn’t signed to use.")
    }

    /// Where shared albums are kept: beside the catalog, or for the sample library in a folder of its own.
    private static var sharedAlbumsStore: SharedAlbumsStore {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return DebugLaunchOptions.sampleSharedStore }
        #endif
        return SharedAlbumsStore(folder: catalogFolder.appendingPathComponent("Shared Albums", isDirectory: true))
    }

    /// The system's notifications; debug runs on the sample library only record them.
    private func makeNotificationCenter() -> MemoryNotificationCenter {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return RecordingNotificationCenter() }
        #endif
        return SystemNotificationCenter()
    }

    /// PugglePhotos never opens by itself when you log in. Earlier versions could, from Settings, so a Mac where that
    /// was turned on has PugglePhotos taken back out of the apps that open at login. (Runs on the sample library leave
    /// the Mac's login items alone.)
    private func stopOpeningAtLogin() {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return }
        #endif
        Task.detached(priority: .utility) {
            let service = SMAppService.mainApp
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try? await service.unregister()
        }
    }

    private static var memoryDefaults: UserDefaults {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return DebugLaunchOptions.sampleDefaults }
        #endif
        return .standard
    }

    private static var memoryClock: () -> Date {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return DebugLaunchOptions.sampleClock }
        #endif
        return Date.init
    }

    /// Application Support/PugglePhotos in the app's container.
    static var catalogFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PugglePhotos", isDirectory: true)
    }

    // MARK: Windows

    @objc func showLibraryWindow(_ sender: Any?) {
        if windowController == nil {
            windowController = LibraryWindowController(library: library, memories: memories, sharing: sharing)
            windowController?.placeLookup = placeLookup
            windowController?.window?.center()
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { UpdateController.shared.whenLaunched { [weak self] in self?.showLibraryWindow(nil) } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Never while macOS's installer is changing the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UpdateController.shared.isInstalling ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveForNextLaunch()
    }

    /// Saves what's kept between launches: as PugglePhotos quits, and just before it opens a new version of itself.
    private func saveForNextLaunch() {
        windowController?.rememberLayout()
        library.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showAboutWindow(_ sender: Any?) { AboutWindowController.show() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(settings) }

    // MARK: Shared albums

    /// Joins an album someone shared with you, from the link they sent, and opens it. A link clicked while PugglePhotos
    /// isn't open waits until it has, or goes to the new version if it updates itself first.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        UpdateController.shared.whenLaunched(handoff: metadata.share.url.map { LaunchHandoff.invitation($0).encoded }) { [weak self] in
            self?.sharing.accept(metadata) { self?.joined($0) }
        }
    }

    /// Joins an album someone shared with you from its link alone: one handed on by the copy that updated itself.
    func joinSharedAlbum(link: URL) {
        sharing.accept(link: link) { [weak self] in self?.joined($0) }
    }

    /// Opens the shared album just joined, or says why it couldn't be.
    private func joined(_ result: Result<UUID, Error>) {
        switch result {
        case let .success(id):
            openSharedAlbum(id)
        case let .failure(error):
            showLibraryWindow(nil)
            let alert = NSAlert()
            alert.messageText = "The shared album couldn’t be opened."
            alert.informativeText = error.localizedDescription
            if let window = windowController?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        sharing.receivedPush(userInfo)
    }

    /// Opens an album shared with you, from a notification about it.
    func openSharedAlbum(_ id: UUID) {
        showLibraryWindow(nil)
        guard sharing.sharedWithMe(id) != nil else { return }
        windowController?.go(to: .sharedAlbum(id))
    }

    // MARK: Memories

    /// Plays a memory, from a clicked notification: the window comes up behind the slideshow.
    func openMemory(_ id: String) {
        showLibraryWindow(nil)
        guard library.hasLoaded else {
            pendingMemory = id
            return
        }
        guard let memory = memories.memory(id), let window = windowController else { return }
        window.go(to: .memories)
        window.play(memory)
    }

    private func playPendingMemory() {
        guard let id = pendingMemory, library.hasLoaded else { return }
        pendingMemory = nil
        memories.refresh()
        openMemory(id)
    }
}

/// Something PugglePhotos was asked to open as it started, kept for the new version when it restarts to finish
/// updating first.
enum LaunchHandoff: Codable {
    /// A link to an album someone shared.
    case invitation(URL)
    /// A memory, from its notification.
    case memory(String)
    /// An album shared with you, from its notification.
    case sharedAlbum(UUID)

    var encoded: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    init?(_ encoded: String) {
        guard let handoff = try? JSONDecoder().decode(LaunchHandoff.self, from: Data(encoded.utf8)) else { return nil }
        self = handoff
    }

    func perform(_ app: AppDelegate?) {
        guard let app else { return }
        switch self {
        case let .invitation(link): app.joinSharedAlbum(link: link)
        case let .memory(id): app.openMemory(id)
        case let .sharedAlbum(id): app.openSharedAlbum(id)
        }
    }
}
