# Kaisola for macOS

This directory contains the production Swift/AppKit desktop app — the macOS
half of Kaisola, the open-source IDE GUI for coding agents — distributed as
`Kaisola.app` with bundle identifier `com.kaisola.mac`.

Kaisola includes project navigation, native in-process terminals, terminal-based
agents, ACP chats with in-conversation account and model switching,
project-scoped Mesh, rendered and editable Markdown, file preview/editing,
Git and PR flows, settings/accounts/MCP, extension registries (themes,
grammars, preview mappings, custom agents), multi-window layouts,
notifications, browser cards, and native Google sign-in. A sealed, pinned Node
runtime ships only for the usage service and custom ACP adapters
(`runtime/node-broker` holds the few modules it runs).

## Open the current source

From the repository root:

```bash
npm run native:fast
```

This is the shortest edit → build → run loop. It performs an
active-architecture incremental Debug build in the persistent
`.build/Kaisola.noindex` cache and launches that build product directly.
It disables the command-line index store, uses only `Package.resolved`, and
skips helper packaging, app installation, Launch Services cleanup,
notarization, and release verification. Useful forms:

```bash
npm run native:fast:build       # compile only; do not launch or control the app
npm run native:fast:launch      # relaunch the existing build product
npm run native:fast -- --refresh-helper
npm run native:test:focus -- WorkspaceFilesTests
npm run native:test:changed -- --changed-file native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift
```

The helper is packaged automatically only when the build product has no sealed
Node helper or the helper inputs changed since the last successful fast build.
`--refresh-helper` forces packaging. On 2026-07-28, the first empty-cache
build took 37 seconds on the development Mac, an immediate warm build took 3
seconds, and forcing helper packaging took 7 seconds. These are local signposts,
not release performance claims.

The focused test command refuses an empty selector so it cannot accidentally
start the complete native suite. Add `--run-only` after one successful build to
rerun the existing test product without compiling:

```bash
npm run native:test:focus -- --run-only WorkspaceFilesTests/testExample
```

For a reproducible test plan from a diff, use the changed-file lane. It prints
the normalized file list and every selected test before execution. Direct
source/test pairs stay focused; terminal-engine, Swift protocol, build graph,
and release changes expand to the broader contract lane; an unknown runtime file
also expands instead of silently skipping coverage.

```bash
# Current working tree and untracked files
npm run native:test:changed

# Exact committed diff, optionally including current edits
npm run native:test:changed -- --base origin/main
npm run native:test:changed -- --base origin/main --include-working-tree

# Review without running, or reuse an already-built macOS test product
npm run native:test:changed -- --changed-file scripts/native-mcp-registry.cjs --dry-run
npm run native:test:changed -- --staged --run-only
```

`native:test:select` emits the same plan without executing it and accepts
`--format json` for automation. Explicit inputs can be repeated with
`--changed-file` or supplied as newline-delimited paths with
`--changed-files-from`. Documentation files are an explicit no-runtime-tests
classification; every other unmapped file receives the safe broad fallback.

Record comparable cold and warm active-architecture build timings around a
structural change with labels:

```bash
npm run native:timing -- --label before-view-split
npm run native:timing -- --label after-view-split --warm-runs 2
```

The timing runner creates a fresh temporary DerivedData directory, builds once
cold and then immediately warm, and appends a JSONL receipt under
`.build/metrics/native-build-timings.jsonl`. It never clears or replaces the
persistent `native:fast` cache and skips helper packaging consistently so the
comparison measures Swift compilation rather than packaging artifacts.

In the same 2026-07-28 local measurement, the first focused test build/run took
17 seconds and the unchanged `--run-only` rerun took 4 seconds. The selected
`FuzzyMatchTests` result was 8 passed, 0 failed.

For a canonical, self-contained development app:

```bash
npm run native:dev
```

That command incrementally builds the current checkout into a Spotlight-hidden
`.noindex` DerivedData folder, installs one development app at
`~/Applications/Kaisola Dev.app`, and launches it. Development uses bundle
identifier `com.kaisola.mac.dev`, so it can be tested without replacing the
signed production app in `/Applications`.

Useful variants:

```bash
npm run native:dev -- --launch-only
npm run native:dev -- --clean-legacy
```

`--launch-only` skips the incremental build. Every run removes raw Xcode build
products from Launch Services and registers only the canonical development app.
`--clean-legacy` additionally moves reproducible old preview/test bundles to
Trash and purges their stale Launch Services records. Trashed bundles use a
recoverable `.kaisola-trashed` suffix because macOS can otherwise rediscover a
normal `.app` inside Trash. Cleanup never deletes arbitrary build directories.

Use `native:fast` for ordinary Swift/UI work. Escalate to `native:dev` after
changes to helper packaging, app resources, launch
lifecycle, entitlements, Keychain, notifications, embedded frameworks, or other
bundle-dependent behavior. Use LocalRelease/Release, preflight, signing,
notarization, update, resource, and full interaction gates only at coherent
milestones; none belongs in the per-edit loop.

