# Pane minus buttons and content-surface show doors

2026-08-08 · approved by Michael in session

## What

Replace the hidden-corner and mixed-metaphor pane chrome with one symmetric
scheme: every side pane hides itself from a `minus` button at its own
top-right, and the open terminal/agent-chat surface grows the matching show
buttons — only while something is hidden.

## Why

The file tree's hide button is an accent-colored `sidebar.trailing` glyph at
its top-LEFT, the preview's dismissal is an `xmark` that only exists when no
tabs are open, and the show controls are hover-only in the titlebar band, so
they are effectively invisible. Michael asked for minus buttons at each
pane's top-right and visible show buttons on the content surface.

## Design

### File tree pane (`WorkspaceRailView`)

- Remove the leading accent `sidebar.trailing` button from the header row.
- Add a `minus` button at the trailing end of the same header row (after the
  refresh button and the mutation spinner), styled like the header's other
  quiet glyphs (caption weight, secondary foreground).
- Same action (the existing `close` closure), same help copy with the ⌘B
  hint, accessibility label stays "Hide Files".

### File preview pane (`FilePreviewView`)

- Add a `minus` button at the very trailing end of the header, present in
  BOTH header shapes (tab-less and tabbed).
- It hides the whole column non-destructively via a new `hideColumn` closure
  wired by `RootShellView` to the same path as the toggle-document command,
  so the current file and tabs are remembered and restored on reopen.
- Remove the tab-less `xmark` (close document). Per-tab close buttons are
  untouched. `closeFilePreview` remains reachable programmatically.
- Help: "Hide Document" plus the toggle-document shortcut hint.
  Accessibility label "Hide Document".

### Show doors on the content surface (`RootShellView`)

- A small floating control group pinned to the top-right of `detailContent`,
  overlaid on the terminal/chat surface with a quiet material capsule
  backing (same family as other floating chrome).
- Contents, each present only while needed:
  - `sidebar.trailing` "Show Files" — only while the files rail is hidden
    and the project has a directory.
  - `doc.text` "Show Document" — only while the preview column is hidden.
    Activation uses the existing toggle path: restores the last document,
    or opens Files when there is nothing to restore.
- When both panes are visible the group renders nothing.
- The hover-only titlebar toggles (`DetailToggleHoverSensor`,
  `filesToolbarControl`, `filePreviewToolbarControl`, and their reveal
  state) are removed. The footer overflow menu items, ⌘B, the
  toggle-document shortcut, and the command palette remain the permanent
  keyboard/menu doors.

## Not doing

- No change to per-tab close behavior, browser card close, pane widths, or
  the footer menu.
- No always-visible toggles on the content surface (explicitly decided:
  show buttons appear only while a pane is hidden).

## Testing

- Update any tests pinning the rail header or preview header layout.
- New assertions: rail hide control is trailing with label "Hide Files";
  preview hide control exists in the tabbed header too and routes through
  the non-destructive hide (restore works after reopen); show doors appear
  exactly when their pane is hidden and disappear when both are open.
