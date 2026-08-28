# Minimal canonical shell design

## Status

The product direction is approved. This written specification awaits Michael's review.

The design branch starts from `e6cc84b9892dc4e4e10eaa3c8573ffdb4c8464c1`. Implementation begins only after approval and after rebasing onto the then-current `origin/main`. Work belongs on `ui/minimal-canonical-shell` in `/Users/michaelofengenden/Developer/kaisola-worktrees/minimal-canonical-shell`.

The baseline is clean:

- 288 Node contract tests passed.
- 207 focused native tests passed with no failures or skips. The selected suites were `RootShellLayoutsTests`, `SessionPaneLayoutTests`, and `NativePreviewSettingsTests`.
- A direct read-only Claude Code design critique checked the measurements and current control homes against source, returned `APPROVE WITH AMENDMENTS`, and the accepted amendments are incorporated here.
- The installed app remains Kaisola 0.1.141 build 1161001. This worktree has not launched, stopped, or replaced it.

## Campaign boundary

This is the first design in the current Kaisola modernization campaign. It covers the window shell, the left project and session rail, the main workspace bar, the optional right inspector, and the removal of the alternate navigation layout.

The following work remains separate because each item has its own state, failure modes, and verification:

- the already-merged updater dismissal fix and its remaining signed older-to-newer installation test;
- the separately implemented and verified selected-chat-first restoration and background hydration slice, whose integration remains independent;
- neutral terminal model names after the retired broker runtime;
- the remaining Settings consolidation;
- issue review, local installation, and release promotion.

The campaign remains active after this shell ships. Completing this design does not complete the larger goal.

## Problem

Kaisola currently renders several horizontal bands for one open session.

The default Left Tree layout receives a 52 point AppKit toolbar lane from `NavigationSplitView`, but puts no Kaisola controls in it. The detail area then adds a 32 point `unifiedSessionHeader`. The right Files rail adds a 42 point header, and the left rail ends with a persistent 40 point `ConnectionFooter`.

The alternate Top Bar layout adds a 36 point project strip, an optional Quick Actions row, and a 36 point session strip above the same pane header. It keeps the footer too. The result feels more like a web workspace than Finder, Safari, or Messages.

The application also maintains both shells as complete products. `NavigationLayout`, `RootShellRenderContract`, Settings, the View menu, the command palette, preview fixtures, and migration tests all know about both choices. That duplication makes every shell change harder and preserves the busier layout indefinitely.

## Goals

The shell has one persistent top bar. It never places a toolbar above a tab strip or another full-width header.

The shell should:

- keep projects and the complete session hierarchy in a native left source list;
- put immediate chat, terminal, Mesh, document, or browser content in the center;
- expose Files, Quick Look, and Details through one optional right inspector;
- show no tab when one surface is visible;
- place compact working-set tabs inside the same top bar when several surfaces are visible;
- retain every current action through the bar, a contextual menu, the menu bar, or an inline error state;
- remove ordinary broker and Reconnect wording from the shell;
- preserve the existing New Session draft rules;
- keep the white canvas and quiet translucent rails already established in Kaisola;
- support pointer, keyboard, VoiceOver, reduced motion, and narrow windows.

## Non-goals

This design does not change terminal ownership, process lifetime, transcript storage, provider resume, update installation, account authentication, or release packaging.

It does not remove useful runtime recovery. It removes permanent recovery chrome and implementation language from the normal interface.

It does not turn the right inspector into another session type. Editable documents and browser surfaces remain workspace content.

## One shell

`RootShellView` will render one canonical shell based on `NavigationSplitView`:

1. `QuietProjectRail` is the source-list column.
2. The central detail column contains the selected workspace content.
3. A trailing inspector is present only when the user opens it.
4. One native window toolbar supplies all persistent top chrome.

The `.leftTree` and `.topBar` strings survive only as legacy migration inputs. Runtime settings no longer publish a `NavigationLayout` value. The product has one layout.

The following alternate-layout code is removed after its behavior has a new home:

- `RootTopBarShell`;
- `ProjectTabStripView` and its drop delegate;
- the private `SessionStrip` row;
- `QuickActionsBar` as a persistent row;
- the top-bar region cases in `RootShellRenderContract`;
- the navigation-layout control in Settings, the View menu, and the command palette.

