# Quiet Fleet Sidebar (v2.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the native sidebar's project/session rail with the approved "Quiet fleet" v2.3 design: single-line rows (glyph · auto-title · time-in-state · status dot at the right edge), idle-is-silent 5-state dots, plain-text headers with hover-only chrome, deep 30pt session indent, collapsed-project status rollups, and drag-to-reorder for projects and sessions.

**Architecture:** All new logic lives in NEW files (pure, unit-tested status/rollup/time/glyph helpers + a self-contained `QuietProjectRail` SwiftUI view + a `SessionOrderStore` modeled on `SessionPinStore`). `RootShellView.swift` gets ONE thin integration hunk replacing the section body of `leftTreeLayout`'s project `ForEach`. This is deliberate: the working tree has a large uncommitted third-party fix pass touching `RootShellView`/`AppModel`; we branch from HEAD (`02566d8`) in an isolated worktree and keep the merge conflict surface to a single region.

**Tech Stack:** Swift 5 / SwiftUI (macOS), XCTest, xcodegen (directory-globbed sources — new files under `Kaisola/Features/Sessions/` and `KaisolaTests/` are picked up automatically after `xcodegen generate`).

## Global Constraints

- Branch from HEAD `02566d8` in a worktree (create via superpowers:using-git-worktrees), branch name `feature/quiet-fleet-sidebar`.
- DO NOT modify these Codex-collision files except where a task explicitly says so, and then only the exact hunk shown: `RootShellView.swift` (Task 6 hunk only), `AppModel.swift` (never), `NativeTerminalSurface.swift` (never — bell wiring is deferred to the post-merge task), `NativeSessionStore.swift` (never).
- Commits: conventional style matching repo history (`feat: …`, `fix: …`). **No Co-Authored-By or AI-attribution trailers — ever** (user's standing rule).
- Visual constants: radii/motion via `KaisolaVisualSystem` (`insetRadius = 10`, `hoverDuration = 0.09`, `stateDuration = 0.14`); project hue via `ProjectTint.color(_:) ?? WorkspacePalette.project`. No new hardcoded radii.
- Type scale (from approved spec): header 13 semibold · session title 12.5 regular · time 10.5 monospacedDigit. Session rows inset 30pt. Nothing smaller than 10.5.
- Status colors (light/dark): working olive `#8A9A46`/`#A6B85E`, needs-you amber `#C7862A`/`#E0A046`, done green `#2E9E5B`/`#4FB878`, failed red `#C64B40`/`#E0716A`. Idle/ended draw NO dot (fixed empty 6pt slot keeps times aligned).
- Every dot state must carry an `accessibilityLabel` word; the working pulse must respect `accessibilityReduceMotion`.
- All commands run from the WORKTREE root. Focused tests: `npm run native:test:focus -- <TestClass>`. Regenerate project after adding files: `(cd native/KaisolaMac && xcodegen generate)`.
- Approved visual reference: https://claude.ai/code/artifact/a9944b18-e1f4-40ab-b6e3-99e1bc2d0eca (label quiet-fleet-v2.3-right-edge-dots).

---

### Task 1: Status model — `QuietSessionStatus`

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Sessions/QuietSessionStatus.swift`
- Test: `native/KaisolaMac/KaisolaTests/QuietSessionStatusTests.swift`

**Interfaces:**
- Consumes: `AgentActivity` (`Kaisola/Broker/BrokerModels.swift:107` — `case idle, working, responded(at: Int64)`).
- Produces: `enum QuietSessionStatus: Equatable { case needsYou, working, doneUnseen, failed, idle, ended }` with `static func terminal(activity:exited:hasAttention:respondedAcknowledged:)`, `static func chat(isRunning:isConnected:hasPendingPermission:hasAttention:statusMessage:)`, `static func mesh(stageIsIdle:hasAttention:)`, `var dotColor: Color?`, `var accessibilityWord: String?`, `var isDimmed: Bool`. Later tasks call these exact names.

- [ ] **Step 1: Write the failing test**

```swift
// native/KaisolaMac/KaisolaTests/QuietSessionStatusTests.swift
import XCTest
@testable import Kaisola

final class QuietSessionStatusTests: XCTestCase {
    func testTerminalDerivation() {
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: false, hasAttention: false, respondedAcknowledged: false), .working)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: true, hasAttention: false, respondedAcknowledged: false), .ended)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .responded(at: 5), exited: false, hasAttention: false, respondedAcknowledged: false), .doneUnseen)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .responded(at: 5), exited: false, hasAttention: false, respondedAcknowledged: true), .idle)
        // attention (bell / permission) outranks everything on a live terminal
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: false, hasAttention: true, respondedAcknowledged: false), .needsYou)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .idle, exited: false, hasAttention: false, respondedAcknowledged: false), .idle)
    }

    func testChatDerivation() {
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: true, isConnected: true, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .working)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: true, isConnected: true, hasPendingPermission: true, hasAttention: false, statusMessage: nil), .needsYou)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: false, hasPendingPermission: false, hasAttention: false, statusMessage: "agent exited"), .failed)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: true, hasPendingPermission: false, hasAttention: true, statusMessage: nil), .needsYou)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: true, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .idle)
    }

    func testMeshDerivation() {
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: false, hasAttention: false), .working)
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: true, hasAttention: true), .needsYou)
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: true, hasAttention: false), .idle)
    }

    func testDotPresence() {
        XCTAssertNil(QuietSessionStatus.idle.accessibilityWord)
        XCTAssertNil(QuietSessionStatus.ended.accessibilityWord)
        XCTAssertEqual(QuietSessionStatus.needsYou.accessibilityWord, "needs you")
        XCTAssertEqual(QuietSessionStatus.working.accessibilityWord, "working")
        XCTAssertEqual(QuietSessionStatus.doneUnseen.accessibilityWord, "done")
        XCTAssertEqual(QuietSessionStatus.failed.accessibilityWord, "failed")
        XCTAssertTrue(QuietSessionStatus.ended.isDimmed)
        XCTAssertFalse(QuietSessionStatus.idle.isDimmed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run native:test:focus -- QuietSessionStatusTests`
Expected: build FAILURE — `cannot find 'QuietSessionStatus' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// native/KaisolaMac/Kaisola/Features/Sessions/QuietSessionStatus.swift
import SwiftUI

/// The five-state "Quiet fleet" status grammar. Idle and ended draw no dot;
/// silence is information (spec: quiet-fleet v2.3).
enum QuietSessionStatus: Equatable {
    case needsYou, working, doneUnseen, failed, idle, ended

    static func terminal(activity: AgentActivity, exited: Bool, hasAttention: Bool, respondedAcknowledged: Bool) -> QuietSessionStatus {
        if exited { return .ended }
        if hasAttention { return .needsYou }
        switch activity {
        case .working: return .working
        case .responded: return respondedAcknowledged ? .idle : .doneUnseen
        case .idle: return .idle
        }
    }

    static func chat(isRunning: Bool, isConnected: Bool, hasPendingPermission: Bool, hasAttention: Bool, statusMessage: String?) -> QuietSessionStatus {
        if hasPendingPermission || hasAttention { return .needsYou }
        if !isConnected { return statusMessage == nil ? .ended : .failed }
        return isRunning ? .working : .idle
    }

    static func mesh(stageIsIdle: Bool, hasAttention: Bool) -> QuietSessionStatus {
        if hasAttention { return .needsYou }
        return stageIsIdle ? .idle : .working
    }

    /// nil for idle/ended — no dot is drawn.
    var dotColor: Color? {
        switch self {
        case .working:   return Color(light: 0x8A9A46, dark: 0xA6B85E)
        case .needsYou:  return Color(light: 0xC7862A, dark: 0xE0A046)
        case .doneUnseen: return Color(light: 0x2E9E5B, dark: 0x4FB878)
        case .failed:    return Color(light: 0xC64B40, dark: 0xE0716A)
        case .idle, .ended: return nil
        }
    }

    var accessibilityWord: String? {
        switch self {
        case .needsYou: return "needs you"
        case .working: return "working"
        case .doneUnseen: return "done"
        case .failed: return "failed"
        case .idle, .ended: return nil
        }
    }

    var isDimmed: Bool { self == .ended }
}

private extension Color {
    /// Appearance-adaptive color from packed RGB hex values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run native:test:focus -- QuietSessionStatusTests`
Expected: PASS (4 tests). If the build cannot find the new file, run `(cd native/KaisolaMac && xcodegen generate)` once and retry.

- [ ] **Step 5: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/QuietSessionStatus.swift native/KaisolaMac/KaisolaTests/QuietSessionStatusTests.swift
git commit -m "feat: add quiet-fleet session status model"
```

---

### Task 2: Time-in-state — tracker + label

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Sessions/QuietStatusClock.swift`
- Test: `native/KaisolaMac/KaisolaTests/QuietStatusClockTests.swift`

**Interfaces:**
- Consumes: `QuietSessionStatus` (Task 1).
- Produces: `struct QuietStatusClock` with `mutating func note(id: String, status: QuietSessionStatus, at: Date)` and `func since(id: String) -> Date?`; `enum QuietTimeLabel { static func label(since: Date, now: Date) -> String }`. The rail (Task 5) calls `QuietTimeLabel.label(since:now:)` and holds one `QuietStatusClock` instance.

- [ ] **Step 1: Write the failing test**

```swift
// native/KaisolaMac/KaisolaTests/QuietStatusClockTests.swift
import XCTest
@testable import Kaisola

final class QuietStatusClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLabelBuckets() {
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(30)), "now")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(90)), "1m")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(34 * 60)), "34m")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(2 * 3600 + 300)), "2h")
        XCTAssertEqual(QuietTimeLabel.label(since: t0, now: t0.addingTimeInterval(3 * 86_400)), "3d")
        // clock skew must never render a negative time
        XCTAssertEqual(QuietTimeLabel.label(since: t0.addingTimeInterval(60), now: t0), "now")
    }

    func testClockTracksTransitionsOnly() {
        var clock = QuietStatusClock()
        clock.note(id: "a", status: .working, at: t0)
        clock.note(id: "a", status: .working, at: t0.addingTimeInterval(60)) // same state: no reset
        XCTAssertEqual(clock.since(id: "a"), t0)
        clock.note(id: "a", status: .doneUnseen, at: t0.addingTimeInterval(120)) // transition: reset
        XCTAssertEqual(clock.since(id: "a"), t0.addingTimeInterval(120))
        XCTAssertNil(clock.since(id: "unknown"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run native:test:focus -- QuietStatusClockTests`
Expected: build FAILURE — `cannot find 'QuietStatusClock' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// native/KaisolaMac/Kaisola/Features/Sessions/QuietStatusClock.swift
import Foundation

/// Remembers when each surface last CHANGED status, so rows can show
/// time-in-state ("working for 34m"), not time-since-creation.
struct QuietStatusClock {
    private var entries: [String: (status: QuietSessionStatus, at: Date)] = [:]

    mutating func note(id: String, status: QuietSessionStatus, at: Date) {
        if entries[id]?.status != status {
            entries[id] = (status, at)
        }
    }

    func since(id: String) -> Date? { entries[id]?.at }
}

enum QuietTimeLabel {
    static func label(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run native:test:focus -- QuietStatusClockTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/QuietStatusClock.swift native/KaisolaMac/KaisolaTests/QuietStatusClockTests.swift
git commit -m "feat: add time-in-state clock for quiet-fleet rows"
```

---

### Task 3: Rollups + kind glyphs

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Sessions/QuietRollup.swift`
- Test: `native/KaisolaMac/KaisolaTests/QuietRollupTests.swift`

**Interfaces:**
- Consumes: `QuietSessionStatus` (Task 1).
- Produces: `struct QuietRollup: Equatable { let total: Int; let dots: [QuietSessionStatus]; static func of(_ statuses: [QuietSessionStatus]) -> QuietRollup }` — `dots` is the ordered cluster for a collapsed header (max 3, priority done < working < failed < needsYou, **amber outermost** = LAST in the array; render count then dots left-to-right). Also `enum QuietKindGlyph { static func glyph(agentName: String?, processName: String?) -> String }` returning "✦" (claude), "⌁" (codex), "⇅" (ssh), "⌗" (mesh — via agentName "mesh"), else "❯".

- [ ] **Step 1: Write the failing test**

```swift
// native/KaisolaMac/KaisolaTests/QuietRollupTests.swift
import XCTest
@testable import Kaisola

final class QuietRollupTests: XCTestCase {
    func testRollupCountsActiveSessionsOnly() {
        let r = QuietRollup.of([.idle, .working, .needsYou, .doneUnseen, .ended, .working])
        XCTAssertEqual(r.total, 4) // idle+ended are silent, not counted
        XCTAssertEqual(r.dots.last, .needsYou) // amber outermost
        XCTAssertTrue(r.dots.contains(.working))
        XCTAssertLessThanOrEqual(r.dots.count, 3)
    }

    func testRollupDeduplicatesStates() {
        let r = QuietRollup.of([.working, .working, .working])
        XCTAssertEqual(r.total, 3)
        XCTAssertEqual(r.dots, [.working]) // one dot per distinct state
    }

    func testFullyIdleProjectIsSilent() {
        let r = QuietRollup.of([.idle, .ended, .idle])
        XCTAssertEqual(r.total, 0)
        XCTAssertTrue(r.dots.isEmpty)
    }

    func testGlyphs() {
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: "Claude Code", processName: nil), "✦")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: "codex", processName: nil), "⌁")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: nil, processName: "ssh"), "⇅")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: "mesh", processName: nil), "⌗")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: nil, processName: "zsh"), "❯")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: nil, processName: nil), "❯")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run native:test:focus -- QuietRollupTests`
Expected: build FAILURE — `cannot find 'QuietRollup' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// native/KaisolaMac/Kaisola/Features/Sessions/QuietRollup.swift
import Foundation

