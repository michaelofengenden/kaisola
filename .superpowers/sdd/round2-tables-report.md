# Round two: tables that look like tables and stay ordinary text

Follow-up to `backlog-markdown-report.md` §7.1 — *"is there no way to render
tables and edit them in place for continuous typing?"*

Worktree `.claude/worktrees/agent-ac106ec8ad43471c7`, branch
`worktree-agent-ac106ec8ad43471c7`, branched from `581e400` on
`backlog-integration`.

---

## 1. The mechanism

One text view. One source string. No widget, no block swap, no modal cell
editor, no character inserted or removed. A table becomes a grid entirely
through **attributes**:

| What you see | What produces it |
| :----------- | :--------------- |
| Columns lining up | `.kern` on the padding runs that are already between the pipes |
| The vertical rules | the pipes themselves, recoloured to `separatorColor` |
| The header band | a fill drawn behind the line by the layout manager |
| The `\|---\|` row as a hairline | that row collapsed to a 6 pt blank strip, hairline drawn behind it |
| `---` as a rule | the same treatment at pane width |

Because the correction is `.kern` — extra advance after a character — the grid
is produced by *moving glyphs*, not by editing text. `textView.string` is
untouched; the save path writes that string; the debug assertion and
`testMarkdownTableStylingRendersAGridWithoutAlteringDocumentBytes` both pin it.

Typing inside a table is therefore ordinary typing. The caret is in the same
text view over the same characters, arrow keys and selection behave as they do
in a paragraph, ⌘F finds the pipes, and the columns re-measure on the next
70 ms debounce.

### The arithmetic

`MarkdownTableGeometry` (pure, `Sendable`, no AppKit state):

```
columnWidths[j] = max over non-delimiter rows of the measured cell width
columnOrigins[0]   = leadingPipeWidth + padding
columnOrigins[j+1] = columnOrigins[j] + columnWidths[j] + padding + pipeWidth + padding
```

Each row is then walked as a sequence of runs — pipe, padding, content,
padding, pipe — and at each position that must be hit exactly, the delta is
handed to the nearest preceding run. Padding runs spread it over every space so
the caret keeps moving forward through them; anything else takes the whole
delta on its last character. Per-column alignment moves the slack: none before
the content for `:---`, all of it for `---:`, half for `:---:`.

Measurement is Core Text (`CTLineGetTypographicBounds`) over the storage's own
attributed substrings, which is why a cell containing `**bold**` still lands on
its column: the `**` has already collapsed to 0.1 pt by the time it is
measured.

### Ordering

The styling pass now runs in three stages inside the one debounce:

1. **Table typography** — row face, row paragraph style, the collapsed rule
   rows. Applied *before* the inline span pass so a cell's own bold, link, or
   inline code still wins over it.
2. **Inline spans** — unchanged.
3. **Geometry** — measured against what the storage actually resolved to, then
   `.kern`, head indents, pipe colour, and the decorations the layout manager
   draws.

### What a table too wide for the pane does

Its fonts are *scaled* rather than replaced — inline code and emphasis inside a
cell keep their own face — up to twice, with a floor at 10.5 pt. If it still
does not fit it falls back to ordinary wrapped source with dimmed pipes, rather
than being clipped into columns nobody can reach.

### What is deliberately conservative

- A table is a table only when GitHub says so: a delimiter row whose column
  count equals its header's, never inside a fence.
- `---` is a rule only when the previous line is blank. Under a paragraph it is
  a Setext heading underline, and on line one it opens YAML front matter; both
  keep their literal source, because drawing a rule there would be a lie about
  what the document says.

`MarkdownTableSource` gained a public `layout(of:)` reporting a line's pipes as
well as its cells, and the block editor's `localCellRanges` now delegates to
it — the two paths share one scan instead of two, which is what keeping
`MarkdownTableSource` alive was for.

---

## 2. The bug the proof found

Verifying "no scroll jump on external change" turned up a defect in the
round-one code that had never fired: **the viewport anchor was dead code in the
running app.**

`viewportAnchor()` gated on `scrollView.contentView.bounds.origin.y > 0`.
Instrumenting the live process printed:

```
visible={{0, -121863}, {480, 787}}  tvFrame={{0, -121883}, {480, 121941}}
```

This scroll view holds the text view at a frame origin of **-121883**, so the
clip's own bounds origin is about -121863 at the *top* of the file and never
becomes positive anywhere. Every anchor came back `nil`; `replaceText` skipped
its restore under the same `> 0` test. Appending one line to a 90 KB file on
disk moved the reader from visible range **47733 → 33081** (originY -49350.5 →
-34257.5), a 15 109 pt jump.

Fixed by measuring in `documentVisibleRect` — the document's own coordinates,
indifferent to where the clip put the frame — and scrolling back with
`NSView.scroll(_:)` instead of moving the clip's bounds by hand.

A second cause sat behind it: `replaceText` measured the new height moments
after `textView.string = value`, when every attribute has been stripped, so it
compared a styled height against an *unstyled* one and restored a proportion of
the wrong number. The replacement now hands its character anchor to the styling
pass, which forces layout before restoring — a line rect asked for *without*
additional layout would otherwise still answer with the geometry the
replacement left behind.

