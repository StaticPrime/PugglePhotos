import AppKit
import ServiceManagement
import UserNotifications
import PugglePhotosKit

/// Posts memory notifications and reports clicks on them.
protocol MemoryNotificationCenter: AnyObject {
    /// Asks the person, the first time, whether PugglePhotos may show notifications.
    func authorize(_ completion: @escaping @MainActor (Bool) -> Void)
    /// Replaces every memory notification waiting to be shown with these. `images` are picture files to show with
    /// them, by day.
    func schedule(_ notifications: [MemoryNotification], images: [CivilDay: URL])
    /// Shows a notification now.
    func show(_ notification: MemoryNotification, image: URL?)
    /// Called with the memory a clicked notification is about.
    var onOpen: ((_ memoryID: String) -> Void)? { get set }
}

/// Opens PugglePhotos when the person logs in, or stops.
protocol LoginItemService: AnyObject {
    var isEnabled: Bool { get }
    /// The person needs to allow it in System Settings ▸ General ▸ Login Items.
    var needsApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func openLoginItemsSettings()
}

/// The system's notification center.
final class SystemNotificationCenter: NSObject, MemoryNotificationCenter, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    static let threadIdentifier = "memories"

    override init() {
        super.init()
        center.delegate = self
    }

    func authorize(_ completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            completion(granted)
        }
    }

    func schedule(_ notifications: [MemoryNotification], images: [CivilDay: URL]) {
        let requests = notifications.map { request($0, image: images[$0.day], trigger: trigger(for: $0)) }
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("memory-") })
            for request in requests { try? await center.add(request.request) }
        }
    }

    func show(_ notification: MemoryNotification, image: URL?) {
        let request = request(notification, image: image, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request.request) }
    }

    private nonisolated struct SendableRequest: @unchecked Sendable { let request: UNNotificationRequest }

    private func trigger(for notification: MemoryNotification) -> UNNotificationTrigger {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notification.date)
        components.second = 0
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private func request(_ notification: MemoryNotification, image: URL?, trigger: UNNotificationTrigger?) -> SendableRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = Self.threadIdentifier
        content.userInfo = ["memory": notification.memoryID]
        if let image, let attachment = try? UNNotificationAttachment(identifier: "photo", url: image, options: nil) {
            content.attachments = [attachment]
        }
        return SendableRequest(request: UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let memory = response.notification.request.content.userInfo["memory"] as? String
        Task { @MainActor in
            if let memory { self.onOpen?(memory) }
        }
        completionHandler()
    }

    /// Shows memory notifications even while PugglePhotos is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// The app itself as a login item.
final class SystemLoginItem: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Whether this launch is macOS opening PugglePhotos at login, read from the event that launched it.
enum LaunchReason {
    static func isLoginLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
