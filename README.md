# PugglePhotos

**A cozy home for your photo library and the memories in it.**

PugglePhotos is a photo album for the Mac that works with the photos and videos already in your Photos library. Wander through every day you've photographed, gather favorites into albums, give photos labels, captions and the stories behind them, and put photos back on the right day just by dragging them there.

- A timeline of every day, with a calendar that shows where your photos are
- Albums, as many as you like, with covers and stories, and a photo can be in any number of them
- Colorful labels, captions and notes on any photo
- Drag photos onto a day, or between two photos, to fix all their dates at once
- Gallery, list and album covers, grouped and sorted your way

PugglePhotos reads your Photos library where it is: nothing is copied or moved. Albums are kept in step with your Photos library, and so are dates and favorites, so they're right everywhere you see your photos. Labels, captions and notes stay on your Mac.

PugglePhotos is free, needs no account and has no tracking. It runs in the macOS app sandbox with no permission to use the network, on macOS 14 Sonoma or later. It's written in Swift with AppKit and SwiftUI, and is part of the PuggleSoft family with [PuggleDocs](https://github.com/StaticPrime/PuggleDocs), [PuggleSheets](https://github.com/StaticPrime/PuggleSheets) and [PuggleSlides](https://github.com/StaticPrime/PuggleSlides).

## Features

### Browsing

