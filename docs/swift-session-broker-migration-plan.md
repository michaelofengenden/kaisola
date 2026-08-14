# Swift session broker migration plan

**Status:** Approved arm64 design; implementation begins after the corrective
v0.1.122 continuity release

**Date:** 2026-08-13

**Scope:** Replace Kaisola-owned production Node runtime with a detached Swift
session broker while preserving terminals through application updates. Keep
ACP agents external and keep CodeMirror as a deliberately isolated web island.
Kaisola remains Apple-Silicon-only; restoring Intel support is outside this
migration.

This document narrows the broader native migration roadmap to the runtime
boundary that still ships Node. It is a compatibility migration, not a terminal
rewrite performed behind a flag day.

## Decision summary

Kaisola's target production topology is:

```text
Kaisola.app (SwiftUI + AppKit)
├── Swift product state, files, Git, usage, companion, and ACP client
├── external ACP agent processes
├── isolated offline CodeMirror WKWebView
└── authenticated private Unix sockets
    ├── current KaisolaSessionBroker (signed Swift executable)
    │   └── all newly created PTYs
    └── zero to seven draining broker generations
        └── only the PTYs they already own
```

"Fully Swift" means all production code owned and executed by Kaisola is
Swift, with two explicit exceptions:

- CodeMirror remains checked-in JavaScript inside its current network-denied,
  ephemeral `WKWebView`. Swift continues to own paths, file I/O, permissions,
  persistence, save, undo, and command authority.
- ACP adapters and agent CLIs remain external processes implementing published
  protocols. Their implementation language is not part of Kaisola's trusted
  runtime.

JavaScript release scripts and tests do not run in the product and therefore
are not a performance or runtime-security concern. They can be replaced after
the production migration if a literally JavaScript-free repository is still a
goal.

## Non-negotiable invariants

1. Updating, quitting, crashing, or replacing the GUI must not change the PID
   of any live shell, agent CLI, SSH connection, or development server.
2. A release must install a matching **current** broker before it routes new
   terminal creation. Existing terminals may remain on older, draining
   generations.
3. No update may claim success until the candidate broker passes authenticated
   hello, status, inventory, and create/write/resize/signal/exit probes.
4. Failed candidate startup or validation leaves the previous generation
   current. Rollback is an atomic registry selection, not a best-effort repair.
5. The first Swift broker must remain wire-compatible with protocol 2 and the
   existing Node implementation. Runtime language is not a wire version.
6. The broker remains a same-user, local-only terminal service. It gains no
   network listener, ACP credentials, Keychain authority, companion identity,
   application database, or UI state.
7. The migration must support a bounded mixed fleet: one current generation
   and up to seven Node or Swift draining generations. Reaching the eight-record
   registry limit fails closed; it never evicts a generation that owns a live
   terminal.
8. Every newly packaged executable and every release acceptance run is arm64.
   A schema-2 package that declares an x86_64-only or unexpected architecture
   is rejected.

## Why the broker remains detached

The broker owns PTY master file descriptors and child process groups. If it
lived in `Kaisola.app`, Sparkle replacement or a normal application relaunch
would close those descriptors and terminate terminal continuity.

The existing design already provides the correct durable boundary:

- a signed Swift bootstrap validates a private launch configuration;
- a content-addressed helper package is copied out of the replaceable app
  bundle into Application Support;
- the broker is spawned in its own session with standard streams detached;
- a generation registry records current and draining brokers; and
- terminal ownership routing directs mutations to the generation that owns the
  terminal.

The migration retains this mechanism and changes only the packaged broker
implementation.

Live PTY file-descriptor transfer between brokers is explicitly out of scope.
Although Unix descriptor passing can move a master descriptor, it does not
atomically move process-reaping responsibility, buffered output, mutation
ledgers, observers, timers, or in-flight writes. Generation draining is safer
and already matches Kaisola's update model.

## Version and identity model

Four identities must remain separate:

| Identity | Meaning | Changes when |
|---|---|---|
| App release | User-facing Kaisola version/build | Every app release |
| Package content digest | Exact sealed helper payload and release provenance | Any packaged byte, launch metadata, or bound app-release metadata changes |
| Broker protocol | Wire-breaking compatibility epoch | Only for an intentional wire break |
| Broker implementation | Additive behavior level | A compatible feature set is added |

