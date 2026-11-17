import AppKit
import PugglePhotosKit
import SwiftUI

/// What the journal asks the window to do.
protocol JournalActions: AnyObject {
    func journalSave(_ text: String, mood: String, for day: CivilDay)
    /// Shows the day's photos in the library.
    func journalShowDay(_ day: CivilDay)
    /// Plays the day's photos as a slideshow.
    func journalPlayDay(_ day: CivilDay)
}

/// What's being written at the top of the Journal page. The window keeps it, so a menu command can point it at a
/// day, and it survives going elsewhere and coming back.
@Observable final class JournalComposer {
    /// The day being written about; nil means today, whatever day that is.
    var day: CivilDay?
    var text = ""
    var mood = ""
    /// Goes up each time the text box should take the keyboard.
    var focusRequests = 0

    /// Starts writing about a day (nil for today), with what's already written about it.
    func write(about day: CivilDay?, catalog: Catalog, today: CivilDay) {
        self.day = day == today ? nil : day
        load(catalog.entry(for: day ?? today))
        focusRequests += 1
    }

    func load(_ entry: JournalEntry?) {
        text = entry?.text ?? ""
        mood = entry?.mood ?? ""
    }

    /// Whether what's written differs from the saved entry.
    func hasChanges(from entry: JournalEntry?) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != (entry?.text ?? "") || mood != (entry?.mood ?? "")
    }
}

/// A row of moods to choose from; choosing the chosen one again clears it.
struct MoodPicker: View {
    @Binding var mood: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(JournalEntry.moods, id: \.self) { option in
                Button {
                    mood = mood == option ? "" : option
                } label: {
                    Text(option)
                        .font(.system(size: 20))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(mood == option ? Color.pugglePink.opacity(0.25) : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(mood == option ? "Clear the mood" : "How the day felt")
                .accessibilityLabel("Mood \(option)")
                .accessibilityAddTraits(mood == option ? .isSelected : [])
            }
        }
    }
}

/// A text box with a prompt, for the journal.
struct JournalTextEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Journal entry")
            if text.isEmpty {
                Text("What happened? Who was there? What do you want to remember?")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(nsColor: .separatorColor)))
    }
}

/// What's written in the journal editor, kept outside the view so it can be saved however the editor closes.
@Observable final class JournalDraft {
    var text: String
    var mood: String
    /// Set by Cancel, so closing saves nothing.
    var isCancelled = false

    init(_ entry: JournalEntry?) {
        text = entry?.text ?? ""
        mood = entry?.mood ?? ""
    }
}

