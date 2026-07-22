# Kaisola Swift-native Phase 0/1 — implementation plan

**Goal:** establish the shared Swift foundation and ship a packaged native
macOS terminal observer without risking Electron or durable terminal sessions.

**Design:** `docs/superpowers/specs/2026-07-21-kaisola-swift-phase-0-1-design.md`

**Sequence:** freeze contracts and baselines → extract the shared package →
rebase iPhone → build the native shell → implement the read-only broker client
→ package/update the helper → run durability and resource gates.

## Global invariants

- Electron remains the daily driver throughout Phase 0/1.
- Native never adopts or mutates a terminal during Phase 1.
- A running broker with live PTYs is never killed for an app or helper update.
- JavaScript and Swift must pass the same versioned protocol fixtures.
- Electron and native never concurrently write the same state database.
- Any later one-way import records source identity/schema, snapshot hash,
  import revision, and destination schema in an immutable ledger.
- Any later dual-daemon terminal record carries explicit Node-or-Swift backend
  provenance before routing decisions are enabled.
- The desktop Board is not rebuilt; legacy wire DTOs are never rendered there.
- Every task leaves existing Electron and iPhone release paths green.

## Phase 0 — shared package

### Task 0.1: Freeze the contract and resource baseline

**Add:**

- `native/KaisolaCore/Package.swift`
- `native/KaisolaCore/Sources/KaisolaCore/KaisolaCoreVersion.swift`
- `native/KaisolaCore/Sources/KaisolaBrokerProtocol/BrokerWire.swift`
- `native/KaisolaCore/Tests/KaisolaCoreTests/`
- `native/KaisolaCore/Tests/KaisolaBrokerProtocolTests/`

Implement package platforms, products, protocol/security constants, and a
minimal fixture/resource test harness. Mirror broker protocol `2`, security
epoch `1`, observe feature `terminal-observe-v1`, and 56 MiB maximum frame.

Record the installed Electron baseline using the Phase 1 workload definitions.
Keep raw reports as ignored build artifacts; record methodology and summarized
results in the plan or release evidence.

**Verify:**

```bash
swift build --package-path native/KaisolaCore
swift test --package-path native/KaisolaCore
npm run typecheck
```

### Task 0.2: Extract protocol and domain models

**Move from the iPhone target into `KaisolaCore`:**

- `Protocol/JSONValue.swift`
- `Protocol/CompanionProtocol.swift`
- `Domain/CompanionModels.swift`

Promote only the API used outside the package. Keep strict decoding and
validation behavior unchanged. Re-export `KaisolaCore` from a small iPhone
compatibility import while application files migrate to explicit imports.

Do not remove legacy `CompanionBoard` Codable conformance in this task; semantic
round-trip fixtures still need it. Mark it as legacy wire compatibility and add
a dependency check that the native desktop UI never consumes Board DTOs.

**Verify:** package tests; existing `ProtocolFixtureTests`; Node protocol tests;
iOS build.

### Task 0.3: Extract crypto, pairing, and framing

**Move into `KaisolaCore`:**

- pure pieces of `CompanionIdentity.swift`;
- `CompanionCrypto.swift`;
- `NoiseXX.swift`;
- `PairingModels.swift`;
- `SecureFrameChannel.swift`;
- `LengthFraming.swift`.

Keep `CompanionIdentityKeychain`, LocalAuthentication prompts, and terminal
control authorization in the iPhone application target. Split the identity
model from persistence instead of conditionally compiling platform UI into the
core.

**Verify:** Node and Swift Noise vector tests, replay/tamper tests, strict
pairing payload tests, maximum-frame tests, iOS build/test.

### Task 0.4: Rebase the iPhone project

**Touch:**

- `mobile/KaisolaCompanion/project.yml`
- iPhone sources importing migrated symbols
- generated `KaisolaCompanion.xcodeproj`

Add `native/KaisolaCore` as a local package dependency. Exclude removed source
paths from the app target. Regenerate the project with XcodeGen and confirm
there is exactly one compiled definition for every migrated type.

**Verify:**

```bash
cd mobile/KaisolaCompanion && xcodegen generate
xcodebuild -project KaisolaCompanion.xcodeproj \
  -scheme KaisolaCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/kaisola-ios-derived test
xcodebuild -project KaisolaCompanion.xcodeproj \
  -scheme KaisolaCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/kaisola-ios-release build
```

