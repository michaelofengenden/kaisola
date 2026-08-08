# Pane Minus Buttons + Content-Surface Show Doors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each side pane (file tree, file preview) hides itself from a minus button at its own top-right; the open terminal/chat surface shows visible "show" buttons only while a pane is hidden, replacing the hover-only titlebar toggles.

**Architecture:** A pure policy type (`DetailShowDoors`) decides which show doors are visible; `RootShellView` renders them as a floating top-trailing overlay on the content surface and drops the hover-toggle machinery. `WorkspaceRailView` and `FilePreviewView` each gain a trailing minus in their existing header rows; the preview's hide reuses the dirty-guard `PendingAction` mechanism so unsaved edits prompt exactly like close does.

**Tech Stack:** SwiftUI (macOS app target `Kaisola`), XCTest via `npm run native:test:focus -- <TestClass>`.

## Global Constraints

- Copy verbatim from spec: rail control label "Hide Files"; preview control label/help "Hide Document"; show doors "Show Files" / "Show Document".
- Show doors appear ONLY while their pane is hidden; both open ⇒ overlay renders nothing.
- Preview hide is non-destructive: routes through `runCommand(.toggleDocumentPreview)` (restores last document on reopen; opens Files when nothing to restore).
- Keep automation identifiers `detail.toggle-files` and `detail.toggle-document` on the new show doors.
- Do not touch: per-tab close buttons, browser card close, footer overflow menu, ⌘B / toggle-document shortcuts, pane widths.
- Commit locally after each task; do NOT push (a push cuts a release — one push at the end of the session).

---

### Task 1: `DetailShowDoors` policy + tests

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Sessions/DetailShowDoors.swift`
- Test: `native/KaisolaMac/KaisolaTests/DetailShowDoorsTests.swift`

**Interfaces:**
- Produces: `struct DetailShowDoors: Equatable` with `let showFiles: Bool`, `let showDocument: Bool`, `var isEmpty: Bool`, and `static func resolve(railVisible: Bool, previewVisible: Bool, hasProjectDirectory: Bool) -> DetailShowDoors`. Task 4 consumes exactly this.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Kaisola

final class DetailShowDoorsTests: XCTestCase {
    func testDoorsAppearExactlyWhileTheirPaneIsHidden() {
        let bothOpen = DetailShowDoors.resolve(
            railVisible: true, previewVisible: true, hasProjectDirectory: true
        )
        XCTAssertTrue(bothOpen.isEmpty)

        let railHidden = DetailShowDoors.resolve(
            railVisible: false, previewVisible: true, hasProjectDirectory: true
        )
        XCTAssertEqual(railHidden, DetailShowDoors(showFiles: true, showDocument: false))

        let previewHidden = DetailShowDoors.resolve(
            railVisible: true, previewVisible: false, hasProjectDirectory: true
        )
        XCTAssertEqual(previewHidden, DetailShowDoors(showFiles: false, showDocument: true))

        let bothHidden = DetailShowDoors.resolve(
            railVisible: false, previewVisible: false, hasProjectDirectory: true
        )
        XCTAssertEqual(bothHidden, DetailShowDoors(showFiles: true, showDocument: true))
        XCTAssertFalse(bothHidden.isEmpty)
    }

    func testNoFilesDoorWithoutAProjectDirectory() {
        // Without a project directory the rail cannot render (see
        // RootShellView.detailRailPanelVisible), so a Files door would dead-end.
        let doors = DetailShowDoors.resolve(
            railVisible: false, previewVisible: false, hasProjectDirectory: false
        )
        XCTAssertEqual(doors, DetailShowDoors(showFiles: false, showDocument: true))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm run native:test:focus -- DetailShowDoorsTests`
