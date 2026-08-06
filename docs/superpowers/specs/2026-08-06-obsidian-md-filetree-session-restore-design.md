# Obsidian-style Markdown, file tree fade, session restore (2026-08-06)

Three independent workstreams, agreed with Michael on 2026-08-06. They share no code and should land as three separate PR-sized tracks. A cross-cutting principle applies to all of them.

**Performance principle (applies everywhere):** Kaisola should feel instant. No feature here may block the main thread, delay app launch, or add per-keystroke work proportional to document size. Disk space is explicitly free to spend: prefer keeping data (scrollback, transcripts, recovery snapshots) over pruning it, and prefer precomputed or cached state on disk over recomputing at runtime.

---

## 1. Obsidian-style Markdown editing (Live Preview)

### Current state

The rendered Markdown view is already a live editor, not a preview. `MarkdownRenderedEditor` (`native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewEditors.swift`) holds the file's exact bytes in an editable TextKit 1 `NSTextView`, styles them with temporary attributes, paints images from the layout manager, and autosaves after 700 ms of quiet. Byte fidelity is the design's spine: the bytes on screen are the bytes saved.

The gap to Obsidian is one behavior: syntax marks (`##`, `**`, backticks, link URLs, HTML tags) are hidden permanently, rendered as invisible 0.1 pt runs (`MarkdownEditingStyle`, `.syntax` case). Editing a delimiter requires flipping to the raw source editor with the toolbar pencil. Obsidian instead reveals syntax exactly where the cursor is.

### Decision

Extend the native editor. Do not move Markdown into the CodeMirror 6 webview island. The hard part of Live Preview (an always-editable rendered surface with exact-byte saves) already works natively, and the webview route would abandon the image-painting layout manager, project-confined drag import, and the native-shell thesis for a rewrite with real regression risk.

### Changes

**1a. Cursor-line syntax reveal (the core).**
The styling pass gains an active range: the paragraph or paragraphs containing the cursor or selection. Syntax spans inside the active range render as visible dimmed marks at normal text size (secondary label color). Everywhere else they stay hidden exactly as today. On selection change, only the paragraphs whose state changed (newly active, newly inactive) are restyled; the pass never re-walks the whole document. The line reflows slightly when marks appear; Obsidian behaves the same way and it is acceptable. The raw source toggle stays as the escape hatch and as the surface for bulk syntax surgery.

Reveal also applies to constructs the editor draws over the source: a table row under the cursor shows its raw pipe syntax; a heading under the cursor shows its `#` prefix.

**1b. Clickable checkboxes.**
`- [ ]` and `- [x]` list items render the bracket group as a drawn checkbox (using the same layout-manager drawing path that paints images, so nothing enters text storage). Clicking the checkbox toggles the single source byte (`x` or space) as a normal text edit: it participates in undo and autosave.

**1c. Smart lists.**
Enter inside a bullet, numbered, or checkbox item continues the list with the right prefix. Enter on an empty item removes the prefix and ends the list. Tab and Shift-Tab indent and outdent the current item. Numbered lists renumber only the touched contiguous list block.

**1d. Wikilinks.**
`[[name]]` styles as a link. Resolution searches the workspace tree for a Markdown file whose name matches (case-insensitive, `.md` implied); the index of names is built from the already-loaded file tree model, not from a fresh directory walk. Click opens the target in a file tab through the existing link-follow path. An unresolvable target renders dimmed and inert. Out of scope for v1: creating files on click, backlinks, graph view.

**1e. Formatting helpers.**
With a selection: Cmd+B toggles `**` wrapping, Cmd+I toggles `*`, Cmd+K wraps as `[selection](url)` placing the cursor in the URL slot. Pasting a URL over a selection produces `[selection](pasted-url)`. All are plain byte edits in `MarkdownNativeTextView` through the normal undo path. Image drag-in already exists and is untouched.

### What stays the same

The outline panel, the source toggle, autosave, crash-recovery journaling, external-change reconciliation, table drawing, and the byte-fidelity contract (styling never mutates text storage) all stay as they are.

### Performance

The span scanner already runs off the main actor on a debounce. Syntax reveal adds selection-change work bounded by the size of the affected paragraphs, not the document. The wikilink name index is a dictionary rebuilt when the file tree model changes, never on keystroke.

### Testing

Pure string-level unit tests: reveal-range computation around a cursor position, checkbox byte toggle, list continuation and renumbering, bold/italic wrap and unwrap, wikilink resolution. One byte-fidelity regression test: open, perform each new edit type, save, and diff against the expected exact bytes.

---

## 2. File tree: names fade, the three dots never move

### Current state