The first Swift broker continues to report protocol 2 and implementation 2 only
after it passes the complete Node/Swift conformance suite. It additionally
reports an optional diagnostic `runtimeKind` of `swift`. A retained broker that
predates this field remains compatible; the UI labels a missing value as Node
only when the independently verified package is schema 1. Runtime kind is never
used as a protocol version, compatibility signal, or routing authority.

A later additive feature may introduce implementation 3 only after both the
current and prior app releases can negotiate it. A wire incompatibility must
increment the protocol version rather than silently widening the implementation
range.

The product diagnostic should distinguish freshness from continuity:

```text
Current broker: Swift · Kaisola 0.1.x · verified
Continuity: 7 live terminals · 5 current · 2 retained on 1 older generation
```

An older generation is expected while it owns sessions. It is a problem only
when it is empty but cannot retire, or when the current generation does not
match both the installed app's packaged content digest and bound app-release
provenance. Draining generations are allowed to report older app releases.

## Runtime-neutral helper package

The current schema is Node-shaped: it requires a Node version, ABI, `node-pty`,
the Node executable, and a broker script. Before a Swift broker can ship,
helper package schema 2 makes the launch payload runtime-neutral. Schema support
becomes an explicit discriminated set, `.nodeV1` and `.nativeV2`; it is not a
single global constant that is bumped from 1 to 2 while schema-1 packages and
draining Node generations still exist.

Normative schema-2 shape:

```json
{
  "schemaVersion": 2,
  "packageVersion": "2.0.0",
  "contentDigest": "<sha256-v2>",
  "appRelease": { "version": "0.1.x", "build": "1099000" },
  "brokerImplementationVersion": 2,
  "brokerProtocol": {
    "minimum": 2,
    "maximum": 2,
    "securityEpoch": 1
  },
  "launch": {
    "kind": "native",
    "executable": "bin/kaisola-session-broker",
    "arguments": []
  },
  "files": [
    {
      "path": "bin/kaisola-session-broker",
      "role": "session-broker-executable",
      "size": 123456,
      "mode": "0755",
      "sha256": "<sha256>",
      "machO": {
        "architectures": ["arm64"],
        "designatedRequirement": "<sealed requirement>"
      }
    }
  ]
}
```

The schema-2 digest uses a new domain and binds the app release, compatibility
envelope, launch kind, executable path, ordered static arguments, and each
file's path, role, size, mode, hash, declared Mach-O slices, and designated
requirement. Schema-1 digest behavior is frozen unchanged. The app-release
fields are signed provenance and freshness inputs; they do not alter protocol
compatibility, and an older draining generation remains valid.

Schema 2 requires exactly one `session-broker-executable` record. The launch
path must resolve to that record, it must be a regular single-link file with
mode `0755`, its actual Mach-O slices must equal `["arm64"]`, and its sealed
designated requirement must validate. Static arguments are an ordered bounded
array of nonempty, NUL-free strings; `--launch` and `--pty-child` are reserved.
The bootstrap appends `--launch <private-configuration-path>` after the static
arguments. Unknown launch kinds, duplicate paths or executable roles, path
substitution, hard links, symlinks, wrong modes, wrong architectures, and
requirement mismatches fail closed.

The verifier accepts existing schema-1 Node packages and schema-2 native
packages during the compatibility window. After verification it returns a
runtime-neutral launch command:

```swift
enum BrokerLaunchPayload: Sendable, Equatable {
    case node(executable: URL, script: URL)
    case native(executable: URL, arguments: [String])
}
```

The existing sealed file inventory, modes, hashes, Mach-O validation,
designated requirements, outer-app signature validation, content digest, and
atomic staging rules remain mandatory. Schema 2 also rejects files with link
count other than one. It removes language-specific metadata; it does not relax
verification.

### Mixed-package catalog and usage service

The current `BrokerHelper` package also supplies Node and the Anthropic SDK to
the provider-usage service. A Swift broker package cannot silently replace that
singular directory. Before mixed canary builds, the signed app bundle gains a
small catalog that names independently sealed packages by digest:

- one schema-2 Swift broker candidate;
- one schema-1 Node broker fallback for the compatibility window; and
- while still required, the schema-1 package that provides the legacy usage
  runtime.

The broker coordinator selects only entries declared for broker service.
`UsageCenter` selects an explicit usage-capable entry and never assumes the
current terminal broker contains Node. Each catalog entry is independently
verified and staged; the outer-app signature seals the catalog. Phase 7 moves
provider usage to Swift or an external adapter, then removes the final bundled
Node package. Old digest-addressed schema-1 packages in Application Support are
retained as long as a live draining generation owns terminals, even after the
new app bundle contains no Node.

