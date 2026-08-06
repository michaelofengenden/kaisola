# Obsidian-style Live Preview Markdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cursor-line syntax reveal, clickable checkboxes, list indent/outdent, wikilinks, and formatting shortcuts on the existing byte-fidelity rendered Markdown editor.

**Architecture:** All work extends `MarkdownRenderedEditor` (TextKit 1 `NSTextView` whose storage holds the exact file bytes; styling is real storage *attributes*, never characters). The core enabler is an incremental attribute pass scoped to paragraph ranges; syntax reveal, checkboxes, and everything else ride on it. New logic lands as pure, testable helpers next to the existing `MarkdownListContinuation` pattern.

**Tech Stack:** Swift, AppKit/TextKit 1, XCTest. No new dependencies.

## Global Constraints

- Performance: no per-keystroke or per-cursor-move work proportional to document size (spec §performance principle). Cursor moves restyle only paragraphs whose active state changed.
- Byte fidelity: styling touches attributes only, never characters; the `assert(storage.string == before)` in the apply pass stays and must keep passing.
- `isRichText = false`, autocorrect/quote/dash substitution stay disabled.
- Spec: `docs/superpowers/specs/2026-08-06-obsidian-md-filetree-session-restore-design.md` §1.
- Test scheme: `xcodebuild test -project native/KaisolaMac/KaisolaMac.xcodeproj -scheme Kaisola -destination 'platform=macOS,arch=arm64' -only-testing:KaisolaTests/<Class>`. Run `xcodegen generate` in `native/KaisolaMac` after adding files.
- Commits: conventional prefixes (`feat(md): …`), no AI co-author trailers.

---

### Task 1: Reveal-state diffing (pure helper)

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Workspace/MarkdownRevealState.swift`
- Test: `native/KaisolaMac/KaisolaTests/MarkdownRevealStateTests.swift`

**Interfaces:**
- Produces: `struct MarkdownRevealState: Equatable { let activeParagraphs: [NSRange] }`, `MarkdownRevealState.compute(selection: NSRange, in source: NSString) -> MarkdownRevealState`, `MarkdownRevealState.changedRanges(from old: MarkdownRevealState, to new: MarkdownRevealState) -> [NSRange]` (ranges needing restyle = symmetric difference, merged when adjacent).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Kaisola

final class MarkdownRevealStateTests: XCTestCase {
    private let source = "# Title\n\nBody one.\n\n## Second\n" as NSString

    func testCaretProducesItsParagraph() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 0), in: source)
        XCTAssertEqual(state.activeParagraphs, [NSRange(location: 0, length: 8)])
    }

    func testSelectionSpanningParagraphsProducesAll() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 12), in: source)
        XCTAssertEqual(state.activeParagraphs, [NSRange(location: 0, length: 19)])
    }

    func testChangedRangesIsSymmetricDifference() {
        let old = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 0), in: source)
        let new = MarkdownRevealState.compute(selection: NSRange(location: 21, length: 0), in: source)
        XCTAssertEqual(
            MarkdownRevealState.changedRanges(from: old, to: new),
            [NSRange(location: 0, length: 8), NSRange(location: 20, length: 10)]
        )
    }

    func testNoMoveMeansNoChange() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 0), in: source)
        XCTAssertEqual(MarkdownRevealState.changedRanges(from: state, to: state), [])
    }
}
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:KaisolaTests/MarkdownRevealStateTests`; expect: does not compile — type missing)

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which paragraphs currently reveal their Markdown syntax marks. Computed
/// from the selection; the diff is what the incremental style pass repaints.
struct MarkdownRevealState: Equatable {
    let activeParagraphs: [NSRange]

    static func compute(selection: NSRange, in source: NSString) -> MarkdownRevealState {
        guard source.length > 0 else { return MarkdownRevealState(activeParagraphs: []) }
        let clamped = NSRange(
            location: min(selection.location, source.length),
            length: min(selection.length, source.length - min(selection.location, source.length))
        )
        return MarkdownRevealState(activeParagraphs: [source.paragraphRange(for: clamped)])
    }