/// Collapsed-header aggregate: "3 ● ●" — count of active sessions plus one
/// dot per distinct active state, amber (needs-you) always at the outer edge.
struct QuietRollup: Equatable {
    let total: Int
    let dots: [QuietSessionStatus]

    static func of(_ statuses: [QuietSessionStatus]) -> QuietRollup {
        let active = statuses.filter { $0 != .idle && $0 != .ended }
        // Outermost-last display priority: done < working < failed < needsYou.
        let order: [QuietSessionStatus] = [.doneUnseen, .working, .failed, .needsYou]
        let distinct = order.filter { state in active.contains(state) }
        return QuietRollup(total: active.count, dots: Array(distinct.suffix(3)))
    }
}

enum QuietKindGlyph {
    static func glyph(agentName: String?, processName: String?) -> String {
        let agent = (agentName ?? "").lowercased()
        if agent.contains("claude") { return "✦" }
        if agent.contains("codex") { return "⌁" }
        if agent.contains("mesh") { return "⌗" }
        if (processName ?? "").lowercased() == "ssh" { return "⇅" }
        return "❯"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run native:test:focus -- QuietRollupTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/QuietRollup.swift native/KaisolaMac/KaisolaTests/QuietRollupTests.swift
git commit -m "feat: add collapsed-project rollups and kind glyphs"
```

---

### Task 4: Session order store

**Files:**
- Create: `native/KaisolaMac/Kaisola/Broker/SessionOrderStore.swift`
- Test: `native/KaisolaMac/KaisolaTests/SessionOrderStoreTests.swift`
- Read for pattern (do not modify): `native/KaisolaMac/Kaisola/Broker/SessionPinStore.swift`

**Interfaces:**
- Produces: `struct SessionOrderStore: Sendable` with `init(directory: URL)` (same persistence convention as `SessionPinStore` — read that file first and mirror its storage/atomic-write approach exactly, including a 500-id cap), `func order(projectID: String) -> [String]`, `func setOrder(projectID: String, ids: [String])`, and `nonisolated static func apply(_ ids: [String], to sessions: [BrokerTerminalRecord]) -> [BrokerTerminalRecord]` — stored ids first in stored order, unknown/new sessions appended in their incoming order, stale stored ids ignored.

- [ ] **Step 1: Write the failing test**

```swift
// native/KaisolaMac/KaisolaTests/SessionOrderStoreTests.swift
import XCTest
@testable import Kaisola

final class SessionOrderStoreTests: XCTestCase {
    private func record(_ id: String) -> BrokerTerminalRecord {
        // Mirror the fixture helper used in ProjectReorderTests / SessionPinStoreTests:
        // construct a minimal BrokerTerminalRecord with the given id. If those tests
        // share a factory, reuse it verbatim instead of this helper.
        BrokerTerminalRecord.fixture(id: id)
    }

    func testApplyOrdersKnownFirstThenAppendsNew() {
        let sessions = [record("a"), record("b"), record("c"), record("d")]
        let out = SessionOrderStore.apply(["c", "a"], to: sessions)
        XCTAssertEqual(out.map(\.id), ["c", "a", "b", "d"])
    }

    func testApplyIgnoresStaleIDs() {
        let sessions = [record("a"), record("b")]
        let out = SessionOrderStore.apply(["ghost", "b"], to: sessions)
        XCTAssertEqual(out.map(\.id), ["b", "a"])
    }

    func testRoundTripPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionOrderStore(directory: dir)
        store.setOrder(projectID: "p1", ids: ["x", "y"])
        XCTAssertEqual(SessionOrderStore(directory: dir).order(projectID: "p1"), ["x", "y"])
        XCTAssertEqual(SessionOrderStore(directory: dir).order(projectID: "missing"), [])
    }
}
```

Note: if `BrokerTerminalRecord` has no test fixture factory, check how `ProjectReorderTests.swift` and `SessionPinStoreTests.swift` build records and copy that exact construction into a private helper here.

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run native:test:focus -- SessionOrderStoreTests`
Expected: build FAILURE — `cannot find 'SessionOrderStore' in scope`.

- [ ] **Step 3: Implement, mirroring SessionPinStore's persistence exactly**

Read `SessionPinStore.swift` (44 lines) first. Implement `SessionOrderStore` with the same directory/file/atomic-write pattern (JSON file `session-order.json` in the given directory, `[String: [String]]` keyed by projectID, cap each list at 500 ids on write). The pure part:

```swift
nonisolated static func apply(_ ids: [String], to sessions: [BrokerTerminalRecord]) -> [BrokerTerminalRecord] {
    let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    var out: [BrokerTerminalRecord] = ids.compactMap { byID[$0] }
    let placed = Set(out.map(\.id))
    out.append(contentsOf: sessions.filter { !placed.contains($0.id) })
    return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run native:test:focus -- SessionOrderStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add native/KaisolaMac/Kaisola/Broker/SessionOrderStore.swift native/KaisolaMac/KaisolaTests/SessionOrderStoreTests.swift
git commit -m "feat: add per-project session order store"
```

---

### Task 5: The rail view — `QuietProjectRail`

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Sessions/QuietProjectRail.swift`
- Read for context (do not modify): `RootShellView.swift` HEAD lines 252–409 (leftTreeLayout), 619–657 (expansionBinding + projectContextMenu), 719–803 (sessionRow + surfaceVisibilityButton), 2820–3069 (old row structs — reference for context menus and bindings).

**Interfaces:**
- Consumes: everything from Tasks 1–4; AppModel APIs (all existing, verified at HEAD): `model.projects: [ProjectGroup]`, `model.chats(in:)`, `model.meshes(in:)`, `model.sessionTitle(for:)`, `model.agentProfile(for:)`, `model.meta(for:)`, `model.isOwned(_:)`, `model.isSurfaceVisible(_:)`, `model.select(_:)`, `model.selectChat(_:)`, `model.selectMesh(_:)`, `model.activateProject(id:)`, `model.moveProject(id:toIndex:)`, `model.pinnedSort(_:)`, `AttentionCenter.shared.entries` + `hasAcknowledgedSessionResponse(targetID:completedAt:)`.
- Produces: `struct QuietProjectRail: View` with `init(model: AppModel, attention: AttentionCenter, expansion: @escaping (String) -> Binding<Bool>, isActiveProject: @escaping (String) -> Bool, contextMenu: @escaping (ProjectGroup) -> AnyView, sessionContextMenu: @escaping (BrokerTerminalRecord) -> AnyView, chatContextMenu: @escaping (AcpChatHandle) -> AnyView, meshContextMenu: @escaping (MeshSession) -> AnyView)`. Task 6 constructs exactly this from `RootShellView`, passing its existing `expansionBinding` and context-menu builders so ALL existing actions (pin, rename, split, End Session, Move) survive unchanged.

- [ ] **Step 1: Implement the view** (UI task — no unit test; the compile + Task 6's launch check verify it)

Structure (complete component list — implement all of it):

```swift
// native/KaisolaMac/Kaisola/Features/Sessions/QuietProjectRail.swift
import SwiftUI

/// "Quiet fleet" v2.3 sidebar rail. Spec: single-line rows
/// (glyph · title · time · dot-at-right-edge), idle rows draw no dot,
/// plain-text headers with hover-only chrome, 30pt session indent,
/// collapsed headers show a count + dot rollup (amber outermost).
struct QuietProjectRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var attention: AttentionCenter
    let expansion: (String) -> Binding<Bool>
    let isActiveProject: (String) -> Bool
    let contextMenu: (ProjectGroup) -> AnyView
    let sessionContextMenu: (BrokerTerminalRecord) -> AnyView
    let chatContextMenu: (AcpChatHandle) -> AnyView
    let meshContextMenu: (MeshSession) -> AnyView