## Terminals

PTYs are direct in-process children owned by one process-wide store. Each
window keeps its own controller identity, so ownership, adoption, and takeover
work across windows exactly as they did across broker connections. Terminals
end when the app quits; their sessions are remembered and reopen as fresh
shells in their recorded working directories on the next launch. **End
Session** closes the PTY and removes its inventory record.

## Sealed Node helper

LocalRelease and Release builds package Node 22.23.1, node-pty 1.1.0, and the
usage/environment modules under `Contents/Resources/BrokerHelper`. The manifest
records every file hash, mode, Mach-O architecture, and designated requirement.
The helper runs only the usage service and custom ACP adapters; it owns no
terminals.

Download checksum-pinned runtimes, generate the project, and build a universal
ad-hoc LocalRelease app:

```bash
npm run native:helper:download
cd native/KaisolaMac
xcodegen generate
cd ../..
xcodebuild -project native/KaisolaMac/KaisolaMac.xcodeproj \
  -scheme Kaisola -configuration LocalRelease \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

`LocalRelease` keeps the hardened runtime but adds the narrow library-validation
exception needed by ad-hoc signatures without a common Team ID. The distributed
`Release` configuration removes that exception and uses Developer ID signing.

Validate the local app, helper, Sparkle embedding, and signatures:

```bash
npm run native:preflight -- \
  --app /tmp/kaisola-mac-release/Build/Products/LocalRelease/Kaisola.app
```

Distribution validation adds `--require-updates --require-developer-id
--require-notarized`. Those flags intentionally fail an ad-hoc local build.

The protected-main candidate workflow requires the Developer ID certificate,
team ID, and Sparkle private-key secrets plus one complete notarization method:

- team App Store Connect API key: `APPLE_API_KEY_ID`,
  `APPLE_API_PRIVATE_KEY` (base64-encoded `.p8`), and
  `APPLE_API_ISSUER` (issuer UUID); or
- Apple ID fallback: `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD`.

Individual App Store Connect API keys are intentionally rejected because Apple
does not permit them to authenticate `notarytool`. Credential preflight runs
before the distribution build so an incomplete set fails quickly.

Xcode signs an SPM framework container but does not replace Sparkle's vendor
signatures on its nested Autoupdate/Updater/XPC executables. Normalize one
already-built candidate before preflight:

```bash
npm run native:sign:distribution -- \
  --app /path/Kaisola.app \
  --identity "Developer ID Application: Example (TEAMID)"
npm run native:preflight -- \
  --app /path/Kaisola.app \
  --require-updates --require-developer-id
```

The signer preserves each code object's existing minimum entitlements, adds the
hardened runtime and secure timestamp, verifies the deep seal, and refuses a
broad or incomplete target. Preflight remains the authority for team identity,
Node JIT entitlements, nested timestamps, and forbidden entitlements.

## Native updates

Sparkle 2.9.2 is pinned for Kaisola's native update channel. **Check for
Updates** is enabled only when both build settings are valid:

- `KAISOLA_SPARKLE_FEED_URL`: an HTTPS appcast URL without credentials or a
  fragment;
- `KAISOLA_SPARKLE_PUBLIC_ED_KEY`: the appcast's 32-byte Ed25519 public key in
  base64.

Missing, partial, insecure, or malformed update configuration fails closed.
Local development builds omit the Info.plist keys and disable the menu item.

A canonical local replacement of `/Applications/Kaisola.app` is a distribution
candidate, not a `LocalRelease` preview. Build it with the same `Release`
identity boundary as CI: manual Developer ID signing,
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, secure timestamps, and both public
Sparkle settings. Then run `native:sign:distribution` to normalize nested
Sparkle code and require `native:preflight --require-updates
--require-developer-id`. Re-signing `LocalRelease` is intentionally insufficient:
its library-validation exception is preserved and the distribution preflight
rejects it; ad-hoc `Release` also injects `get-task-allow` unless base
entitlements are disabled.

## Resource and interaction gates

The exact workloads and counting policy live in
`ResourceGates/workloads-v1.json`. See `ResourceGates/README.md` for capture
commands, `ResourceGates/interaction-matrix-v2.md` for the current native workspace matrix, and
`ResourceGates/continuity-gate-v1.md` for the retained-output handoff contract.
Raw reports belong under ignored `ResourceGates/results/`.

## Development verification

```bash
cd native/KaisolaMac
xcodegen generate
xcodebuild -project KaisolaMac.xcodeproj -scheme Kaisola \
  -configuration LocalRelease -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
xcodebuild -project KaisolaMac.xcodeproj -scheme Kaisola \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-tests CODE_SIGNING_ALLOWED=NO test
```

Before release, also run the repository-wide Node service contract floor and
the distribution/manual rows in the interaction matrix. A local green build is
not evidence of Developer ID signing, notarization, app translocation, a real
Sparkle update, or real Claude/Codex continuity.