## Broker process architecture

Add a `KaisolaSessionBroker` macOS command-line target and split its logic into
testable components:

```text
KaisolaSessionBrokerMain
├── BrokerServer                 socket lifecycle and connection admission
├── BrokerConnection             framing, authentication, access role, limits
├── BrokerRequestGate            concurrency, idempotency, mutation ledger
├── TerminalRegistry             ownership and terminal lifecycle actor
├── DarwinPTY                    PTY creation, resize, signal, foreground state
├── TerminalSpool                durable bytes, paging, quotas, metadata
├── TerminalObserverHub          bounded subscription fan-out/coalescing
├── BrokerInventory              terminal and generation snapshots
└── BrokerGenerationLifecycle    current, draining, retirement, rollback
```

`KaisolaBrokerProtocol` remains the shared framing and compatibility package.
The executable should not import the GUI target.

### Safe PTY creation in Swift

The broker must not call `fork()` and then execute Swift code in a
multithreaded process. The preferred design is:

1. The broker opens the PTY pair.
2. It uses `posix_spawn` to launch the same signed executable in a small
   `--pty-child` mode with the slave descriptor explicitly inherited and a
   minimal allowlisted environment plus a close-on-exec readiness/error pipe.
3. The child mode becomes a session leader, claims the controlling terminal,
   resets inherited signal masks and dispositions, duplicates the slave to
   stdin/stdout/stderr, closes unrelated descriptors, and immediately calls
   `execve` for the requested shell or command.
4. The parent reports `terminal.create` success only after the readiness pipe
   proves successful `execve`; otherwise it reaps the failed child, closes the
   PTY, and returns a bounded error.
5. The parent closes the slave and retains only the master descriptor and child
   identity.

This avoids running Swift after a fork, avoids bundling `node-pty` or a C spawn
helper, and keeps the production package fully Swift. Kaisola is arm64-only;
the following must be proven on Apple Silicon before choosing this design
permanently:

- interactive zsh/bash/fish job control;
- foreground process groups;
- Ctrl-C, Ctrl-Z, resume, terminate, and window-size propagation;
- SSH, Vim, tmux, Claude, Codex, and a long-output process;
- clean child reaping with no zombies; and
- orderly drain and retirement never terminate a broker-owned process group.

A real broker crash can close PTY masters and is not claimed as recoverable.
It must be diagnosed as terminal loss rather than mislabeled as restored
continuity.

If macOS prevents the self-spawn helper from establishing the controlling TTY
correctly, stop and record that result before adopting any native shim. A tiny
auditable POSIX shim would be preferable to unsafe post-fork Swift, but it
would be an explicit exception to the all-Swift goal and requires approval.

## Rolling update state machine

For packaged digest `N+1` while generation `N` is current:

```text
stage N+1
  -> verify sealed package
  -> authenticate N and verify exact administrative/handoff capability
  -> prepare N to drain toward the exact N+1 digest
  -> launch detached candidate
  -> authenticated hello + status + empty inventory
  -> run and release the disposable create/write/resize/signal/exit probe
  -> re-prove empty candidate inventory
  -> compare-and-swap registry current N -> N+1
  -> route all new terminal.create calls to N+1
  -> keep mutations for existing terminal IDs on their recorded owner
  -> retire N only after inventory is empty and leases/writers are quiescent
```

Preparing the old broker before candidate launch is deliberate. The running
implementation already uses this order to prevent retry-time PID churn when an
older broker cannot perform the handoff. The prepare window pauses new creates
and is bounded by the existing startup/probe deadlines; mutations for existing
terminals continue. A future non-mutating administration preflight may reduce
that pause, but launch-first is not reintroduced without equivalent proof.

The disposable readiness terminal uses a unique project and terminal identity.
The Phase-0 golden scenario defines its exact protocol-2 behavior: create,
confirm an echoed token, resize and observe the geometry, invoke the existing
`terminal.signal` semantic (ETX input, not an unnegotiated OS-signal API), wait
for structured exit, release the terminal and its spool, and verify inventory
is empty again. The candidate is not publishable if any step times out, emits
an incompatible shape, leaks a terminal, or cannot be authenticated.

Failure behavior:

- Before registry publication: cancel any exact prepared handoff on `N`,
  terminate the candidate, and leave `N` current.
- After publication but before any new terminal: select `N` again and retire
  the candidate.
- After the candidate owns terminals: do not kill it. Mark it draining, select
  the last healthy generation current, and preserve its owned terminals.
- If an app update is interrupted, reconcile the registry against authenticated
  live status and exact content digests. Never infer ownership from stale PID
  metadata alone.

The bootstrap and registry must retain at least the current package plus every
package that still has a live generation. Empty superseded packages can be
removed only after a grace interval and an authenticated inventory check.
Registry publication is compare-and-swap against the exact authenticated
topology and revision observed before launch. Concurrent winners, missing
registries, changed drain sets, and stale selections fail closed or adopt only
an independently verified exact current generation.

## Protocol parity surface

The Swift broker must implement the current request families before cutover:

- broker status, inventory, shutdown, rolling prepare/cancel/retire;
- terminal availability, create, attach, snapshot/output, list, diagnostics;
- write, resize, signal, kill, release, and delayed release cancellation;
- owner and renderer detach;
- history paging and continuous cross-epoch offsets;
- subscribe/unsubscribe with bounded observer queues;
- focus, agent-turn state, control leases, wait-for-exit, and exit status; and
- mutation idempotency and exact access-role enforcement.

Parity is defined by observable wire behavior, not by matching internal Node
classes. Node remains the reference implementation until the Swift broker
passes the same golden fixtures and black-box scenarios.

One checked-in language-neutral feature inventory is consumed by both Node and
Swift tests. It includes every currently advertised feature, including
`terminal-history-continuous-v1`, `terminal-exit-status-v1`, observer-only
output, attach acknowledgement, and observer coalescing. A shadow Swift broker
advertises only behavior it implements and is marked internally ineligible for
registry publication. Protocol 2/implementation 2 becomes eligible current
only after the complete shared suite passes; `runtimeKind` never substitutes
for that proof.

## Durable spool requirements

The Swift spool is not ordinary log output. Protocol 2 observes JSON strings,
and the Node reference turns node-pty strings back into UTF-8 before advancing
offsets and writing the spool. Therefore the first Swift broker preserves that
normalized UTF-8 byte contract; it does not introduce a raw-octet wire change
under protocol 2. Invalid and split UTF-8 behavior is frozen by Phase-0 golden
fixtures. A future raw-byte transport requires explicit negotiation and, if it
changes cursor meaning, a new protocol version.

The spool must preserve:

- append-only bytes with monotonic absolute offsets;
- a separate live-parser epoch boundary so old ANSI state is never replayed
  into a fresh terminal parser;
- complete history paging back to retained offset zero;
- bounded in-memory hot tail and observer queues;
- snapshot barriers preventing duplicate or missing bytes between snapshot and
  subscription;
- UTF-8-safe display slicing with the same normalized bytes on disk that define
  protocol-2 offsets;
- per-terminal and global quotas with deterministic eviction;
- mode `0700` directories and `0600` files;
- no symlink traversal, hard-link substitution, ownership mismatch, or
  group/world-writable parent acceptance; and
- atomic metadata replacement with crash recovery at every write boundary.

## Security boundary

The Swift broker must preserve or improve the current controls:

- verify peer UID from the Unix socket in addition to checking a token;
- compare authentication tokens without data-dependent early exit;
- bind launch configuration, socket, PID, start time, content digest, protocol,
  security epoch, and implementation identity;
- accept controller, observer, and administrator methods only on their declared
  roles;
- preserve method-specific frame caps before full JSON decoding;
- cap clients, outstanding requests, observers, terminals, spools, and
  mutation-ledger memory;
- create private files through descriptor-relative, no-follow operations;
- inherit an allowlisted environment rather than the bootstrap's entire
  environment;
- close every nonessential file descriptor in broker and PTY child modes;
- keep broker logging bounded and free of terminal text, tokens, environment,
  prompts, and paths unless explicitly redacted; and
- expose no network listener.

The detached broker bootstrap allowlist is limited to the user's identity and
locale needed for shell startup (`HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`,
`TMPDIR`, `LANG`, and bounded `LC_*` entries) plus explicit Kaisola launch
markers. Credential-, proxy-, provider-, and developer-injection variables are
not inherited. Each terminal then receives the existing separately validated
terminal environment from its authenticated create request; the broker's own
environment is never used as a hidden credential channel.

