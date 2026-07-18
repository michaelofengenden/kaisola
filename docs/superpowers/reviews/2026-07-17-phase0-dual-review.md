# Phase 0 dual review — Claude /code-review findings (2026-07-17)

Range: e7812d0..cb4c8d4. Finding [3] (spool RIS/DECSTR) already fixed in 0ec43a6.

## [0] electron/companion/gateway.cjs:141 — CONFIRMED (correctness)

**Summary:** mergeAcpProjection (and mergeLedgerProjection) feed unguarded provider/ledger strings into sanitizeProjection, whose throw escapes gateway.synchronize into #hello/receive and the queued-sync catch, permanently killing all companion connections (verified by repro: whitespace-only ACP session name throws 'sessions.N.title is empty'; two pending permissions with 8x16KB diffs throw 'projection exceeds the companion limit'). [same root cause also at: electron/companion/gateway.cjs:141]

**Failure scenario:** An ACP entry whose meta name is whitespace, a ledger task with a whitespace title, or >=2 pending permissions carrying large diffs (each within the per-field 16KB caps but jointly pushing the merged projection over MAX_PROJECTION_BYTES) makes sanitizeProjection throw inside gateway.synchronize. #hello then throws so a connecting device can never complete hello, and #queueSynchronization's catch closes every connected session with 'synchronization_failed' on each state change — the mobile companion is fully unusable until the permission resolves or the offending name changes, with no error surfaced on desktop.

## [1] electron/companion/desktopState.cjs:220 — CONFIRMED (correctness)