Saved `.topBar` preferences migrate to the canonical shell. Migration is one way. Kaisola does not keep a hidden switch that can recreate the old layout.

## The single top bar

The native toolbar is the only persistent horizontal band above the main workspace. The left rail material may continue behind the traffic lights, as it does in Apple's full-height sidebars. The main content and inspector begin directly below the same toolbar lane.

Every persistent control in that lane is a genuine native toolbar item installed through SwiftUI `ToolbarItem` or the equivalent `NSToolbarItem`. Kaisola does not draw clickable views into the sidebar's titlebar material, because the current AppKit lane can render and expose such a view to accessibility while refusing its pointer events. Toolbar acceptance uses synthesized pointer clicks as well as `AXPress`.

The bar has three areas:

- Leading: the sidebar toggle.
- Principal: the selected surface title or the compact working-set switcher.
- Trailing: New Session, an optional Documents menu, the inspector control, and one contextual More menu.

The sidebar and inspector toggles remain visible at every supported width. Other items can reduce or move into overflow.

### No visible surface

The principal area shows the active project name. New Session remains available. The central workspace shows the existing new-session chooser without creating a process before a concrete choice.

### One visible surface

The principal area shows a small status mark, the session title, and a short activity label only when the activity needs explanation. It is text, not a tab or pill.

The bar configures its trailing actions for the focused surface. For example, a chat can expose Stop and Transcript in More, while a document can expose page or editor actions. The bar does not reserve empty slots for controls that do not apply.

### Several visible surfaces

The principal area becomes a compact working-set switcher inside the toolbar. Its items are the terminal, chat, and Mesh surfaces already present in the active project's pane layout, plus a New Session draft when one exists. A running surface that the user has hidden is not in this window working set. It remains available in the complete left source list and the top-bar More menu without forcing a tab to appear. Recently Closed items stay in their menu and do not become tabs.

The bar renders a title when the working set contains zero or one item and compact tabs only when it contains two or more items. Hiding a surface therefore removes its tab without stopping its work. Restoring a hidden surface through the source list uses the source-list navigation command; the tab switcher itself never represents a hidden surface.

The active item has enough width for its title. Inactive items compress first. The left rail remains the complete, readable session list, so the toolbar never needs to display every title at full length.

The switcher uses three fitting variants in order:

1. Full compact tabs while they fit.
2. A titled active tab with icon-only inactive tabs.
3. A titled active tab and a count menu for the remaining sessions.

The layout chooses the first variant that fits. It does not depend on a single hard-coded window width. The count menu contains full titles, status text, and selection state.

Selecting a tab focuses the surface that already owns a pane. It does not add, replace, reorder, or remove a pane, and it can never evict the first pane as a side effect. Tab context menus preserve Stop, rename, close to Recently Closed, permanent delete, and End Session where each action applies. Recently Closed moves to the File menu and the top-bar More menu. A toolbar tab never creates a second lifetime model.

### Surface lifetime commands

The compact bar has no generic close button. Each command keeps one exact meaning:

- `Hide Session` removes a surface from the pane layout and keeps its terminal, chat, or Mesh process and saved state running.
- The current pane-menu label `Hide Pane` is renamed to `Hide Session` everywhere. It is not a second command or an alias with different process semantics.
- `Move to Project` and `Return to <project>` keep the existing terminal-adoption behavior. They live in the pane marker More menu and the source-list row menu, and neither action ends, recreates, or silently hides the session.
- `Stop Chat` stops the active chat turn. It does not hide, archive, or delete the chat.
- `Stop All Columns` stops active Mesh work. It does not hide, archive, or delete the Mesh.
- `Close to Recently Closed` applies only to chats and Mesh runs. It removes the surface from the open list and writes the existing durable Recently Closed entry. If work is active, the confirmation says that closing will stop it.
- `End Session` applies only to terminal and agent-terminal sessions. It requires destructive confirmation, commits the local durable close first, and releases the terminal through the existing best-effort path.
- `Delete Permanently` requires destructive confirmation and uses the existing chat, Mesh, or Recently Closed deletion path. It never substitutes for Hide or End.
- `Close Document` and `Close Browser Card` keep their current unsaved-change and load-state guards. They do not affect the parent session.

Menus show only commands that apply to that surface. Labels stay complete in compact and overflow variants so a visual `x` can never hide a process-lifetime decision.

### New Session drafts