The broker necessarily runs with the user's filesystem authority because it
launches the user's shells. Swift removes a large general-purpose runtime and
native addon from the package, but it does not turn terminal execution into a
sandbox.

## External ACP agents

ACP remains outside the terminal broker:

- The Swift app owns ACP protocol state, permissions, persistence, and UI.
- Each agent adapter is a separately launched, capability-negotiated process.
- The broker may provide PTYs requested through ACP, but it does not parse ACP,
  hold provider credentials, or decide permissions.
- App relaunch restores persisted ACP chat state and asks a capable adapter to
  resume. It must not fabricate continuity when an adapter cannot resume.

If uninterrupted ACP turns during GUI replacement become a requirement, add a
separate, narrow Swift `KaisolaAgentHost` in a later design. Do not expand the
terminal broker into a combined terminal, ACP, MCP, usage, and companion
daemon.

## Isolated CodeMirror editor

CodeMirror remains the only intentional JavaScript runtime island:

- checked-in, deterministic assets only;
- no remote scripts, package resolution, network, frames, forms, or workers;
- ephemeral web data store and private scheme handler;
- opaque per-view bridge token;
- bounded validated messages;
- no file paths or arbitrary shell commands exposed to JavaScript; and
- Swift remains the sole file and persistence authority.

Rewriting CodeMirror in Swift is a separate editor project with substantial
correctness and accessibility risk. It is not required to remove Node from the
shipping application.

## Claude transcript normalization

The XML-like `/model` and `/effort` bubbles seen after importing a Claude Code
session are not commands generated by Kaisola. Claude stores local slash
commands and their output as transcript records, including a caveat that they
are not conversational input. A generic importer can flatten those user-role
records and expose ANSI sequences such as `ESC[1m` and `ESC[22m` as `[1m` and
`[22m`.

If Kaisola adds Claude JSONL import/export, use this classification contract:

1. Import human conversation only when metadata identifies a typed human
   prompt, such as `origin.kind == "human"` or `promptSource == "typed"`.
2. Drop local-command caveats and file-history snapshots from conversation.
3. Convert `command-name`, `command-args`, and `local-command-stdout` records
   into an optional collapsed session-settings event, never a user message.
4. Strip ANSI control sequences before displaying any retained command output.
5. Preserve the original record type in export metadata so another importer
   cannot mistake it for conversational input.

This normalization is independent of the Swift broker migration.

## Delivery phases

### Phase 0 — Contract freeze and measurements

Deliverables:

- Capture golden protocol fixtures for every request, response, event, access
  role, rejection, and frame-size boundary.
- Record baseline idle/active physical footprint, CPU, I/O latency, throughput,
  wakeups, package size, and terminal-creation latency for the arm64 Node broker
  with pinned workloads, warmup, samples, and hardware metadata.
- Add a real two-process mixed-generation matrix covering Node current/Node
  draining, not only scripted Swift fakes.
- Reconcile Swift and Node feature constants so drift is visible in tests.
- Freeze protocol-2 UTF-8 normalization, cursor, `terminal.signal`, exit-shape,
  snapshot-to-live ordering, and full eight-generation behavior.

Exit gate: the black-box suite can identify a deliberately altered Node broker
response and the performance harness produces repeatable measurements.

### Phase 1 — Runtime-neutral packaging

Primary files:

- `native/KaisolaMac/Shared/BrokerHelperPackage.swift`
- `native/KaisolaMac/BrokerBootstrap/BrokerBootstrapService.swift`
- `native/KaisolaMac/BrokerBootstrap/DetachedBrokerProcess.swift`
- `native/KaisolaMac/Shared/BrokerLaunchConfiguration.swift`
- `native/KaisolaCore/Sources/KaisolaBrokerProtocol/BrokerWire.swift`
- `native/KaisolaMac/project.yml`
- `native/KaisolaMac/BrokerHelper/package-policy.json`
- `scripts/native-broker-package.cjs`
- `scripts/native-distribution-sign.cjs`
- `scripts/native-release-preflight.cjs`
- `scripts/native-broker-helper-probe.cjs`
- `native/KaisolaMac/KaisolaTests/BrokerHelperPackageTests.swift`
- `native/KaisolaMac/KaisolaTests/BrokerLaunchConfigurationTests.swift`

Deliverables:

