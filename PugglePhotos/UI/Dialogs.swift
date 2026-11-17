import AppKit
import PugglePhotosKit
import SwiftUI

/// Settings shared by every window.
enum Preferences {
    static let askBeforeChangingDatesKey = "AskBeforeChangingDates"
    static let showsCalendarKey = "ShowsCalendar"
    static let showsBadgesKey = "ShowsBadges"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [askBeforeChangingDatesKey: true, showsCalendarKey: true, showsBadgesKey: true])
    }

    static var askBeforeChangingDates: Bool { UserDefaults.standard.bool(forKey: askBeforeChangingDatesKey) }
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

struct SettingsView: View {
    @AppStorage(Preferences.askBeforeChangingDatesKey) private var askBeforeChangingDates = true
    @AppStorage(Preferences.showsCalendarKey) private var showsCalendar = true
    @AppStorage(Preferences.showsBadgesKey) private var showsBadges = true

    var body: some View {
        Form {
            Section {
                Toggle("Ask before changing dates when photos are dropped", isOn: $askBeforeChangingDates)
                Toggle("Show the calendar in the sidebar", isOn: $showsCalendar)
                Toggle("Show favorites, labels and notes on thumbnails", isOn: $showsBadges)
            } footer: {
                Text("Albums, labels, captions and notes are kept on this Mac. Dates and favorites are changed in your Photos library, so they’re right everywhere you see your photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        if controller.window?.isVisible != true { controller.window?.center() }
        controller.showWindow(nil)
    }

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "PugglePhotos Settings"
        window.styleMask = [.titled, .closable]
        window.isRestorable = false
        window.setContentSize(host.view.fittingSize)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: Keyboard shortcuts

struct ShortcutsView: View {
    let onClose: () -> Void

    private let groups: [(String, [(String, String)])] = [
        ("Browsing", [
            ("Open the selected photo", "Return or Space"),
            ("Back to the photos", "Esc or ⌘["),
            ("Previous or next photo in the viewer", "← or →"),
            ("Gallery or list", "⌘1 or ⌘2"),
            ("All Albums", "⌘3"),
            ("Bigger or smaller thumbnails", "⌘+ or ⌘−"),
            ("Search", "⌘F"),
            ("Show or hide the sidebar", "⌃⌘S"),
            ("Show or hide the info panel", "⌘I"),
            ("Library, Favorites, Videos, Recently Added", "⌥⌘1 … ⌥⌘4"),
            ("Go to today", "⌘T"),
        ]),
        ("Organizing", [
            ("New album", "⌘N"),
            ("New album with the selection", "⇧⌘N"),
            ("New label", "⌥⌘N"),
            ("Favorite", "."),
            ("Put on or take off the first nine labels", "⌃1 … ⌃9"),
            ("Remove from the album", "Delete"),
            ("Change date and time", "⇧⌘D"),
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
                Text("A cozy home for your photo library and the memories in it. PugglePhotos shows the photos and videos already in your Photos library: make albums, add labels, captions and notes, and put photos back on the right day by dragging them there. Your photos never leave your Mac.")
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