**Summary:** acpSessionEvent appends agent.permission.requested display payloads to the event log after only boundedClone (size check), and CompanionGatewaySession replays them verbatim to devices as event frames — bypassing the redaction that the snapshot path enforces (mergeAcpProjection drops absolute diff paths via safeRelativePath, slices diff text to 16KB, and sanitizeProjection's assertNoForbiddenKeys runs only on snapshots), even though gateway.cjs's own comment says 'absolute or unsafe paths never enter the projection'.

**Failure scenario:** With a companion device connected, an agent requests permission for a file edit: the acpSessionService displayPayload carries absolute local filesystem paths (OpenCode sends block.path absolute) and up to 40KB oldText/newText per diff; the device receives these unredacted in the live agent.permission.requested event while the snapshot for the same permission shows them removed and marked 'redacted' — leaking full workspace paths/diff bodies past the redaction boundary and giving the phone UI a permission card whose live-event and snapshot representations disagree.

## [2] electron/companion/gateway.cjs:278 — CONFIRMED (correctness)

**Summary:** A device that reconnects fully caught up (hello lastAck == currentSeq) gets an empty replay that never advances lastSentSeq from 0, so the next queued synchronize replays the entire retained event log to it (verified by repro: device acked seq 3, then received event seq 1, 2, 3 again). [same root cause also at: electron/companion/gateway.cjs:278]

**Failure scenario:** Phone reconnects while up to date; #sendSynchronization's replay branch only sets lastSentSeq inside the per-event loop, so an empty resume replay leaves it 0. The next state change (or the already-queued microtask sync) calls synchronize({afterSeq: 0}) and re-delivers up to 2048 retained events as fresh frames: agent.turn.delta duplicated into the mobile chat transcript, attention.raised re-notifying already-seen events, terminal.output re-applied — the companion UI shows duplicated agent text and stale re-raised alerts after every caught-up reconnect.

## [3] electron/ipc/terminalSpool.cjs:114 — CONFIRMED (correctness)

**Summary:** _trackModes only parses CSI ? h/l sequences and ignores full-terminal resets (RIS \x1bc, DECSTR \x1b[!p) that implicitly disable all tracked private DEC modes, so modePrefix replays modes that the terminal no longer has enabled.

**Failure scenario:** A TUI enables mouse tracking (\x1b[?1000h/?1003h) then crashes; the user runs `reset`, which emits RIS without individual ?1000l/?1003l sequences, and the live terminal correctly stops mouse reporting. The spool's decModes map still records the modes as enabled and persists them to meta, so on the next renderer remount (or app restart) snapshot.modePrefix rewrites \x1b[?1000h... into xterm — every subsequent click injects mouse escape sequences as garbage input into the shell prompt, exactly the class of corruption this paste fix was meant to prevent.

## [4] electron/ipc/attentionHandler.cjs:50 — CONFIRMED (correctness)

**Summary:** The dock badge no longer derives from live renderers' reported counts (cleared via forget() when a window's WebContents died) but from service.stats().active, which counts persisted attention records for all projects including windows that are closed or deleted, and active records are never expired by #trim (only cleared records age out).

**Failure scenario:** An agent finishes in project P (attention record raised, dock badge shows 1); the user closes or deletes that saved window without viewing the session. Old code cleared the badge on webContents destroy; new code keeps the record active forever — the AttentionService persists it to the db and reloads it on launch — so the macOS dock badge shows a stuck count that survives app restarts and cannot be cleared because no open window shows project P to acknowledge or observe the session (synchronizeProjections deliberately retains records for absent projects, and deleteSavedWindow never purges attention records).

## [5] electron/ipc/attentionHandler.cjs:181 — PLAUSIBLE (correctness)

**Summary:** attention:notify raises ACP permission notices into the attention service under source 'renderer-notice' (usually without a sessionId, since App.tsx derives it from req.key.split('::')[1] which is undefined for '@@'-format keys), duplicating the authoritative source:'permission' record that handleAcpEvent raises for the same permId — and only the latter is cleared on permission resolution. [same root cause also at: electron/ipc/attentionHandler.cjs:181]

**Failure scenario:** User is unfocused when an agent asks permission: handleAcpEvent raises a 'permission'/permId record and App.tsx's notifyAgent raises a second 'renderer-notice'/permId record with no sessionId, producing two active attention records (two macOS notifications, dock badge 2 for one request). When the user answers the card, agent.permission.resolved clears only the 'permission' source; the 'renderer-notice' record has no sessionId so visibility acknowledgement never matches it either — the dock badge and companion 'needs you' list keep showing a phantom permission for up to the 7-day retention unless the user clicks that exact stale notification.

## [6] electron/companion/gateway.cjs:453 — CONFIRMED (correctness)

**Summary:** agent.* command handlers build the ACP actor from the device's full granted capability list, but createAcpActorCapability only accepts 'observe'/'agent-control', so a device also granted 'terminal-control' makes acpActor throw instead of returning a receipt. [same root cause also at: electron/companion/gateway.cjs:453]

**Failure scenario:** Once a later phase enables control capabilities and a paired device is granted ['observe','agent-control','terminal-control'], every agent.prompt/agent.steer/agent.cancel/permission.respond from that device throws 'ACP actor capabilities are invalid.' inside the command handler; the rejection propagates out of commandRouter.route and session.receive as a transport-level error (connection error/close) rather than a 'rejected' command receipt, so the most-capable devices can never drive agents and get disconnected instead of an actionable error.

## [7] electron/companion/desktopState.cjs:217 — CONFIRMED (cleanup)

**Summary:** Every ACP turn delta is JSON-serialized ~5 times per event on the main thread (publishUpdate cloneJson+deepFreeze in acpSessionService.cjs:302-309, boundedClone here, then eventLog.append's payload clone, byte-accounting stringify, and return clone) and appended to the companion event log even when zero companion devices are connected.

**Failure scenario:** During normal agent streaming with no phone paired, main-process CPU per streamed update roughly doubles versus the old direct renderer send; sustained turns produce visible typing/render latency in the desktop UI for a pipeline with no consumer. Cheaper: gate setAcpSessionEventSink/the hub append on gateway.sessions.size > 0 (a late-connecting device already falls back to snapshot on cursor mismatch) and thread one encoded form through instead of repeated stringify/parse cycles.

## [8] electron/ipc/attentionService.cjs:853 — CONFIRMED (cleanup)

**Summary:** #persist synchronously JSON.stringifies the entire store (up to 512 records with 8KB detail/result fields plus 500 sessions) and writes it on every single raise/#clear/#upsertSession, including once per record inside loops like synchronizeProjections, acknowledgeVisibleSession, and #clearSourcePrefix.

**Failure scenario:** A burst that clears N attention records (e.g. focusing a window with many visible sessions) performs N full multi-hundred-KB serializations plus N dbMutate writes back-to-back on the Electron main thread, causing UI jank on every attention burst. Cheaper: coalesce with a dirty flag flushed once per microtask/timer.

## [9] electron/ipc/attentionService.cjs:616 — CONFIRMED (cleanup)

**Summary:** synchronizeProjections (invoked on every projection publish, removal, and snapshot) detects session changes by double-JSON.stringifying the full 500-entry sessions map, and its return value at line 622 computes a full boardState() (cloneJson per session plus several whole-record scans) that every production caller discards.

**Failure scenario:** Each renderer projection publish — a frequent event tied to store changes — pays two full serializations of up to 500 sessions plus a complete board projection that is thrown away (grep shows no production boardState caller besides this return). Cheaper: set a dirty flag while building nextSessions and make boardState lazy/on-demand.

---

# Codex adversarial review findings (2026-07-17, session 019f72c4)

Verdict: needs-attention. Seven findings beyond the Claude list; [C7] fixed in-repo.

## [C1] HIGH — desktopState.cjs:215-220: raw ACP updates bypass companion redaction
agent.turn.delta is only JSON-cloned before the replay log; loopback repro delivered environment.API_TOKEN, an absolute /Users path, and secret diff text verbatim to an observe client. Apply an allowlisted, bounded per-update-type sanitizer before logging or broadcasting; test live and replay delivery with secret-shaped payloads.

## [C2] HIGH — acpSessionService.cjs:176-183: approvals ignore completeness/persistent-option policy
providerDecision accepts raw allow or any advertised option regardless of actor surface or completeness; repro applied allow_always on a redacted request. For companion actors: reject always allowed; approval only when the stored revision is complete AND the option is allow_once; reject persistent option kinds; test every completeness × option combination.

## [C3] HIGH — gateway.cjs:500-503: terminal subscriptions feed a global duplicate replay stream
Subscription callbacks append terminal bytes to the shared state hub, which syncs to every session regardless of subscriptions; two-device repro showed a non-subscriber receiving output and double delivery under different seqs for dual subscribers. One authoritative upstream observer per terminal; filter delivery by session subscription (or per-session stream logs); record each byte range once; multi-device isolation + duplicate-cursor tests.

## [C4] HIGH — attentionHandler.cjs:151-165: attention actors minted from untrusted renderer project ids
attention:ack builds a project capability from the IPC payload without proving the sender's window owns the project; events broadcast to all windows leak the event ids needed to clear other projects' attention. Derive allowed projects from main-owned window/projection state; reject non-owned projects; scope event delivery.

## [C5] MEDIUM — gateway.cjs:328-346: connected companion is not an ACP subscriber
hasSubscriberFor does not count the gateway's event sink; with a destroyed renderer and a connected companion, a permission request auto-cancelled. Register project-scoped ACP subscriptions per negotiated companion session; remove on disconnect/revocation; test orphaned live entry + connected companion.

## [C6] MEDIUM — gateway.cjs:487-520: unsubscribe races subscription setup; observer cap unenforced
The observer is awaited before entering terminalSubscriptions; unsubscribe checks only that map, so a late subscription installs after a successful unsubscribe. Serialize per project/terminal key or use generation tokens; dispose late superseded handles; enforce the 8-observer cap in the broker authority.

## [C7] MEDIUM — terminalSpool.cjs:117-133: DEC carry window drops long split sequences — FIXED
Carry window widened to hold the longest tracked sequence with an every-split-position regression test.
