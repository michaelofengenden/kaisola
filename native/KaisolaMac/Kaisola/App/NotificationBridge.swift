import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when the user clicks a Kaisola system notification. `userInfo`
    /// carries the surface id under `NotificationBridge.targetIDKey`; the shell
    /// observes this and jumps to the originating chat/terminal.
    static let kaisolaAttentionJump = Notification.Name("kaisolaAttentionJump")
}

/// Bridges the needs-you inbox to macOS UserNotifications. When a background
/// event lands (permission ask, finished turn, agent response) while Kaisola is
/// not the frontmost app, it posts a system notification; clicking that
/// notification reactivates Kaisola and jumps to the surface. This is the native
/// analog of Electron's `new Notification(...)` + `window.focus()` flow.
///
/// `UNUserNotificationCenter.current()` traps in processes with no bundle
/// identifier (unbundled binaries, `swift test`), so every access is guarded
/// behind a bundle-id check *and* a lazily-initialized optional — nothing here
/// touches UserNotifications until `requestAuthorizationIfNeeded()` or a real
/// `post()` actually runs inside the packaged app.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()

    /// `userInfo` key carrying the surface (chat/terminal) id to jump to.
    /// `nonisolated` so the `nonisolated` delegate callbacks can read it.
    nonisolated static let targetIDKey = "targetID"

    /// One notification category per attention kind, so future actionable
    /// buttons can be registered per kind without touching call sites.
    enum Category: String {
        case permission = "kaisola.attention.permission"
        case turnCompleted = "kaisola.attention.turnCompleted"
        case sessionResponded = "kaisola.attention.sessionResponded"

        init(_ kind: AttentionCenter.Kind) {
            switch kind {
            case .permission: self = .permission
            case .turnCompleted: self = .turnCompleted
            case .sessionResponded: self = .sessionResponded
            }
        }
    }

    /// A resolved post() call, captured for tests via `postHook`.
    struct PostRequest: Equatable {
        let identifier: String
        let categoryID: String
        let title: String
        let body: String
    }

    /// Test seam: when set, `post()` hands the resolved request here and never
    /// touches UserNotifications. Production leaves this nil (the real UN path
    /// runs). Only ever invoked from `post()`, so it stays main-actor isolated.
    var postHook: (@MainActor (PostRequest) -> Void)?

    /// Test seam for the "background only" gate. Production reads the live app
    /// state; the gate fires only when this returns `false` — matching the
    /// `NSApp?.isActive == false` contract exactly (nil ⇒ not eligible).
    var appIsActiveProvider: @MainActor () -> Bool? = { NSApp?.isActive }

    /// Whether authorization was granted (informational; set from the async
    /// request callback). Not required for provisional delivery.
    private(set) var authorizationGranted = false

    private let defaults: UserDefaults
    private var didRequestAuthorization = false

    private enum Keys {
        static let enabled = "nativeNotificationsEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Whether background needs-you moments post system notifications.
    /// Persisted in UserDefaults; defaults to on.
    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// True when this process is an XCTest host. The unit-test host launches the
    /// full app delegate, but its process is unsigned (CODE_SIGNING_ALLOWED=NO)
    /// and runs on a headless CI runner with no notification session — where
    /// `UNUserNotificationCenter.current()` / `requestAuthorization` hangs the
    /// main thread until the test bootstrap watchdog kills it. Detected via the
    /// env var XCTest sets in its host.
    static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    /// The notification center, resolved lazily and only when the process is
    /// bundled and not a test host. `UNUserNotificationCenter.current()` traps in
    /// an unbundled process and is headless-hostile under XCTest, so both are
    /// gated here — the one chokepoint every notification path funnels through.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil, !Self.isRunningUnderXCTest else { return nil }
        return UNUserNotificationCenter.current()
    }()

    // MARK: - Authorization

    /// Ask once for provisional + alert + sound and wire the delegate. Provisional
    /// authorization lets the first notifications deliver quietly without an
    /// upfront prompt (Electron never prompts either). Safe to call on every
    /// launch — it no-ops after the first, and no-ops entirely when unbundled.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        guard let center else { return }
        center.delegate = self
        // The completion handler MUST be @Sendable (nonisolated). Without it the
        // closure inherits this @MainActor type's isolation, but
        // UNUserNotificationCenter invokes it on a background queue — Swift's
        // executor-isolation check then traps (EXC_BREAKPOINT /
        // dispatch_assert_queue) and the app dies at launch. @Sendable de-isolates
        // it; the main-actor state is set via a hop. (The async API can't be used
        // here: awaiting `center.requestAuthorization` would send the non-Sendable
        // `center` across the isolation boundary — a data-race error.)
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { @Sendable granted, error in
            if let error {
                NSLog("Kaisola notifications: authorization request failed: \(error.localizedDescription)")
            }
            Task { @MainActor in NotificationBridge.shared.authorizationGranted = granted }
        }
    }

    // MARK: - Posting

    /// Post a system notification for a background needs-you moment. No-ops when
    /// notifications are disabled or Kaisola is frontmost. The identifier is the
    /// `targetID`, so a newer event for the same surface replaces the older
    /// banner. Never throws — a delivery failure is logged and dropped.
    func post(kind: AttentionCenter.Kind, title: String, detail: String, targetID: String) {
        guard enabled else { return }
        guard appIsActiveProvider() == false else { return }

        let request = PostRequest(
            identifier: targetID,
            categoryID: Category(kind).rawValue,
            title: title,
            body: detail
        )

        if let postHook {
            postHook(request)
            return
        }

        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        content.categoryIdentifier = request.categoryID
        content.userInfo = [Self.targetIDKey: targetID]

        let notificationRequest = UNNotificationRequest(
            identifier: targetID,   // repeats for the same surface replace in place
            content: content,
            trigger: nil            // deliver immediately
        )
        // @Sendable makes this completion nonisolated: without it the closure
        // inherits this type's @MainActor isolation, but the framework calls it
        // on a background queue — the same executor-isolation trap that crashed
        // requestAuthorization. The body only logs, so it needs no actor.
        center.add(notificationRequest) { @Sendable error in
            if let error {
                NSLog("Kaisola notifications: post failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// A click reactivates Kaisola and asks the shell to jump to the surface.
    /// `nonisolated` because the delegate protocol isn't main-actor annotated;
    /// only a `Sendable` `targetID` crosses into the main-actor hop.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let targetID = response.notification.request.content.userInfo[NotificationBridge.targetIDKey] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let targetID {
                NotificationCenter.default.post(
                    name: .kaisolaAttentionJump,
                    object: nil,
                    userInfo: [NotificationBridge.targetIDKey: targetID]
                )
            }
        }
        completionHandler()
    }

    /// Never present a banner while Kaisola is frontmost — the inbox and dock
    /// badge already cover foreground moments.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
