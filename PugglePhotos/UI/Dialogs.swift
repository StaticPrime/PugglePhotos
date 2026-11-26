import AppKit
import Observation
import PugglePhotosKit
import SwiftUI

/// Settings shared by every window.
enum Preferences {
    static let askBeforeChangingDatesKey = "AskBeforeChangingDates"
    static let showsCalendarKey = "ShowsCalendar"
    static let showsBadgesKey = "ShowsBadges"
    /// Whether a click on a photo turns it over to show its back.
    static let flipsOnClickKey = "FlipsPhotosOnClick"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [askBeforeChangingDatesKey: true, showsCalendarKey: true, showsBadgesKey: true,
                                                  flipsOnClickKey: true, Handwriting.key: Handwriting.defaultFamily])
    }

    static var askBeforeChangingDates: Bool { UserDefaults.standard.bool(forKey: askBeforeChangingDatesKey) }
    static var flipsOnClick: Bool { UserDefaults.standard.bool(forKey: flipsOnClickKey) }
}

// MARK: Moving photos in time

/// Asks before photos dropped on a day (or between two photos) get new dates.
struct RedateConfirmView: View {
    enum Kind {
        /// Dropped on a day: they keep their times of day, or all get one time.
        case day(String)
        /// Dropped between two photos: they take a moment between them.
        case between(String)
    }

    let count: Int
    let kind: Kind
    let onCancel: () -> Void
    let onConfirm: (Redate.TimeChoice) -> Void
    @State private var setsTime = false
    @State private var time = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    @AppStorage(Preferences.askBeforeChangingDatesKey) private var ask = true

    private var what: String { count == 1 ? "this photo" : "these \(count) photos" }
    private var one: Bool { count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case let .day(day):
                Text("Move \(what) to \(day)?").font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(one ? "Its date changes in your Photos library too, so it shows in the right place everywhere."
                         : "Their dates change in your Photos library too, so they show in the right place everywhere.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $setsTime) {
                    Text(one ? "Keep its time of day" : "Keep each one’s time of day").tag(false)
                    HStack {
                        Text("Set the time to")
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .disabled(!setsTime)
                    }
                    .tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            case let .between(moment):
                Text("Move \(what) here?").font(.headline)
                Text(one ? "It’ll be dated \(moment), between the photos on either side, and its date changes in your Photos library too."
                         : "They’ll be dated from \(moment), between the photos on either side, and their dates change in your Photos library too.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Don’t ask again", isOn: Binding(get: { !ask }, set: { ask = !$0 }))
                .controlSize(.small)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(one ? "Move Photo" : "Move Photos") {
                    if setsTime {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        onConfirm(.setTime(hour: parts.hour ?? 12, minute: parts.minute ?? 0))
                    } else {
                        onConfirm(.keepTimes)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 330)
    }
}

/// Edit ▸ Change Date and Time: picks a date and time, and how the photos get it.
struct ChangeDateView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case shift, keepTimes, exact
        var id: String { rawValue }

        var title: String {
            switch self {
            case .shift: "Shift them all by the same amount"
            case .keepTimes: "Move to this day, keep their times"
            case .exact: "Give them all this date and time"
            }
        }
    }

    let items: [(id: PhotoID, date: Date)]
    let formatting: Formatting
    let onCancel: () -> Void
    let onChange: ([Redate.Change]) -> Void
    @State private var date: Date
    @State private var mode: Mode

    init(items: [(id: PhotoID, date: Date)], formatting: Formatting, onCancel: @escaping () -> Void,
         onChange: @escaping ([Redate.Change]) -> Void) {
        self.items = items
        self.formatting = formatting
        self.onCancel = onCancel
        self.onChange = onChange
        _date = State(initialValue: items.map(\.date).min() ?? Date())
        _mode = State(initialValue: items.count == 1 ? .exact : .shift)
    }

    private var changes: [Redate.Change] {
        switch mode {
        case .shift: Redate.shift(items, firstTo: date)
        case .keepTimes: Redate.move(items, to: CivilDay(date, in: formatting.timeZone), time: .keepTimes, calendar: formatting.calendar)
        case .exact: Redate.set(items, to: date)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? "Change Date and Time" : "Change the Date and Time of \(items.count) Items").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 200)
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                    if items.count > 1 {
                        Picker("", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                    let preview = changes
                    if let first = preview.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preview.count == 1 ? "New date" : "First").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(formatting.dateAndTime(first.to)).font(.callout)
                            if preview.count > 1, let last = preview.last {
                                Text("Last").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                                Text(formatting.dateAndTime(last.to)).font(.callout)
                            }
                        }
                    }
                }
            }
            Text("The dates change in your Photos library too. Edit ▸ Undo puts them back.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Change") { onChange(changes) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}

// MARK: Labels

/// Makes a label, or changes one: a name, a color and an optional emoji.
struct LabelEditorView: View {
    let isNew: Bool
    let onCancel: () -> Void
    let onSave: (String, LabelColor, String) -> Void
    @State private var name: String
    @State private var color: LabelColor
    @State private var emoji: String