If that simulator is unavailable, choose an installed iPhone simulator and
record the exact destination used.

### Task 0.5: Cross-language conformance gate

Add package tests that consume every current Companion fixture and crypto
vector. Add fixture generation/round-trip checks where ordering is canonical.
Run the complete Electron companion test group and compare failures by fixture,
not by prose.

**Exit evidence:** package tests, iOS tests, Release build, Node companion tests,
Electron test floor, and `git diff --check` all green.

## Phase 1 — native terminal observer

### Task 1.1: Create the native macOS shell

**Add:**

- `native/KaisolaMac/project.yml`
- `native/KaisolaMac/Kaisola/App/`
- `native/KaisolaMac/Kaisola/Features/Sessions/`
- `native/KaisolaMac/Kaisola/UI/`
- `native/KaisolaMac/KaisolaTests/`

Use AppKit for application/window commands and SwiftUI for the initial shell.
Add local `KaisolaCore` and pinned SwiftTerm 1.15.0 dependencies. Use a distinct
preview bundle identifier and application-support directory.

Implement a restrained project/session list, connection state, read-only badge,
terminal surface, reconnect action, empty state, and native appearance.

**Verify:** macOS Debug and Release builds; unit tests; VoiceOver labels; light,
dark, Reduce Motion, and increased-contrast inspection.

### Task 1.2: Implement the broker wire codec

**Add to `KaisolaBrokerProtocol`:**

- newline frame decoder with a 56 MiB cap;
- hello/request/response/event models;
- strict protocol/security negotiation;
- request-id correlation;
- structured broker errors;
- cursor/snapshot/subscription result models.

Use fixture and chunk-boundary tests. Cover one byte per push, multiple frames
per push, split multibyte UTF-8, oversized frames, malformed JSON, unknown
response ids, and disconnect with a partial frame.

### Task 1.3: Implement authenticated broker discovery and connection

**Add to the macOS application:**

- user-data-path resolver;
- private broker-info reader with ownership/mode checks;
- Unix-socket connection actor;
- reconnect state machine with bounded exponential backoff and jitter;
- cursor persistence scoped by broker identity, project, and terminal id.

The resolver must reproduce Electron's installed legacy precedence for
`pasola`, `Pasola`, and `Kiasola`, plus the explicit development profile, while
storing all native state under the native bundle's own directory. Reject
symlinked metadata/socket candidates and files with the wrong owner, type, or
mode.

Never log tokens, terminal output, prompts, environment variables, or retained
snapshots. Scrub secrets from structured error descriptions.

**Verify:** fake-socket tests; stale info; missing/recreated socket path; wrong
token; wrong protocol; broker exit; app foreground/reopen; sleep/wake.

### Task 1.4: Subscribe without ownership theft

Fetch discovery through the exact read surface (`broker.status`,
`terminal.list`, and `terminal.diagnostics`), map project-scoped terminal
records into the session list, and use only `terminal.subscribe` and
`terminal.unsubscribe` for streams. Subscribe using
`streamEpoch`/`afterOffset` and feed ordered bytes to SwiftTerm on the main
actor without losing backpressure.

Do not expose a keyboard/composer or invoke any terminal mutation. Add an
observer access marker plus a typed transport API whose method enum cannot
represent mutation; keep raw request construction private. New brokers enforce
the allowlist server-side and compatibility tests cover old protocol-2 brokers.

**Verify:** Electron controller and native observer receive matching ordered
output while broker ownership diagnostics remain unchanged.

### Task 1.5: Package the durable helper

**Integrated through Task 1.4 (2026-07-21):** the observer now queries
`broker.status`, `terminal.list`, and `terminal.diagnostics`; retries private
socket loss with capped jittered backoff; reopens on wake/foreground; persists
0600 cursor checkpoints scoped by broker identity, project, and terminal; and
appends exact cursor-relative suffixes without replacing already-visible
scrollback. Cold launches still request the full retained broker snapshot, using
the persisted cursor only to surface an explicit retention gap. The remaining
Phase 1 work starts with helper packaging below.

