import AppKit
import PugglePhotosKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var library: LibraryController!
    private(set) var windowController: LibraryWindowController?
    private var observer: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        library = makeLibrary()
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PHDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        #endif
        library.start(catalog: initialCatalog)
        showLibraryWindow(nil)
        observer = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: library, queue: .main) { note in
            guard (note.userInfo?["change"] as? LibraryController.Change) == .catalog else { return }
            MainActor.assumeIsolated { DynamicMenus.refresh() }
        }
        #if DEBUG
        DebugLaunchOptions.runIfRequested(self)
        SelfTest.runIfRequested(self)
        #endif
    }

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

    private var initialCatalog: Catalog?

    /// Application Support/PugglePhotos in the app's container.
    static var catalogFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PugglePhotos", isDirectory: true)
    }

    @objc func showLibraryWindow(_ sender: Any?) {
        if windowController == nil {
            windowController = LibraryWindowController(library: library)
            windowController?.window?.center()
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
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

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show() }
}
