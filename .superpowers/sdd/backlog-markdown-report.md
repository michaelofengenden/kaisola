# Markdown editing: continuous document surface

Backlog item: *"editing md files is very annoying. it keeps jumping me to the
top, and I don't like how I have to edit preview md files block by block. I want
to have a smooth lesswrong/google docs experience editing md files."*

Worktree `.claude/worktrees/agent-ad53c236d51188251`, branch
`worktree-agent-ad53c236d51188251`, branched from `216196b` (v1.1.9).

---

## 1. Diagnosis

### (a) What "block by block" was

`MarkdownDocumentView` rendered the file as a `LazyVStack` of structural blocks
and swapped **exactly one** block for a small embedded text editor at a time.

| Mechanism | Location (pre-change) |
| --- | --- |
| One-block-at-a-time edit state | `MarkdownPreview.swift:963` `@State private var activeEdit: ActiveEdit?` |
| Body splits into before / editor / after | `MarkdownPreview.swift:982-985` |
| Entering an edit re-parses and slices the document | `MarkdownPreview.swift:1206-1217` `beginEditing(_:)` |
| The editor itself, capped at 420 pt | `MarkdownPreview.swift:1164-1176` |
| Exact-range write-back on every keystroke | `MarkdownPreview.swift:1257-1281` `updateActiveText(_:)` |
| The range replacement primitive | `MarkdownPreview.swift:685-691` `MarkdownSourceDocument.replacing(_:in:with:)` |
| Table cells were a *second*, finer-grained commit path | `MarkdownPreview.swift:1300-1319` `commitTableCellEdit()` |

So: double-click a paragraph, type into a boxed editor, press Done, double-click
the next paragraph. Every change was a separate committed write into a computed
source range.

### (b) Why it jumped to the top — two independent causes

**Cause 1 — `ForEach` identity churn while typing.**
`MarkdownSourceBlock.id` was its source location (`MarkdownPreview.swift:564`,
`var id: Int { range.location }`), and `updateActiveText` shifted the location of
**every block after the caret** by the edit delta on each keystroke
(`MarkdownPreview.swift:1264-1278`). Every length-changing keystroke therefore
re-identified every block below the edit, so SwiftUI tore down and rebuilt the
whole lazy stack under the scroll view, the measured content height churned, and
the offset collapsed. Entering/leaving an edit additionally swapped the
`LazyVStack` between a one-child and a three-child shape
(`MarkdownPreview.swift:982-1003`). The `ScrollView` at
`MarkdownPreview.swift:980` had **no** position retention at all — unlike the
plain-text surfaces, which share `FilePreviewTextScrollMemory`.

**Cause 2 — images collapsing after every save.**
`imageRevision` was wired to the workspace watcher's monotonic change token
(`FilePreviewView.swift:794` ← `workspaceWatcher.changeToken`). That token fed
`MarkdownLocalImageView.loadIdentity` (`MarkdownAssets.swift:301-303`), whose
`.task(id:)` set `image = nil` and fell back to a 64 pt `ProgressView`
(`MarkdownAssets.swift:334-337`); the cache key embedded the same token
(`MarkdownAssets.swift:279`), guaranteeing a miss. The token advanced on **the
document's own 700 ms Markdown autosave** writing the `.md` file into the watched
tree (`FilePreviewView.swift:1361-1384`). Result: save → every image blanks →
document height collapses → the scroll view clamps the offset upward.

A third, smaller cost was found and fixed alongside: `.onChange(of: draft)` ran
`refreshHighlight()` on every keystroke (`FilePreviewView.swift:230`), which for
Markdown only wrote an empty `AttributedSource` into `@State` — a whole-view
SwiftUI invalidation per character, for output Markdown never renders. And
`beginAutomaticEditIfReady` re-parsed the entire document on every source change
(`MarkdownPreview.swift:1045`, `:1231`) to discard the result.

---

## 2. Architecture chosen: (A), single continuous rich editor