    init(label: PhotoLabel?, suggestedName: String, onCancel: @escaping () -> Void, onSave: @escaping (String, LabelColor, String) -> Void) {
        isNew = label == nil
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: label?.name ?? suggestedName)
        _color = State(initialValue: label?.color ?? .pink)
        _emoji = State(initialValue: label?.emoji ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Label" : "Edit Label").font(.headline)
            HStack(spacing: 8) {
                TextField("Emoji", text: $emoji)
                    .frame(width: 54)
                    .onChange(of: emoji) { _, new in if new.count > 1 { emoji = String(new.suffix(1)) } }
                    .accessibilityLabel("Emoji")
                TextField("Name", text: $name)
                    .accessibilityLabel("Label name")
            }
            HStack(spacing: 8) {
                ForEach(LabelColor.allCases, id: \.self) { option in
                    Button {
                        color = option
                    } label: {
                        Circle()
                            .fill(Color(option))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary, lineWidth: color == option ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(color == option ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), color, emoji)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 330)
    }
}

// MARK: Settings

/// What Settings shows that isn't kept in PugglePhotos' settings: the song picked for slideshows.
@Observable
final class SettingsModel {
    var songName: String? = SlideshowMusic.songName

    func refresh() {
        songName = SlideshowMusic.songName
    }

    func chooseSong() {
        SlideshowMusic.chooseSong { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @AppStorage(Preferences.askBeforeChangingDatesKey) private var askBeforeChangingDates = true
    @AppStorage(Preferences.showsCalendarKey) private var showsCalendar = true
    @AppStorage(Preferences.showsBadgesKey) private var showsBadges = true
    @AppStorage(MemoryPreferences.notifyKey) private var notifies = true
    @AppStorage(MemoryPreferences.timeKey) private var minutes = 9 * 60
    @AppStorage(MemoryPreferences.secondsPerPhotoKey) private var secondsPerPhoto = 4.5
    @AppStorage(MemoryPreferences.musicKey) private var music = SlideshowMusic.Choice.tune.rawValue
    @AppStorage(BookPreferences.alwaysPlayKey) private var booksAlwaysPlay = false
    @AppStorage(BookPreferences.soundKey) private var booksPlaySound = true
    @AppStorage(Handwriting.key) private var handwriting = Handwriting.defaultFamily
    @AppStorage(Preferences.flipsOnClickKey) private var flipsOnClick = true

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
                set: { minutes = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) })
    }

