# Changelog

## 1.2.0 — 2026-08-02

- Glass tracks the desktop behind the window, so moving Kaisola slides the wallpaper underneath it like real glass.
- Glass reads the same on any wallpaper — blues no longer wash out to white, greens no longer oversaturate.
- Glass follows the wallpaper's texture, not just its colour, and re-reads it whenever the wallpaper changes.
- New Appearance controls for glass clarity, blur, and colour.
- The active project reads bold instead of filled, and the open session is marked in blue.
- The sidebar no longer scrolls the first project out of view at launch.
- Real ChatGPT and Claude marks, and a terminal running Claude Code now shows the Claude one.
- Tinted canvas is actually tinted, and Solid is named for what it does.
- Markdown edits as one continuous document, tables and all — no block-by-block, no jumping to the top.
- Panels run to the window's top edge, reclaiming the empty band above them.
- A rebuilt agent composer: model, provider, and reasoning effort all change mid-conversation from one menu.
- Queued messages can be steered into a turn that is already running.

## 1.1.9 — 2026-08-01

- Text and HTML files edit in a fast offline editor, with the exact bytes on disk still Kaisola's to keep.
- Outlines navigate Markdown, Swift, Python, JavaScript, TypeScript, HTML, CSS, shell, JSON, and YAML.
- PDFs open in a native viewer with selection, scrolling, and zoom.
- Switching files can no longer lose text — the newest edit is saved first.
- Restored drafts, disk conflicts, and save failures explain themselves in notices you can dismiss.
- Rendered Markdown refuses links carrying credentials and paths that leave the project.
- Files and folders move between project directories with collision checks and real Undo.
- Chat and Mesh share one transcript: headings, tables, highlighted code, copy buttons, and clickable project citations.
- Long histories move to a private database, reopen quickly, and page back without losing your place.
- Oversized images are scaled down instead of refused.
- A pop-out that fails to open offers Try Again rather than a blank window.
- Queued Mesh prompts keep their order across restarts, and stay inspectable, removable, and resumable.
- Hide, Stop, Close, and Delete are properly distinct — only Delete discards anything.
- Status reads by shape as well as colour, and Reduce Motion is respected throughout.
- An ended terminal can be recreated in place with its agent, account, title, and draft intact.
- Menus, the command palette, and workspace controls run off one registry, so shortcuts and unavailable states agree everywhere.
- Keyboard shortcuts can be remapped in Settings; a bad override fails safely and leaves the defaults standing.
- Settings unifies app defaults, provider accounts, and per-project overrides, and can check an API key without revealing it.
- First run is a live readiness checklist, and Help opens a real user guide.
- Git stages or unstages everything in one reversible step, and pulls stay to safe fast-forwards.
- Pull-request review shows the full changed-file set and stops if the destination changes under it.
- Agent permission prompts show exactly what was asked for and what a new rule would cover.
- Broker updates roll over to a new generation without disturbing terminals that are still running.

## 1.1.8 — 2026-08-01

- Projects stay in their saved order instead of moving when selected.
- A slimmer sidebar keeps the hierarchy clear and shows only your first name in the footer.
- Document and Files controls now sit together, and Document closes either a file preview or browser card correctly.
- Both right-side dividers keep their resize cursor and drag behavior along their full height, even beside rendered documents.
- Glass is calmer, subtly warmer, and consistently rounded.

## 1.1.7 — 2026-07-31

- Cleaner sidebar: slimmer default width, deeper session indentation, and no row highlight boxes.
- Brand icons drawn plain, without background tiles.
- Panel dividers are draggable along their entire length.
- Glass is fully color-neutral — the only tint comes from your wallpaper.

## 1.1.6 — 2026-07-31

- Glass now reflects your desktop wallpaper only — other windows never show through.
- The active project gets a subtly tinted glass highlight.
- Terminals running Claude or Codex show their brand icon, and the OpenAI logo is now the real one.
- Settings and usage are one click away in the sidebar footer.
- Clearer status colors: blue means working, green means done.

## 1.1.5 — 2026-07-31

- The sidebar matches its intended design: full-width titles, quieter chrome, visible wallpaper tint.
- Smooth, stable cursor around panel dividers.

## 1.1.4 — 2026-07-31

- Sidebar rows are fully readable by VoiceOver and automation.
- Terminals hold less memory for long histories.
- Development builds keep their data separate from the released app.

## 1.1.3 — 2026-07-31

- Terminal bells now mark a session as needing your attention.
- Long terminal histories open much faster.
- Friendlier wording across the app and a working Help menu.

## 1.1.2 — 2026-07-31

- Large files open instantly in read mode, with Find built in.
- Previews no longer re-parse files while you move around.
- A damaged workspace layout now explains itself and keeps a recoverable copy.

## 1.1.1 — 2026-07-31

- The Git panel refreshes live and lets you review a pull request before creating it.
- Terminal polish: your chosen font in transcripts, a Clear command, and a jump-to-latest button.
- Safer clipboard handling for terminal applications.

## 1.1.0 — 2026-07-31

- A redesigned sidebar: your active project on top, other projects below, and live agent status at a glance.
- A broad reliability pass across terminals, chats, previews, Git, and settings.

## 1.0.0 — 2026-07-30T02:41:50-0700 (PDT)

