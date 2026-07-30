# Changelog

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
