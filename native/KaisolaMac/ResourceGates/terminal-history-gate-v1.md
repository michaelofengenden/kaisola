# Installed terminal-history qualification v1

This is the remaining physical gate for the twelve-surface terminal-history
work. A fixture, unit test, automated scroll event, ad-hoc build, or isolated
broker is useful preflight evidence but is not a substitute for this protocol.
The passing run uses `/Applications/Kaisola.app`, its Developer ID/notarized
Release binary, a physical trackpad, and the broker generation that owns the
twelve selected live PTYs.

Run it only in an explicitly scheduled release-qualification window. Preparing
the deck creates terminals and relaunching the instrumented GUI changes visible
app state. Quitting/relaunching the GUI must leave the detached broker and every
selected PTY alive. Do not stop, replace, adopt, release, or send input to a PTY
from the receipt tooling. The snapshot command performs one authenticated,
read-only `broker.status` request and strips tokens, socket paths, owners,
last-owners, and working directories before writing anything.

## Required evidence

Create a new private directory under `ResourceGates/results/`; never reuse an
old output filename. Record the following seven immutable JSON inputs:

1. Distribution preflight for the exact installed app and 40-character source
   commit, with updates, Developer ID, secure timestamp, notarization, stapling,
   Gatekeeper, helper digest, and launch probe required.
2. A `before` status snapshot selecting exactly twelve live terminal IDs.
3. Sixteen physical-footprint samples one minute apart (a full 15-minute span),
   covering the exact app process plus detached broker, with a fixed 512 MiB
   p95 ceiling.
4. The installed workspace's request-gated `NSView.displayLink` cadence report.
5. A 15-minute Animation Hitches trace attached to the exact app PID, analyzed
   over seconds 0 through 900 with the checked-in absolute limits.
6. An operator attestation for the physical interaction matrix.
7. An `after` snapshot of the same selected terminal IDs.

The attestation begins with
`terminal-history-attestation-v1.example.json`. Replace every example ID and
timestamp with the observed values. Tour all twelve surfaces at least three
times. While one terminal continuously streams, repeatedly search retained
history, page backward by more than one page, select text, resize the window,
switch tabs, and return to the live bottom. Put every visible stall/hitch in
`uiStalls` and every missing, duplicated, reordered, stale, or corrupted output
observation in `correctnessFailures`; either makes the qualification fail.

## Capture sequence

Set `run_root` to a new private directory and generate distribution evidence
for the exact commit embedded in the installed candidate:

```sh
run_root="$(pwd -P)/native/KaisolaMac/ResourceGates/results/history-qualification-v1"
mkdir -m 700 "$run_root"
source_commit=REPLACE_WITH_EXACT_40_CHARACTER_INSTALLED_SOURCE_COMMIT

npm run native:preflight -- \
  --app /Applications/Kaisola.app --require-updates \
  --require-developer-id --require-notarized \
  --source-commit "$source_commit" \
  --json-output "$run_root/release.json"
```

First prepare the twelve sessions, then close only the GUI. Confirm the broker
and all twelve PTYs remain alive before launching the installed executable with
cadence instrumentation and a private log:

```sh
env KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=1 \
  /Applications/Kaisola.app/Contents/MacOS/Kaisola \
  > "$run_root/installed-app.log" 2>&1 &
app_pid=$!
```

Set `broker_info` to the exact current-generation metadata file that backs the
selected terminals. Use the generation file named by the sealed registry when
one exists; use the legacy `session-broker/broker.json` only when no generation
registry exists. Do not copy, print, or edit this file because it contains the
live authentication token. Capture `before.json`, repeating `--terminal-id`
exactly twelve times:

```sh
npm run native:terminal-history-gate -- snapshot \
  --release "$run_root/release.json" --app-pid "$app_pid" \
  --broker-info "$broker_info" \
  --terminal-id ID-01 --terminal-id ID-02 --terminal-id ID-03 \
  --terminal-id ID-04 --terminal-id ID-05 --terminal-id ID-06 \
  --terminal-id ID-07 --terminal-id ID-08 --terminal-id ID-09 \
  --terminal-id ID-10 --terminal-id ID-11 --terminal-id ID-12 \
  --output "$run_root/before.json"
```

Start the footprint sampler and Animation Hitches trace against that exact PID,
then perform the physical matrix continuously until both collectors finish:

```sh
npm run native:resource -- \
  --label installed-optimized-physical \
  --workload terminal-history-sustained-12-surface-v1 \
  --root-pid "$app_pid" --include-info "$broker_info" \
  --samples 16 --interval-ms 60000 --max-p95-mib 512 \
  --output "$run_root/footprint.json" &
footprint_pid=$!

xcrun xctrace record --template "Animation Hitches" \
  --attach "$app_pid" --time-limit 905s \
  --output "$run_root/terminal-history.trace" &
trace_pid=$!

wait "$footprint_pid" "$trace_pid"
```

Capture `after.json` with the identical snapshot command and terminal-ID list.
Use its capture time as the attestation completion time; use the before capture
time as the start and record their actual elapsed seconds. Then extract and
analyze the two frame receipts:

```sh
npm run native:terminal-history-gate -- extract-cadence \
  --input "$run_root/installed-app.log" \
  --output "$run_root/cadence.json"

npm run native:frame-trace -- \
  --trace "$run_root/terminal-history.trace" \
  --label terminal-history-sustained-12-surface-v1 \
  --target-pid "$app_pid" --steady-start-s 0 --steady-end-s 900 \
  --output "$run_root/frame-trace.json"
```

Finally, seal the seven sources into the deterministic qualification receipt:

```sh
npm run native:terminal-history-gate -- finalize \
  --release "$run_root/release.json" \
  --footprint "$run_root/footprint.json" \
  --cadence "$run_root/cadence.json" \
  --frame-trace "$run_root/frame-trace.json" \
  --before "$run_root/before.json" --after "$run_root/after.json" \
  --interaction "$run_root/interaction.json" \
  --output "$run_root/qualification.json"
```

Finalization fails closed unless all seven SHA-256-sealed inputs agree on the
installed source/helper, app PID and start identity, broker PID and start
identity, twelve terminal IDs, every PTY PID, every stream epoch, monotonically
advancing offsets, the streaming terminal's positive progress, the complete
physical matrix, and all fixed performance limits. The final receipt contains
only bounded summaries and hashes; the source files remain the audit trail.
