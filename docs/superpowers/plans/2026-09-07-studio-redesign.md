# Kaisola studio redesign implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded parallel slices. Root owns integration, builds, visual QA, and final Git actions.

**Goal:** Make Kaisola substantially more readable, modern, and smooth while retaining its current capabilities.

**Architecture:** Restyle the existing native SwiftUI/AppKit presentation. Keep AppModel and terminal lifecycle intact. Fix confirmed ACP presentation and cancellation problems at their existing boundaries.

**Tech Stack:** Swift 6, SwiftUI, AppKit, SwiftTerm, existing Xcode build and fixture lanes.

**Spec:** `docs/superpowers/specs/2026-09-07-studio-redesign.md`

## Global constraints

- Work only in `/Users/michaelofengenden/Developer/kaisola-worktrees/september-2026-ui`.
- Preserve the copied pre-existing settings/CommandRegistry patch. Do not stage those edits.
- No commits, pushes, or version changes before the final portion of the four-hour work window.
- Do not terminate the production app or any agent/session process during iteration.
- Root owns all builds and computer interaction. Workers must coordinate test runs to avoid build-cache collisions.
- Visual-only changes use actual rendered QA. Behavior fixes get focused regression tests.
- Do not add dependencies or change credentials, permissions, launch safety, or provider execution policy.
- No AI attribution in commits or pull requests.

## Task 1: Native shell and shared visual grammar (root)

**Files:** `App/NativeVisualTokens.swift`, `App/NativeAppearanceViews.swift`, `Features/Sessions/RootShellView.swift`, `RootShellLayouts.swift`.

**Interfaces:** Existing theme/settings tokens remain available. Add shared conversation layout/type tokens that chat uses. Retain native toolbar action routing and pane identity.

- [x] Capture the baseline shell and read theme/row contracts.
- [x] Set the sidebar resting width to 244 points while honoring persisted widths and the existing minimum/maximum band.
- [x] Refresh shell spacing, header hierarchy, shared control hover/focus, and pane separation.
- [x] Add a shared 780-point conversation width and standard reading type treatment.
- [x] Keep light, dark, tinted, reduced-transparency and increased-contrast drawing paths coherent.
- [x] Compile and inspect actual fixtures before proceeding to refinements.

## Task 2: Sidebar and session invitation (navigation worker)

**Files:** `Features/Sessions/QuietProjectRail.swift`, `NewSessionChooserView.swift`. Related tests only if behavior changes.

**Interfaces:** Keep `QuietRailMetrics`, `NewSessionChooserPresentation`, existing action closures and accessibility identifiers. Root owns sidebar outer geometry and persistent New session/Search action routing. Navigation worker owns project/session rows; those rows must not duplicate or remove the root action homes.

- [x] Increase row readability and hit areas; preserve status, reordering, project collapse and session context actions.
- [x] Improve selection and hover treatment while retaining a clear blue selected state.
- [x] Make the session invitation more welcoming and scannable, with native option rows/cards and clear next actions.
- [x] Preserve disabled reasons, launch progress, error messages, focus movement, Back and Cancel.
- [x] Report narrow-state checks and any token changes root needs to integrate.

## Task 3: Conversation and composer (chat worker)

**Files:** `Acp/AcpChatView.swift`, `AcpComposerView.swift`, `AcpComposerMenuView.swift` if needed. Do not edit model files owned by Task 4.

**Interfaces:** Consume `AcpTranscriptDisplay.finalResponseMessageIDs(rows:isRunning:activeTurnStartRowID:)` from Task 4. Use shared root layout/type tokens. All existing closures and notifications remain intact.

- [x] Align transcript, notices, status, queue, attachments, and composer to a shared readable column.
- [x] Improve the message/working-log rhythm and user prompt bubble without making every tool a card.
- [x] Make composer controls adapt at 220-point panes with accessible overflow or wrapping.
- [x] Show a compact queue count by default. Expansion reveals a FIFO scroll region capped at min(132 points, pane height / 4), with a persistent collapse action and accessible steering/removal. Verify empty, one-item, multi-item, expanded, removal and narrow/larger-text states.
- [x] Avoid duplicated recovery messages where the composer already gives the cause and recovery action.
- [x] Apply the running-aware final-response call and preserve scrolling/search anchors.
- [x] Audit Reduce Motion behavior of any touched animations.