This shipped once and regressed. `WorkspaceRailView.fileName` (`native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift:651-686`) already masks long names with a trailing gradient fade, and the row reserves `optionsClearance` (30 pt) for the always-visible floating `···` options button.

The bug: `.fixedSize(horizontal: true, vertical: false)` on the name `Text` makes the label report its full ideal width as its minimum. That minimum propagates up through the row, so a long file name pushes the whole row wider than the rail; the rail's clip shape chops it, and the `···` overlay (anchored to the oversized row's trailing edge) is carried off the panel with it. `backlog-round-ha` in the tree today ends at the panel edge with no dots and no fade.

### Change

Render the name so its width can never propagate into row layout: a flexible, clipped container (for example `Color.clear` with the `Text` as a leading-aligned overlay, or an equivalent non-propagating wrapper) carries the existing gradient mask. The row keeps its `optionsClearance` trailing padding, so the fade completes just before the dots. Result: every row, however long its name, shows icon, name fading out, then the `···` button pinned at the trailing edge.

The search-results row in the same file currently uses middle ellipsis truncation. It adopts the same faded-name treatment so the rail is consistent. The fade-name rendering is extracted into one shared view or modifier used by both rows.

### Testing

A layout unit test (or the project's closest equivalent) asserting that a row with a pathologically long name reports a width no larger than the rail width, plus a visual check in the running app against the screenshot case.

---

## 3. Session restore after quit or reboot

### Current state

Workspace, file tabs, pane layout, and agent chats already restore automatically at launch, and agent chats resume their provider session (`session/resume` with the stored session id, guarded by account binding). Two-phase quit flushes all state. This part already meets the goal.

Terminals do not survive. On relaunch the app reattaches only to terminals still alive in the broker's inventory. After a reboot the broker is dead, so restore skips every terminal record, the layout normalizer drops the panes, and the next state save erases them permanently. Scrollback spool files survive on disk in `terminal-cache/` but the next spawn constructs its spool with `fresh: true` and unlinks them unread. The stored working directory is snapshotted at creation time and never updated, so a shell that has `cd`-ed away would be restored to the wrong place.

### Decision

Terminal resurrection, fully automatic, with one safety gate: plain shells respawn on their own; terminals that were running an agent CLI come back as a shell plus a one-keystroke resume chip, because auto-running `claude --continue` on every reboot silently spends usage and risks the wrong account binding. Michael chose this explicitly.

### Changes

**3a. Never erase a terminal pane.**
A persisted terminal absent from broker inventory becomes a dormant pane instead of being dropped. Layout normalization keeps dormant panes; state saves keep their records. `native-sessions.json` already holds what resurrection needs (id, projectID, cwd, title, agentID, accountBinding).

**3b. Respawn.**
At restore, each dormant plain-shell terminal is respawned through the broker at its recorded working directory, asynchronously after the UI is up, never blocking launch. A dormant agent terminal respawns as a plain shell at the recorded directory and shows an inline chip naming the agent's resume command (from the existing `AgentRegistry.resumeCommand` table, e.g. `claude --continue`); one click or keystroke runs it. The chip appears only when the account binding still normalizes, mirroring the existing chat-resume guard.

**3c. Cold scrollback replay.**
The broker stops destroying prior spools. A respawn for a known terminal id reads the retained spool first and returns it as recovered scrollback, which the terminal view shows above the new session with a clear divider (dimmed, marked as from before the restart). Spools are kept indefinitely and rotated by size generously (disk is free); a size cap exists only to bound single-file read time, not to save space.

**3d. Working-directory tracking.**
The broker refreshes each terminal record's cwd from the live process (macOS `proc_pidinfo`-based lookup) whenever it writes its periodic state snapshot, and once more during shutdown flush, so resurrection reopens where the shell actually was, not where it started.

**3e. Retention loosened.**
The agent-chat transcript cap rises from 40 chats to 1000, still evicted oldest-first by update time. File-preview recovery snapshots and terminal spools are never pruned for space.

### Out of scope

Multi-window session sets, resuming an agent turn that was mid-flight at quit, a picker over provider-side session history (`claude --resume` list), and broker auto-start at login (resurrection makes it unnecessary: a fresh broker serves respawns fine).

### Performance

Launch paints the restored UI first; respawns and spool reads happen after, concurrently, with the pane showing its recovered scrollback immediately and going live when its shell arrives. Spool replay streams; it never loads a giant file into memory at once.

### Testing

Broker-side tests: spool retained across restart, respawn returns recovered scrollback, cwd refresh updates the record. App-side tests: dormant pane survives normalization and a save/load round trip; agent terminal produces a chip and does not auto-run; account-binding mismatch suppresses the chip. One end-to-end test through the existing broker test harness simulating kill-broker-then-relaunch.