The whole document is one TextKit `NSTextView` holding the file's exact Markdown,
styled in place. Click anywhere, type. No blocks, no per-edit commits.

**Why (A) and not (B):** the byte-fidelity concern that motivated exact-range
block editing does not apply to a whole-file text view — it is *stronger* here.
Block editing had a write path (`replacing(range:with:)`) that had to compute the
right range; a whole-file editor has no write path at all, because the bytes on
screen are the bytes saved. The class of bug that once deleted relative images on
edit is now structurally impossible rather than defended against.

**The one real trade, made deliberately:** the structural renderer is gone, so
Markdown **tables render as their pipe source** rather than as a laid-out grid,
and `---` renders as literal dashes rather than a divider. Table *cell* editing
(double-click a cell, arrow between cells) is gone with it — a table is now
edited as text like everything else. Given the request was explicitly to stop
editing block by block, trading a table widget for one continuous document is the
right side of that trade, but it is a real loss and is called out here rather
than buried.

### What was added to make (A) not a regression

- **Inline images.** Drawn by an `NSLayoutManager` subclass
  (`MarkdownInlineImageLayoutManager`) with line fragments inflated through the
  layout-manager delegate. Deliberately *not* `NSTextAttachment`, which would
  require a real `U+FFFC` character in the document — exactly the kind of
  rendering artifact in the text storage that caused the historical image-loss
  bug. Only whole-line references are drawn; a line mixing prose and an image
  link keeps its source visible so a picture is never painted over a sentence.
- **Link following** via Command-click, under the unchanged
  `WorkspacePreviewLinkPolicy` (project files open in Kaisola, external schemes
  go to the browser, everything else refused).
- **Real typography.** See §4.

---

## 3. Killing the jump

- SwiftUI updates that carry the string already on screen are a no-op
  (`MarkdownEditorTextSync.plan` → `.unchanged`). Save, autosave, journal, and
  identical-bytes reconciliation all take this path, so the storage is never
  swapped and the viewport never collapses.
- A styling pass or a genuine text replacement re-pins the character that was at
  the top of the viewport (`viewportAnchor()` / `restore(_:)`), rather than
  keeping a pixel offset that no longer refers to the same text.
- A full text replacement (external reload, discard) restores position through
  `MarkdownEditorScrollRetention.restoredOrigin` — exact pixels when the height
  barely moved, proportional when it changed materially.
- Image cache identity is now path + mtime + size (`MarkdownImageIdentity`), so
  the document's own autosave no longer invalidates every image. An
  agent-written replacement still refreshes.
- The editor joins the shared `FilePreviewTextScrollMemory`, so the
  document ↔ raw-source toggle keeps its place.

---

## 4. Why styling moved to text-storage attributes

The pre-existing editor applied styling as TextKit **temporary** attributes.
Temporary attributes are documented as not affecting layout, and in practice a
temporary font drives neither glyph metrics nor line height: verified in the
running app, headings rendered at body size and "hidden" delimiters kept their
full width. That was invisible when the editor was a 420 pt box inside a
separately rendered document. Now that it *is* the document, the typography has
to be real, so the styling pass writes text-storage attributes.

**This does not weaken the byte guarantee.** Attributes are not characters:
`textView.string` is untouched, and the save path writes that string. The view is
`isRichText = false`, so styling cannot be typed, pasted, or copied out either. A
debug assertion enforces the invariant at runtime, and
`testLiveMarkdownStylingNeverAltersDocumentBytes` pins it in CI.

Measured on a 100 KB document: **31 ms** span scan (off the main actor) and
**67 ms** main-actor styling, both behind the existing 70 ms typing debounce.
Because full-document styling proved affordable, the viewport-window machinery
drafted for this was removed rather than shipped unused.

---

## 5. Verification

- Build warning-clean (0 warnings, 0 errors) after forcing recompilation of all
  five touched sources.
- `npm run native:test:focus -- WorkspaceFilesTests DataPreviewsTests
  SyntaxHighlighterTests` — green.