**Local implementation integrated 2026-07-21:** LocalRelease and Release builds now stage a
manifested Node 22.23.1 + node-pty 1.1.0 helper with pinned upstream checksums,
universal arm64/x86_64 Node and Swift bootstrap executables, architecture-
specific native modules, nested hashes/modes/designated requirements, and a
per-user `SMAppService` LaunchAgent. The Swift verifier checks the intact outer
application seal before trusting the nested manifest and refuses symlinks,
unmanifested files, writable code, invalid architecture/version ranges, or
signature drift. The launcher adopts compatible live brokers, defers package
replacement while they are live, and removes rendezvous files only after a
second identity/liveness check. Shared Node/Swift fixtures pin protocol,
security epoch, implementation N/N+1, and helper package schema independently.
The ad-hoc `LocalRelease` signing profile now carries only the library-
validation exception needed to load Sparkle without a Team ID; the Developer
ID `Release` profile forbids that exception. Preflight executes a side-effect-
free native launch probe so a sealed but unloadable framework cannot pass.

Bundle a signed standalone Node runtime and the exact `node-pty` dependency
closure. Add a per-user helper registration and a broker launcher/adopter that
never replaces an incompatible live broker automatically.

Record every nested executable/native module and its designated requirement.
Verify hardened-runtime entitlements, `codesign --verify --deep --strict`,
Gatekeeper assessment, notarization/stapling, translocation, helper file modes,
and explicit rejection after a bundled helper is altered.

Define independent app, broker protocol, broker implementation, and package
versions. Add N/N+1 compatibility fixtures before allowing helper upgrades.

**Verify:** clean-user install, notarization assessment, app translocation-safe
paths, first launch, update, rollback, login relaunch, and zero-live cleanup.

### Task 1.6: Add native updating and the real continuity gate

**Local implementation integrated 2026-07-21:** Sparkle 2.9.2 is exact-pinned
for a separate native-preview channel. The updater starts only with an HTTPS
appcast without credentials/fragment and an exact 32-byte Ed25519 public key;
missing or partial configuration fails closed. A packaged-helper probe now runs
one real node-pty terminal through N → N+1 → rollback-N observer replacement,
proves the broker and terminal PIDs remain stable, resumes each exact byte
cursor, and requires the combined numbered output to be continuous. The Swift
client revalidates protocol/security/implementation/package identity on the
live hello and status frames rather than trusting rendezvous metadata alone.

The actual signed Sparkle update with real Claude and Codex processes remains a
distribution gate and is not satisfied by the synthetic client-replacement
probe.

**Packaged-swap continuity gate recorded 2026-07-22:** two Developer ID-signed,
hardened-runtime Release builds (CFBundleVersion 100 and 101, Sparkle feed and
EdDSA public key baked in, both passing release preflight with
`updatesConfigured` true) were swapped atomically in `~/Applications` five
times in both directions while one continuously streaming shell, a looping
real Claude CLI (25 sequential `claude -p` invocations), and a looping real
Codex CLI (20 sequential `codex exec` invocations) ran on one live broker. An
independent read-only witness asserted on every leg that the broker PID, every
terminal PID, every stream epoch, and offset monotonicity held; plain-stream
retained content matched exactly across legs, and both provider ladders
arrived complete and in order (`CLAUDE_SEQ_1..25`, `CODEX_SEQ_1..20`, zero
failures). Gatekeeper posture of the local artifact was recorded honestly:
`codesign --verify --deep --strict` valid, `spctl` rejected as
"Unnotarized Developer ID" — notarization is CI's step. The gate also caught
and fixed two latent release bugs: custom `INFOPLIST_KEY_SU*` settings were
silently dropped by Xcode (updater shipped unconfigured; now merged from a
partial Info.plist), and non-archive Developer ID builds carried
`get-task-allow` (now suppressed). The Sparkle-transport leg — the appcast
download and installer run end to end from the published feed — remains open
pending the next published release, together with notarized
Gatekeeper/translocation/clean-user evidence.

Integrate Sparkle for the native preview channel. Run a packaged update while a
real Claude CLI and a real Codex CLI emit uniquely numbered output. Confirm the
same PIDs survive and the post-update view contains a continuous retained
sequence or an explicit retention-gap marker.

Repeat with an old broker/new client combination and a rolled-back client.

### Task 1.7: Resource and interaction gate

**Harnesses integrated 2026-07-21:** `scripts/native-resource-gate.cjs` measures
Electron and native with the same top-level `total footprint` byte metric from
one `/usr/bin/footprint -j` invocation, follows complete app process trees, adds
detached helpers explicitly, records median/p95, and refuses mismatched metric
families or workloads. Versioned workloads and an evidence-scoped interaction
matrix live under `native/KaisolaMac/ResourceGates`.

