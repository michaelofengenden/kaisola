# Kaisola

Kaisola is a native agent workspace for macOS with an iPhone Companion. The
product UI, lifecycle, storage, security, and Companion host are implemented in
Swift and SwiftUI/AppKit.

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

The ordered PR plan and acceptance criteria live in
[PULL_REQUEST.md](PULL_REQUEST.md). The authoritative feature-parity inventory
is [docs/native-migration-roadmap.md](docs/native-migration-roadmap.md).
