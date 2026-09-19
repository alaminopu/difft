import AppKit
import UserNotifications
import DifftUI

/// Tells you a run finished when you are not looking at the app.
///
/// A review takes minutes — measured at 9 and 12 on real pull requests — and
/// until now finishing was silent. You either sat watching a spinner or came
/// back later and guessed.
@MainActor
final class RunNotifier {
    static let shared = RunNotifier()

    /// Runs that ended while the app was in the background, cleared when it
    /// comes forward. Drives the Dock badge.
    private(set) var unread = 0
    private var authorization: UNAuthorizationStatus = .notDetermined
    private var observer: Any?

    private init() {}

    /// A plain executable has no bundle to attach notifications to, and asking
    /// `UNUserNotificationCenter` for one traps. `swift run` hits this; the
    /// packaged app does not.
    private var bundled: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunNotifier.shared.clear() }
            }
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in self.authorization = settings.authorizationStatus }
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorization = granted ? .authorized : .denied
            }
        }
    }

    /// - Parameter label: the run that finished — "Reviewing", "Fixing", …
    func runFinished(label: String, pr: Int, title: String, outcome: String) {
        // The Dock badge is set before any gate. macOS silently swallows a
        // notification while permission is undecided or denied, and "you were
        // looking at the window" is not a reason to lose the fact that it
        // finished — it is only a reason not to interrupt with an alert.
        guard !NSApp.isActive else { return }
        unread += 1
        NSApp.dockTile.badgeLabel = String(unread)

        let wanted = UserDefaults.standard.object(forKey: PrefKey.notifyOnRunFinished) as? Bool ?? true
        guard bundled, wanted, authorization == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(label) finished · #\(pr)"
        content.body = "\(outcome)\n\(title)"
        content.sound = .default
        // nil trigger delivers immediately.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clear() {
        guard unread > 0 else { return }
        unread = 0
        NSApp.dockTile.badgeLabel = nil
    }
}