## Task 4: ACP correctness and streaming work (behavior worker)

**Files:** `Acp/AcpConversation.swift`, `AcpTranscriptRendering.swift`, `AcpTranscriptDisplay.swift`, focused tests under `KaisolaTests`.

**Interfaces:** Add `isRunning: Bool = false` and `activeTurnStartRowID: String? = nil` to `finalResponseMessageIDs(rows:)`. Expose the boundary through a read-only computed property based on existing activePromptTurn; add no lifecycle state. Chat owner passes both. Existing search public API is unchanged.

- [x] Add regression tests for canceled startup, closed-search refresh, and stable final-answer chrome while a turn runs.
- [x] Coordinate with root to run the focused tests and capture meaningful failures.
- [x] Catch intentional startup cancellation separately and preserve restartability and draft/queue state.
- [x] Skip indexing when Find is closed; rebuild current content on presentation.
- [x] Exclude the current unfinished turn from final-response IDs using its actual boundary while preserving completed earlier turns. Cover steering, harness notices, completion, and a boundary paged out of the visible tail.
- [x] Run the focused tests after changes and report exact results and limitations.

## Task 5: Broader UI tour and refinement (root, bounded follow-up workers)

**Files:** `Features/Workspace/WorkspaceRailView.swift`, `Features/Palette/CommandPaletteView.swift`, `Mesh/MeshView.swift` and narrow extracted presentation files only when visual QA supports changes.

- [x] Inspect actual terminal, split, chat, new-session, Files/preview, palette, Mesh and settings surfaces.
- [x] Improve typography, action placement, empty/recovery states and compact layouts wherever the tour identifies a clear inconsistency.
- [x] Keep the terminal mount/cache/feed path stable and test real terminal interaction in an isolated fixture.
- [x] Check keyboard access, focus, resizing and larger text in the changed surfaces.

## Task 6: Review, local delivery and final save (root)

- [x] Run independent direct peer and root adversarial reviews; deduplicate and fix actionable findings. The companion reviewer was unavailable, so direct GPT-6 Astra/GPT-5.6 Sol peers supplied the independent reviews.
- [x] Run native builds, selected behavioral tests, and rendered UI checks. Repeat the distribution build and preflight on final version metadata during delivery.
- [x] Recheck original dirty-file hashes and production process ownership. Stage explicit scoped paths and verify that the seven pre-existing settings/CommandRegistry patches are absent. SettingsView may contain only the separately owned native-defaults caption hunk.
- [ ] Near 00:20 UTC, choose the next unclaimed version using current repo metadata, update changelog/version, and commit only scoped changes.
- [ ] Push the reviewed branch and save a durable version. Do not imply a public release unless its actual publication boundary is performed.
- [x] Build and verify the canonical local candidate, install safely when production process ownership permits, and inspect the installed app.
- [ ] Record exact commit, version, installation state, exercised UI paths, and any unresolved limitations.


## Verification scope

The focused behavioral cohorts and real PTY smoke checks passed. Live checks covered chat/terminal navigation, draft selection and Cancel, queued prompts, palette focus/caret restoration, file routing, Markdown editing/saving/change inspection, and compact/wide panes with 170% chat type. The final combined layout and hosted typography cohort passed 27/27 after retaining test windows to avoid invoking the production quit-on-last-window policy.

Light and dark captures were inspected. Existing theme, Reduce Motion, Reduce Transparency and Increased Contrast branches were preserved and reviewed; system accessibility preferences were not changed, so full accessibility-mode rendering is not claimed. Live provider inference and a live multi-agent Mesh run were not exercised. Markdown source bytes remain unchanged; soft LF still occupies a physical line in TextKit rather than reflowing as a space.

Local performance artifacts are under `.build/september-redesign`. Optimized transcript derivation CPU measurements are separate from terminal cadence measurements and do not establish end-to-end chat FPS. The signed 0.1.151 candidate (build 1196002) passed distribution preflight and the complete optimized terminal gate against public feed floor 1196001. The final narrow-sidebar label refinement was built and checked during local delivery. Installed-app receipts and the local archive are recorded under the same artifact directory.