- `npm run native:test:changed -- --include-working-tree` — green,
  141/141 node tests, "Changed-file test lane passed."
  (The runner's pass signal was itself verified by deliberately breaking an
  assertion and confirming `** TEST FAILED **`.)

### Dev-launch AX proof

Development profile, `notes/native-audit-2026-07-30.md` (105 KB), pid-exact
`AXUIElementCreateApplication`. `totalCharacters=104164` confirms the **whole**
document is a single text area.

```
AFTER_OPEN            visible=0..<1516       caret=104164  frameOriginY=132.0
AFTER_SCROLL          visible=51146..<52994  caret=52000   frameOriginY=-22489.0
AFTER_TYPING          visible=51146..<53012  caret=52018   frameOriginY=-22489.0
AFTER_AUTOSAVE        visible=51146..<53012  caret=52018   frameOriginY=-22489.0
AFTER_TYPING (2nd)    visible=51146..<53024  caret=52030   frameOriginY=-22489.0
AFTER_COMMAND_S       visible=51146..<53024  caret=52030   frameOriginY=-22489.0
```

The visible range start stays at **51146** and the scroll offset stays at
**-22489.0** across typing, the 700 ms autosave, and an explicit ⌘S. Reverting
the file on disk while it was open (external-change reconciliation) also held:
`51146` / `-22489.0`, with the character count returning to 104164. ⌘F opens the
find bar without moving the viewport.

### Byte-fidelity proof (on-disk)

After two edits at character 52000 the file grew **105192 → 105222 bytes**,
exactly +18 (`"KAISOLA-LIVE-EDIT "`) +12 (`"SECOND-EDIT "`), and `git diff`
showed **one line changed** — the inserted text mid-word, every other byte of the
105 KB file untouched. Test edits were reverted.

---

## 6. Tests

Added to `WorkspaceFilesTests`: identical-text sync is a no-op; selection
clamping when external text shrinks; scroll retention (pixel-exact vs
proportional); whole-line image detection incl. HTML `<img>`, prose-line
rejection and badge rows; image-scan and styling-pass interaction budgets;
heading typography; whole-line image collapse; and the styling byte-identity
guarantee.

**No existing test was rewritten or deleted.** All Markdown tests target pure
model types (`MarkdownSourceDocument`, `MarkdownDocument`, `MarkdownTableSource`,
`MarkdownPreviewLayout`, `MarkdownEditingStyle`, `MarkdownAssetStore`), none of
which changed behaviour — including the image-preservation and exact-block-range
tests. One test drafted during this work (`MarkdownStylingWindow`) was removed
together with the production code it covered, once measurement showed the
viewport window was unnecessary.

## 7. Known gaps / follow-ups

1. **Tables and thematic breaks render as source.** The largest visible
   regression. A presentation-only table widget on the same layout-manager
   mechanism as images is the natural follow-up.
2. **`MarkdownTableSource`, `MarkdownTableNavigation` and
   `MarkdownSourceBlockCache` are no longer reachable from the preview UI.**
   They were kept (with tests) rather than deleted:
   `MarkdownSourceDocument`/`MarkdownSourceBlock` remain live for ACP transcript
   rendering, and the table helpers are the foundation for follow-up 1.
3. **CI visual baselines will move.** `preview`, `preview-edit`,
   `preview-table-edit` and `preview-dirty-tab` now capture the continuous
   editor. `automaticallyEditFirstBlock` / `automaticallyEditFirstTableCell` were
   replaced by a single `automaticallyFocus` flag; `KaisolaMacAppDelegate` (not
   owned here) still sets the same env vars and needs no change.
4. **The broker helper could not be packaged in this worktree** (no
   `node_modules`); the dev launch used a parent-repo symlink, since removed. The
   markdown surface does not involve the broker.
5. Typing directly inside a heading briefly shows the new characters at body size
   until the 70 ms restyle lands, because `isRichText = false` forces
   `typingAttributes`. Cosmetic; fixable by deriving typing attributes from the
   caret's run.
