# Kaisola

Kaisola is an **open-source IDE GUI for coding agents**, built native in
Swift. It hosts the agent CLIs you already use — Claude Code, Codex, and any
CLI you register — in durable terminals and rich ACP chat surfaces, organized
by project, with an iPhone Companion for approving and steering from your
pocket. The interface is the product; the agent runtimes stay the vendors'
own.

What that means in practice:

- **Agents, first-class.** Terminal-hosted CLI agents and ACP chats side by
  side per project; switch the subscription account *or* the model
  mid-conversation with the transcript intact; a cross-project attention
  center for everything that needs you, with per-event notification rules.
- **Many subscriptions, one app.** Sign in to multiple Claude and Codex
  accounts, see each plan's usage, reset windows, and per-turn cost, and get
  told before you start a session on a spent account.
- **An IDE around the agents.** File tree, editable Markdown and file
  previews, syntax highlighting, Git panels, project-scoped MCP
  configuration, command palette, multi-window and split layouts, terminals
  that survive relaunches through a detached broker.
- **Native all the way down.** SwiftUI/AppKit, a measured glass aesthetic
  over your desktop wallpaper, Sparkle updates — no Electron, no web-view
  shell.
- **Yours to extend.** Validated registries for custom terminal themes,
  syntax grammars, preview mappings, and custom agents — including
  chat-capable ACP adapters installed as pinned, integrity-verified code.

This repository intentionally contains only the shipping native product:

- `native/KaisolaMac` — the macOS application;
- `mobile/KaisolaCompanion` — the iPhone Companion;
- `native/KaisolaCore` — shared protocols, security, and domain models;
- `runtime/node-broker` — the small transitional terminal broker packaged by
  the macOS app until its Swift replacement passes continuity gates;
- `scripts` and `tests` — native packaging, release, and contract tooling.

There is no Electron renderer or React application in this repository.

## Fast development

```bash
npm install
npm run native:fast
```

The fast lane performs an active-architecture incremental Debug build using a
persistent DerivedData cache, reuses the detached broker, and launches the build
product directly. It skips application installation, universal packaging,
notarization, and release checks.

Run a focused test while iterating:

```bash
npm run native:test:focus -- WorkspaceFilesTests
npm run native:test:focus -- --run-only WorkspaceFilesTests/testExample
```

Use the installed development-app lane when bundle resources, helper packaging,
entitlements, Keychain, notifications, or launch behavior changed:

```bash
npm run native:dev
```

See [the macOS development guide](native/KaisolaMac/README.md) for release and
broker-continuity details.

## Projects

- macOS: `native/KaisolaMac/KaisolaMac.xcodeproj`, scheme `Kaisola`
- iPhone: `mobile/KaisolaCompanion/KaisolaCompanion.xcodeproj`, scheme
  `KaisolaCompanion`
- shared Swift package: `native/KaisolaCore/Package.swift`

## Next implementation slices

The ordered large-feature plan and acceptance criteria live in
[PULL_REQUEST_FEATURES.md](PULL_REQUEST_FEATURES.md). Bounded bugs, reliability
work, iteration speed, and release promotion live in
[PULL_REQUEST_FIXES.md](PULL_REQUEST_FIXES.md). The authoritative feature-parity
inventory is [docs/native-migration-roadmap.md](docs/native-migration-roadmap.md).
Drop untriaged ideas into the intentionally empty [BACKLOG.md](BACKLOG.md).
Completed release work and verification receipts are recorded in
[CHANGELOG.md](CHANGELOG.md).