- Decode and verify schema 1 Node and schema 2 native packages.
- Return a runtime-neutral verified launch payload.
- Launch either package kind without weakening signature or digest checks.
- Add schema downgrade, path substitution, duplicate/wrong executable role,
  hard-link, non-executable, x86_64/wrong architecture, and wrong designated-
  requirement tests.
- Narrow the broker bootstrap environment and give the native executable a
  hardened arm64 signature profile without Node's JIT entitlements.

Exit gate: the shipping schema-1 Node package preserves its frozen manifest,
entrypoint, digest, and launch semantics, while a signed arm64 fixture native
executable passes the same staging and bootstrap path. Generated timestamps and
timestamped code signatures are not required to be byte-identical artifacts.

### Phase 2 — Swift broker skeleton

Primary files:

- new `native/KaisolaMac/KaisolaSessionBroker/` sources;
- `native/KaisolaMac/project.yml`; and
- new broker unit and executable integration tests.

Deliverables:

- Private Unix socket lifecycle and stale-socket recovery.
- Authenticated hello and role negotiation.
- Status/inventory and administration lifecycle.
- Framing, limits, request gate, idempotency ledger, and bounded logging.
- A shadow mode that never creates PTYs and is structurally ineligible for the
  generation registry or terminal routing.

Exit gate: the existing Swift clients can connect to either broker and cannot
distinguish their common status/inventory behavior except for optional
`runtimeKind`; the shadow advertises no unimplemented terminal feature and
cannot be published current.

### Phase 3 — PTY engine

Deliverables:

- Safe self-spawn PTY child mode.
- Create/attach/write/resize/signal/kill/release/wait-for-exit.
- Process groups, foreground process, cwd, exit status, and activity state.
- Terminal caps, environment normalization, and exact ownership semantics.

Exit gate: the full interactive PTY matrix passes on arm64 and a terminal PID
survives repeated GUI termination/relaunch. Intel and Rosetta are not release
targets or substitutes for this gate.

### Phase 4 — History and observation

Deliverables:

- Durable spool and atomic metadata.
- Snapshot/history/continuous offsets.
- Observer subscription, batching, backpressure, and slow-client eviction.
- Agent-turn, focus, and control-lease parity.

Exit gate: multi-gigabyte bounded-history stress, crash injection, UTF-8 split,
quota, observer-gap, and snapshot-to-live transition tests have no duplicate or
missing bytes.

### Phase 5 — Mixed-generation canary

Deliverables:

- Bundle independently sealed Node and Swift candidates through the signed
  mixed-package catalog.
- Run Swift in explicit opt-in canary mode for newly created terminals.
- Exercise Node-to-Swift and Swift-to-Node rollback with both generations live.
- Publish diagnostics that name current versus retained generations clearly.
- Publish canary artifacts through a separate prerelease workflow and update
  channel. Canary tags do not begin with `v`, so they cannot trigger the stable
  Sparkle feed mutation in `.github/workflows/release.yml`.

Exit gate: update, rollback, and crash-injection runs preserve exact terminal
PIDs, output cursors, owners, and working directories.

### Phase 6 — Swift default with Node fallback

Deliverables:

- Ship Swift as the default current generation.
- Retain one sealed Node fallback package for the compatibility window.
- Fail back only after authenticated Swift readiness failure, never because an
  old but healthy session remains active.

Exit gate: at least one complete release/update cycle shows no Swift broker
rollback and all Node generations retire when their sessions close. This gate
cannot close in the same release that first makes Swift the default.

### Phase 7 — Remove production Node

Deliverables:

- Remove Node, `node-pty`, broker JavaScript, and the broker-bundled Anthropic
  SDK from the application helper package.
- Move provider usage lookup to a narrow Swift/provider-specific service or an
  external adapter; it must not keep Node inside the session broker package.
- Retain legacy wire decoding and mixed-generation observation for the declared
  support horizon.

Exit gate: release preflight proves the app bundle contains no Node executable
or broker JavaScript, while CodeMirror remains isolated and all continuity
tests pass. The preflight distinguishes the new app bundle from legitimate old
schema-1 packages retained in Application Support for still-live drains.

## Release acceptance matrix

Every Swift-default release must pass:

