# Kaisola User Guide

Kaisola keeps project files, agent chats, Mesh runs, and durable terminal
sessions together in one native macOS app. This guide covers setup,
everyday controls, and the recovery steps to use when something is not ready.

## Get ready

1. Choose **File > Open Folder…** and select a project folder.
2. Check the footer. **Connected** means saved terminals are visible; new
   terminals additionally require the connection to have write control.
3. For Claude or Codex, open **Settings > Accounts**. Use **Sign In to Claude**
   or **Sign In to Codex**, or choose an already configured named account.
4. Optional direct-provider keys live under **Settings > Models & Keys**. The
   **Test** action checks the provider's model-list endpoint without sending a
   model prompt.
5. Start a terminal with **Command-T**, or choose a specific agent from
   **File > New Agent Session**.

Kaisola terminals are durable. Closing a window or updating the app does not
end a running terminal. A terminal ends only when its process exits or you
explicitly choose **End Session**.

## Work with projects and sessions

- **Files** opens the active project's file tree. A single click opens a
  temporary preview; editing or choosing **Keep Open** makes the tab persistent.
- **Chat** runs supported agents through their chat adapters. Drafts and queued
  follow-ups are saved. If an adapter restarts, only prompts that were never
  dispatched can resume automatically.
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

Choose a project first. If saved sessions are visible but new terminals remain
disabled, the connection is temporarily read-only. Choose **Reconnect** in the
footer. Existing terminal processes remain untouched while Kaisola reconnects.

### Kaisola is offline

Choose **Reconnect**. If macOS asks about a Login Item, allow the Kaisola session
helper in **System Settings > General > Login Items** and reconnect. Do not kill
an existing terminal process to repair the app connection.

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
restart when active in-process agent turns would be interrupted.

## Report a problem

Include the Kaisola version, macOS version, the visible connection state, the
project action you attempted, and the exact safe error text. Never include API
keys, OAuth tokens, or credential files in a report.

Report reproducible problems at
[github.com/michaelofengenden/kaisola/issues](https://github.com/michaelofengenden/kaisola/issues).
