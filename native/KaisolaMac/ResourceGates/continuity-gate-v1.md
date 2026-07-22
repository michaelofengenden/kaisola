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
  /path/KaisolaMacPreview.app/Contents/Resources/BrokerHelper \
  --require-signed-host
```

The probe also requires server-enforced observer access, `broker.status`,
`terminal.diagnostics`, real PTY creation, and exact N/N+1 package metadata.
`--require-signed-host` refuses the usual development bypass and verifies the
outer application seal before launching the helper.
It is the repeatable lower continuity gate, not a substitute for the release
gate.

The distribution gate remains open until a Developer ID/notarized native N+1
artifact is installed through its real signed Sparkle appcast while real Claude
and Codex CLIs emit numbered output. Evidence must record the app versions,
appcast/signature, broker PID, both CLI/PTY PIDs, cursor bounds, retained output,
rollback result, Gatekeeper result, and notarization/stapling result.
