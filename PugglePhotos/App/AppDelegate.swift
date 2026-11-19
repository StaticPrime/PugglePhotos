import AppKit
import PugglePhotosKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var library: LibraryController!
    private(set) var memories: MemoriesController!
    private(set) var sharing: SharingController!
    private(set) var notifications: MemoryNotificationCenter!
    private(set) var loginItem: LoginItemService!
    private(set) var settings: SettingsModel!
    private(set) var windowController: LibraryWindowController?
    /// Whether macOS opened PugglePhotos at login, so it waits quietly in the menu bar instead of opening a window.
    private(set) var launchedAtLogin = false
    private var statusItem: NSStatusItem?
    private var observer: NSObjectProtocol?
    private var initialCatalog: Catalog?
    /// A memory to play once the library has loaded (from a notification clicked before PugglePhotos was open).
    private var pendingMemory: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        MemoryPreferences.registerDefaults()
        BookPreferences.registerDefaults()
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        launchedAtLogin = LaunchReason.isLoginLaunch()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PHLaunchedAtLogin") { launchedAtLogin = true }
        #endif
        library = makeLibrary()
        let notifications = makeNotificationCenter()
        self.notifications = notifications
        memories = MemoriesController(library: library, notifications: notifications, defaults: Self.memoryDefaults, clock: Self.memoryClock)
        notifications.onOpen = { [weak self] id in self?.openMemory(id) }
        let sharedStore = Self.sharedAlbumsStore
        sharing = SharingController(library: library, backend: makeSharingBackend(store: sharedStore), store: sharedStore, notifications: notifications)
        notifications.onOpenSharedAlbum = { [weak self] id in self?.openSharedAlbum(id) }
        loginItem = makeLoginItem()
        settings = SettingsModel(loginItem: loginItem)
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
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
        if launchedAtLogin {
            waitInMenuBar()
        } else {
            showLibraryWindow(nil)
        }
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
        return UnavailableSharing(reason: "Sharing albums uses iCloud, which this copy of PugglePhotos isn’t set up to reach yet.")
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

    private func makeLoginItem() -> LoginItemService {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return RecordingLoginItem() }
        #endif
        return SystemLoginItem()
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
        leaveMenuBar()
        if windowController == nil {
            windowController = LibraryWindowController(library: library, memories: memories, sharing: sharing)
            windowController?.window?.center()
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibraryWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.rememberLayout()
        library.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showAboutWindow(_ sender: Any?) { AboutWindowController.show() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(settings) }

    // MARK: Memories

    /// Plays a memory, from a clicked notification or the menu bar: the window comes up behind the slideshow.
    /// Opens an album shared with you, from a notification about it.
    func openSharedAlbum(_ id: UUID) {
        showLibraryWindow(nil)
        guard sharing.sharedWithMe(id) != nil else { return }
        windowController?.go(to: .sharedAlbum(id))
    }

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

    // MARK: Waiting in the menu bar

    /// After a login launch: no window and no Dock icon, just a paw in the menu bar, while memory notifications
    /// are kept up to date.
    func waitInMenuBar() {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "PugglePhotos")
        item.button?.toolTip = "PugglePhotos"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func leaveMenuBar() {
        guard NSApp.activationPolicy() != .regular || statusItem != nil else { return }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        NSApp.setActivationPolicy(.regular)
    }

    var isWaitingInMenuBar: Bool { statusItem != nil }

    @objc private func openFromMenuBar(_ sender: Any?) { showLibraryWindow(nil) }

    @objc private func playFromMenuBar(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { openMemory(id) }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The menu bar paw's menu: open PugglePhotos, today's memories, quit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "Open PugglePhotos", action: #selector(openFromMenuBar(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let today = memories.page.onThisDay
        if !today.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "On This Day", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for memory in today {
                let item = NSMenuItem(title: memory.title, action: #selector(playFromMenuBar(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = memory.id
                item.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PugglePhotos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