`NewSessionDraftState` remains window-local.

- Repeated New Session actions reuse one draft per project.
- Creating a draft starts no terminal, chat, agent, or Mesh process.
- With no other visible surface, the toolbar title becomes `New Session` without drawing a tab.
- With other visible surfaces, the draft appears as one item in the compact switcher.
- Selecting a real surface keeps the unfinished draft available.
- Cancel and completion remove the draft exactly as they do today.

## Left source list

The left rail is the only complete project and session navigator.

It keeps:

- projects as workspace boundaries;
- deeply indented session rows;
- reorder, context actions, New Session, and remembered sessions;
- restrained activity and attention marks;
- native collapse, resize, focus, and keyboard behavior.

The default width remains close to 245 points and the user's saved width is respected. Width limits should follow the existing native sizing policy rather than introducing a second set of constants.

There is one strong blue selection treatment. Idle rows are quiet. Working state uses a small mark or progress treatment. Attention uses text and an accessible status, not a collection of badges.

The persistent `ConnectionFooter` is removed. Its actions move as follows:

- Settings goes to the application menu and Command-comma.
- Usage goes to Settings and the command palette.
- The Firebase application account menu moves to an Account submenu in the application menu and the existing Accounts settings pane. Sign in and sign out remain one command away, but the rail no longer spends permanent space on the account name.
- New terminal, agent, chat, and Mesh actions go to New Session, project context menus, and the File menu.
- Saved Quick Actions move to a project submenu in the top-bar More menu and remain in the command palette.
- Files goes to the inspector control.
- The existing Show or Hide File Preview command keeps its meaning as the central editable document or browser column. It moves to the top-bar More menu and the View menu. Inspector Quick Look is a separate read-only surface and never substitutes for that command.
- Check for Updates remains in the application menu and Updates settings pane.
- Copy Diagnostics moves to Help and the command palette.
- Uncommon recovery actions appear only in the affected content's More menu or inline error state.
- Attention appears on the affected project or session row. The always-present top-bar More control gains a quiet count or dot when the all-project inbox or storage notices need attention, and its menu opens the existing inbox. No toolbar item appears or disappears when attention changes, so neighbouring controls never move under the pointer.

The rail can show a short inline failure message for a project when action is required. It does not keep a permanent connection bar for the healthy case.

## Main workspace

Content begins immediately below the native toolbar.

Chat already suppresses its internal top header, and terminal adds none. That behavior remains.

The current 32 point `unifiedSessionHeader` is split into state and presentation:

- session identity and the focused surface actions move to the native toolbar;
- session status feeds the toolbar and left rail;
- pane-specific actions become a compact overlay on the pane that owns them;
- controls that do not need constant visibility move into a named More menu.

The existing header inventory is explicit. Companion control, chat account selection and overflow, maximize and restore, terminal transcript and pop-out, minimize, rename, pane drag, Move to Project, Return to Project, Files, and central File Preview each receive a tested toolbar, pane-marker, inspector, contextual-menu, or menu-bar home before the header is removed.

The Mesh inventory is equally explicit: purpose and title, running state, isolation note, hook notice, staged prompt queue, Stop All, and configuration. Structural status and notices stay inside Mesh content; commands move to the focused toolbar contribution or its More menu. The document inventory includes selected file, switching, dirty and save state, loading and conflict state, outline, editing or rendered mode, options, Keep Open, close, reopen, and Hide Document. The browser inventory includes address, loading or failure state, Reload or Retry, Open in Browser, and Close Browser Card. Tests assign every item a visible, inline, or menu home before deleting a header.

A single pane has no internal header.

Split panes do not receive repeated full-width toolbars. Each pane gets one identity marker inside its content boundary. The marker is at most 22 points high and 180 points wide. It contains the title, acts as the pane drag target, and may place one 28 by 28 point More control beside the title. It cannot grow into a row across the pane. A single pane renders neither the marker nor the More control.

When a split surface is represented both by a working-set tab and a pane marker, the pane marker is the local authority for its full identity. Redundant inactive tab titles compress before pane markers do. The selected tab communicates focus; it does not need to repeat every local title at full width.

The split-pane marker and More control remain visible when split panes exist. They do not rely on hover for discovery or accessibility. Full Keyboard Access visits the marker, then More, then content. VoiceOver exposes one marker and one More action per pane, with no hidden duplicate menus. A one-pixel focus treatment identifies the active pane without adding another blue selection block.

