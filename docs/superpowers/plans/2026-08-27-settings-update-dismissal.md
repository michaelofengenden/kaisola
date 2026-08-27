# Settings update dismissal implementation plan

> **For Michael:** Execute with test-driven development. Keep Sparkle configuration, signatures, and appcast publication unchanged; make every install route share one app-global modal safety gate.

**Goal:** A Check Now action started inside workspace Settings waits for that sheet to dismiss. Restart and Update waits until every Kaisola window is free of sheets, and remains retryable until Sparkle's Apple quit event actually reaches Kaisola's application delegate.

**Evidence:** Unified logs from the installed 0.1.140-to-0.1.141 attempt show `App termination blocked by modal sheet` at 2026-08-27 14:03:17.806. After the sheet escaped, the 14:03:29 retry reached `applicationShouldTerminate`, Kaisola completed its bounded drain, terminated, and relaunched. Both check surfaces already call the same `NativeUpdateController`.

**Architecture:** Add a one-shot workspace-sheet coordinator that records either a check or install request, asks that sheet to dismiss, and forwards the request from SwiftUI's `.sheet(..., onDismiss:)` callback. Make `UpdateCenter` the final app-global authority for installation. It retains Sparkle's documented repeatable immediate-install closure while any `NSApp.modalWindow` or app-window `attachedSheet` exists, polls with one bounded main-actor callback, and requires two consecutive clear probes before each invocation. Sparkle queues the real installer work after the closure returns, so the closure stays retained and a single watchdog can invoke it again if a later sheet prevents the Apple quit event from reaching `applicationShouldTerminate`. The application delegate acknowledges that boundary, invalidates the watchdog, ends attached sheets, performs Kaisola's bounded teardown, and ends sheets again before its prepared final quit.

**Files:**

- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Settings/SettingsView.swift`
- Modify: `native/KaisolaMac/Kaisola/App/KaisolaMacAppDelegate.swift`
- Modify: `native/KaisolaMac/Kaisola/Updates/UpdateCenter.swift`
- Modify: `native/KaisolaMac/KaisolaTests/NativeUpdateConfigurationTests.swift`

## Task 1: Prove the modal lifecycle contract

1. Add failing coordinator tests for Check Now and Restart and Update. Each test records event order and proves the update closure is not invoked when requested, is invoked only after dismissal, and cannot run twice from duplicate dismissal callbacks.
2. Run `NativeUpdateConfigurationTests` and confirm the new tests fail for the missing deferral behavior.
3. Implement the minimum one-shot coordinator in `RootShellView.swift`.
4. Run the focused tests green.

## Task 2: Route both sheet update actions through dismissal

1. Give `SettingsView` an injected install action alongside its existing check action. The standalone Settings window injects `UpdateCenter.shared.installAndRelaunch` directly.
2. In `RootShellView`, queue sheet Check Now and Restart and Update requests, set `showSettings = false`, and perform the queued action only from the sheet's `onDismiss` callback.
3. Preserve the pending-update guard, active-turn warning, updater availability, and all app-menu/command-palette paths.
4. Run `NativeUpdateConfigurationTests`, `NativeUpdateCheckRaceTests`, and the changed-file test selector. Run `git diff --check`.
5. Keep this change uncommitted until the app-global install gate and review findings are incorporated.

## Task 3: Gate installation across every app window

1. Add deterministic failing tests for two simultaneous window blockers, a replacement blocker appearing between clear probes, a modal appearing after the first Sparkle invocation, repeated restart requests, termination-delegate acknowledgement, clearing a deferred update, replacing the ready Sparkle closure while waiting, and stale callbacks after installation. Add AppKit-backed probe and sheet-cleanup tests using real `NSWindow.beginSheet` state without launching or terminating the installed app.
2. Run `KAISOLA_NATIVE_DERIVED_DATA=/Users/michaelofengenden/Library/Developer/Xcode/DerivedData/KaisolaMac-almkjywkkvzvyddgvqosfhsfbaqv npm run native:test:focus -- NativeUpdateConfigurationTests` and confirm failures are the premature install behavior.
3. Add injectable modal-probe and scheduling hooks to `UpdateCenter`. Keep one monotonic request ticket and one scheduled callback. A blocked probe schedules a 50 ms recheck. The first clear probe schedules a next-main-turn confirmation. A second clear probe changes the visible phase to installing and invokes Sparkle's handler.
4. Keep the handler and one one-second watchdog while waiting for the application delegate acknowledgement. A late modal returns the watchdog to the same two-clear-probe path; a clear retry invokes Sparkle's handler again, which Sparkle 2.9.2 explicitly supports after cancelled termination. `clear()` and the delegate acknowledgement must invalidate queued callbacks. Replacement ready state while waiting must preserve the user's original install request while using the newest closure.
5. At the start of `applicationShouldTerminate`, acknowledge the install request and end every attached sheet. Route the prepared final quit through a second coordinator: end sheets, abort an active AppKit `runModal` loop, wait for `modalWindow` to unwind, recheck all modal boundaries, and call `NSApp.terminate` only on a clear main-loop turn. Cover this with an injected deterministic test and a real `runModal(for:)` lifecycle test, matching the modal API used throughout Kaisola production source.
6. Run `KAISOLA_NATIVE_DERIVED_DATA=/Users/michaelofengenden/Library/Developer/Xcode/DerivedData/KaisolaMac-almkjywkkvzvyddgvqosfhsfbaqv npm run native:test:focus -- NativeUpdateConfigurationTests NativeUpdateCheckRaceTests`.

## Task 4: Verify and review

1. Run the changed-file selector for all modified Swift and test files, `npm run test:node`, and the full native XCTest suite at the integration checkpoint. Run `git diff --check`.
2. Use only an isolated app fixture for any process-level event-order check. Never replace or quit the live `/Applications/Kaisola.app` process.
3. Request independent code review, address confirmed findings, and rerun focused and changed-file verification.
4. Commit as `fix(updates): wait for modal sheets before installing`, push, and open a PR. Do not publish a tag or replace the installed app until the live ACP/PTY/agent processes are no longer at risk.