- **The window.** The sidebar on the left (your library, albums and labels, with a calendar underneath), your photos in the middle and the info panel on the right (View ▸ Show Info, ⌘I). The toolbar has Back, gallery or list, a thumbnail size slider, grouping and sorting, the favorite heart and search. Light and Dark Mode both work.
- **The timeline.** Library shows every photo and video under the day it was taken ("Today", "Yesterday", "Saturday, June 14, 2025"), oldest first, opening on the newest. Each day's heading stays at the top while its photos scroll by, and counts what's under it; click a heading to select that day's photos. Go ▸ Today (⌘T) jumps to the most recent day.
- **Gallery, list and grouping.** View as a gallery of thumbnails (⌘1) or a list (⌘2) with each photo's title, date, kind, size, albums, labels and note. Group by day, month, year, album or label (a photo in two albums shows in both, and the ones in none come last), or not at all. Sort by date taken, date added, title or kind, either way round. Library, Favorites, Videos and Recently Added each remember their own choice, as do albums and labels. Click a list column's heading to sort by it. ⌘+ and ⌘− (or the slider) change the thumbnail size.
- **The calendar.** A month in the sidebar, with every day that has photos tinted, more strongly the more there are. Click a day to go to it; click the month to jump to any month of any year with photos; scroll over it to turn the months. View ▸ Hide Calendar puts it away.
- **The viewer.** Double-click, Return or Space opens a photo as big as the window allows, on a dark background. ← and → step through the photos, pinching, double-clicking or ⌘+ zooms in, and dragging moves around a zoomed photo. Videos play right there. Esc, ⌘[ or Back returns to the photos with the same one selected.
- **Search.** The search field (⌘F) finds photos by caption, note, label, album, file name, kind ("video", "screenshot"), "favorite", year ("2019") or month ("june"); every word has to match.
- **Thumbnails** show a heart for favorites, the length of videos, a dot for each label and a bubble when a photo has a note. Settings can hide all but the video length.

### Organizing

- **Albums.** File ▸ New Album (⌘N), or New Album with Selection (⇧⌘N), names the album right in the sidebar. Add photos by dragging them onto an album in the sidebar or onto its cover, from the Photo ▸ Add to Album menu or from the info panel. A photo can be in any number of albums. An album opens with its title and story at the top, both editable where they are, with its dates and size. Show it oldest or newest first, or in its own order, and drag photos around to arrange them. Delete removes photos from the album (never from your library); Photo ▸ Make Album Cover picks its cover.
- **Albums in step with your Photos library.** Every album is also an album in your Photos library. Make, rename, fill, arrange or delete one here and the same happens there; albums made or changed there, on this Mac or your other devices, show up here. Each change goes to the library as one change, and Undo puts it back in both places. An album's story and cover stay with PugglePhotos.
- **All Albums.** Every album's cover as a little stack of prints, with its dates and size, sorted by name, date, date created or size. Double-click a cover to open the album, drop photos on it to add them, or click New Album.
- **Labels.** Make labels with a name, a color and an emoji ("😂 Funny", "🐶 Pets"). Put them on photos from the info panel or the Photo ▸ Labels menu, by dropping photos on a label in the sidebar or on a label's heading, or with ⌃1 to ⌃9 for the first nine. A label in the sidebar shows every photo that has it, by month.
- **Captions and notes.** Give any photo a caption, its title in lists and the viewer, and a note for the story behind it, right in the info panel. Albums have a story of their own.
- **Favorites.** Press period (.), click the heart in the toolbar or the info panel, or drop photos on Favorites. Favorites are the same ones as in your Photos library.
- **Several at once.** Select several photos and the info panel shows how many there are and their dates, with every label marked on all, some or none of them, and buttons to favorite them, add them to an album or change their dates together.
- **Undo** (⌘Z) and **Redo** (⇧⌘Z) for every change, named for what they undo.

### Fixing dates

Scanned prints dated the day they were scanned, a camera with its clock set wrong, photos sent by a friend: PugglePhotos puts them on the right day without changing them one by one.

- **Drop photos on a day.** Drag any number of photos onto a day in the calendar or onto a day's heading in the timeline. Each keeps its time of day, or they all get a time you choose, a second apart in the order they were in. While dragging, hover over the calendar's arrows to turn the months.
- **Drop photos between two others.** In a view sorted by date, drop photos between two photos and they take a moment right between them, so they sit exactly there.
- **Change Date and Time** (⇧⌘D) sets an exact date and time for the selected photos: shift them all by the same amount (keeping the gaps between them), move them to a day keeping their times, or give them all one date and time.
- PugglePhotos asks before changing dates (Settings can turn that off), changes the whole batch in one go, then shows the photos where they landed. The new dates are saved to your Photos library, so the photos sort correctly everywhere; Edit ▸ Undo puts the old ones back.

### Your library and your privacy

- The first time it opens, PugglePhotos asks for permission to use your Photos library. It reads photos where they are and never copies, moves or deletes them; it changes only what you ask it to: a photo's date, whether it's a favorite, and your albums.
- Labels, captions, notes and album stories are saved on your Mac in the app's own folder (`~/Library/Containers/com.pugglesoft.PugglePhotos/Data/Library/Application Support/PugglePhotos`), with a copy from each of the last 14 days kept in `Backups` next to it. A file that can't be read is set aside, never overwritten.
- PugglePhotos has no permission to use the network and sends nothing anywhere.

Help ▸ Keyboard Shortcuts (⌘/) lists every keyboard shortcut.

## Known limits

- macOS may ask you to confirm when PugglePhotos changes dates or favorites in your Photos library; PugglePhotos sends each batch as one change, so you're asked at most once per drop.
- Labels, captions, notes, album stories and covers are PugglePhotos' own and don't show in other apps. They follow photos by the library's identifiers for them, so they stay with the library on this Mac; switching to a different Photos library leaves them behind.
- Albums in folders in the Photos library show as albums of their own, and new albums are made outside any folder. Smart albums and shared albums aren't shown.
- Times are shown in the Mac's current time zone.
- Places are shown as coordinates, not place names. Live photos show as still photos, and hidden photos and shared albums aren't shown.
- On a large library, file names arrive a little after the photos, so sorting by title settles once they have.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (developed with Xcode 27.2, Swift 6)

## Building and running

Open `PugglePhotos.xcodeproj` in Xcode and run the **PugglePhotos** scheme. Or, from the command line:

```sh
xcodebuild -project PugglePhotos.xcodeproj -scheme PugglePhotos -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/PugglePhotos.app
```

The app is sandboxed, with access to the Photos library, and signs locally ("Sign to Run Locally"). To distribute it, set your team under *Signing & Capabilities*.

### Installer

```sh
Tools/make-installer.sh
```

This builds `build/PugglePhotos.pkg`, which installs PugglePhotos.app in /Applications for all users (macOS asks for an administrator's password). The app runs on every Mac with macOS 14 or later.

A local build is ad-hoc signed and the installer is unsigned. That's fine on the Mac that built it, but a copy that arrives by download or email is blocked the first time: the user has to click **Open Anyway** in System Settings ▸ Privacy & Security. To sign with a Developer ID and have the installer notarized, set the variables described at the top of `Tools/make-installer.sh` before running it. Releases built on GitHub are signed and notarized this way when the repository has the Developer ID secrets (see below).

### Releasing a new version

Versions are MAJOR.MINOR.FIX. To release the next one, run this on `main`, up to date with GitHub and with everything committed:

```sh
Tools/release.sh            # a fix:          1.2.3 → 1.2.4
Tools/release.sh minor      # a minor update: 1.2.3 → 1.3.0
Tools/release.sh major      # a major update: 1.2.3 → 2.0.0
```

The script raises the version and the build number in the Xcode project, commits "Release version 1.2.4", tags it `v1.2.4` and pushes both. The tag starts the Release workflow on GitHub, which runs the package tests, builds the installer with `Tools/make-installer.sh` and publishes it as a GitHub release. The installer keeps the same name in every release, so https://github.com/StaticPrime/PugglePhotos/releases/latest/download/PugglePhotos.pkg always downloads the newest one. `Tools/release.sh --dry-run` shows the next version without changing anything.

To sign and notarize releases, add these secrets under the repository's Settings ▸ Secrets and variables ▸ Actions. Without them, releases are published unsigned, with a warning on the run.

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | A .p12 file with the "Developer ID Application" and "Developer ID Installer" certificates and their private keys, base64-encoded (`base64 -i DeveloperID.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12 file's password |
| `NOTARY_API_KEY` | The text of an App Store Connect API key file (`AuthKey_….p8`), used to notarize |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys in App Store Connect |

## Tests

The catalog of albums, labels, captions and notes, the date arithmetic behind moving photos in time, sorting, grouping, search and saving live in a Swift package with 54 unit tests:

```sh
cd Packages/PugglePhotosKit && swift test
```

Debug builds also include an end-to-end check that drives a real window on a made-up sample library (never the real Photos library or catalog) and prints `SELFTEST PASS/FAIL` lines. It covers the timeline and its headings, the calendar, thumbnails, selecting, favorites and their undo, a refused change, albums (making, naming, adding by dropping, removing with Delete, covers, arranging by dragging, banners, covers sorted every way, and every change reaching the album's twin in the Photos library, changes made there arriving here, deleting and undeleting, and a refused change), labels and their shortcuts, captions, notes, search, moving photos to a day, between two photos and onto the calendar (with undo and redo, the question asked first and Change Date and Time), grouping and sorting, the list, the size slider, the viewer and its keys, videos, and saving:

```sh
build/DerivedData/Build/Products/Debug/PugglePhotos.app/Contents/MacOS/PugglePhotos -PHSelfTest YES
```

Other debug launch arguments: `-PHSampleLibrary YES` uses the sample library: about 120 illustrated photos over seven years (a lake, the beach, birthdays, snow days, a pug named Waffles), a few videos, screenshots, a batch of scanned prints all dated the day they were scanned, and photos from this day in past years, with albums, labels, captions and notes to match. `-PHToday 2026-11-17` fixes the day it treats as today. `-PHSnapshot name.png` saves a screenshot of the window (or the About or Settings window, or an open sheet or question) to the app's temporary folder and quits, always on the sample library. Combine it with `-PHWindowWidth`, `-PHWindowHeight`, `-PHInspector YES`, `-PHDark YES`, `-PHSource favorites` (or `videos`, `recent`, `albums`, `album:2`, `label:1`), `-PHViewMode list`, `-PHGrouping month`, `-PHSort title`, `-PHDescending YES`, `-PHZoom 220`, `-PHSearch lake`, `-PHSelect 3,4,5`, `-PHViewer YES`, `-PHCalendar 2019-07`, `-PHRedate day` (or `between`), `-PHOpenSheet changeDate` (or `shortcuts`, `newLabel`), `-PHAccess ask` (or `denied`), `-PHShowAbout YES` or `-PHSettings YES`. `-PHBenchmark YES` adds 60,000 sample photos and times grouping, sorting, searching and laying out the grid.

## Project layout

```
PugglePhotos/                macOS app target (files are picked up automatically by Xcode)
  App/                       Entry point, app delegate, debug-only sample library, launch options and self-test
  Library/                   The Photos library through PhotoKit, and LibraryController: every change and its undo
  Browser/                   The window: sidebar and calendar, the photo grid and its layout, the list, album
                             covers, the toolbar, commands and dropping photos
  Viewer/                    One photo or video at a time
  UI/                        Info panel, dialogs, settings, About, menus, colors
  Resources/                 Asset catalog (app icon, accent color, About window logo)
Packages/PugglePhotosKit/    The catalog, dates, sorting, grouping and search (no UI)
  Model/                     Photos and videos, albums, labels, captions and notes
  Dates/                     Calendar days, moving photos in time, wording for dates and counts
  Library/                   Picking, sorting, grouping and searching photos
  Store/                     Saving the catalog, with daily backups
Tools/make-icons.swift       Regenerates the app icon PNGs
Tools/make-installer.sh      Builds the PugglePhotos.pkg installer
Tools/release.sh             Releases the next version (see Releasing a new version)
```

## How it works

- **The photos** stay in the Photos library. PugglePhotos reads every item's date, size, kind and favorite through PhotoKit off the main thread, asks for thumbnails at the size each view shows them (and keeps them in memory by size), and follows changes made elsewhere as they happen.
- **The catalog** is everything made in PugglePhotos: albums with their photos in order, labels, captions and notes, all referring to photos by the library's identifiers. It's one small JSON file, written whole and atomically half a second after each change.
- **Albums are mirrored.** Each album is linked to its twin in the Photos library, which decides the album's title and photos whenever the two differ: each time the library changes, its albums are read again and new, changed and deleted ones are taken in. A change made in PugglePhotos shows at once and goes to the twin as one change, which compares first so only what differs is changed; changes made while one is on its way follow it together. If the library refuses, it keeps its version and so does PugglePhotos.
- **Days** are worked out once per item as plain day numbers, so grouping a large library by day, month or year is arithmetic rather than calendar lookups. The grid's layout places thumbnails by arithmetic too, section by section, and asks only for what's on screen, which keeps scrolling smooth with tens of thousands of photos.
- **Moving photos in time** works out every new date first, keeping the photos in the order they had, then sends the whole batch to the Photos library as one change. Undo sends the old dates back the same way.
- **Edits** to the catalog go through one method that keeps the catalog as it was, so undo and redo restore exactly what was there. Changes to the Photos library register their undo at once and write the old values back when undone.

## Contributing

Bug reports, ideas and pull requests are welcome. Before your first pull request is merged, you sign the [PuggleSoft Contributor License Agreement](CLA.md) by posting one comment, and a bot walks you through it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 PuggleSoft.

PugglePhotos is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.
