# R2-C: Settings Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grouped, consistent settings; an update row that tells the truth; usage stats that refresh themselves.

**Architecture:** Restructure `SettingsView.swift` into a shell + per-pane files; give `UpdateCenter` two independent published axes; add a background refresh loop to `UsageCenter` keyed by context. Spec §3 (rev 3).

**Tech Stack:** Swift/SwiftUI, Sparkle 2.9.2, XCTest.

## Global Constraints

- `checkStatus` and `pendingUpdate` are separate axes; clearing check state must never discard a handed-over install closure.
- Usage loop: 5-minute cadence, app-active only, frontmost workspace only, non-forced (TTL coalesces), re-armed on didBecomeActive/didWake.
- Published usage becomes keyed by context; each window reads its own workspace's entry.
- Both settings entry points (window + sheet) construct with identical capability.

---

### Task 1: Grouped navigation + sizing + enum selection
Modify `Features/Settings/SettingsView.swift`: `SettingsSection` becomes internal, gains `group: SettingsGroup` (`app, workspace, agents, device` with titles App/Workspace/Agents/Device); sidebar renders group headers (caption, secondary, 11pt, 8pt top spacing) with sections beneath; selection binding uses the enum end-to-end (delegate/sheet APIs change from `String` to `SettingsSection`, with a `SettingsSection(rawValue:)` shim where deep links pass strings). `KaisolaMacAppDelegate` window: `contentRect` 1100×800, `minSize` 820×560 (match view). Uniform `.scrollContentBackground(.hidden)` applied once in the shell around `settingsContent`. Tests: every section has a group; groups render in order App, Workspace, Agents, Device; string shim round-trips. Commit `feat(settings): grouped navigation and honest window sizing`.

### Task 2: File split + idiom unification
Create `Features/Settings/GeneralSettingsTab.swift`, `UpdatesSettingsTab.swift`, `TerminalSettingsTab.swift`, `GuardrailsSettingsTab.swift` (moving `GuardrailsSettings`, `SensitiveGlobPolicy` + converting Guardrails and Agents panes from `Form` to `SettingsCard`/`SettingsRow`). `SettingsView.swift` keeps: shell, navigation, `SettingsSection`, the card/row primitives, routing switch. No behavior change; existing settings tests stay green. Run full settings-related suites. Commit `refactor(settings): per-pane files, one idiom`.

### Task 3: Sheet parity
Modify `RootShellView.swift` `InAppSettingsSheet` (~3796): pass `updateDetail` and `interruptibleTurnCount` (source them the same way the delegate window path does — `UpdateCenter`/model); `Check Now` disabled when `availability.canCheck == false` in both paths. Test: a capability-parity assertion constructing both entry points' argument sets from the same fixtures. Commit `fix(settings): the sheet is a full settings surface`.

### Task 4: UpdateCenter two-axis state machine
Modify `Updates/UpdateCenter.swift`, `Updates/NativeUpdateController.swift`, `Features/Settings/UpdatesSettingsTab.swift`.

```swift
enum UpdateCheckStatus: Equatable {
    case idle(lastChecked: Date?)
    case checking(generation: UInt64)
    case upToDate(at: Date)
    case failed(reason: String, at: Date)
}
// UpdateCenter publishes: checkStatus (above) AND pendingUpdate (existing) independently.
```
Sparkle delegate transitions (enumerated): `updater(_:didFinishUpdateCycleFor:error:)` → upToDate (nil error, no update) / failed(reason) ; `updater(_:didFindValidUpdate:)` → checking stays until download outcome; `markReady` → pendingUpdate set (checkStatus → idle(lastChecked: now)); user-driver session end (`standardUserDriverWillFinishUpdateSession`) → clears `sparkleIsPresentingUpdate` but NEVER `pendingUpdate` (the closure survives until `installAndRelaunch` or a new check finds a different version); `checkForUpdates()` bumps the generation — a completion carrying a stale generation is dropped. Row UI: always shows `CFBundleShortVersionString` + last-checked relative time; spinner while checking; inline failure text; Restart-and-Update only with pendingUpdate. `sparkleIsPresentingUpdate` hides Kaisola's Check Now while Sparkle's window is up. Tests: every transition above; stale-generation drop; pending survives session end. Commit `feat(updates): the update row tells the truth`.

### Task 5: UsageCenter background loop + keyed publishing
Modify `App/UsageCenter.swift`: published `planUsage` becomes `planUsageByContext: [String: [ProviderPlanUsage]]` (+ a compatibility accessor for the frontmost context so existing consumers migrate incrementally); `startBackgroundRefresh(activeWorkspace: @escaping () -> URL?)` — a 5-minute `Task` loop (template: remembered-sessions loop at `KaisolaMacAppDelegate.swift:2221`): only while `NSApp.isActive`, non-forced, frontmost workspace; observers re-arm on `didBecomeActiveNotification` + `didWakeNotification`; `readSingleProviderPlanUsage`'s `Thread.sleep` poll (~1358) becomes `withTaskCancellationHandler` + `terminationHandler` continuation, stdout/stderr drained concurrently before wait. Footer chip + Usage pane + onboarding read their window's context entry. Snapshot writes debounce 10 s. Tests: injected-clock loop (ticks active-only, TTL coalesces, cancellation mid-fetch kills the process), keyed publish (two contexts don't clobber), continuation path decodes fixture output. Commit `feat(usage): stats refresh themselves, keyed by workspace`.

### Task 6: Full verification
Full `KaisolaTests`; manual pass over every settings pane in window + sheet; update check against the live appcast; usage numbers refresh without touching Settings. Commit `test(settings): overhaul verified`.


---

## Status (2026-08-07 morning)

Done: grouped navigation (Task 1 core), window sizing fix, sheet capability parity (Task 3), the two-axis update state machine with generation fencing and the honest row (Task 4), background usage refresh + async process wait (Task 5 core). Deferred to the next round: the per-pane file split (Task 2, pure refactor), Form→card conversion for Agents/Guardrails, per-context published usage (the existing context-key guard prevents cross-workspace bleed on write; a focus change can briefly show the previous workspace until the next tick).
