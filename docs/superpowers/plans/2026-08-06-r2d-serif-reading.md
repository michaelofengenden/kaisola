# R2-D: Serif Reading Typography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LessWrong-grade reading typography in the byte-fidelity Live Preview: serif body, tuned measure, styled quotes and code blocks.

**Architecture:** Restyle `MarkdownEditingStyle` with trait-composing font resolution; extend the layout-manager decoration model to range-backed kinds with visual-fragment enumeration; add a measure/centering inset. No text-storage mutations; edit-time cost unchanged (spec 1d). Spec §1 (rev 3).

**Tech Stack:** Swift/AppKit/TextKit 1, XCTest.

## Global Constraints

- Byte fidelity: attributes only; the existing `assert(storage.string == before)` stays green.
- Measure defined in unmagnified document points (≈620 pt); magnification scales it naturally — never double-scale.
- Trait composition: emphasis composes onto the resolved base face at that range (serif in body, sans in tables, mono in code).
- Decorations are range-backed and enumerate every intersecting visual line fragment.

---

### Task 1: Composed font resolution
Modify `Features/Workspace/FilePreviewEditors.swift` `MarkdownEditingStyle`:
```swift
static func bodyFont(size: CGFloat) -> NSFont      // NSFont.systemFont(...).withDesign(.serif) via NSFontDescriptor
static func composed(base: NSFont, bold: Bool, italic: Bool) -> NSFont  // symbolic traits on the base's descriptor, fallback to base on failure
```
`baseAttributes` → serif body 16 pt, paragraph style lineSpacing for ~1.5 leading; `.bold`/`.italic`/nested spans resolve via `composed(base:)` where base = the face already resolved at that range (serif body, sans table cell — table styler runs first, spans compose onto it), replacing static fonts and `obliqueness`; headings sans, retuned `[28, 23, 20, 17, 16, 15]` with tracking −0.3 on H1/H2. Tests: serif bold in body; sans bold in a table cell; bold+italic nests; quote face is full-size serif italic. Commit `feat(md): serif reading face with trait composition`.

### Task 2: Reading measure
Modify `FilePreviewEditors.swift` (container sizing ~1688, width-change restyle path):
```swift
enum ReadingMeasure {
    static let maxWidth: CGFloat = 620   // unmagnified document points
    static func inset(paneWidth: CGFloat, magnification: CGFloat) -> CGFloat
    // = max(12, (paneWidth/magnification - maxWidth) / 2), returned in document points
}
```
Applied via `textContainerInset.width` on layout/width change (the existing `restyleIfDocumentWidthChanged` hook). Tests: inset math at several widths/magnifications (clamps at 12, centers above the cap, no double-scale: inset at 2x magnification equals inset at 1x for the same document-space width). Manual: anchor continuity across resize/zoom on a long doc with tables and images. Commit `feat(md): centered reading measure`.

### Task 3: Range-backed decorations — quote bars and code cards
Modify `Features/Workspace/MarkdownLiveEditor.swift` (`Decoration` ~258, drawing ~344):
```swift
struct Decoration: Equatable {
    enum Kind { case rule, fill, quoteBar, codeBlockBackground }
    let range: NSRange          // replaces single characterIndex+width for the new kinds
    let kind: Kind
}
```
Drawing for `.quoteBar`/`.codeBlockBackground` enumerates line fragments over `glyphRange(forCharacterRange:)` and draws per fragment: quote bar = 3 pt rounded accent bar in the leading gutter of each fragment; code background = full-fragment-width quiet fill, corner rounding only on the first and last visual fragments. Emission: `MarkdownTableStyler.applyGeometry`'s decoration pass (or a sibling emitter in the same styling pass) emits quote/code decorations from the scan's block spans. Behind them, quote text uses Task 1's serif italic; code keeps mono. Tests: fragment enumeration on soft-wrapped fixtures (a 3-line-wrapped quote yields 3 bar fragments); first/last rounding flags. Commit `feat(md): quote bars and code cards drawn per visual fragment`.

### Task 4: Palette + polish pass
Thematic breaks, table strokes, link color, checkbox accent re-tuned to sit with the serif (one place: the attribute/color constants in `MarkdownEditingStyle` + decoration colors). Visual check at 100%/150% zoom, light + dark. Byte-fidelity + bounded-restyle regressions green. Commit `feat(md): reading palette`.

### Task 5: Full verification
All markdown test classes + full suite; manual read of a long real document (harvest blueprint) checking: serif body, centered measure, quote bars, code cards, tables sans, reveal still works, no anchor jumps on zoom. Commit `test(md): serif reading verified`.


---

## Status (2026-08-07 morning)

Done: serif face with trait composition (Task 1), centered reading measure (Task 2). Deferred to the next round: range-backed quote bars and code-block cards (Task 3) and the palette pass (Task 4) — decoration-model surgery deserves a fresh session.