Expected: build failure "cannot find 'DetailShowDoors' in scope" (a compile error is this repo's red state for a new type).

- [ ] **Step 3: Implement**

```swift
/// Which "show" doors the content surface draws at its top-right. The panes'
/// own minus buttons are the hide doors; a show door exists exactly while its
/// pane is hidden, so when everything is open the corner is clean.
struct DetailShowDoors: Equatable {
    let showFiles: Bool
    let showDocument: Bool

    var isEmpty: Bool { !showFiles && !showDocument }

    /// `hasProjectDirectory` gates the Files door: without a project root the
    /// rail cannot render, and a door that opens onto nothing teaches the user
    /// it is broken.
    static func resolve(
        railVisible: Bool,
        previewVisible: Bool,
        hasProjectDirectory: Bool
    ) -> DetailShowDoors {
        DetailShowDoors(
            showFiles: !railVisible && hasProjectDirectory,
            showDocument: !previewVisible
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npm run native:test:focus -- DetailShowDoorsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/DetailShowDoors.swift native/KaisolaMac/KaisolaTests/DetailShowDoorsTests.swift
git commit -m "feat(shell): DetailShowDoors policy for content-surface show buttons"
```

---

### Task 2: WorkspaceRailView — trailing minus replaces the leading hide button

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift:66-124` (header row)

**Interfaces:**
- Consumes: the view's existing `close: () -> Void` property (already wired in `RootShellView` to `settings.workspaceRailVisible = false`). No signature changes.

- [ ] **Step 1: Remove the leading button, add the trailing minus**

In `body`'s header `HStack(spacing: 6)`, DELETE this block (currently first child):

```swift
Button(action: close) {
    Image(systemName: "sidebar.trailing")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 20, height: 20)
}
.buttonStyle(.borderless)
.help("Hide \(root.lastPathComponent) files (Command-B)")
.accessibilityLabel("Hide Files")
```

and ADD this as the LAST child of the same HStack, after the `if isMutating { ProgressView()... }` block:

```swift
Button(action: close) {
    Image(systemName: "minus")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
}
.buttonStyle(.borderless)
.help("Hide \(root.lastPathComponent) files (Command-B)")
.accessibilityLabel("Hide Files")
.accessibilityIdentifier("files.hide")
```

- [ ] **Step 2: Build + run the rail's existing suites**

Run: `npm run native:test:focus -- WorkspaceFilesTests WorkspaceRailNameFadeTests`
Expected: PASS (change is header-chrome only; these suites cover tree/model behavior and must stay green).

- [ ] **Step 3: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift
git commit -m "feat(files): rail hides from a quiet minus at its own top-right"
```

---

### Task 3: FilePreviewView — dirty-guarded hide, minus in both header shapes

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift` (property list ~line 25, `PendingAction` enum ~line 135, `completePendingAction()` ~line 329, `requestClose()` ~line 343, `header` ~line 438)

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: new stored property `let hide: () -> Void` on `FilePreviewView`, declared immediately BEFORE `let close: () -> Void`, and added to the memberwise-style `init` the same way `close` is threaded (same default treatment: required, no default). Task 4 passes it at the `RootShellView` call site.

- [ ] **Step 1: Add the closure property and init parameter**

Next to `let close: () -> Void` (~line 25) add:

```swift
/// Hides the whole preview column non-destructively (the toggle-document
/// path): tabs and the current file stay remembered for reopen. `close`
/// remains the destructive per-document door.
let hide: () -> Void
```

Thread `hide` through the explicit `init` exactly as `close` is (parameter directly before `close`'s, assignment beside it).

- [ ] **Step 2: Extend the pending-action machinery**

In `private enum PendingAction: Equatable` add `case hide` after `case close`.
In `completePendingAction()` extend the switch:

```swift
case .hide:
    hide()
```

Below `requestClose()` add:

```swift
private func requestHide() {
    if isDirty {
        pendingAction = .hide
        autosavePendingAction = false
        showUnsavedPrompt = true
    } else {
        hide()
    }
}
```

- [ ] **Step 3: Swap the header's dismissal control**

In `header` (~line 470), DELETE the tab-less xmark block:

```swift
if tabs.isEmpty {
    Button {
        requestClose()
    } label: {
        Image(systemName: "xmark")
    }
    .buttonStyle(.borderless)
    .help("Close document")
}
```

and ADD, unconditionally, as the last child of the header `HStack` (after `previewOptionsMenu`):

```swift
Button {
    requestHide()
} label: {
    Image(systemName: "minus")
}
.buttonStyle(.borderless)
.help("Hide Document")
.accessibilityLabel("Hide Document")
.accessibilityIdentifier("preview.hide")
```

- [ ] **Step 4: Fix every construction site**

Run: `grep -rn "FilePreviewView(" native/KaisolaMac --include="*.swift"` and add a `hide:` argument to each. The production site (`RootShellView.swift:1364`) gets its real wiring now, in this task: `hide: { runCommand(.toggleDocumentPreview) }` — that is the non-destructive toggle path the spec names, and it keeps every commit green even though Task 4 owns the rest of RootShellView. Any test or preview fixtures pass `hide: {}`.

- [ ] **Step 5: Build + run the preview suites**

Run: `npm run native:test:focus -- DataPreviewsTests PreviewMappingTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift
git commit -m "feat(preview): always-present minus hides the column behind the dirty guard"
```

---

### Task 4: RootShellView — show-doors overlay in, hover toggles out

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift` (state ~line 47, `detailArea` overlay ~line 719, `detailPanelToggles`/`filesToolbarControl`/`filePreviewToolbarControl`/`detailChromeToggle` ~lines 743-860, `detailPane` ~line 1352, `DetailToggleHoverSensor` ~line 2967)

