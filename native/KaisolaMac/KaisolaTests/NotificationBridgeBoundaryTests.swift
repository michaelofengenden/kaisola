import Foundation
import UserNotifications
import XCTest
@testable import Kaisola

/// `UNUserNotificationCenter.current()` traps — silently, with EXC_BREAKPOINT and
/// no Swift-level message — in any process without a live notification session.
/// `NotificationBridge` owns the one guarded chokepoint that keeps unbundled,
/// XCTest, and headless visual-fixture processes away from it.
///
/// v1.1.0 regressed by adding a second call site: `SettingsView` queried
/// `UNUserNotificationCenter.current()` directly from `onAppear`, so the
/// native-visual `settings` fixture became the first fixture process ever to
/// reach the notification daemon and trapped at launch (exit 133) while all
/// twenty non-Settings surfaces passed. These tests pin the boundary that
/// prevents a third call site from doing it again.
@MainActor
final class NotificationBridgeBoundaryTests: XCTestCase {
    private func nativeSourceFiles() throws -> [URL] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kaisola", isDirectory: true)
        return try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )?.allObjects as? [URL]
        ).filter { $0.pathExtension == "swift" }
    }

    /// Prose may discuss the boundary; only code may not cross it.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The chokepoint is only a chokepoint while it is the sole call site.
    func testOnlyNotificationBridgeReachesUserNotificationsDirectly() throws {
        let files = try nativeSourceFiles()
        XCTAssertFalse(files.isEmpty, "Source enumeration found no Swift files")

        var offenders: [String] = []
        for file in files where file.lastPathComponent != "NotificationBridge.swift" {
            let source = strippingComments(try String(contentsOf: file, encoding: .utf8))
            if source.contains("UNUserNotificationCenter") || source.contains("import UserNotifications") {
                offenders.append(file.lastPathComponent)
            }
        }

        XCTAssertEqual(
            offenders.sorted(),
            [],
            """
            UserNotifications must be reached only through NotificationBridge's \
            guarded `center` chokepoint. Direct access traps (exit 133) in the \
            headless visual-QA fixture and the unbundled test host.
            """
        )
    }

    /// The gate must exclude the visual fixture, not just unbundled/XCTest
    /// processes: the fixture is a signed, bundled app that clears both of the
    /// original conditions yet has no notification session on the CI runner.
    func testVisualFixtureIsRecognizedFromItsLaunchEnvironment() {
        XCTAssertEqual(
            ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
            NotificationBridge.isRunningVisualFixture,
            "Fixture detection must match the env var the capture harness sets"
        )
    }

    /// Settings mounts inside the test host, which the chokepoint excludes, so
    /// the state resolves without ever constructing a notification center.
    func testAuthorizationStateIsUnknownWhenTheChokepointIsClosed() async {
        XCTAssertTrue(
            NotificationBridge.isRunningUnderXCTest,
            "Precondition: these tests run in the XCTest host"
        )
        let state = await NotificationBridge.shared.authorizationState()
        XCTAssertEqual(state, .unknown)
    }

    // MARK: - Status mapping

    /// `.ephemeral` is App Clips only and cannot be constructed on macOS, so the
    /// two statuses macOS can actually report as deliverable are pinned here.
    func testAuthorizationStateMapsEveryDeliverableStatusToAllowed() {
        XCTAssertEqual(NotificationAuthorizationState(.authorized), .allowed)
        XCTAssertEqual(NotificationAuthorizationState(.provisional), .allowed)
    }

    func testAuthorizationStateMapsBlockingStatuses() {
        XCTAssertEqual(NotificationAuthorizationState(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationAuthorizationState(.denied), .denied)
    }
}