---

## 3. Verification

Build warning-clean (0 Swift warnings, 0 errors) after forcing recompilation of
all five touched sources.

- `npm run native:test:focus -- WorkspaceFilesTests DataPreviewsTests
  SyntaxHighlighterTests` — green.
- `npm run native:test:changed -- --include-working-tree` — green,
  "Changed-file test lane passed."
  (The runner's signal was checked by deliberately breaking
  `columnOrigins == [17, 65]` and confirming `** TEST FAILED **` naming the
  test.)

### Alignment, proved twice

**Arithmetically, in a unit test.** `testMarkdownTableGeometryLandsEveryRowOnTheSameColumns`
replays the planner's own kern deltas character by character — the same advance
arithmetic TextKit performs — over a ragged table:

```
| a | bb |        columnWidths  [21, 14]
| - | -- |        columnOrigins [17, 65]      totalWidth 96
| ccc | d |       separators    [0, 48, 89]   ← identical for all three rows
|x|yy|
```

**In the running app, over AX.** `AXBoundsForRange` on the document text area,
pid-exact, for a table whose three columns are `:---`, `---:` and `:---:`:

| Row | col 0 x | col 1 right edge | col 2 centre |
| :-- | ------: | ---------------: | -----------: |
| header | 892.65 | 1093.15 | 1146.60 |
| One | 892.65 | 1093.16 | 1146.60 |
| Two | 892.65 | 1093.15 | 1146.60 |
| Three | 892.65 | 1093.16 | 1146.60 |

Left column origins identical, right column right-edges identical, centre
column centres identical — the three alignments doing exactly what the
delimiter row asked for. The delimiter row itself reports `h=7.00` against
`h=20.00` for every text row, and its string is still
`| :-------- | -------: | :---: `.

Typing `-AND-WIDER` into the first cell widened column 0 from 81.85 to 172.62
and moved columns 1 and 2 right by the same amount in every row, all four right
edges landing on 427.92 and all four centres on 481.37.

### Byte fidelity and the viewport

Development-profile launch, isolated fixture state (per-pid defaults suite, no
broker), 90 025-character document with tables at char 48114,
`AXUIElementCreateApplication` on the exact pid:

```
AFTER_SCROLL          visible=47733..<48454  caret=48182  originY=-49350.5
AFTER_TYPING          visible=47733..<48460  caret=48191  originY=-49350.5
AFTER_RESTYLE         visible=47733..<48460  caret=48191  originY=-49350.5
AFTER_AUTOSAVE        visible=47733..<48460  caret=48191  originY=-49350.5
AFTER_COMMAND_S       visible=47733..<48461  caret=48192  originY=-49350.5
AFTER_COMMAND_F       visible=47733..<48461  caret=48192  originY=-49350.5
AFTER_EXTERNAL_CHANGE visible=47733..<48454  caret=48182  originY=-49350.5
```

The row read back as `| One-TYPED | file.swift:12 | kept |` — every pipe still
in the document. On disk the file went **90 052 → 90 058 bytes**, exactly the
six characters typed, and a further `X` took it to 90 059.

**Observation method, honestly.** Screenshots are TCC-blocked, so nothing here
is a visual check: every number above is `AXNumberOfCharacters`,
`AXVisibleCharacterRange`, `AXPosition`, `AXStringForRange` and
`AXBoundsForRange` read from the live process, plus `wc -c` on the file.
Keystrokes were posted with `CGEvent.postToPid` (Command-S, Command-F via the
Edit menu's `AXPress`); the character insertion was done by setting
`AXSelectedText`, which NSTextView services through the same
`insertText:replacementRange:` a keystroke takes, rather than by CGEvent —
CGEvent text entry would have depended on which application was frontmost.

---

## 4. Known gaps

1. **Freshly typed characters are unstyled for 70 ms.** Same cause as round
   one's gap 5: `isRichText = false` forces `typingAttributes`, so a character
   typed inside a table row carries no kern until the debounce lands. Visible
   as a momentary shimmer of the column edge, not of the text.
2. **The delimiter row is 6 pt and clear.** You can still click into it and
   type — it is ordinary text — but it is deliberately hard to see, which is
   the point. The raw-source toggle remains the explicit way to edit it.
3. **A table wider than the pane is not aligned at all.** Font scaling only
   buys about 30 %; beyond that it reverts to wrapped source. A pane-width
   horizontal scroll for table regions alone would fix it and was not
   attempted.
4. **`MarkdownTableNavigation` is still unreachable from the UI.** Tab-between-
   cells has no home in a continuous editor; the type is left with its tests
   rather than deleted, in case cell-aware Tab lands later.
5. **CI visual baselines will move again.** `preview`, `preview-edit`,
   `preview-table-edit` and `preview-dirty-tab` now capture aligned grids.
6. **The worktree had no `node_modules`.** The Node half of the changed-file
   lane needs `rollup`; a symlink to the parent repo's tree was used for the
   run and should not be committed.
