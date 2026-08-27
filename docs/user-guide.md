# Kaisola User Guide

Kaisola keeps project files, agent chats, Mesh runs, and terminal session
records together in one native macOS app. This guide covers setup,
everyday controls, and the recovery steps to use when something is not ready.

## Get ready

1. Choose **File > Open Folder…** and select a project folder.
2. For Claude or Codex, open **Settings > Accounts**. Use **Sign In to Claude**
   or **Sign In to Codex**, or choose an already configured named account.
3. Optional direct-provider keys live under **Settings > Models & Keys**. The
   **Test** action checks the provider's model-list endpoint without sending a
   model prompt.
4. Start a terminal with **Command-T**, or choose a specific agent from
   **File > New Agent Session**.

Terminal processes run inside Kaisola and end when Kaisola quits or installs an
update. Kaisola keeps each session record, including its working folder, title,
and agent choice. On relaunch, records that were active reopen as fresh shells
in their saved working folders. An individual terminal also ends when its
process exits or you choose **End Session**.

## Work with projects and sessions

- **Files** opens the active project's file tree. A single click opens a
  temporary preview; editing or choosing **Keep Open** makes the tab persistent.
  A file's action menu can rename it, move it to another project folder, reveal
  it in Finder, or move it to the recoverable macOS Trash. The outline menu in
  supported source files jumps to exact headings, declarations, and keys.
- The scope button in **Files** explicitly follows files declared by the
  currently selected Chat or Mesh. It starts off, follows only structured agent
  file activity, and opens replaceable previews so background work cannot pin
  documents or infer paths from ordinary response text.
- **Chat** runs supported agents through their chat adapters. Drafts and queued
  follow-ups are saved. Long histories open at the latest messages; continue
  scrolling upward to load earlier pages without losing your reading position.
  Unsent attachments stay with the draft across relaunches. If an adapter
  restarts, only prompts that were never dispatched can resume automatically.
- **Mesh** gives several agents one task. Editing columns use isolated Git
  copies when the project supports them, and the review controls show changes
  before integration.
- **Recently Closed** holds recoverable Chat and Mesh surfaces. Restore them or
  delete them permanently with a separate confirmation.
- **Git Panel** shows the active project's status and pull-request review. Push
  and pull-request creation remain separate from the review step.

## Review permissions safely

Permission requests keep three decisions distinct:

- **Deny** rejects this request.
- **Allow Once** approves only this request.
- **Always Allow** first shows the exact persistent rule that would be created.

Review the full command, resource, and affected paths before approving. Files
covered by the sensitive-file list always ask and cannot be covered by a saved
allow rule.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Command-K | Command Palette |
| Command-L | Message Current Agent |
| Command-T | New Terminal Session |
| Command-O | Open Project Folder |
| Shift-Command-N | New Window |
| Command-B | Show or Hide Files |
| Shift-Command-B | Show or Hide Document Preview |
| Shift-Command-O | Open Current File in External Editor |
| Option-Command-Left/Right | Previous or Next File Tab |
| Control-Command-Left/Right | Focus Previous or Next Terminal Pane |
| Option-Command-K | Clear Visible Terminal Scrollback |
| Option-Command-Down | Scroll Terminal to Latest Output |
| Command-Comma | Settings |
| Command-F | Find in the Active Text or Terminal Surface |

The menu bar is the authoritative list for shortcuts available in the current
version and disables actions that do not apply to the focused surface.

## Troubleshooting

### New Terminal is disabled

Choose a project first. If a project is already open, terminals are still
preparing. Wait a moment and try again. Chat and Mesh remain available while
terminal startup finishes.

### Terminal input is temporarily unavailable

The terminal header explains which local state applies. Kaisola retries input
automatically for a terminal it owns. If another window or Companion controls
input, return to that controller or close it before typing in this window. Other
terminals remain usable.

### Claude or Codex asks you to sign in

Open **Settings > Accounts** and run that provider's sign-in action. Named
accounts use separate `CLAUDE_CONFIG_DIR` or `CODEX_HOME` folders. The provider
CLI owns the credentials; Kaisola stores only the account label and directory.

### A direct API key fails its test

Check the provider and Base URL under **Settings > Models & Keys**, paste the
key again, and choose **Test** before saving. A rejected key is different from a
timeout or provider rate limit. Kaisola never displays the saved key or the
provider's raw error body.

### A file changed outside Kaisola

A clean preview reloads from disk. If you also have unsaved edits, Kaisola shows
a conflict instead of overwriting either version. Choose **Reload from Disk**
or **Overwrite** deliberately; **Reveal in Finder** and **Open Externally** are
available for unsupported files.

### A Chat or Mesh run disappeared from the layout

Open **Recently Closed** in the project rail and choose **Restore**. **Stop** and
ordinary close preserve transcripts, drafts, queued prompts, and recoverable
Git work. Only a confirmed permanent delete removes them.

### Companion cannot reconnect

Open **Settings > Companion** on the Mac. Confirm nearby access or Link is
enabled, then pair again if the device was revoked or its account changed.
Revocation intentionally invalidates old resume access immediately.

### Updates do not appear

Open **Kaisola > Check for Updates…**. Automatic checks and downloads can be
configured under **Settings > General** in signed builds. Kaisola asks before a
restart when active in-process agent turns would be interrupted. Terminal
records reopen as fresh shells after the update relaunches Kaisola.

## Report a problem

Include the Kaisola version, macOS version, the affected project and terminal,
the action you attempted, and the exact safe error text. If input was not
available, include whether the header said Kaisola was retrying or another
window or Companion had control. Never include API keys, OAuth tokens, or
credential files in a report.

Report reproducible problems at
[github.com/michaelofengenden/kaisola/issues](https://github.com/michaelofengenden/kaisola/issues).
