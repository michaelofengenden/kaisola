# Kaisola for macOS

This directory contains the production Swift/AppKit desktop app, distributed
as `Kaisola.app` with bundle identifier `com.kaisola.mac`.

Kaisola includes project navigation, durable native terminals, terminal-based
agents, ACP chats, project-scoped Mesh, rendered and editable Markdown, file
preview/editing, Git and PR flows, settings/accounts/MCP, multi-window layouts,
notifications, browser cards, and native Google sign-in. A deliberately small
Node broker under `runtime/node-broker` remains packaged by the native app while
its Swift replacement is completed and proven compatible with live sessions.

## Open the current source

From the repository root:

```bash
npm run native:fast
```

This is the shortest edit → build → run loop. It performs an
active-architecture incremental Debug build in the persistent
`.build/Kaisola.noindex` cache and launches that build product directly.
It disables the command-line index store, uses only `Package.resolved`, reuses
the selected detached broker, and skips helper packaging, app installation,
Launch Services cleanup, notarization, and release verification. Useful forms:

```bash
npm run native:fast:build       # compile only; do not launch or control the app
npm run native:fast:launch      # relaunch the existing build product
KAISOLA_NATIVE_BROKER_PROFILE=development npm run native:fast
npm run native:fast -- --refresh-helper
npm run native:test:focus -- WorkspaceFilesTests
```

The helper is packaged automatically only when the selected broker is absent
and the build product has no helper. `--refresh-helper` forces packaging. Use
the isolated `development` profile for experiments that must not attach to the
ordinary native broker. On 2026-07-28, the first empty-cache build took 37
seconds on the development Mac, an immediate warm build took 3 seconds, and
forcing helper packaging took 7 seconds. These are local signposts, not release
performance claims.

The focused test command refuses an empty selector so it cannot accidentally
start the complete native suite. Add `--run-only` after one successful build to
rerun the existing test product without compiling:

```bash
npm run native:test:focus -- --run-only WorkspaceFilesTests/testExample
```

In the same 2026-07-28 local measurement, the first focused test build/run took
17 seconds and the unchanged `--run-only` rerun took 4 seconds. The selected
`FuzzyMatchTests` result was 8 passed, 0 failed.

For a canonical, self-contained development app:

```bash
npm run native:dev
```

That command incrementally builds the current checkout into a Spotlight-hidden
`.noindex` DerivedData folder, installs one development app at
`~/Applications/Kaisola Dev.app`, starts or reuses the selected broker, and
launches it. The ordinary route uses the **Kaisola Native** broker so its durable
PTYs survive GUI replacement; setting `KAISOLA_NATIVE_BROKER_PROFILE=development`
uses the clean-room **Kaisola Dev** broker instead. Development uses bundle
identifier `com.kaisola.mac.dev`, so it can be tested without replacing the
signed production app in `/Applications`.

Useful variants:

```bash
npm run native:dev -- --launch-only
npm run native:dev -- --clean-legacy
KAISOLA_NATIVE_BROKER_PROFILE=development npm run native:dev
```

`--launch-only` skips the incremental build. Every run removes raw Xcode build
products from Launch Services and registers only the canonical development app.
`--clean-legacy` additionally moves reproducible old preview/test bundles to
Trash and purges their stale Launch Services records. Trashed bundles use a
recoverable `.kaisola-trashed` suffix because macOS can otherwise rediscover a
normal `.app` inside Trash. Cleanup never deletes arbitrary build directories
or broker-owned PTYs.

Use `native:fast` for ordinary Swift/UI work. Escalate to `native:dev` after
changes to broker/helper packaging, profile discovery, app resources, launch
lifecycle, entitlements, Keychain, notifications, embedded frameworks, or other
bundle-dependent behavior. Use LocalRelease/Release, preflight, signing,
notarization, update, resource, and full interaction gates only at coherent
milestones; none belongs in the per-edit loop.

## Broker continuity

Native-created terminals use a capability-bound controller lane and stay alive
in the detached broker across app quit, relaunch, and update. The observation
lane admits inventory, diagnostics, subscriptions, and retained-output reads but
cannot mutate sessions. **End Session** invokes owner-gated `terminal.release`,
which closes the PTY and removes its retained spool and inventory record.

Transient socket loss is recovered with capped exponential backoff and jitter.
The app reconnects after wake and foreground activation and resumes from the
exact in-memory UTF-8 byte cursor. Cursor checkpoints are stored with mode
`0600`, scoped by broker identity, project, and terminal id. A cold launch still
requests the broker's retained snapshot; the disk cursor identifies a real
retention gap rather than suppressing output.

## Standalone broker helper

LocalRelease and Release builds package Node 22.23.1, node-pty 1.1.0, the
detached broker, and a universal Swift bootstrap under
`Contents/Resources/BrokerHelper`. The manifest records every file hash, mode,
Mach-O architecture, and designated requirement. The app registers the
bootstrap as a per-user `SMAppService` LaunchAgent. It adopts a compatible live
broker and starts the packaged broker only when no compatible broker exists;
ambiguous or incompatible brokers are left untouched.

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

Validate the local app, helper, Sparkle embedding, signatures, and LaunchAgent
contract:

```bash
npm run native:preflight -- \
  --app /tmp/kaisola-mac-release/Build/Products/LocalRelease/Kaisola.app
npm run native:helper:probe -- \
  /tmp/kaisola-mac-release/Build/Products/LocalRelease/Kaisola.app/Contents/Resources/BrokerHelper \
  --require-signed-host
```

Distribution validation adds `--require-updates --require-developer-id
--require-notarized`. Those flags intentionally fail an ad-hoc local build.

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
