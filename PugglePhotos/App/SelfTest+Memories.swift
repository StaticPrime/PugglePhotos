#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// Memories, their notifications, slideshows, opening at login and waiting in the menu bar.
    static func memoryAndSlideshowSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let memories = app.memories!
        let notifications = memories.notifications as! RecordingNotificationCenter
        var page: MemoriesPage { memories.page }

        // MARK: Memories
        step {
            memories.refresh()
            check(memories.isFinding, "memories are found away from the main thread")
            wait { !memories.isFinding }
        }
        step {
            check(page.onThisDay.map(\.title) == ["1 Year Ago Today", "2 Years Ago Today", "3 Years Ago Today", "This Day Through the Years"],
                  "this day in each earlier year is a memory", "\(page.onThisDay.map(\.title))")
            check(page.onThisDay.first?.items.count == 4, "a memory holds that day's photos")
            check(!page.highlights.isEmpty && page.highlights.allSatisfy { $0.items.count >= 8 }, "busy days become highlights",
                  "\(page.highlights.map(\.title))")
            check(page.highlights.contains { $0.title.hasPrefix("Summer at the Lake") }, "a highlight is named for the album most of it is in",
                  "\(page.highlights.map(\.title))")
            check(!page.years.isEmpty && page.years.map(\.title).allSatisfy { $0.hasSuffix(" in Photos") }, "years with enough photos are memories")
            check(page.labels.contains { $0.title == "❤️ Family" }, "a label with enough photos is a memory")
            check(!page.all.flatMap(\.items).contains { library.snapshot.item($0)?.kind == .screenshot }, "screenshots are never memories")
            window.go(to: .memories)
            check(window.memoriesHost?.view.window != nil && window.window?.title == "Memories", "the Memories page opens from the sidebar")
            check(window.memoriesToday == 3, "the sidebar counts the years with memories today")
        }

        // MARK: Notifications
        step {
            UserDefaults.standard.set(0, forKey: MemoryPreferences.timeKey)
            memories.scheduleNotifications()
            wait { !notifications.shown.isEmpty }
        }
        step {
            let shown = notifications.shown.last
            check(shown?.title == "Memories from This Day" && shown?.body.contains("Click to watch them as a slideshow") == true,
                  "today's memories are announced once their time has come", shown?.body ?? "none")
            check(notifications.authorizations >= 1, "PugglePhotos asks before showing notifications")
            let now = DebugLaunchOptions.sampleClock()
            check(notifications.scheduled.allSatisfy { $0.date > now && $0.day != memories.today }, "only days still to come are scheduled")
            let count = notifications.shown.count
            memories.scheduleNotifications()
            wait(upTo: 1) { notifications.shown.count > count }
        }
        step {
            check(notifications.shown.count == 1, "today's notification comes only once", "\(notifications.shown.count)")
            UserDefaults.standard.set(false, forKey: MemoryPreferences.notifyKey)
            memories.scheduleNotifications()
            check(notifications.scheduled.isEmpty, "turning notifications off takes them all away")
            UserDefaults.standard.set(true, forKey: MemoryPreferences.notifyKey)
        }

        // MARK: Slideshows
        step {
            guard let id = notifications.shown.last?.memoryID else { return }
            notifications.onOpen?(id)
            check(SlideshowController.current?.memory.title == "This Day Through the Years", "clicking the notification plays its memory",
                  SlideshowController.current?.memory.title ?? "none")
        }
        step {
            guard let show = SlideshowController.current else {
                check(false, "a slideshow is playing")
                return
            }
            check(show.slides.count == show.memory.items.count + 2, "a slideshow has a title card, every photo and an end card")
            check(show.window.isVisible && show.window.frame == (window.window?.screen ?? NSScreen.main)?.frame,
                  "the slideshow fills the screen")
            check(SlideshowMusic.isSilenced, "test runs play no music")
            show.next()
            show.next()
            check(show.index == 2, "→ goes to the next photo")
            show.previous()
            check(show.index == 1, "← goes back")
            show.togglePause()
            check(show.isPaused, "Space pauses")
            show.togglePause()
            check(!show.isPaused, "Space plays again")
            for _ in 0..<show.slides.count { show.next() }
            check(show.index == show.slides.count - 1 && show.slide.duration == 0, "the slideshow ends on its end card")
            show.playAgain()
            check(show.index == 0, "Play Again starts over")
            show.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
            check(SlideshowController.current == nil && !show.window.isVisible, "Esc ends the slideshow")
            check(NSApp.presentationOptions.isEmpty, "the menu bar and Dock come back")
        }
        step {
            // An album's slideshow, then its photos from the end card.
            guard let album = library.catalog.albums.first(where: { $0.title == "Mia’s 7th Birthday" }) else { return }
            window.go(to: .album(album.id))
            window.phPlaySlideshow(nil)
            check(SlideshowController.current?.memory.title == album.title, "View ▸ Play Slideshow plays the album")
            let video = SlideshowController.current?.slides.firstIndex { if case .video = $0.content { true } else { false } }
            check(video != nil, "an album's videos are in its slideshow")
            if let show = SlideshowController.current, let video {
                for _ in 0..<video { show.next() }
            }
            wait(upTo: 8) { SlideshowController.current?.isPlayingVideo == true }
        }
        step {
            check(SlideshowController.current?.isPlayingVideo == true, "videos play inside the slideshow")
            let albumID = window.currentAlbum?.id
            SlideshowController.current?.close(showPhotos: true)
            check(SlideshowController.current == nil && window.state.source == .album(albumID!), "Show Photos ends on the album's photos")
        }
        step {
            guard let highlight = page.highlights.first else { return }
            window.showPhotos(of: highlight)
            check(window.state.source == .memory(highlight.id) && window.content.allIDs.count == highlight.items.count,
                  "a memory's photos can be shown as photos", "\(window.content.allIDs.count) of \(highlight.items.count)")
            check(window.window?.title == highlight.title, "the window is named for the memory")
            window.setSelection(Array(highlight.items.prefix(3)))
            check(window.slideshowForCurrentPlace()?.items == Array(highlight.items.prefix(3)), "with photos selected, the slideshow plays them")
        }

        // MARK: Opening at login
        step {
            app.settings.setOpensAtLogin(true)
            check((app.loginItem as! RecordingLoginItem).isEnabled && app.settings.opensAtLogin, "PugglePhotos can open at login")
            app.settings.setOpensAtLogin(false)
            check(!(app.loginItem as! RecordingLoginItem).isEnabled, "and stop")
            app.waitInMenuBar()
            check(app.isWaitingInMenuBar && NSApp.activationPolicy() == .accessory, "after a login launch it waits in the menu bar")
            app.showLibraryWindow(nil)
            check(!app.isWaitingInMenuBar && NSApp.activationPolicy() == .regular, "opening the window brings back the Dock icon")
        }
        step {
            var data: Data?
            SlideshowMusic.tune { data = $0 }
            wait(upTo: 20) { data != nil }
            step {
                check((data?.count ?? 0) > 1_000_000, "PugglePhotos' own tune is made", "\(data?.count ?? 0) bytes")
            }
        }
    }
}
#endif