When focus moves between panes, the native toolbar updates its title and contextual actions. Pane layout, maximization, transcript, pop-out, and close behavior keep their current model semantics.

Mesh agent names, purpose, isolation, and hook notices remain structural labels inside the Mesh surface. They are not window toolbars. The same rule applies to a document page label or an inline browser location field when the content cannot be understood without it.

Document and browser headers lose their separate toolbar backgrounds. Actions that belong to the focused document or browser move through the focused-surface command bridge into the native toolbar. Small labels that are part of the content may remain. When the working-set switcher occupies the principal toolbar area, an editable document column keeps one bounded identity marker under the same 22 by 180 point budget as a split-pane marker. It carries the file name and modified state, not a second action row. A browser may keep a selectable inline location label because the content cannot be understood or navigated safely without it. That label is embedded at the content boundary, is at most 22 points high and 360 points wide, and never restores a full-width 42 point header or its background. Its tooltip and accessibility value expose the untruncated address.

## Focused surface command bridge

Document and browser controls currently depend on state owned inside `FilePreviewView` and `BrowserCardView`. `RootShellView` cannot recreate those commands from `AppModel` alone.

`FocusedSurfaceToolbarCoordinator` is a `@MainActor` object owned by `RootShellView` and passed through the environment. A mounted child registers a `FocusedSurfaceToolbarContribution` containing:

- an owner token, surface identifier, and revision;
- the title, status, and selected document name;
- stable command identifiers, labels, symbols, enabled state, help, accessibility text, and keyboard equivalents;
- main-actor actions that call the mounted child state.

Registration returns a lifetime token. The child updates its contribution when local state changes and unregisters on disappearance. The coordinator publishes a contribution only when its surface owns the focused pane and its owner token and revision are still current. Every action checks the token again before running. Focus changes, child replacement, and late updates therefore cannot invoke a stale document or browser action.

The command bridge carries the current child-owned inventory:

- Documents: selected document, document switching, pin or Keep Open, close and reopen, dirty state, loading and saving state, outline, edit or rendered mode, conflict state, Save, options, and Hide Document.
- Browser: current address, loading or failure state, Reload or Retry, Open in Browser, and Close Browser Card.

Document tabs do not become a second tab strip. The principal title includes the focused document name when one surface is visible. Whenever two or more documents are open, regardless of session count, a trailing `Documents` menu shows the selected document, modified state, the complete document list, Keep Open, close, and reopen commands. Zero or one document needs no separate switching control. The always-present More menu still contains Open Document and Show or Hide Document Column, and the File and View menus retain their equivalents, so hiding or closing the column never creates a pointer-only dead end. At narrow widths, Documents moves into More before the principal session control compresses and before the sidebar or inspector toggles can overflow. Command-S and the existing edit commands remain active. Browser address and status use the title's accessibility value and tooltip; Reload, Open in Browser, and Close live in More.

## Right inspector

The current Files rail becomes one optional inspector with three modes:

- Files;
- Quick Look;
- Details.

Inspector visibility, mode, and width use one application preference, matching the scope of today's Files rail settings. Each window keeps a live copy while it is open and writes changes back to that preference. New windows use the latest saved values.

The inspector control in the native toolbar opens, closes, and switches the inspector. The control has a menu for direct mode selection. The inspector does not draw its own 42 point toolbar.

Each mode begins with content:

- Files can show its search field and file tree.
- Quick Look shows the selected read-only preview.
- Details shows session identity, activity, account, and other secondary facts.

The Files action map is complete:

| Current action | Canonical home |
| --- | --- |
| Search | Search field inside Files content, without a full-width toolbar background |
| New File, New Folder, New AGENTS.md | Inspector control menu and Files background context menu |
| Refresh, Follow Selected Agent | Inspector control menu |
| Open | Read-only inspector Quick Look |
| Keep Open | Editable document in the central workspace |
| Copy Contents, Reveal in Finder | File-row More menu |
| Rename, Move, Move to Trash | File-row More menu with the existing sheets and confirmations |
| Mutation progress, failure, and retry | Inline in Files content |
| Hide Files | Window inspector control |

The file-row More menu stays mounted and labelled for VoiceOver even when its resting visual treatment is quiet. File clicks have one stable rule: Open or a transient single click uses inspector Quick Look, while Keep Open or the existing pin gesture opens an editable central document. Hiding the inspector never changes the selected session or closes an editable document.