| Area | Required proof |
|---|---|
| Continuity | Exact PTY and foreground child PIDs survive app quit, crash, Sparkle replacement, and relaunch |
| Routing | New terminals use current; every mutation for an old terminal reaches its recorded generation |
| History | Byte cursor has no gaps or duplicates across snapshot, live output, restart, and paging |
| Terminal behavior | Shell job control, resize, signals, SSH, tmux, editors, and agent CLIs behave normally |
| Upgrade | Candidate failure leaves current untouched; post-publication rollback preserves candidate-owned terminals |
| Security | UID/token/role checks, frame caps, symlink/hard-link attacks, modes, ownership, signature, and digest tests pass |
| Resources | Arm64 physical footprint, CPU and wakeups stay within Phase-0 measured thresholds; literal zero CPU is not used as an acceptance claim |
| Cleanup | Empty draining generations and unreferenced packages retire after their grace interval |
| Compatibility | Current app works with Node and Swift protocol-2 generations; rollback behavior is explicitly tested |

Performance targets should be fixed only after Phase 0 measurements. The
expected direction is lower idle memory and a substantially smaller helper
package, but no release claim should use source line count as a proxy for
runtime performance.

## Release train

Each stable release is cut only from its exact merged `main` commit after the
native release-candidate workflow has signed, notarized, stapled, probed, and
uploaded that commit's immutable candidate. A later `main` push can cancel an
earlier candidate, so phases are not merged while the release they are meant to
qualify is still building.

The approved arm64 release train is:

1. **v0.1.121** — the already-published initial continuity and neutral-white
   Glass release. Final multi-window persistence fencing and adversarial broker
   handoff hardening were not complete when this tag was cut, so this release
   is not claimed as the migration baseline.
2. **v0.1.122** — corrective session persistence and broker-continuity release.
   It preserves the schema-1 Node broker and contains no claim that the Swift
   broker migration is implemented.
3. **v0.1.123** — Phase 0 plus schema-2 decoding/verification and
   `BrokerLaunchPayload`; production still launches the schema-1 Node broker.
4. **v0.1.124** — complete runtime-neutral launch packaging and ship the Phase-2
   Swift broker in non-publishable shadow mode.
5. **v0.1.125** — ship the arm64 Swift PTY engine behind explicit development
   selection while Node remains stable current.
6. **v0.1.126** — ship history/observer parity and the mixed-generation canary
   machinery while the stable default remains Node.
7. **`swift-broker-canary-0.2.0-rc.N`** — signed GitHub prereleases from a
   separate workflow and feed, used for Node↔Swift rollback and update soak.
   These tags never match the stable `v*` release workflow.
8. **v0.2.0** — Swift becomes default current with one sealed Node fallback.
9. **v0.2.1** — complete the required real update cycle with the fallback still
   present and prove clean Node retirement.
10. **v0.2.2 or later** — remove bundled production Node only after the declared
   support horizon, usage-service migration, and absence of live Node drains.

This sequence avoids the repository's historical `v0.1.135` collision and
uses the minor-version boundary to make the default-runtime switch visible.

## First implementation slice

The first migration code change after the corrective v0.1.122 release should
be **Phase 0 plus the decoding half of Phase 1**, not PTY creation:

1. Capture one shared complete feature inventory and normalized protocol-2
   scenario corpus, including the Node compatibility behavior named above.
2. Prove both Node and Swift consumers fail when a fixture response or feature
   is deliberately changed.
3. Extract a schema-discriminated language-neutral package manifest model.
4. Preserve schema-1 decoding, digest, staging, and verification unchanged
   through frozen fixtures.
5. Add schema-2 arm64 native-package fixtures, the v2 digest, and negative
   security cases.
6. Add the runtime-neutral `BrokerLaunchPayload` without switching production
   launch behavior or changing the shipping package policy.
7. Record repeatable arm64 Node baseline measurements and a real two-Node
   current/draining black-box result.

That slice is independently reviewable, does not touch live PTYs, and creates
the trust and compatibility seam required by every later phase.

## Parallel-work ownership

The corrective v0.1.122 continuity release lands before migration
implementation. Every migration branch starts from that exact merged commit.
The first slice must not edit `BrokerControlClient.swift`,
`BrokerStartupCoordinator.swift`, or their
tests; the safe prepare-before-launch ordering, authenticated legacy bridge,
stale-target cancellation, exact registry CAS, drain preservation, and
target-promotion behavior are frozen by Phase 0. Initial work is confined to
package models, verification and protocol fixtures, measurement harnesses, and
new conformance tests. Other agents' dirty worktrees remain untouched unless
their changes are separately reviewed, tested, and explicitly integrated.
