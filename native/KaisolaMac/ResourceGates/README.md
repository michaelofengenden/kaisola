# Native resource gate

`scripts/native-resource-gate.cjs` measures the same metric for native and
Electron: the top-level `total footprint` byte count from one
`/usr/bin/footprint -j` invocation. It includes every descendant of the app
root plus detached broker/control-plane PIDs passed explicitly. It does not mix
RSS, resident size, or Activity Monitor estimates into the comparison.

The versioned workload definitions are in `workloads-v1.json`. Before a paired
capture, put both applications into the same named workload, use the same
broker state, wait for the same warm-up point, and take at least five samples.
Do not compare an idle native observer with a streaming Electron terminal or an
already-running broker with a fresh broker.

## Capture

Create the ignored output directory, identify the app root PID, and pass the
private broker metadata file so its detached PID is counted:

```bash
mkdir -p native/KaisolaMac/ResourceGates/results
npm run native:resource -- \
  --label native \
  --workload one-window-idle-terminal-existing-broker \
  --root-pid NATIVE_APP_PID \
  --include-info "$HOME/Library/Application Support/pasola/session-broker/broker.json" \
  --samples 7 --interval-ms 1000 \
  --output native/KaisolaMac/ResourceGates/results/native-idle.json
```

Repeat without changing the workload for Electron:

```bash
npm run native:resource -- \
  --label electron \
  --workload one-window-idle-terminal-existing-broker \
  --root-pid ELECTRON_APP_PID \
  --include-info "$HOME/Library/Application Support/pasola/session-broker/broker.json" \
  --samples 7 --interval-ms 1000 \
  --output native/KaisolaMac/ResourceGates/results/electron-idle.json
```

Use the actual first-existing Electron profile (`pasola`, `Pasola`, `Kiasola`,
or `Kaisola`) rather than assuming the example path.

## Compare

```bash
npm run native:resource -- \
  --compare-candidate native/KaisolaMac/ResourceGates/results/native-idle.json \
  --compare-baseline native/KaisolaMac/ResourceGates/results/electron-idle.json \
  --max-fraction 0.5
```

The comparison refuses mismatched schemas, metric families, or workload IDs.
`--max-fraction` is an explicit release threshold, not a hard-coded claim. Keep
raw local reports ignored and copy only reviewed medians/p95 values into release
evidence.

Physical footprint is the automated resource gate. Launch-to-interactive time,
CPU, frame pacing, energy impact, and sustained-stream battery impact still
require paired Instruments/signpost capture for each distribution candidate.