**Paired idle-workload capture recorded 2026-07-21:** both apps were measured
sequentially against the same live 0.1.86 broker under the isolated
`Kaisola Dev` profile in the `one-window-idle-terminal-existing-broker`
workload (7 samples, 1 s apart, one `/usr/bin/footprint` metric family, broker
PID counted on both sides). Electron — the repository binary loading the
production `dist/` bundle from a local HTTP preview server — measured
197.6 MiB median / 197.7 MiB p95 across app, renderer, GPU, utility helper,
and broker. The sealed universal `LocalRelease` native preview observing the
same live PTY measured 62.1 MiB median / 62.1 MiB p95 (app + broker): a
candidate fraction of 0.314 against the 0.5 release threshold, a 68.6 %
reduction. The same session verified live streaming end to end — a controller
wrote a marker command, the stream offset advanced past it, and the packaged
observer held its subscription while a non-owner `terminal.kill` was denied.
Still open: an installed-app Electron baseline (the installed daily driver
still runs a pre-observation 0.1.60 broker with live sessions and was
deliberately not disturbed), the streaming/three-window/fresh-broker
workloads, and re-measurement from the Developer ID artifact.

**Remaining workloads captured 2026-07-22** (same isolated profile, metric,
and 7-sample discipline): streaming — Electron 307.5 MiB median / 320.0 p95
versus native 91.9 / 91.9 (fraction 0.299, 70.1 % reduction, gate pass);
fresh-broker idle — Electron 202.1 median / 203.0 p95; three restored
Electron windows — 1119.0 median / 1119.3 p95, ≈460 MiB per additional
window, which is the strongest quantitative motivation recorded for the
migration. The native preview is deliberately single-window in Phase 1, so
the three-window workload stands as Electron-only baseline evidence.

Automated tests cover the 56 MiB frame envelope, >56 MiB streaming batches,
sync backpressure, an 8 MiB retained-output boundary, split UTF-8, ANSI modes,
8,192-line capped SwiftTerm scrollback, Unicode terminal widths, and resize/
reflow. The exact sealed universal `LocalRelease` artifact also passed its
side-effect-free launch probe and direct AppKit/accessibility-tree inspection:
the named shell/status/reconnect/sidebar controls were exposed, sidebar
hide/show worked, and the preview correctly remained read-only rather than
replacing an older live Electron broker without observation support. Paired
native/Electron captures and packaged selection/copy/search, VoiceOver,
appearance, multiple-window, and sustained-GUI inspections remain open release
evidence.

Implement a native physical-footprint probe that counts the app, WebKit helpers,
broker, control plane, and any other bundled helper consistently. Remeasure the
Electron baseline with the same tool and workloads.

Exercise SwiftTerm with large scrollback, sustained output, ANSI modes, Unicode,
selection/copy/search, accessibility, appearance, resize, app backgrounding,
and multiple windows.

**Phase 1 exit evidence:** signed packaged build, update-continuity transcript,
compatibility matrix, physical-footprint report, stress results, and no changes
to Electron terminal ownership.

**Accepted follow-ups from the 2026-07-22 adversarial review** (recorded, not
blocking Phase 1): the native preview build currently runs inside the Electron
release job, so a native-only or notarization outage would delay an Electron
release until reran or reverted — splitting it into an independent job with an
Electron-only publication path is queued for the next workflow pass. The
terminal accessibility value exposes the raw retained stream rather than
SwiftTerm's rendered display model, so ANSI-heavy sessions read poorly under
VoiceOver; deriving the value from the parsed buffer belongs with the
VoiceOver judgment rows.

## Repository-wide verification floor

Run after each integration milestone:

```bash
swift test --package-path native/KaisolaCore
ELECTRON_RUN_AS_NODE=1 npx electron --test \
  electron/*.test.cjs electron/companion/*.test.cjs
npm run typecheck
env -u ELECTRON_RUN_AS_NODE npm run smoke
git diff --check
```

Run the relevant iOS/macOS `xcodebuild` commands whenever shared Swift or an app
target changes. A GUI/simulator environment failure must be reported separately
from a test failure and rerun in a GUI-capable session before release.

## Release boundary

Phase 0 and Phase 1 are separate releasable milestones. Each completed milestone
bumps the appropriate app version, commits intentionally, pushes `main`, creates
and pushes the next annotated `v*` tag, monitors `.github/workflows/release.yml`,
and verifies the published artifacts. The native preview channel must not
silently replace the Electron daily-driver channel.