    @State private var clock = QuietStatusClock()
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ForEach(model.projects) { project in
            QuietProjectGroup(...)   // header + (expanded ? rows : nothing)
        }
        .onMove { indices, target in
            guard let first = indices.first else { return }
            let id = model.projects[first].id
            let to = target > first ? target - 1 : target
            model.moveProject(id: id, toIndex: to)
        }
        .onReceive(tick) { now = $0 }
    }
}
```

Required sub-views in the same file (all private):

1. `QuietProjectGroup` — plain-text header row (name `.system(size: 13, weight: isActive ? .semibold : .medium)`, secondary color when inactive), height 30, `contentShape(Rectangle())`, tap toggles `expansion(project.id)` AND `model.activateProject(id:)` when inactive. Active project header background: `RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius).fill(tint.opacity(0.12))` where `tint = ProjectTint.color(project.colorHex) ?? WorkspacePalette.project`. On hover (`onHover` + `@State hovering`, animate with `KaisolaVisualSystem.hoverDuration`): show a trailing chevron (`chevron.down`/`chevron.right`, 9pt, tertiary) and a `plus` button that calls the same new-session path the old header's `+` used (pass through `contextMenu` for the menu variant). When collapsed: trailing `QuietRollupView`.
2. `QuietRollupView(rollup: QuietRollup)` — `HStack(spacing: 5)`: `Text("\(rollup.total)")` (10.5 monospacedDigit, secondary; hidden when 0) then one 6pt `Circle().fill(state.dotColor!)` per `rollup.dots` in array order (amber lands outermost). `accessibilityLabel` joins the words ("3 active, needs you").
3. `QuietSessionRowView` — the four-token row, 26pt height, `.padding(.leading, 30)`:
   - glyph: `Text(QuietKindGlyph.glyph(agentName: agentProfile?.name, processName: meta?.processName))` 10.5, tertiary, 13pt fixed width;
   - title: `model.sessionTitle(for: record)` 12.5, primary (tertiary when `status.isDimmed`), `lineLimit(1)`;
   - `Spacer()`; time: `QuietTimeLabel.label(since:now:)` 10.5 monospacedDigit tertiary (empty when clock has no entry);
   - dot slot: fixed `frame(width: 6)`; `Circle().fill(dotColor)` 6pt when `status.dotColor != nil`; working state pulses opacity 1→0.3 with a 1.4s repeating ease animation ONLY when `!reduceMotion` (`@Environment(\.accessibilityReduceMotion)`);
   - selection: `RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius).fill(Color.primary.opacity(0.06))` when `model.isSurfaceVisible(record.id)`;
   - `.accessibilityElement(children: .combine)` + `.accessibilityLabel("\(title), \(status.accessibilityWord ?? "idle"), \(timeLabel)")`;
   - tap → `Task { await model.select(record.id) }`; attach `sessionContextMenu(record)`; tooltip `.help()` carries what the old subtitle held: "PID … · ⎇ branch · process".
   - status derivation: `QuietSessionStatus.terminal(activity: record.agentActivity, exited: record.exited, hasAttention: attention.entries.contains { $0.targetID == record.id && $0.kind != .turnCompleted }, respondedAcknowledged: {< if case .responded(let at) = record.agentActivity, use attention.hasAcknowledgedSessionResponse(targetID: record.id, completedAt: at), else false >})`. Feed `clock.note(id:status:at: now)` from `onChange`/body evaluation.
4. `QuietChatRowView` / `QuietMeshRowView` — same anatomy; chat status via `QuietSessionStatus.chat(isRunning: chat.conversation.isRunning, isConnected: chat.conversation.isConnected, hasPendingPermission: chat.conversation.pendingPermission != nil, hasAttention: …, statusMessage: chat.conversation.statusMessage)`, title `chat.conversation.title`, glyph from `chat.agentID`; mesh via `QuietSessionStatus.mesh(stageIsIdle: mesh.stage == "Idle", hasAttention: …)`, glyph "⌗".
5. Session ordering inside a group: `SessionOrderStore.apply(orderStore.order(projectID: project.id), to: model.pinnedSort(project.sessions))` with `.onMove` writing back via `setOrder`. Instantiate the store with the same support-directory the pin store uses (find `SessionPinStore` construction — one call site — and mirror its directory argument).

- [ ] **Step 2: Compile check**

Run: `npm run native:fast:build`
Expected: `Fast build finished` with no errors. (`ForEach` + `.onMove` on macOS List enables native drag-reorder without edit mode.)

- [ ] **Step 3: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/QuietProjectRail.swift
git commit -m "feat: add quiet-fleet project rail view"
```