/// Writing about one day, in a popover by its heading or in a sheet: a mood and some words.
struct JournalEditorView: View {
    @Bindable var draft: JournalDraft
    let dayTitle: String
    let photoCount: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle).font(.system(size: 17, weight: .bold, design: .rounded))
                if !photoCount.isEmpty { Text(photoCount).font(.callout).foregroundStyle(.secondary) }
            }
            MoodPicker(mood: $draft.mood)
            JournalTextEditor(text: $draft.text)
                .focused($focused)
                .frame(minHeight: 140)
            HStack {
                Text("Search finds the day’s photos by what you write.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    draft.isCancelled = true
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save (⌘↩)")
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

/// The Journal page: a place to write about today at the top, then every entry, the newest first, each with the
/// day's photos.
struct JournalView: View {
    let library: LibraryController
    @Bindable var composer: JournalComposer
    let actions: () -> JournalActions?

    private var formatting: Formatting { library.formatting }

    var body: some View {
        let catalog = library.catalog
        let today = CivilDay(Date(), in: formatting.timeZone)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    JournalComposerCard(library: library, composer: composer, today: today, actions: actions) { day in
                        write(about: day, today: today)
                    }
                    .id("composer")
                    if catalog.journal.isEmpty {
                        Text("Your journal starts here. Write about today above, about any day with Another Day, or about a day in the library with the pencil on its heading. Search finds a day’s photos by what you wrote.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    ForEach(catalog.journalDays, id: \.self) { entryDay in
                        if let entry = catalog.entry(for: entryDay) {
                            JournalEntryCard(day: entryDay, entry: entry, library: library, actions: actions) {
                                write(about: entryDay, today: today)
                                withAnimation { proxy.scrollTo("composer", anchor: .top) }
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 22, leading: 26, bottom: 30, trailing: 26))
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: composer.focusRequests) { proxy.scrollTo("composer", anchor: .top) }
        }
        .background(Color(nsColor: Theme.gridBackground))
        .onDisappear { keepWriting(today: CivilDay(Date(), in: formatting.timeZone)) }
    }

    /// Moves the writing box to another day (nil for today), keeping what was written about the one before.
    private func write(about day: CivilDay?, today: CivilDay) {
        keepWriting(today: today)
        composer.write(about: day, catalog: library.catalog, today: today)
    }

    /// Saves what's in the writing box, if it changed: nothing written is lost by going to another day or page.
    private func keepWriting(today: CivilDay) {
        let day = composer.day ?? today
        guard composer.hasChanges(from: library.catalog.entry(for: day)) else { return }
        actions()?.journalSave(composer.text, mood: composer.mood, for: day)
    }
}

/// The top of the Journal page, where the writing happens.
struct JournalComposerCard: View {
    let library: LibraryController
    @Bindable var composer: JournalComposer
    let today: CivilDay
    let actions: () -> JournalActions?
    /// Moves the writing box to another day (nil for today).
    let onWriteAbout: (CivilDay?) -> Void
    @State private var choosingDay = false
    @State private var pickedDate = Date()
    @FocusState private var focused: Bool

    private var formatting: Formatting { library.formatting }
    private var day: CivilDay { composer.day ?? today }

    var body: some View {
        let saved = library.catalog.entry(for: day)
        let changed = composer.hasChanges(from: saved)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(day == today ? "Today" : formatting.longDay(day))
                    .font(.system(size: day == today ? 24 : 20, weight: .bold, design: .rounded))
                if day == today {
                    Text(formatting.weekdayAndDay(today)).foregroundStyle(.secondary)
                }
                Spacer()
                if day != today {
                    Button("Back to Today") { onWriteAbout(nil) }
                        .buttonStyle(.link)
                }
                Button("Another Day…") {
                    pickedDate = day.start(in: formatting.calendar)
                    choosingDay = true
                }
                .buttonStyle(.link)
                .popover(isPresented: $choosingDay, arrowEdge: .bottom) { dayPicker }
            }
            MoodPicker(mood: $composer.mood)
            JournalTextEditor(text: $composer.text)
                .focused($focused)
                .frame(minHeight: 120)
            HStack(spacing: 12) {
                Text(photoLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if saved != nil, !changed {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button(saved == nil ? "Save Entry" : "Save Changes") {
                        actions()?.journalSave(composer.text, mood: composer.mood, for: day)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!changed)
                    .help("Save (⌘↩)")
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.pugglePink.opacity(0.07)))
        .onChange(of: composer.focusRequests) { focused = true }
        // An entry changed elsewhere (by its heading's pencil, or Undo) shows here, unless there's unsaved writing.
        .onChange(of: saved) { old, new in
            if !composer.hasChanges(from: old) { composer.load(new) }
        }
        .onAppear {
            if composer.text.isEmpty, composer.mood.isEmpty { composer.load(saved) }
        }
    }

    private var photoLine: String {
        let ids = library.snapshot.ids(on: day)
        guard !ids.isEmpty else { return day == today ? "No photos yet today." : "No photos from this day." }
        let counts = library.snapshot.counts(of: ids)
        return "\(formatting.count(photos: counts.photos, videos: counts.videos)) from this day."
    }

    private var dayPicker: some View {
        VStack(spacing: 10) {
            DatePicker("Day", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Button("Write About This Day") {
                choosingDay = false
                onWriteAbout(CivilDay(pickedDate, in: formatting.timeZone))
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }
}

/// One entry: its day and mood, the day's photos, and what was written.
struct JournalEntryCard: View {
    let day: CivilDay
    let entry: JournalEntry
    let library: LibraryController
    let actions: () -> JournalActions?
    let onEdit: () -> Void

    var body: some View {
        let formatting = library.formatting
        let photos = library.snapshot.ids(on: day)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatting.longDay(day)).font(.system(size: 17, weight: .bold, design: .rounded))
                if !entry.mood.isEmpty {
                    Text(entry.mood).font(.system(size: 18)).accessibilityLabel("Mood \(entry.mood)")
                }
                Spacer()
                Menu {
                    Button("Edit", action: onEdit)
                    if !photos.isEmpty {
                        Button("Show the Day’s Photos") { actions()?.journalShowDay(day) }
                        Button("Play the Day as a Slideshow") { actions()?.journalPlayDay(day) }
                    }
                    Divider()
                    Button("Delete Entry", role: .destructive) { actions()?.journalSave("", mood: "", for: day) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Edit, play or delete")
                .accessibilityLabel("Entry actions")
            }
            if !photos.isEmpty {
                DayCollage(ids: photos, library: library)
                    .onTapGesture { actions()?.journalShowDay(day) }
                    .help("Show the day’s photos")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { actions()?.journalShowDay(day) }
            }
            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .contextMenu {
            Button("Edit", action: onEdit)
            if !photos.isEmpty {
                Button("Show the Day’s Photos") { actions()?.journalShowDay(day) }
                Button("Play the Day as a Slideshow") { actions()?.journalPlayDay(day) }
            }
            Divider()
            Button("Delete Entry") { actions()?.journalSave("", mood: "", for: day) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(formatting.longDay(day))
    }
}

/// Up to five of a day's photos: one large, the rest small beside it, with a count of any more on the last.
struct DayCollage: View {
    let ids: [PhotoID]
    let library: LibraryController

    var body: some View {
        let shown = Array(ids.prefix(5))
        let more = ids.count - shown.count
        HStack(spacing: 4) {
            if let first = shown.first {
                PhotoTile(id: first, library: library, pixels: CGSize(width: 900, height: 600))
                    .frame(maxWidth: .infinity)
            }
            if shown.count > 1 {
                column(Array(shown[1..<min(3, shown.count)]), more: shown.count <= 3 ? more : 0)
            }
            if shown.count > 3 {
                column(Array(shown[3...]), more: more)
            }
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let counts = library.snapshot.counts(of: ids)
        return library.formatting.count(photos: counts.photos, videos: counts.videos)
    }

    /// A column of small photos; the last one says how many more there are.
    private func column(_ ids: [PhotoID], more: Int) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                PhotoTile(id: id, library: library, pixels: CGSize(width: 400, height: 300))
                    .overlay {
                        if more > 0, index == ids.count - 1 {
                            Text("+\(more)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.4))
                        }
                    }
            }
        }
        .frame(width: 160)
    }
}

/// One photo, cropped to fill its space.
struct PhotoTile: View {
    let id: PhotoID
    let library: LibraryController
    let pixels: CGSize
    @State private var image: CGImage?
    @State private var request: ImageRequest?

    var body: some View {
        Color(nsColor: Theme.placeholder)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .onAppear {
                guard image == nil else { return }
                request = library.source.requestImage(id, pixels: pixels, fit: false) { image, _ in
                    if let image { self.image = image }
                }
            }
            .onDisappear {
                request?.cancel()
                request = nil
            }
    }
}