Kaisola 1.0.0 is the first release from the native-only repository. It contains
the Swift macOS app, iPhone Companion, shared Swift protocols, and the sealed
transitional terminal broker; no Electron renderer or React application ships
in this repository.

### Terminal and app experience

- Made Claude Code, Codex, and ordinary shell streaming stable while scrolling:
  output is coalesced on a 16 ms lane, contiguous bytes feed SwiftTerm directly,
  parsed terminal surfaces survive tab switches, and deliberate user scrolling
  remains unpinned until the user returns to live output.
- Raised ordinary terminal history to 20,000 rows with a bounded 100,000-row
  maximum and preserved access to older disk-backed transcript pages.
- Removed redundant semantic-terminal work from plain output. Buffer cursor
  searches now run only for an active OSC 133/633 input region, and semantic
  decorations paint once after final scroll positioning.
- Increased the project sidebar's default/ideal width to 200 points and made
  project headers visually distinct from their nested session rows.
- Added direct, persistent controls to switch projects and sessions between the
  left sidebar and Chrome-like top bars in either direction.
- Moved local browser cards into the same right-hand preview slot as files, so
  the active terminal stays mounted and visible.
- Made terminal file citations resolve relative, absolute, and `file:` paths,
  including line/column targets. A citation outside every open project adopts
  the nearest Git root (or a safe directory fallback), activates it, expands
  its ancestors, and highlights the exact file in the workspace rail.

### Markdown and previews

- Fixed Markdown wrapping in narrow preview panes and added both trackpad pinch
  and Command-mouse-wheel zoom to rendered documents and direct editing.
- Replaced the plain block source box with a styled native TextKit editor that
  preserves exact Markdown bytes while rendering headings, emphasis, links,
  code, and visible list markers during editing.
- Added automatic continuation and clean exit behavior for bullet, task, and
  ordered lists.
- Rebuilt README table separators as real cell boundaries so rules no longer
  cross through values.
- Split the workspace rail from the large preview implementation and preserved
  selected-file highlighting and ancestor expansion.

### Broker/app parity and continuity

- Added a deterministic lowercase SHA-256 content digest to every sealed broker
  generation and carried it through the helper manifest, launch configuration,
  `broker.json`, authenticated hello, status, development, and probe receipts.
- Added an authenticated atomic `broker.shutdownForUpdate` operation. It
  rechecks PID, start time, digest, activity epoch, in-flight work, child tasks,
  and live PTYs inside the broker before allowing an empty generation to stop.
- Automatically replaces a stale empty broker, retries pending upgrades on a
  2.5-second heartbeat, and reports precise pending/current generation details.
  A broker that owns any live terminal is preserved and never presented as
  current merely because every agent is idle.
- Sealed broker package generation is `1.1.0`, implementation version `1`,
  protocol `2`, and security epoch `1`. The immutable release provenance receipt
  records its digest alongside the final app build, source commit, signatures,
  notarization, and artifact hashes.

### Faster development and testing

- Added deterministic changed-file-to-test selection with printed plans,
  focused native selectors, Swift-package routing, Node routing, and a broad
  fallback for shared or unmapped changes.
- Added path-isolated reusable SwiftPM test caches and fixed no-argument behavior
  on the macOS system Bash.
- Added cold/warm build timing receipts. The measured native edit build was
  35.461 seconds cold, then 3.014 and 2.937 seconds warm.
- The integrated changed-file lane completed in 27.97 seconds with 540 passing
  checks, one intentionally skipped UI check, and no failures.

### One-to-two-minute release promotion

- Added a main-commit candidate workflow that builds, tests, Developer ID signs,
  notarizes, staples, Sparkle-signs, and stores one immutable app candidate plus
  a machine-readable provenance receipt.
- Replaced tag-time rebuilding with a serialized promotion workflow that checks
  the tag, exact source commit, version/build, helper digest, Ed25519 signature,
  notarization, and SHA-256 inventory before publishing those exact bytes.
- Made the permanent Sparkle appcast monotonic, verified remote GitHub asset
  digests after upload, and added safe first-release/interrupted-promotion
  recovery. Expensive candidate validation is reported separately from the
  target one-to-two-minute public promotion.
- Tightened notarization credential preflight after the first protected-main
  candidate exposed an invalid assumption: Apple individual API keys are now
  rejected before building, team API-key authentication always requires its
  issuer UUID, and a complete Apple-ID/app-specific-password pair can serve as
  the explicit fallback.
- Made unattended visual, memory, and cadence fixtures ignore AppKit crash-state
  restore prompts without accepting unrelated output, and aligned their broker
  metadata lookup with the private native fixture layout.

### Release validation completed before publication

- Node contracts: 127 passed, 0 failed.
- Shared KaisolaCore contracts: 25 passed, 0 failed.
- Full macOS suite: 856 passed, 8 intentionally skipped, 0 failed.
- Universal arm64/x86_64 app preflight and sealed broker/PTTY continuity probe:
  passed.
- Broker-free 64 MiB/100,000-row terminal resource gate: 434.8 MiB p95 against
  a 512 MiB ceiling.
- Streaming 120 Hz cadence gate: 99.78% callback coverage, 8.49 ms p95,
  19.73 ms maximum interval, and 4.44 ms/s deadline loss while 965 KiB of
  terminal output advanced during the measured interval.