---

### Task 6: Integration hunk in RootShellView

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift` — ONLY inside `leftTreeLayout` (HEAD 252–409). Do not touch anything else in this file; the old `SessionRow`/`ChatRow`/`MeshRow` structs stay in place (dormant) to keep the Codex-merge surface minimal — they are deleted in the post-merge task.

**Interfaces:**
- Consumes: `QuietProjectRail` (Task 5) with the exact init from Task 5's Produces block.

- [ ] **Step 1: Replace the project ForEach body**

Inside `leftTreeLayout`'s `List`, replace the `ForEach(model.projects) { project in Section(...) }` block (the Section header closure at 309–376 and the row content invoking `sessionRow`/`ChatRow`/`MeshRow`) with:

```swift
QuietProjectRail(
    model: model,
    attention: attention,
    expansion: { expansionBinding($0) },
    isActiveProject: { model.selectedProjectID == $0 },
    contextMenu: { AnyView(projectContextMenu($0)) },
    sessionContextMenu: { record in AnyView(sessionContextMenuContent(record)) },
    chatContextMenu: { chat in AnyView(chatContextMenuContent(chat)) },
    meshContextMenu: { mesh in AnyView(meshContextMenuContent(mesh)) }
)
```

If the existing context-menu builders are inline closures rather than named funcs, extract each into a `private func …Content(_:) -> some View` INSIDE the leftTreeLayout region (still one contiguous hunk) rather than reformatting distant code.

- [ ] **Step 2: Build and launch**

Run: `npm run native:fast:build` then `KAISOLA_NATIVE_BROKER_PROFILE=development npm run native:fast -- --refresh-helper`
Expected: app launches; sidebar shows quiet rows (verify against the artifact: plain headers, 30pt indent, right-edge dots, no dots on idle rows, rollup on a collapsed project). Quit the dev instance afterwards (`kill -TERM <pid printed by the script>`).

- [ ] **Step 3: Run the changed-file test lane**

Run: `npm run native:test:changed -- --include-working-tree`
Expected: selected suites PASS (the lane will pick RootShellView's mapped suites plus the new test files).

- [ ] **Step 4: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift
git commit -m "feat: adopt quiet-fleet rail in the left-tree sidebar"
```