Recently Closed also keeps a complete map:

| Current action | Canonical home |
| --- | --- |
| Undo Last Close | File menu and top-bar More menu |
| Restore named item | Recently Closed submenu in both locations |
| Delete Permanently | Named item submenu with the existing destructive confirmation |

## Recovery language

Healthy sessions show no connection message.

Kaisola attempts recovery automatically. A transient loss can use a quiet status mark or toast. If automatic recovery fails and user action can help, the affected content shows `Try Again` with a plain explanation.

The shell must not show `Broker`, `Reconnect`, generation, socket, ownership, or similar implementation terms. Companion Link can still use reconnect language when it describes a phone connection; that is a different user-facing concept.

The retired broker model cleanup remains a separate refactor because internal terminal serving and migration types still use broker names. This shell only defines what the user sees.

## Visual language

The visual direction is quiet and white-led.

- The central canvas is white in light appearance and uses the existing dark canvas in dark appearance.
- Both rails use the shared translucent sidebar material.
- Blue is reserved for selection and standard system focus.
- Status colors are small and have text or accessibility equivalents.
- Dividers use native hairlines.
- Corners, shadows, and hover fills stay subtle.
- Motion is limited to native sidebar, inspector, selection, and overflow transitions. Reduced Motion removes nonessential animation.

The shell's distinctive quality is spatial continuity. Selecting a session changes the content and title in place. It should not make the window feel as if several navigation bars have been inserted or removed.

## Commands and accessibility

Removing visible chrome must not remove actions.

Every action that leaves a persistent row needs at least one stable replacement. The old footer's complete inventory is account sign in and sign out, Usage, Settings, the all-project attention inbox, Files, central File Preview, three Mesh variants, Copy Diagnostics, connection status, and Reconnect. Tests must account for each item before `ConnectionFooter` is deleted.

Each replacement uses at least one of these paths:

- a visible toolbar or inline control for frequent actions;
- a menu-bar or contextual-menu command;
- a command-palette entry where one exists today;
- an accessibility label, help text, and state.

The implementation preserves existing shortcuts. New shortcuts require menu items so users can discover them. The inspector uses the standard macOS inspector command if it does not conflict with an existing binding.

VoiceOver order follows the visible structure: sidebar toggle, principal session control, New Session, inspector, More, workspace, then inspector content. Session status is not communicated by color alone. Compact tabs expose full titles and selected state even when their visual variant is icon-only.

The sidebar divider keeps its adjustable accessibility action. Any removed Files or central File Preview "door" receives an always-mounted toolbar or menu equivalent before the old control disappears.

## State and component boundaries

The design adds focused types rather than expanding `RootShellView.swift` further.

`WorkspaceTopBarState` is a pure value that describes:

- active project;
- visible working-set surfaces in the active project;
- selected surface or draft;
- focused pane;
- activity and attention state;
- the global attention count and storage-notice state;
- available contextual actions;
- inspector visibility and mode.

`WorkspaceTopBarView` renders that state and dispatches existing commands. It does not own session lifetime, create processes, or load conversations.

`WorkspaceTopBarLayoutPolicy` selects the full, compressed, or overflow presentation. It is pure and receives measured available space plus item widths, which makes narrow-window behavior testable without launching an app.

`WorkspaceInspectorState` owns inspector visibility, mode, and width for the open window. It reads and writes `workspaceInspectorVisible`, `workspaceInspectorMode`, and `workspaceInspectorWidth` in `NativePreviewSettings`. The width range is 164 through 420 points and the default for a new unsized inspector is 280. The lower bound preserves every valid width from the current 164 through 300 point Files rail instead of silently taking canvas space on migration. Inspector content adapts at the narrow end. The state does not own files, documents, or session data.

`SessionPaneChromePolicy` decides whether a pane needs an identity marker and which contextual actions belong to the focused pane. `SessionPaneLayout` remains the source of pane structure.

`RootShellView` remains the integrator. It derives these values from `AppModel`, `NewSessionDraftState`, and the existing pane and workspace stores.

## Migration

Migration must be deterministic and reversible through normal Git history, not through a hidden preference.

On first launch after the change:

- saved `.topBar` and `.leftTree` values both open the canonical shell;
- the obsolete navigation-layout preference is removed after migration reads it;
- project selection, session selection, drafts, panes, rail widths, and inspector visibility survive;
- no terminal, chat, or Mesh process is ended because of the shell migration.

Inspector migration is exact:

- If `workspaceInspectorVisible` is absent and the legacy `workspaceRailVisible` key exists, copy its value. If neither key exists, use `false` for the minimalist new-window default.
- If `workspaceInspectorWidth` is absent and the valid legacy `workspaceRailWidth` exists, copy it exactly. Clamp only corrupt or out-of-range values into 164 through 420 points. If neither value exists, use 280.
- If `workspaceInspectorMode` is absent, use Files. A restored transient read-only file selection may select Quick Look after the window finishes restoring.
- `filePreviewWidth` remains the central editable-document width during this slice. It never becomes the inspector width.
- Remove the two legacy Files-rail keys only after all new values have been written successfully.

Settings, the View menu, and the command palette stop offering a navigation-layout switch. Preview fixtures stop accepting a layout environment value after the canonical fixtures replace both variants.

## Error handling

The shell should fail locally.

- If a contextual action is unavailable, the relevant control is disabled with a reason.
- If a session fails, its row and content describe that session's failure.
- If inspector content cannot load, the inspector shows an inline error without replacing the workspace.
- If a saved layout cannot decode, Kaisola uses the canonical shell with the existing safe pane defaults.
- A failed shell migration must not change process ownership or delete saved session data.

## Performance

The top bar and rails must not materialize chat transcripts or trigger terminal inventory work.

They consume already-published summaries and stable identifiers. Expensive collections are derived once per render pass or in the model, not through repeated computed-property scans. The compact switcher must remain responsive while chat content hydrates in the background.

Selected-chat-first restoration is a separate subproject, but the shell must be ready to show its selected title and cached tail before other sessions finish hydrating.

## Testing

Implementation starts with failing tests for the new contracts.

### Pure and migration tests

- `RootShellLayoutsTests` proves the alternate project, quick-action, session-strip, and pane-header regions are gone. It does not count native toolbars.
- New `WorkspaceTopBarLayoutPolicyTests` cover zero or one visible surface, several visible surfaces, hidden surfaces excluded from the working set, icon compression, overflow, draft selection, and narrow widths. Selection tests prove tab focus cannot mutate or reduce the pane layout.
- `SessionPaneLayoutTests` and a new chrome-policy suite cover one pane, split panes, focus changes, and maximization.
- `KaisolaProductMigrationTests` prove both saved layout values reach the canonical shell without changing project or pane state.
- Inspector migration tests cover absent keys, exact legacy visibility and width preservation, corrupt-value clamping, default mode, transient Quick Look restoration, and removal of the old keys only after a successful write.
- `NativePreviewSettingsTests`, `CommandRegistryTests`, and Settings tests prove the old choice is gone.
- Focused-surface coordinator tests cover registration, update, unregister, focus changes, stale owner tokens, stale revisions, child replacement, disabled actions, and document-menu placement for one or several sessions at wide and narrow widths.

### Behavior tests

- `NewSessionDraftTests` and `NewSessionChooserTests` keep their no-process and reuse guarantees.
- `DetailShowDoorsTests` proves Files and the central editable File Preview remain reachable after their pane-header buttons move, including the zero-document state.
- Workspace Files tests cover Search, New File, New Folder, New AGENTS.md, Refresh, Follow, Open, Keep Open, Copy Contents, Reveal, Rename, Move, Move to Trash, mutation feedback, retry, and Hide through their canonical homes.
- Quick Action tests prove every saved action remains available through the new menu presentation.
- Account tests prove sign in and sign out remain reachable through the application menu and Settings.
- Attention tests prove the fixed More control opens the same all-project inbox, includes storage notices, changes state without changing its frame, and clears its count or dot only when no attention remains.
- Command tests prove Copy Diagnostics and Check for Updates remain reachable after the footer is removed.
- Session close, delete, Recently Closed, rename, Stop, maximize, pop-out, transcript, Move to Project, and Return to Project tests keep their current semantics and canonical menu homes.
- Pane-menu tests prove the old `Hide Pane` label is gone and `Hide Session` keeps the same non-destructive minimize behavior in every menu.
- Surface-lifetime tests prove Hide never stops work, Stop never hides or deletes, active Close to Recently Closed confirms process stopping, End Session confirms and commits locally first, and Delete Permanently never substitutes for another action.
- Recently Closed tests cover Undo Last Close, named restore, permanent delete, capacity failure, and retry through both menu locations.
- Document and browser tests prove every child-owned command registers, follows local enabled state, becomes unavailable after unregister, and never runs for a stale focused surface.
- Recovery tests prove healthy sessions have no permanent connection control and a failed session gets one local `Try Again` path.