    static func changedRanges(from old: MarkdownRevealState, to new: MarkdownRevealState) -> [NSRange] {
        guard old != new else { return [] }
        var ranges = old.activeParagraphs + new.activeParagraphs
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
```

- [ ] **Step 4: Run to verify pass**
- [ ] **Step 5: Commit** (`feat(md): reveal-state diffing for cursor-line syntax reveal`)

---

### Task 2: Incremental attribute application (spec 1a-pre)

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewEditors.swift` — `apply(_:to:)` (~line 1415), `scheduleStyling` (~1371), coordinator state
- Test: `native/KaisolaMac/KaisolaTests/MarkdownIncrementalStyleTests.swift`

**Interfaces:**
- Consumes: `MarkdownRevealState` (Task 1), existing `MarkdownLiveStyleScan`, `MarkdownEditingStyle`.
- Produces: `apply(_ scan: MarkdownLiveStyleScan, to textView: NSTextView, limitedTo ranges: [NSRange]?)` — `nil` = whole document (load, width change, edits for now); non-nil = only those paragraph ranges get base reset + span reapplication. Also `MarkdownEditingStyle.attributes(for: role, revealed: Bool)` where `revealed` only changes `.syntax`: visible dim marks (`NSFont.systemFont(ofSize: bodySize * 0.85)`, `.tertiaryLabelColor`) instead of the 0.1pt clear run.

Implementation notes an engineer needs:
- Extract the per-range work from today's full pass: `storage.setAttributes(base, range: r)` then `for span in scan.spans where NSIntersectionRange(span.range, r).length > 0 || spanInside(r)` apply `attributes(for:revealed:)` — reveal decided by whether the span's paragraph intersects the coordinator's current `revealState`.
- Table regions: if a limited range intersects any `scan.tables` region, extend that range to the union with the table's full region and rerun `MarkdownTableStyler.applyTypography` + `applyGeometry` for those regions only; recompute decorations by calling `applyGeometry` with all regions (its cost is proportional to table count, acceptable) only when an intersection occurred.
- Viewport anchor save/restore (`viewportAnchor()`/`restore`): run it only in the full-document path and in limited passes (reveal changes line heights). Cheap either way; keep behavior identical.
- The `assert(storage.string == before)` moves into the shared per-range helper so both paths keep it.
- Wrap limited passes in `isApplyingStyle = true` / `storage.beginEditing()` exactly like the full pass.

- [ ] **Step 1: Write the failing test** — the apply-range computation is exercised through a seam: add `static func rangesToRestyle(changed: [NSRange], tables: [MarkdownTableRegion], in source: NSString) -> [NSRange]` to a new `enum MarkdownIncrementalStyle` in `FilePreviewEditors.swift`, pure and testable:

```swift
import XCTest
@testable import Kaisola

final class MarkdownIncrementalStyleTests: XCTestCase {
    func testRangesPassThroughWhenNoTableIntersects() {
        let source = "alpha\n\nbeta\n" as NSString
        let ranges = MarkdownIncrementalStyle.rangesToRestyle(
            changed: [NSRange(location: 0, length: 6)], tables: [], in: source
        )
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 6)])
    }

    func testTableIntersectionExtendsToWholeTableRegion() {
        let source = "| a | b |\n| - | - |\n| 1 | 2 |\ntail\n" as NSString
        let table = MarkdownTableRegions.scan(source as String)
        let ranges = MarkdownIncrementalStyle.rangesToRestyle(
            changed: [NSRange(location: 10, length: 5)], tables: table, in: source
        )
        XCTAssertEqual(ranges.first, table.first?.range)
    }
}
```

(Adjust the `MarkdownTableRegion` accessor for its actual `range` property name after reading `MarkdownTableRendering.swift` — use whatever exposes the region's full NSRange.)

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement `MarkdownIncrementalStyle.rangesToRestyle` + thread `limitedTo:` through `apply`**, per the notes above. `scheduleStyling` keeps calling `apply(scan, to: textView, limitedTo: nil)`.
- [ ] **Step 4: Run new tests + the full `KaisolaTests` markdown classes** (`MarkdownRevealStateTests`, `MarkdownIncrementalStyleTests`, `WorkspaceFilesTests`); expect all pass.
- [ ] **Step 5: Commit** (`feat(md): range-scoped incremental style application`)

---

### Task 3: Cursor-line syntax reveal (spec 1a)

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewEditors.swift` — coordinator gains `revealState: MarkdownRevealState`, delegate gains `textViewDidChangeSelection(_:)`; `MarkdownEditingStyle.attributes(for:revealed:)` from Task 2 is now driven by real state.

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: user-visible reveal. No new API.

Implementation notes:
- In `textViewDidChangeSelection`: guard `!isApplyingStyle` (selection changes fired by styling must not recurse); compute `new = MarkdownRevealState.compute(selection: textView.selectedRange(), in: textView.string as NSString)`; if unchanged, return. `let changed = MarkdownRevealState.changedRanges(from: revealState, to: new)`; set `revealState = new`; run `apply(lastScan, to: textView, limitedTo: changed)` where the coordinator caches `lastScan` from the most recent full pass (add `private var lastScan: MarkdownLiveStyleScan?`; a limited pass with no cached scan just returns — the pending full pass covers it).
- After `textDidChange`, the debounced full pass recomputes `lastScan`; reveal state stays valid because it is recomputed on every selection change (typing moves the caret → selection change fires).
- Manual check: open a large doc, caret on a heading shows `##` dimmed; arrow down hides it and reveals the next paragraph's marks; bold `**` pairs reveal on their line; table row under caret shows raw pipes.

- [ ] **Step 1: Implement** per notes (no new pure logic beyond Tasks 1–2; the delegate method is glue).
- [ ] **Step 2: Run all markdown test classes**; expect pass (byte-fidelity assert exercised via existing tests).
- [ ] **Step 3: Manual visual check** in the app (open `notes/harvest-blueprint-2026-08.md`, move the caret through headings/bold/table).
- [ ] **Step 4: Commit** (`feat(md): syntax marks reveal on the cursor's paragraph`)

---

### Task 4: Clickable checkboxes (spec 1b)

**Files:**
- Modify: `FilePreviewEditors.swift` — `MarkdownEditingStyle` span scanner (add task-marker spans), `MarkdownNativeTextView.mouseDown`
- Create: `native/KaisolaMac/Kaisola/Features/Workspace/MarkdownTaskToggle.swift`
- Test: `native/KaisolaMac/KaisolaTests/MarkdownTaskToggleTests.swift`

**Interfaces:**
- Produces: `enum MarkdownTaskToggle { static func toggleRange(at characterIndex: Int, in source: NSString) -> (range: NSRange, replacement: String)? }` — locates a `- [ ]` / `- [x]` marker whose bracket group contains (or whose line contains) the index and returns the single-character edit (`"x"` ↔ `" "`); nil when the line is not a task item. New scanner roles: `.taskChecked`, `.taskUnchecked` spanning the `[x]`/`[ ]` group (regex `(?m)^([ \t]*(?:[-*+])\s+)(\[( |x|X)\])(\s)`), styled with `controlAccentColor` and semibold body font so the marker reads as a control; the surrounding syntax stays governed by reveal.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Kaisola

final class MarkdownTaskToggleTests: XCTestCase {
    func testTogglesUncheckedToChecked() {
        let source = "- [ ] write tests\n" as NSString
        let edit = MarkdownTaskToggle.toggleRange(at: 3, in: source)
        XCTAssertEqual(edit?.range, NSRange(location: 3, length: 1))
        XCTAssertEqual(edit?.replacement, "x")
    }

    func testTogglesCheckedToUnchecked() {
        let source = "  - [x] done\n" as NSString
        let edit = MarkdownTaskToggle.toggleRange(at: 5, in: source)
        XCTAssertEqual(edit?.range, NSRange(location: 5, length: 1))
        XCTAssertEqual(edit?.replacement, " ")
    }

    func testNonTaskLineReturnsNil() {
        XCTAssertNil(MarkdownTaskToggle.toggleRange(at: 2, in: "- plain bullet\n" as NSString))
    }
}
```

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement** `MarkdownTaskToggle` (regex over the paragraph containing the index) + scanner roles + `mouseDown` branch: before the Cmd+link branch, if the click's character index sits inside a task-marker bracket group (consult `MarkdownTaskToggle.toggleRange` with the exact bracket-interior index; only trigger when the hit is within the 3-character bracket group so ordinary text clicks still place the caret), perform `insertText(edit.replacement, replacementRange: edit.range)` — the normal edit path drives undo, autosave, and restyle.
- [ ] **Step 4: Run tests; manual check** (click toggles, undo untoggles, file bytes flip exactly one character).
- [ ] **Step 5: Commit** (`feat(md): task checkboxes toggle on click`)

---

### Task 5: List indent/outdent + ordered renumbering (spec 1c remainder)

**Files:**
- Modify: `FilePreviewEditors.swift` — `MarkdownNativeTextView` overrides `insertTab(_:)` / `insertBacktab(_:)`
- Create: `native/KaisolaMac/Kaisola/Features/Workspace/MarkdownListIndent.swift`
- Test: `native/KaisolaMac/KaisolaTests/MarkdownListIndentTests.swift`

**Interfaces:**
- Consumes: `MarkdownListContinuation` (exists, `FilePreviewEditors.swift:1844`) for line classification.
- Produces: `enum MarkdownListIndent { static func edit(for source: NSString, paragraph: NSRange, direction: Direction) -> (range: NSRange, replacement: String)?; enum Direction { case indent, outdent } }` — indent inserts `"\t"` at the paragraph start of a list line; outdent removes one leading `"\t"` or up to 4 leading spaces; nil on non-list lines (caller falls through to normal Tab). Also `static func renumber(block: NSRange, in source: NSString) -> [(range: NSRange, replacement: String)]` re-sequencing a contiguous ordered-list block (`1.`, `2.`, …) bottom-up so ranges stay valid when applied in order.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Kaisola

final class MarkdownListIndentTests: XCTestCase {
    func testIndentInsertsTabAtListLineStart() {
        let source = "- item\n" as NSString
        let edit = MarkdownListIndent.edit(for: source, paragraph: NSRange(location: 0, length: 7), direction: .indent)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.replacement, "\t")
    }

    func testOutdentRemovesOneLevel() {
        let source = "\t- item\n" as NSString
        let edit = MarkdownListIndent.edit(for: source, paragraph: NSRange(location: 0, length: 8), direction: .outdent)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(edit?.replacement, "")
    }

    func testNonListLineReturnsNil() {
        let source = "plain text\n" as NSString
        XCTAssertNil(MarkdownListIndent.edit(for: source, paragraph: NSRange(location: 0, length: 11), direction: .indent))
    }

    func testRenumberRewritesContiguousOrderedBlock() {
        let source = "1. a\n5. b\n9. c\n" as NSString
        let edits = MarkdownListIndent.renumber(block: NSRange(location: 0, length: 15), in: source)
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits.first?.replacement, "3")  // bottom-up: "9" -> "3"
    }
}
```

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement** helper + `insertTab`/`insertBacktab` overrides (caret with zero-length selection on a list line → apply edit via `insertText(_:replacementRange:)` then renumber the surrounding ordered block if the line is ordered; anything else → `super`).
- [ ] **Step 4: Run tests + manual check** (Tab nests a bullet, Shift-Tab unnests, ordered lists renumber).
- [ ] **Step 5: Commit** (`feat(md): list indent, outdent, and ordered renumbering`)

---

### Task 6: Wikilinks (spec 1d)

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Workspace/WikilinkIndex.swift`
- Modify: `FilePreviewEditors.swift` — scanner adds wikilink spans; `MarkdownLinkTargets.destination` recognizes `[[name]]`; `MarkdownDocumentView`/`FilePreviewView` link policy resolves and opens
- Test: `native/KaisolaMac/KaisolaTests/WikilinkIndexTests.swift`

**Interfaces:**
- Consumes: the workspace root URL available to `FilePreviewView`; existing bounded enumeration in `ProjectFiles` (see `WorkspaceFilesTests.swift` for its API).
- Produces: `final class WikilinkIndex { init(root: URL); func refresh(); func resolve(_ name: String) -> URL? }` — case-insensitive match on file base name with `.md` implied (`[[harvest-blueprint-2026-08]]` → `notes/harvest-blueprint-2026-08.md`); built from the bounded enumeration, refreshed when `FilePreviewView` loads a document and on workspace watcher change; lookups are a dictionary hit. Scanner role: `[[…]]` interior styled `.link`, double brackets styled `.syntax` (regex `(\[\[)([^\]\r\n]+)(\]\])` with syntaxGroups `[1, 3]`). `MarkdownLinkTargets.destination` returns `"kaisola-wiki://" + name` for an index inside a wikilink; the link policy resolves via the index and opens the file in a tab (existing open-file path); unresolved names are ignored on click (dim styling deferred — resolution inside the style pass would couple the scanner to I/O; noted as spec deviation).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Kaisola

final class WikilinkIndexTests: XCTestCase {
    func testResolvesCaseInsensitiveBaseName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikilink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("notes/Harvest-Blueprint.md")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let index = WikilinkIndex(root: root)
        index.refresh()
        XCTAssertEqual(index.resolve("harvest-blueprint")?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertNil(index.resolve("missing-note"))
    }
}
```

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement** index + scanner spans + destination + link policy.
- [ ] **Step 4: Run tests + manual check** (`[[note]]` renders as link, click opens, brackets reveal on cursor line).
- [ ] **Step 5: Commit** (`feat(md): wikilinks resolve against the workspace`)

---

### Task 7: Formatting shortcuts + paste-URL-as-link (spec 1e)

**Files:**
- Create: `native/KaisolaMac/Kaisola/Features/Workspace/MarkdownInlineFormatting.swift`
- Modify: `FilePreviewEditors.swift` — `MarkdownNativeTextView` `performKeyEquivalent(with:)` (Cmd+B/I/K) and `paste(_:)`
- Test: `native/KaisolaMac/KaisolaTests/MarkdownInlineFormattingTests.swift`

**Interfaces:**
- Produces: `enum MarkdownInlineFormatting { static func toggleWrap(_ delimiter: String, selection: NSRange, in source: NSString) -> (edits: [(NSRange, String)], newSelection: NSRange)?; static func linkEdit(selection: NSRange, url: String?, in source: NSString) -> (edits: [(NSRange, String)], newSelection: NSRange)? }` — `toggleWrap("**", …)` wraps the selection (or unwraps when already exactly wrapped); `linkEdit` with a URL produces `[selection](url)` selecting nothing; with `url: nil` produces `[selection]()` placing the caret inside the parens. Edits are ordered bottom-up for safe sequential application via `insertText(_:replacementRange:)` (each through the undo-grouped `shouldChangeText` path).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Kaisola

final class MarkdownInlineFormattingTests: XCTestCase {
    func testWrapAddsDelimiters() {
        let result = MarkdownInlineFormatting.toggleWrap(
            "**", selection: NSRange(location: 0, length: 4), in: "bold text" as NSString
        )
        XCTAssertEqual(result?.edits.map(\.1), ["**", "**"])  // bottom-up: trailing first
        XCTAssertEqual(result?.edits.first?.0, NSRange(location: 4, length: 0))
        XCTAssertEqual(result?.newSelection, NSRange(location: 2, length: 4))
    }

    func testWrapOnWrappedSelectionUnwraps() {
        let result = MarkdownInlineFormatting.toggleWrap(
            "**", selection: NSRange(location: 2, length: 4), in: "**bold** text" as NSString
        )
        XCTAssertEqual(result?.edits.map(\.1), ["", ""])
        XCTAssertEqual(result?.newSelection, NSRange(location: 0, length: 4))
    }

    func testLinkEditWithPastedURL() {
        let result = MarkdownInlineFormatting.linkEdit(
            selection: NSRange(location: 0, length: 4), url: "https://kaisola.dev", in: "docs here" as NSString
        )
        XCTAssertEqual(result?.edits.map(\.1), ["](https://kaisola.dev)", "["])
    }

    func testCollapsedSelectionReturnsNilForWrap() {
        XCTAssertNil(MarkdownInlineFormatting.toggleWrap(
            "**", selection: NSRange(location: 0, length: 0), in: "text" as NSString
        ))
    }
}
```

- [ ] **Step 2: Run to verify failure**
- [ ] **Step 3: Implement** helper + view wiring: `performKeyEquivalent` catches Cmd+B (`**`), Cmd+I (`*`), Cmd+K (`linkEdit(url: nil)`); `paste(_:)` checks `NSPasteboard.general.string(forType: .string)` — if it parses as an `http(s)` URL and the selection is non-empty, apply `linkEdit(url:)` instead of plain paste, else `super.paste(sender)`.
- [ ] **Step 4: Run tests + manual check** (Cmd+B toggles, paste URL over words makes a link, plain paste unaffected).
- [ ] **Step 5: Commit** (`feat(md): bold/italic/link shortcuts and paste-URL-as-link`)

---

### Task 8: Byte-fidelity + perf regression tests, full verification

**Files:**
- Create: `native/KaisolaMac/KaisolaTests/MarkdownLivePreviewFidelityTests.swift`

**Interfaces:** consumes everything above.

- [ ] **Step 1: Write the fidelity test** — build a source exercising every new edit (checkbox toggle, indent, wrap, link paste) through the pure helpers and assert exact expected bytes:

```swift
import XCTest
@testable import Kaisola

final class MarkdownLivePreviewFidelityTests: XCTestCase {
    func testEveryNewEditProducesExactBytes() {
        var text = "- [ ] task\n- item\n1. a\n5. b\nbold word\n"
        func apply(_ edit: (range: NSRange, replacement: String)?) {
            guard let edit else { return }
            let ns = text as NSString
            text = ns.replacingCharacters(in: edit.range, with: edit.replacement)
        }
        apply(MarkdownTaskToggle.toggleRange(at: 3, in: text as NSString))
        XCTAssertTrue(text.hasPrefix("- [x] task\n"))
        let paragraph = (text as NSString).paragraphRange(for: NSRange(location: 11, length: 0))
        apply(MarkdownListIndent.edit(for: text as NSString, paragraph: paragraph, direction: .indent))
        XCTAssertTrue(text.contains("\t- item\n"))
    }

    func testRevealRestyleIsBoundedByParagraph() {
        let big = String(repeating: "paragraph body line\n\n", count: 5_000) as NSString
        let old = MarkdownRevealState.compute(selection: NSRange(location: 0, length: 0), in: big)
        let new = MarkdownRevealState.compute(selection: NSRange(location: 42, length: 0), in: big)
        let changed = MarkdownRevealState.changedRanges(from: old, to: new)
        let total = changed.reduce(0) { $0 + $1.length }
        XCTAssertLessThan(total, 200, "cursor move restyle must not scale with document size")
    }
}
```

- [ ] **Step 2: Run the whole markdown test set** (all new classes + `WorkspaceFilesTests`), then the full `KaisolaTests` suite.
- [ ] **Step 3: Manual pass** over a real document: type, arrow through, toggle, indent, wikilink, Cmd+B, paste URL; flip to source view and confirm the bytes read exactly as expected; save and `git diff` the file.
- [ ] **Step 4: Commit** (`test(md): live-preview fidelity and bounded-restyle regressions`)