---

### Task 7: Keyboard reorder + polish pass

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/QuietProjectRail.swift` (Task 5's file — additions only)

- [ ] **Step 1: Add Move Up / Move Down to the header's own context area**

In `QuietProjectGroup`, wrap the header in `.contextMenu { contextMenu(project) }` (already passed through — verify the existing `projectContextMenu` still exposes Move actions; it does at HEAD 631–657 as "Move Left"/"Move Right" → since the rail is vertical, ALSO add two new items in the rail-side menu):

```swift
Button("Move Up") { model.moveProject(id: project.id, delta: -1) }
    .keyboardShortcut(.upArrow, modifiers: .option)
Button("Move Down") { model.moveProject(id: project.id, delta: 1) }
    .keyboardShortcut(.downArrow, modifiers: .option)
```

Scope the shortcuts to the focused/active project only (guard inside the action on `isActiveProject(project.id)`) so ⌥↑/⌥↓ has one deterministic target.

- [ ] **Step 2: Manual verification**

Run: `KAISOLA_NATIVE_BROKER_PROFILE=development npm run native:fast -- --refresh-helper`
Verify: drag a project header up/down reorders and persists across relaunch (`native:fast:launch`); drag a session between positions within its project persists; ⌥↑/⌥↓ moves the active project; hover reveals chevron/plus; collapsed project shows rollup. Quit the dev instance.

- [ ] **Step 3: Full focused suite + commit**

Run: `npm run native:test:focus -- QuietSessionStatusTests QuietStatusClockTests QuietRollupTests SessionOrderStoreTests`
Expected: all PASS.

```bash
git add -A native/KaisolaMac/Kaisola/Features/Sessions/QuietProjectRail.swift
git commit -m "feat: keyboard reorder and hover chrome for quiet-fleet rail"
```

---

### Task 8 (POST-MERGE — do not start until the third-party fix pass has landed on main and this branch has been rebased):

1. Wire `bell(source:)` in `NativeTerminalSurface.swift:1126` (HEAD numbering) to `AttentionCenter.shared.notify(kind:targetID:title:detail:)` so terminals gain the needs-you state (the derivation from Task 1 already handles it).
2. Delete the dormant `SessionRow`/`ChatRow`/`MeshRow`/`sessionRow(_:)`/`sessionDetail` code from `RootShellView.swift`.
3. Hide the "Other Macs" section + "Updated Ns ago" row unless at least one remembered remote Mac exists; consolidate the footer per spec.
4. Re-run `npm run native:test:changed -- --base origin/main`.

---

## Self-review notes

- Spec coverage: row anatomy (T5), 5-state dots + idle-silent (T1/T5), time-in-state (T2), rollups amber-outermost (T3), 30pt indent + plain headers + hover chrome (T5), active-header tint fill (T5), drag reorder projects (T5 onMove) and sessions (T5 §5) + keyboard (T7), tear-off is explicitly OUT of scope for this plan (existing window features unaffected); needs-you for terminals lands with the bell wiring in T8 (chats have it from day one via pendingPermission).
- Type consistency: `QuietSessionStatus` case names, `QuietRollup.of`, `QuietTimeLabel.label(since:now:)`, `QuietKindGlyph.glyph(agentName:processName:)`, `SessionOrderStore.apply` are used identically across Tasks 1–7.
- Known judgment calls for the implementer: exact `BrokerTerminalRecord` fixture construction (copy from existing tests, Task 4 note); `AgentProfile`'s display-name property (checked at call site, Task 5 §3); whether `attention.entries` kinds beyond `turnCompleted` exist at HEAD (Task 5 §3 filters `!= .turnCompleted` for needs-you vs done).