### Accessibility and visual tests

Fixtures cover:

- no session;
- one terminal;
- one chat;
- three mixed sessions at a wide width;
- the same sessions at a narrow width with overflow;
- a New Session draft beside real sessions;
- two and four split panes;
- Files, Quick Look, and Details inspector modes;
- light, dark, Increased Contrast, and Reduced Motion settings.

The accessibility tree must contain exactly one `AXToolbar`. One visible surface must not expose a tab list. Several visible surfaces must expose one selected tab and full accessible names for compressed tabs. Every persistent toolbar control must also pass a synthesized pointer click at its visual center, not only `AXPress`. Removed footer actions must remain reachable by their new controls or menus.

A single pane exposes no pane marker. Each split pane exposes exactly one always-visible identity marker and one More control, in that order, before its content. Tests reject a full-width pane overlay, hover-only accessibility, duplicate hidden actions, and a browser location label that grows back into a full-width header.

Visual inspection checks spacing, traffic-light clearance, full-height rail material, title truncation, inspector continuity, focus, and the absence of stacked header backgrounds.

### Verification

The implementation runs:

- generated-project refresh if new Swift files are added;
- focused native tests selected from the changed files;
- all Node contracts;
- `git diff --check`;
- a clean native build;
- isolated visual and accessibility fixtures;
- a launch smoke against the built candidate.

The verified app replaces the local installation only after a process-continuity gate passes. The pre-replacement receipt records the GUI PID, installed bundle identity and hash, open surface and terminal identifiers, terminal-engine or compatibility-helper PIDs, socket ownership where present, and every live PTY or agent descendant. If any active process depends on the GUI and has no verified handoff path, replacement stops before quitting the app.

The post-replacement receipt allows the GUI PID and bundle bytes to change. Every process promised continuity must keep the same PID and identity, every preserved surface must keep the same identifier and ownership route, and the previous app must remain recoverable in Trash. An in-process terminal that cannot survive GUI exit blocks replacement while it is active; the verification must not rename expected process loss as continuity.

Publishing needs a meaningful release milestone and an exact candidate receipt. A candidate built for an older commit cannot be reused for this shell.

## Acceptance criteria

The shell is ready to ship when all of the following are true:

1. A normal window renders one persistent native top bar and no stacked project, quick-action, session, pane, Files, document, or browser toolbar rows.
2. One visible surface renders as a title, not a tab; hidden running sessions remain in the left source list without forcing tabs to appear.
3. Several visible surfaces switch through compact controls inside the same top bar and collapse into an accessible overflow menu at narrow widths. Switching tabs cannot replace or remove a pane.
4. The left rail remains the complete project and session navigator with one strong selection treatment.
5. The right side is one optional inspector with Files, Quick Look, and Details modes and no separate toolbar band. Central editable File Preview remains a distinct workspace column.
6. Split panes use one bounded identity marker and one More control per pane, while a single pane has no pane chrome.
7. Every action removed from the old strips, footer, Files header, pane header, document header, and browser header has a tested canonical home.
8. The navigation-layout setting and alternate shell are removed, and saved Top Bar users migrate without losing workspace state.
9. Healthy sessions show no Reconnect control or broker language. Recoverable failures are automatic, and actionable failures are local to the affected session.
10. Keyboard, VoiceOver, narrow-window, contrast, motion, and visual fixtures pass.
11. The shell renders from published summaries and never waits for unrelated chat or terminal hydration.
12. Focused document and browser commands come only from the current registered owner, and stale contributions cannot run.
13. Hide, Stop, Close to Recently Closed, End Session, and Delete Permanently remain distinct commands with the specified confirmation and process effects.
14. Legacy Files visibility and width migrate to the exact inspector preferences without turning editable documents into inspector previews.
15. The local app replacement and any later release pass the process-continuity gate and carry receipts tied to the exact source commit.