**Interfaces:**
- Consumes: `DetailShowDoors.resolve(railVisible:previewVisible:hasProjectDirectory:)` from Task 1; existing `runCommand(.toggleFiles)` / `runCommand(.toggleDocumentPreview)` and `detailPreviewPanelVisible` / `detailRailPanelVisible` / `keymap.shortcut(for:)`.

- [ ] **Step 1: Delete the hover machinery**

Remove: `@State private var detailTogglesRevealed` (line 47), the `.overlay(alignment: .topTrailing) { if settings.navigationLayout == .topBar { detailPanelToggles } }` in `detailArea` (~line 719 — the overlay modifier only; `detailArea` keeps its other modifiers), `detailPanelToggles`, `filesToolbarControl`, `filePreviewToolbarControl`, `detailChromeToggle(symbol:isOn:help:label:identifier:action:)`, and the `DetailToggleHoverSensor` struct (~line 2967). Update the doc comments at lines ~45 and ~696 and ~1553 that point at `detailPanelToggles` to point at `detailShowDoors` instead.

- [ ] **Step 2: Add the show-doors overlay**

In `detailPane`'s `HStack`, attach to `detailContent` (after `.layoutPriority(1)`):

```swift
.overlay(alignment: .topTrailing) { detailShowDoors }
```

Then add, near `detailPane`:

```swift
/// The show half of the pane chrome: each hidden pane's door floats at the
/// content surface's top-right, on a material capsule so it reads over
/// terminal text. The panes' own minus buttons are the hide half, so when
/// both panes are open this renders nothing and the corner is clean.
/// Keyboard/menu doors (⌘B, toggle-document, footer overflow, palette) are
/// unchanged.
@ViewBuilder
private var detailShowDoors: some View {
    let doors = DetailShowDoors.resolve(
        railVisible: detailRailPanelVisible,
        previewVisible: detailPreviewPanelVisible,
        hasProjectDirectory: model.currentProjectDirectory != nil
    )
    if !doors.isEmpty {
        HStack(spacing: NativeWorkspaceChrome.detailChromeControlGap) {
            if doors.showDocument {
                showDoor(
                    symbol: "doc.text",
                    label: "Show Document",
                    shortcut: keymap.shortcut(for: .toggleDocumentPreview)?.display,
                    identifier: "detail.toggle-document",
                    action: { runCommand(.toggleDocumentPreview) }
                )
            }
            if doors.showFiles {
                showDoor(
                    symbol: "sidebar.trailing",
                    label: "Show Files",
                    shortcut: keymap.shortcut(for: .toggleFiles)?.display,
                    identifier: "detail.toggle-files",
                    action: { runCommand(.toggleFiles) }
                )
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .padding(.trailing, 10)
    }
}

private func showDoor(
    symbol: String,
    label: String,
    shortcut: String?,
    identifier: String,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: NativeWorkspaceChrome.detailChromeGlyphSize, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 20)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(shortcut.map { "\(label) (\($0))" } ?? label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
}
```

Door order matches the old pair: document control left of the Files control (panels sit preview-then-rail left to right).

- [ ] **Step 3: Build + run shell/session suites**

Run: `npm run native:test:focus -- CommandRegistryTests WorkspaceFilesTests DetailShowDoorsTests`
Expected: PASS; also confirm `grep -n "detailTogglesRevealed\|DetailToggleHoverSensor" native/KaisolaMac -r` returns nothing.

- [ ] **Step 4: Commit**

```bash
git add native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift
git commit -m "feat(shell): visible show doors replace the hover-only pane toggles"
```

---

### Task 5: Whole-lane verification + visual sanity

- [ ] **Step 1: Changed-file test lane**

Run: `./scripts/native-test-changed.sh`
Expected: "Changed-file test lane passed."

- [ ] **Step 2: Launch smoke**

Run: `npm run native:fast` (build + launch the dev app). Verify by eye: rail header shows the minus at its right end and no accent button at its left; preview header shows the minus with tabs open and without; hiding each pane makes its door appear at the content top-right; both open ⇒ no overlay; door glyphs match the footer menu's symbols.

- [ ] **Step 3: Update the fixes/notes ledger only if a defect was found; otherwise nothing.**