    var body: some View {
        Form {
            Section("Memories") {
                Toggle("Tell me about photos from this day in earlier years", isOn: $notifies)
                DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
                    .disabled(!notifies)
            }
            Section("Slideshows") {
                Picker("Music", selection: $music) {
                    ForEach(SlideshowMusic.Choice.allCases) { choice in
                        Text(choice == .song ? (model.songName.map { "“\($0)”" } ?? choice.title) : choice.title).tag(choice.rawValue)
                    }
                }
                if music == SlideshowMusic.Choice.song.rawValue || model.songName == nil {
                    HStack {
                        Text(model.songName.map { "Your song: \($0)" } ?? "Pick a song from your Mac to play under slideshows.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Song…") { model.chooseSong() }
                    }
                }
                HStack {
                    Text("Each photo shows for")
                    Slider(value: $secondsPerPhoto, in: 2...8, step: 0.5)
                    Text(String(format: "%.1f seconds", secondsPerPhoto)).monospacedDigit().frame(width: 84, alignment: .trailing)
                }
            }
            Section {
                HandwritingPicker(family: $handwriting)
                Toggle("Turn a photo over to read its back when it’s clicked", isOn: $flipsOnClick)
            } header: {
                Text("Handwriting")
            } footer: {
                Text("Notes on the backs of photos, and everything written in photo books, are in this handwriting. Each book can have its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Photo Books") {
                Toggle("Play videos with sound when the pointer is over them", isOn: $booksPlaySound)
                Toggle("Always play the videos on the open pages, without sound", isOn: $booksAlwaysPlay)
            }
            Section {
                Toggle("Ask before changing dates when photos are dropped", isOn: $askBeforeChangingDates)
                Toggle("Show the calendar in the sidebar", isOn: $showsCalendar)
                Toggle("Show favorites, labels and notes on thumbnails", isOn: $showsBadges)
            } header: {
                Text("Photos")
            } footer: {
                Text("Albums are kept in step with your Photos library, and dates and favorites are changed there too, so they’re right everywhere you see your photos. Labels, captions, notes and album stories are kept on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { model.refresh() }
    }
}

final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    private let model: SettingsModel

    static func show(_ model: SettingsModel) {
        let controller = shared ?? SettingsWindowController(model: model)
        shared = controller
        model.refresh()
        if controller.window?.isVisible != true {
            controller.fitScreen()
            controller.window?.center()
        }
        controller.showWindow(nil)
    }

    private init(model: SettingsModel) {
        self.model = model
        let host = NSHostingController(rootView: SettingsView(model: model))
        // The window gives the settings their height (see fitScreen), and they scroll when there's more of them.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "PugglePhotos Settings"
        window.styleMask = [.titled, .closable]
        window.isRestorable = false
        super.init(window: window)
        fitScreen()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// As tall as all the settings, or as the screen has room for: they're taller than a 1080-point screen leaves room
    /// for, so there they scroll.
    private func fitScreen() {
        guard let window else { return }
        let whole = NSHostingView(rootView: SettingsView(model: model).fixedSize(horizontal: false, vertical: true)).fittingSize
        guard let screen = window.screen ?? NSScreen.main else {
            window.setContentSize(whole)
            return
        }
        let room = window.contentRect(forFrameRect: screen.visibleFrame).height - 40
        window.setContentSize(NSSize(width: whole.width, height: min(whole.height, max(room, 300))))
    }
}

// MARK: Keyboard shortcuts

struct ShortcutsView: View {
    let onClose: () -> Void

    private let groups: [(String, [(String, String)])] = [
        ("Browsing", [
            ("Open the selected photo", "Return or Space"),
            ("Turn a photo over, or back", "Click it again, or Esc"),
            ("Back to the photos", "Esc or ⌘["),
            ("Previous or next photo in the viewer", "← or →"),
            ("Gallery, list or book", "⌘1, ⌘2 or ⌘3"),
            ("All Albums", "⌥⌘5"),
            ("Turn a book's page", "← or →"),
            ("Bigger or smaller thumbnails", "⌘+ or ⌘−"),
            ("Search", "⌘F"),
            ("Show or hide the sidebar", "⌃⌘S"),
            ("Show or hide the info panel", "⌘I"),
            ("Get Info in a window of its own", "⌥⌘I"),
            ("Memories", "⌥⌘0"),
            ("Library, Favorites, Videos, Recently Added", "⌥⌘1 … ⌥⌘4"),
            ("Journal", "⌥⌘6"),
            ("Map", "⌥⌘7"),
            ("Play a slideshow", "⌥⌘P"),
            ("Go to today", "⌘T"),
        ]),
        ("Organizing", [
            ("New album", "⌘N"),
            ("New album with the selection", "⇧⌘N"),
            ("New label", "⌥⌘N"),
            ("Favorite", "."),
            ("Put on or take off the first nine labels", "⌃1 … ⌃9"),
            ("Remove from the album", "Delete"),
            ("Duplicate", "⌘D"),
            ("Delete from the library", "⌘Delete"),
            ("Copy, then paste copies elsewhere", "⌘C, ⌘V"),
            ("Change date and time", "⇧⌘D"),
            ("Write on the back of a photo", "⌥⌘B"),
            ("Write in the journal about the day", "⌘J"),
            ("Save what you wrote", "⌘Return"),
            ("Tilt a photo in a book", "[ or ]"),
            ("Save a book as a PDF, or print it", "⇧⌘E or ⌘P"),
            ("Select all", "⌘A"),
            ("Undo or redo", "⌘Z or ⇧⌘Z"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            HStack(alignment: .top, spacing: 28) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.0).font(.headline)
                        ForEach(group.1, id: \.0) { row in
                            HStack {
                                Text(row.0)
                                Spacer(minLength: 16)
                                Text(row.1).foregroundStyle(.secondary).font(.system(.body, design: .rounded))
                            }
                        }
                    }
                    .frame(width: 330)
                }
            }
            HStack {
                Text("Drag photos onto a day in the calendar or a day’s heading to move them to that day, or between two photos to put them right there.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
    }
}

// MARK: Welcome

/// What the window shows before PugglePhotos may see the library, or while it loads.
struct WelcomeView: View {
    enum State { case ask, loading, denied }

    let state: State
    let onAllow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image("AboutLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 200, height: 200)
                .accessibilityHidden(true)
            switch state {
            case .ask:
                Text("Welcome to PugglePhotos").font(.largeTitle.bold())
                Text("A cozy home for your photo library and the memories in it. PugglePhotos shows the photos and videos already in your Photos library: make albums, add labels, captions and notes, and put photos back on the right day by dragging them there. Your photos stay on your Mac, apart from albums you share.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Button("Show My Photos", action: onAllow)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case .loading:
                ProgressView().controlSize(.large)
                Text("Gathering your photos…").font(.title3).foregroundStyle(.secondary)
            case .denied:
                Text("PugglePhotos can’t see your photos").font(.title.bold())
                Text("To show your photos, PugglePhotos needs permission to use your Photos library. Turn on PugglePhotos in System Settings ▸ Privacy & Security ▸ Photos, then come back.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                Button("Open Privacy Settings", action: onOpenSettings)
                    .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What a view says when it has nothing to show.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.pugglePink.opacity(0.75))
            Text(title).font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
