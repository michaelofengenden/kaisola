# Kaisola studio redesign

Kaisola should feel comfortable for hours of work: readable conversations, recognizable projects, and agent activity that is easy to follow. The current app packs small text into a narrow sidebar while letting conversation lines span most of the window. This redesign gives each surface a clearer purpose and more room.

Michael authorized broad UI changes, refactoring, online research, local screenshots, and repeated iteration over four hours. Work began at 20:38 UTC on September 7, 2026. Commit, push, and versioning belong near the end of that window, around 00:20 to 00:38 UTC on September 8. Local usability takes priority over exhaustive tests.

## Direction

Use a native studio layout. A lightly frosted project sidebar frames a white conversation canvas. The same reading width aligns messages, work summaries, and the composer. Terminal content remains faithful to the chosen terminal theme. One compact row carries workspace identity and its controls; split panes retain the local identity needed to distinguish agents.

Two alternatives were considered: an IDE layout with more permanent toolbars and dense navigation, and a highly translucent interface throughout. The first gives too much space to controls; the second makes long-form text and terminal output harder to read. The studio approach keeps the useful parts of a coding app and the ease of a conversation app.

The palette has six roles: paper #FFFFFF, navigation ground #F3F5F8, primary ink #20242B, secondary ink #687180, selection blue #0A71E8, and a dark content surface #191B20. Use existing appearance-aware semantic colors wherever they already provide the role. Keep user-selected Solid, Glass, and Tinted themes, dark appearance, Increased Contrast, and Reduce Transparency working.

Typography uses San Francisco for native controls and conversation text, with the user's selected monospace font for terminals and code. Conversation body text should read at roughly 15 points at the standard size, navigation titles at 13 points, project headings at 12 points, and metadata at 11 points. Honor chat size settings rather than forcing a constant at every row.

The initial layout targets a 244-point sidebar and a 780-point conversation column. Transcript and composer width is min(780, available pane width minus shared horizontal insets), with identical leading and trailing anchors. Standard reading text uses a scaled 15-point base and follows existing chat zoom. Persisted sidebar widths remain respected, including narrow layouts. Rows become easier to click, with 30-point session rows and 36-point project cadence. The composer has a generous field, a quiet control row, and an adaptive narrow layout. Corners use consistent continuous shapes without adding a card around every piece of content.

## Functional boundaries

- Preserve project switching, task ordering, multi-window layouts, saved sessions, and session restoration.
- Preserve native PTY ownership, mounted terminal identities, cached terminal surfaces, incremental feeds, scroll intent, and keyboard input.
- Preserve attachments, provider/account/model settings, permission decisions, queued prompts, steering, and cancellation.
- Preserve Files, previews, Markdown editing, Git actions, command palette, Mesh, settings, and keyboard shortcuts.
- Keep app controls and actions accessible. Every essential action remains available at minimum pane width and with larger text.
- Running feedback must be tied to real state. Avoid fake progress, arbitrary duration claims, and per-frame SwiftUI state updates.

## Smoothness fixes

Treat intentional local ACP startup task cancellation separately from provider failure. Cleanup must finish, hasStarted must reset, providerStartupFailure stays nil, and restart remains available. A real adapter startup error must still surface. Leave the existing client cleanup in place. Do not display a raw cancellation error as an account failure.

Closed transcript Find should keep its query but stop rebuilding a search index on streamed content. Reopening Find indexes current rows and preserves navigation where possible.

The active turn must not label each interim narration paragraph as a final response. Use the existing activePromptTurn boundary, exposed as activeTurnStartRowID, so steering messages do not create false completion boundaries. Completed turns retain their response controls; the active turn gains them after completion.

Show a compact queued-follow-up count by default. Expanding it reveals all prompts in FIFO order inside a scroll region capped at 132 points or one quarter of the pane height, whichever is smaller. A collapse action stays visible. Steering and removal remain available for every row, including at narrow widths and larger text.

## Local safety and verification

The source worktree is `/Users/michaelofengenden/Developer/kaisola-worktrees/september-2026-ui`, branch `codex/september-2026-ui`. The original checkout remains intact. Its pre-existing settings and CommandRegistry patch was copied into the worktree for visual continuity and must remain outside the redesign commit.

Build with `npm run native:fast:build`. Use `KAISOLA_NATIVE_VISUAL_FIXTURE=1` for private fixture launches. A dev bundle identifier alone is insufficient isolation because several current stores use a shared path. Never relaunch the installed app while it owns live agent processes. Recheck process ownership before final installation.

Use visual inspection of actual SwiftUI/AppKit windows for appearance changes. Use focused behavior tests for cancellation, search, final-response stability, and queue policy. Build and exercise navigation, narrow layouts, light/dark, terminals, chat, palette, previews, and settings. Report only what was actually exercised. Do not claim notarization or a public release from a local installation.

## Research evidence

The live installed Claude app was inspected on September 7. Its comfortable reading column, persistent navigation, restrained message actions, and rounded composer informed this direction. The installed Kaisola baseline was also captured. CUA blocks direct inspection of the installed Codex app, so official product material supplies that reference.

- [OpenAI Codex app introduction](https://openai.com/index/introducing-the-codex-app/)
- [ChatGPT desktop release notes](https://help.openai.com/en/articles/6825453)
- [Apple: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Apple: Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Apple: Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [Apple: Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Claude desktop](https://claude.com/download)


The final reference check also used the [WWDC26 Design guide](https://developer.apple.com/wwdc26/guides/design/), [Claude Code desktop documentation](https://code.claude.com/docs/en/desktop), and current OpenAI documentation for [permissions](https://learn.chatgpt.com/docs/permission-modes) and [long-running work](https://learn.chatgpt.com/docs/long-running-work). These support adaptive window layouts and compact progress summaries with nearby intervention controls. The living product documentation is not treated as evidence of a dated September release.
