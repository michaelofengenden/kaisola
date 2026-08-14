# Swift Session Broker: Remaining Work

## v0.1.123 boundary

Version 0.1.123 includes an arm64 Swift broker that can run as an explicit,
unbundled developer mode. It authenticates the existing controller and observer
clients, owns a real Darwin PTY, runs `zsh`, and supports fresh-session create,
write, resize, ETX, whole-session kill, output snapshots, bounded retention, and
release. The shipping app still selects the packaged Node broker by default.

This release deliberately supports a clean start. It does not claim adoption or
migration of sessions created by older Node broker versions.

## Required before the Swift broker becomes the default

### 1. Ordered live output and backpressure

- Replace snapshot-only subscription with ordered incremental output and exit
  events using the existing stream epoch and contiguous offsets.
- Bound every client queue and define one fail-closed slow-consumer policy:
  disconnect with an exact resubscribe cursor instead of buffering without a
  limit or silently dropping bytes.
- Prove snapshot-to-live ordering, UTF-8 repair, truncation, reconnect, and exit
  publication with multiple controller and observer clients.

### 2. Production packaging and default enablement

- Package and sign the arm64 Swift broker as a native schema-2 helper. The app,
  bootstrap service, release preflight, and helper probe currently remain
  intentionally pinned to the schema-1 Node launch path.
- Add an explicit opt-in selector and rollback to the Node helper before making
  Swift the default for newly created sessions.
- Verify the sealed executable identity, launch arguments, update replacement,
  and app-to-broker version reporting in the signed release artifact.

### 3. Reliability soak

- Repeat real-shell create, write, resize, ETX, descendant cleanup, kill,
  release, broker shutdown, and socket cleanup under process churn.
- Measure retained-output memory and file-descriptor bounds at the 64-session
  capacity limit and with slow or disconnected observers.
- Exercise app relaunch and same-version broker restart for sessions created by
  the Swift broker. Record actionable diagnostics for any fail-closed result.

### 4. CI deduplication

- Keep fast, path-focused feedback on pull requests.
- Run the expensive authoritative matrix once on the merge queue's exact
  would-be merge commit.
- After `main` advances, reuse commit-bound receipts and run only candidate
  packaging, signing, notarization, promotion, and lightweight integrity
  checks. Do not repeat identical source suites on both PR and `main` push.

## Deliberately excluded: old-session migration

The frozen mixed-version and legacy-continuity worktrees are not part of
v0.1.123. The release assumes existing broker/session state can be cleared before
the Swift broker is enabled. Adopting Node-owned sessions, migrating old cleanup
witnesses, or supporting mixed Node/Swift generations would require a separate
protocol and release project with its own durable crash-state matrix.
