# Broker continuity gate v1

The automated gate packages a real universal Node runtime and node-pty, starts
one detached broker and one real PTY, and replaces only the observer client in
this order:

1. client N reads uniquely numbered output and records its exact byte cursor;
2. client N+1 reconnects to the same broker and PTY PID from that cursor;
3. rollback client N reconnects again from the new cursor;
4. the combined output must be exactly `1, 2, 3, 4, 5`, with no duplicate,
   silent gap, or broker/terminal PID change.

Run it against the packaged Release helper:

```bash
npm run native:helper:probe -- \
  /path/Kaisola.app/Contents/Resources/BrokerHelper \
  --require-signed-host
```

The probe also requires server-enforced observer access, `broker.status`,
`terminal.diagnostics`, real PTY creation, and exact N/N+1 package metadata.
`--require-signed-host` refuses the usual development bypass and verifies the
outer application seal before launching the helper.
It is the repeatable lower continuity gate, not a substitute for the release
gate.

## Distribution status

This continuity gate is complete. On 2026-07-22 a real signed Sparkle update
moved the installed notarized app from 0.1.88 build 101 to 0.1.93 build 11001
while live Claude and Codex CLIs emitted numbered output. Appcast EdDSA,
download, install, relaunch, retained cursors, broker/PTY identity, Gatekeeper,
notarization, and stapling all passed. Five Developer-ID N⇄N+1 packaged swaps
also preserved the same broker and PTYs.

On 2026-07-28, direct replacements through signed 0.1.132 build 15119 again
preserved detached broker PID 40496 and live PTYs 40700 and 42996. Build 15110
also adopted that older 0.1.131 broker and exercised its feature-negotiated
in-memory retained-transcript fallback without a restart. These later runs are
additional replacement evidence, not a second Sparkle test.

The 15116→15117 replacement also preserved Codex processes 41379/41380 and
Claude process 43224 with their exact original start times. Installed 15117
passes distribution preflight and the signed-host helper probe; its recoverable
predecessor is
`Kaisola-0.1.132-b15116-before-b15117-20260728-110101.kaisola-backup` in Trash.

The later 15118→15119 replacement preserved the same broker, PTYs, Codex, and
Claude processes with their exact original start times. Installed 15119 passes
distribution preflight and the signed-host helper probe from its current bytes;
the concurrent predecessor remains recoverable as
`Kaisola-0.1.132-b15118-concurrent-before-b15119-20260728-112903.kaisola-backup`
in Trash.

The packaged helper probe itself is also fail-bounded: hello and every RPC have
eight-second deadlines, socket close rejects pending requests, and error cleanup
closes every partial client before the best-effort broker shutdown. Build 15119
passed the signed-host probe with one broker PID, one PTY PID, and exact
`1, 2, 3, 4, 5` output across N→N+1→rollback.

Automatic publication of the current signed appcast is still a separate
release-pipeline gate: the repository lacks `SPARKLE_PRIVATE_ED_KEY`, so a new
tag correctly fails closed. Do not describe that secret/configuration gap as a
broker-continuity failure, and do not infer current appcast freshness from the
historical successful update.
