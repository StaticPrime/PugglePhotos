import SwiftUI

/// The Updates section of PugglePhotos ▸ Settings… (⌘,): Automatic Updates, and the version this is.
struct UpdateSettingsSection: View {
    /// Kept where the update check reads it: in debug runs on the sample library, with that library's settings.
    @AppStorage(UpdateController.automaticUpdatesKey, store: UpdateController.defaults) private var automaticUpdates = true
    private let capability = UpdateController.shared.capability

    var body: some View {
        Section {
            switch capability {
            case .appStore:
                Text("The App Store keeps PugglePhotos up to date. When it has a new version, a banner at the top of the window says so.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .none(reason):
                automaticToggle
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .updatesItself:
                automaticToggle
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(AboutView.version)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var automaticToggle: some View {
        Toggle(isOn: $automaticUpdates) {
            Text("Automatic Updates")
            Text("When PugglePhotos opens, it checks for a new version. With Automatic Updates on, it downloads the new version and installs it, then opens again. With it off, a banner at the top of the window says when a new version is available.")
        }
    }
}
