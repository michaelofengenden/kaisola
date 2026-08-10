'use strict'

const { after, test } = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const manager = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const { TerminalSpool } = require('../../runtime/node-broker/ipc/terminalSpool.cjs')
const { DEFAULT_OBSERVER_QUEUE_BYTES } = require('../../runtime/node-broker/ipc/terminalObservers.cjs')
const { TERMINAL_GEOMETRY_LIMITS } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
const { __test } = manager

const {
  maxCols: MAX_TERMINAL_COLS,
  maxRows: MAX_TERMINAL_ROWS,
} = TERMINAL_GEOMETRY_LIMITS

const managerSpoolDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-manager-'))
manager.configureStorage(managerSpoolDir)
after(() => {
  manager.killAll()
  fs.rmSync(managerSpoolDir, { recursive: true, force: true })
})

test('terminal resize commits geometry only after node-pty accepts it', () => {
  const calls = []
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: (cols, rows) => calls.push([cols, rows]) },
  }

  assert.equal(__test.resizeRecord(record, 132, 44), true)
  assert.deepEqual(calls, [[132, 44]])
  assert.equal(record.cols, 132)
  assert.equal(record.rows, 44)
})

test('terminal resize returns false and preserves geometry when node-pty throws', () => {
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: () => { throw new Error('pty exited during resize') } },
  }

  assert.equal(__test.resizeRecord(record, 20, 8), false)
  assert.equal(record.cols, 80)
  assert.equal(record.rows, 24)
})

test('terminal resize rejects invalid or fractional wire geometry', () => {
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: () => assert.fail('invalid geometry reached node-pty') },
  }

  assert.equal(__test.resizeRecord(record, 0, 24), false)
  assert.equal(__test.resizeRecord(record, -1, 24), false)
  assert.equal(__test.resizeRecord(record, 80.5, 24), false)
  assert.equal(__test.resizeRecord(record, '80', 24), false)
  assert.equal(__test.resizeRecord(record, 80, '24'), false)
  assert.equal(__test.resizeRecord(record, Number.POSITIVE_INFINITY, 24), false)
  assert.equal(__test.resizeRecord(record, 80, Number.NaN), false)
  assert.equal(record.cols, 80)
  assert.equal(record.rows, 24)
})

test('terminal resize applies the create validator maxima before node-pty', () => {
  const calls = []
  const record = {
    cols: 80,
    rows: 24,
    pty: { resize: (cols, rows) => calls.push([cols, rows]) },
  }

  assert.equal(__test.resizeRecord(record, MAX_TERMINAL_COLS, MAX_TERMINAL_ROWS), true)
  assert.equal(__test.resizeRecord(record, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER), true)
  assert.deepEqual(calls, [
    [MAX_TERMINAL_COLS, MAX_TERMINAL_ROWS],
    [MAX_TERMINAL_COLS, MAX_TERMINAL_ROWS],
  ])
  assert.equal(record.cols, MAX_TERMINAL_COLS)
  assert.equal(record.rows, MAX_TERMINAL_ROWS)
})

function spawnKillTestRecord(t, id) {
  const record = manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  })
  assert.ok(record)
  const pty = record.pty
  const acceptedKill = pty.kill.bind(pty)
  t.after(() => {
    record.exited = false
    record.pty = pty
    pty.kill = acceptedKill
    manager.release(id)
  })
  return { record, pty }
}

test('terminal kill reports node-pty refusal and leaves the registered terminal live', async (t) => {
  const id = 'kill-refusal-stays-live'
  const { record, pty } = spawnKillTestRecord(t, id)

  pty.kill = () => false
  assert.deepEqual(manager.kill(id), {
    id,
    ok: false,
    code: 'terminal_kill_failed',
    message: 'terminal signal failed',
  })
  assert.equal(manager.has(id), true)
  assert.equal(manager.isLive(id), true)

  pty.kill = () => { throw new Error('sensitive node-pty diagnostic') }
  assert.deepEqual(manager.kill(id), {
    id,
    ok: false,
    code: 'terminal_kill_failed',
    message: 'terminal signal failed',
  })
  assert.equal(manager.has(id), true)
  assert.equal(manager.isLive(id), true)

  // A retained record is only bookkeeping evidence. Prove the process itself
  // survived the refused signal by writing through the PTY and observing cat's
  // echo in the captured output.
  const livenessToken = 'kill-refusal-process-still-running'
  assert.deepEqual(manager.write(id, `${livenessToken}\n`), { ok: true })
  let output = ''
  for (let attempt = 0; attempt < 40 && !output.includes(livenessToken); attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50))
    output = manager.snapshot(id).output
  }
  assert.match(output, new RegExp(livenessToken))
})

test('terminal kill distinguishes a missing record from signaling refusal', () => {
  const id = 'missing-terminal-kill'
  assert.deepEqual(manager.kill(id), {
    id,
    ok: false,
    code: 'terminal_not_found',
    message: 'terminal is no longer available',
  })
})

test('terminal kill is idempotent after exit and never signals node-pty', (t) => {
  const id = 'kill-already-exited'
  const { record, pty } = spawnKillTestRecord(t, id)
  let killCalls = 0
  pty.kill = () => { killCalls += 1 }
  record.exited = true
  const alreadyExited = { id, ok: true, alreadyExited: true }
  assert.deepEqual(manager.kill(id), alreadyExited)
  assert.deepEqual(manager.kill(id), alreadyExited)
  assert.equal(killCalls, 0)
})

test('terminal kill fails closed when a live record has no pty', (t) => {
  const id = 'kill-live-without-pty'
  const { record } = spawnKillTestRecord(t, id)
  record.pty = null
  assert.deepEqual(manager.kill(id), {
    id,
    ok: false,
    code: 'terminal_kill_unavailable',
    message: 'terminal signal unavailable',
  })
})

test('terminal kill reports accepted signaling without claiming synchronous exit', (t) => {
  const id = 'kill-signal-accepted'
  const { record, pty } = spawnKillTestRecord(t, id)
  let killCalls = 0
  pty.kill = () => { killCalls += 1 }

  assert.deepEqual(manager.kill(id), { id, ok: true })
  assert.equal(killCalls, 1)
  assert.equal(record.exited, false)
})

test('terminal owner detach targets one terminal when an owner has several', (t) => {
  const owner = 'instance-shared|renderer-7|project-a'
  const sender = { id: owner, send: () => {}, isDestroyed: () => false }
  const firstID = 'detach-owner-first-terminal'
  const secondID = 'detach-owner-second-terminal'
  for (const id of [firstID, secondID]) {
    manager.spawn({
      id,
      command: '/bin/cat',
      args: [],
      cwd: managerSpoolDir,
      sender,
    })
  }
  t.after(() => {
    manager.release(firstID)
    manager.release(secondID)
  })

  assert.equal(manager.detachSender(owner), 0, 'an omitted terminal id must fail closed')
  assert.equal(manager.ownership(firstID).owner, owner)
  assert.equal(manager.ownership(secondID).owner, owner)
  assert.equal(manager.detachSender(owner, firstID), 1)
  assert.equal(manager.ownership(firstID).owner, '')
  assert.equal(manager.ownership(secondID).owner, owner)
})

test('socket-loss prefix detach remains explicitly broad across projects', async (t) => {
  const records = [
    ['detach-prefix-project-a', 'instance-shared|renderer-7|project-a'],
    ['detach-prefix-project-b', 'instance-shared|renderer-7|project-b'],
    ['detach-prefix-other-instance', 'instance-other|renderer-7|project-a'],
  ]
  manager.setEventSink(() => true)
  const exits = []
  for (const [id, owner] of records) {
    const record = manager.spawn({
      id,
      command: '/bin/cat',
      args: [],
      cwd: managerSpoolDir,
      sender: owner,
    })
    exits.push(new Promise((resolve) => record.pty.onExit(resolve)))
  }
  t.after(async () => {
    for (const [id] of records) manager.release(id)
    await Promise.allSettled(exits)
    manager.setEventSink(null)
  })

  assert.equal(manager.detachSenderPrefix('instance-shared|'), 2)
  assert.equal(manager.ownership(records[0][0]).owner, '')
  assert.equal(manager.ownership(records[1][0]).owner, '')
  assert.equal(manager.ownership(records[2][0]).owner, records[2][1])
})

test('primary output overflow stays bounded until an explicit snapshot reattach', async (t) => {
  const id = 'primary-output-backpressure'
  const owner = 'instance-primary|renderer-1|project-a'
  const frames = []
  let queuedBytes = DEFAULT_OBSERVER_QUEUE_BYTES - 32
  manager.setEventSink((sender, channel, payload, options = {}) => {
    // Other manager tests can still be receiving asynchronous native exit
    // callbacks. They have no authenticated owner and would not share this
    // client's broker socket in production.
    if (sender !== owner) return true
    const frameBytes = Buffer.byteLength(JSON.stringify({ channel, payload }))
    const limit = options.maxQueueBytes
    const accepted = options.force === true
      || (Number.isFinite(limit) && queuedBytes + frameBytes <= limit)
    frames.push({ sender, channel, payload, options, frameBytes, accepted })
    if (accepted) queuedBytes += frameBytes
    return accepted
  })
  const record = manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
    sender: owner,
  })
  const exited = new Promise((resolve) => record.pty.onExit(resolve))
  t.after(async () => {
    manager.release(id)
    await exited
    manager.setEventSink(null)
  })

  const overflow = 'overflow-primary-output'
  record.spool.push(overflow)
  record.cursor.append(overflow)
  record.pending = overflow
  record.flushPending()
  assert.equal(frames.length, 2)
  assert.equal(frames[0].channel, `terminal:data:${id}`)
  assert.equal(frames[0].options.maxQueueBytes, DEFAULT_OBSERVER_QUEUE_BYTES)
  assert.equal(frames[0].accepted, false)
  assert.equal(frames[1].channel, 'terminal:snapshot-required')
  assert.equal(frames[1].options.force, true)
  assert.deepEqual(frames[1].payload, {
    id,
    reason: 'slow_consumer',
    streamEpoch: record.cursor.streamEpoch,
    endOffset: record.cursor.nextOffset,
  })
  assert.ok(
    queuedBytes <= DEFAULT_OBSERVER_QUEUE_BYTES + frames[1].frameBytes,
    `queued ${queuedBytes} bytes past the one permitted reset marker`,
  )

  const saturatedFrameCount = frames.length
  const stressChunk = 'x'.repeat(64 * 1024)
  for (let index = 0; index < 10_000; index += 1) {
    record.pending = stressChunk
    record.flushPending()
  }
  assert.equal(record.pending, '')
  assert.equal(frames.length, saturatedFrameCount, 'paused output kept allocating socket frames')
  assert.equal(manager.isLive(id), true)

  assert.deepEqual(manager.write(id, 'still-running\n'), { ok: true })
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (manager.snapshot(id).output.includes('still-running')) break
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.match(manager.snapshot(id).output, /still-running/)
  record.flushPending()
  assert.equal(frames.length, saturatedFrameCount, 'spooled PTY output escaped while reset was required')

  // `terminal.attach` calls setSender and then returns a fresh snapshot. Only
  // that explicit reset is allowed to resume incremental delivery.
  queuedBytes = 0
  manager.setSender(id, owner)
  const recovery = manager.snapshot(id)
  assert.equal(recovery.streamEpoch, frames[1].payload.streamEpoch)
  assert.equal(recovery.endOffset >= frames[1].payload.endOffset, true)
  assert.match(recovery.output, /still-running/)
  record.pending = 'after-snapshot'
  record.flushPending()
  assert.equal(frames.length, saturatedFrameCount + 1)
  assert.equal(frames.at(-1).channel, `terminal:data:${id}`)
  assert.equal(frames.at(-1).payload, 'after-snapshot')
  assert.equal(frames.at(-1).accepted, true)
})

test('coldTail reads the bounded retained tail across previous and current segments', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-cold-tail-'))
  const spool = new TerminalSpool({ dir, id: 'cold-segments' })
  t.after(() => {
    spool.close()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  fs.writeFileSync(spool.prevFile, 'older-', { mode: 0o600 })
  fs.writeFileSync(spool.file, 'newer', { mode: 0o600 })

  assert.deepEqual(TerminalSpool.coldTail('cold-segments', dir, 8), {
    text: 'er-newer',
    truncated: true,
  })
  assert.equal(TerminalSpool.coldTail('absent-terminal', dir), null)
})

test('restore spawn reuses retained bytes and appends new output', async (t) => {
  const id = 'restore-after-broker-restart'
  const before = 'before-restart\n'
  const after = 'after-restart'
  const seeded = new TerminalSpool({ dir: managerSpoolDir, id, fresh: true })
  seeded.push(before)
  seeded.close()
  t.after(() => manager.release(id))

  const record = manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', `printf ${after}`],
    cwd: managerSpoolDir,
    restore: true,
  })

  const beforeBytes = Buffer.byteLength(before)
  assert.equal(record.cursor.nextOffset, beforeBytes)
  assert.equal(record.spool.epochStartOffset, beforeBytes)
  assert.equal(Object.hasOwn(record.spool, 'readStartBytes'), false)
  assert.deepEqual(manager.snapshot(id), {
    output: '',
    truncated: false,
    viewState: null,
    modePrefix: '',
    streamEpoch: record.cursor.streamEpoch,
    startOffset: beforeBytes,
    endOffset: beforeBytes,
    exited: false,
    exitStatus: null,
    agentBusy: false,
    agentTurnOpen: false,
    agentCompletionSignal: null,
    agentCompletedAt: null,
    agentRespondedAt: null,
  })
  await manager.waitForExit(id)
  const liveSnapshot = manager.snapshot(id)
  assert.equal(liveSnapshot.output, after)
  assert.equal(liveSnapshot.startOffset, beforeBytes)
  assert.equal(liveSnapshot.endOffset, beforeBytes + Buffer.byteLength(after))
  assert.doesNotMatch(liveSnapshot.output, /before-restart/)

  const history = manager.history(id, {
    streamEpoch: liveSnapshot.streamEpoch,
    beforeOffset: liveSnapshot.endOffset,
    maxBytes: 1024 * 1024,
  })
  assert.equal(history.ok, true)
  assert.equal(history.output, before + after)
  assert.equal(history.startOffset, 0)
  assert.equal(history.endOffset, liveSnapshot.endOffset)
  assert.equal(history.hasMore, false)
  assert.equal(TerminalSpool.readMeta(id, managerSpoolDir).epochStartOffset, beforeBytes)
  assert.deepEqual(TerminalSpool.coldTail(id, managerSpoolDir), {
    text: before + after,
    truncated: false,
  })
})

test('plain spawn wipes stale bytes instead of inheriting them', async (t) => {
  const id = 'plain-spawn-stays-fresh'
  const seeded = new TerminalSpool({ dir: managerSpoolDir, id, fresh: true })
  seeded.push('stale-output')
  seeded.close()
  t.after(() => manager.release(id))

  const record = manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'printf fresh-output'],
    cwd: managerSpoolDir,
  })

  await manager.waitForExit(id)
  record.spool.flush()
  assert.equal(record.cursor.nextOffset, Buffer.byteLength('fresh-output'))
  assert.equal(record.spool.epochStartOffset, 0)
  assert.equal(Object.hasOwn(record.spool, 'readStartBytes'), false)
  assert.deepEqual(TerminalSpool.coldTail(id, managerSpoolDir), {
    text: 'fresh-output',
    truncated: false,
  })
})

test('parseLsofCwd maps each process marker to its cwd name field', () => {
  assert.deepEqual(
    [...__test.parseLsofCwd([
      'p101',
      'fcwd',
      'n/Users/michael/First Project',
      'p202',
      'fcwd',
      'n/private/tmp/second',
      'pnot-a-pid',
      'n/ignored',
      '',
    ].join('\n'))],
    [
      [101, '/Users/michael/First Project'],
      [202, '/private/tmp/second'],
    ],
  )
})

test('cwd refresh batches live pids and fails soft without erasing last known cwd', () => {
  const records = [
    { id: 'one', exited: false, pty: { pid: 41 }, cwd: '/last/one' },
    { id: 'two', exited: false, pty: { pid: 42 }, cwd: '/last/two' },
    { id: 'done', exited: true, pty: { pid: 99 }, cwd: '/last/done' },
  ]
  const calls = []
  assert.equal(__test.refreshTerminalCwds(records, (...args) => {
    calls.push(args)
    return 'p41\nfcwd\nn/live/one\np42\nfcwd\nn/live/two\n'
  }), true)
  assert.equal(calls.length, 1)
  assert.equal(calls[0][0], '/usr/sbin/lsof')
  assert.deepEqual(calls[0][1], ['-a', '-p', '41,42', '-d', 'cwd', '-Fn'])
  assert.equal(records[0].cwd, '/live/one')
  assert.equal(records[1].cwd, '/live/two')
  assert.equal(records[2].cwd, '/last/done')

  assert.equal(__test.refreshTerminalCwds(records, () => {
    throw new Error('lsof unavailable')
  }), false)
  assert.equal(records[0].cwd, '/live/one')
  assert.equal(records[1].cwd, '/live/two')
})

test('live terminal inventory and diagnostics expose cwd', async (t) => {
  const id = 'terminal-inventory-cwd'
  const record = manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  })
  assert.ok(record)
  t.after(() => manager.release(id))

  const liveCwd = fs.realpathSync(managerSpoolDir)
  // The periodic cwd refresh is deliberately asynchronous — a slow lsof
  // must never stall the broker event loop — so poll briefly for the
  // background refresh triggered by list() to land on the record.
  let listed = null
  for (let attempt = 0; attempt < 40; attempt += 1) {
    listed = manager.list().find((row) => row.id === id)?.cwd
    if (listed === liveCwd) break
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  assert.equal(listed, liveCwd)
  assert.equal(manager.diagnostics().find((row) => row.id === id)?.cwd, liveCwd)
})

test('a natural pty exit stamps durable exit evidence', async (t) => {
  const id = 'natural-exit-evidence'
  t.after(() => manager.release(id))
  manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'exit 7'],
    cwd: managerSpoolDir,
  })

  const exitStatus = await manager.waitForExit(id)
  const meta = TerminalSpool.readMeta(id, managerSpoolDir)
  assert.ok(Number.isSafeInteger(meta.exitedAt))
  assert.equal(exitStatus.exitCode, 7)
  assert.deepEqual(meta.exitStatus, exitStatus)
})

test('release deletes the spool without recreating exit evidence', async () => {
  const id = 'released-terminal-has-no-exit-evidence'
  const record = manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  })
  const exited = new Promise((resolve) => record.pty.onExit(resolve))

  manager.release(id)
  await exited

  assert.equal(TerminalSpool.readMeta(id, managerSpoolDir), null)
  assert.equal(TerminalSpool.coldTail(id, managerSpoolDir), null)
})

test('killAll suppresses exit stamping during managed broker shutdown', async () => {
  const id = 'managed-shutdown-has-no-exit-evidence'
  const record = manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  })
  let markExitedCalls = 0
  const markExited = record.spool.markExited.bind(record.spool)
  record.spool.markExited = (status) => {
    markExitedCalls += 1
    return markExited(status)
  }
  const exited = new Promise((resolve) => record.pty.onExit(resolve))

  manager.killAll()
  await exited

  const meta = TerminalSpool.readMeta(id, managerSpoolDir)
  assert.equal(markExitedCalls, 0)
  assert.equal(meta.exitedAt, undefined)
  assert.equal(meta.exitStatus, undefined)
})

test('spool hot cache lives only while observed', async (t) => {
  const id = 'observer-driven-spool-cache'
  const record = manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'printf watched-bytes; sleep 5'],
    cwd: managerSpoolDir,
  })
  assert.ok(record)
  t.after(() => manager.release(id))

  manager.setEventSink(() => true)
  t.after(() => manager.setEventSink(null))
  const sub = manager.subscribe(id, 'window-a|observer', {})
  assert.equal(sub.ok, true)
  await new Promise((resolve) => setTimeout(resolve, 300))
  assert.ok(record.spool.visible, 'an observed spool caches')

  manager.unsubscribe(id, 'window-a|observer')
  assert.equal(record.spool.visible, false, 'last unsubscribe drops the cache')
  assert.equal(record.spool.chunksLen, 0)

  // Two observers across two fake connections: one leaving keeps the cache.
  manager.subscribe(id, 'window-a|observer', {})
  manager.subscribe(id, 'window-b|observer', {})
  manager.unsubscribeSubscriberPrefix('window-a|')
  assert.equal(record.spool.visible, true, 'a remaining observer keeps the cache')
  manager.unsubscribeSubscriberPrefix('window-b|')
  assert.equal(record.spool.visible, false)
})

test('the renderer exit channel carries the signal that killed the session', async (t) => {
  const id = 'signal-exit-keeps-its-cause'
  const events = []
  manager.setEventSink((sender, channel, payload) => {
    events.push({ sender, channel, payload })
    return true
  })
  t.after(() => {
    manager.setEventSink(null)
    manager.release(id)
  })
  manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'kill -TERM $$'],
    cwd: managerSpoolDir,
    sender: 'instance-a|1|project',
  })

  const exitStatus = await manager.waitForExit(id)
  // SIGTERM leaves exitCode 0, so the code alone reads as a clean exit.
  assert.deepEqual(exitStatus, { exitCode: 0, signal: 15 })
  assert.deepEqual(events.filter((event) => event.channel === `terminal:exit:${id}`), [{
    sender: 'instance-a|1|project',
    channel: `terminal:exit:${id}`,
    payload: { exitCode: 0, signal: 15 },
  }])
})

test('agent silence relaxes the busy indicator but never completes the turn', async (t) => {
  const id = 'agent-turn-silence-is-not-completion'
  const record = manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  })
  assert.ok(record)
  t.after(() => manager.release(id))

  t.mock.timers.enable({ apis: ['setTimeout'] })
  assert.equal(manager.agentTurn(id, true), true)
  assert.equal(record.agentBusy, true)
  assert.equal(record.agentTurnOpen, true)
  assert.equal(manager.rollingUpdateReadiness().safe, false)

  // Well past AGENT_QUIET_MS with the pty saying nothing at all.
  t.mock.timers.tick(30_000)

  // Degraded, not done: the indicator relaxes so the UI stops claiming live
  // work, and the record still reports an open, unconfirmed turn.
  assert.equal(record.agentBusy, false)
  assert.equal(record.agentTurnOpen, true)
  assert.equal(record.agentCompletionSignal, null)
  assert.ok(Number.isSafeInteger(record.agentQuietSince))
  assert.equal(manager.snapshot(id).agentCompletionSignal, null)

  const quiet = manager.rollingUpdateReadiness()
  assert.equal(quiet.safe, false, 'silence must not authorize a broker cutover')
  assert.deepEqual(quiet.busyTerminalIds, [id])
  assert.deepEqual(quiet.unconfirmedTurnIds, [id])
  assert.ok(manager.upgradeReadiness().busyTerminalIds.includes(id))

  // Only the explicit lifecycle signal closes the turn.
  assert.equal(manager.agentTurn(id, false), true)
  assert.equal(record.agentTurnOpen, false)
  assert.equal(record.agentCompletionSignal, 'agent-turn')
  const settled = manager.rollingUpdateReadiness()
  assert.equal(settled.safe, true)
  assert.deepEqual(settled.busyTerminalIds, [])
  assert.deepEqual(settled.unconfirmedTurnIds, [])
})

test('a pty exit completes an open agent turn as an explicit signal', async (t) => {
  const id = 'agent-turn-closed-by-exit'
  const record = manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'exit 0'],
    cwd: managerSpoolDir,
  })
  assert.ok(record)
  t.after(() => manager.release(id))

  assert.equal(manager.agentTurn(id, true), true)
  await manager.waitForExit(id)

  assert.equal(record.agentTurnOpen, false)
  assert.equal(record.agentCompletionSignal, 'terminal-exit')
  assert.equal(manager.rollingUpdateReadiness().safe, true)
})

test('a shell command-end mark completes an open agent turn', async (t) => {
  const id = 'agent-turn-closed-by-shell-mark'
  const record = manager.spawn({
    id,
    command: '/bin/sh',
    args: ['-c', 'printf "\\033]133;D;0\\007"; sleep 5'],
    cwd: managerSpoolDir,
  })
  assert.ok(record)
  t.after(() => manager.release(id))

  assert.equal(manager.agentTurn(id, true), true)
  for (let attempt = 0; attempt < 50 && record.agentTurnOpen; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20))
  }

  assert.equal(record.agentTurnOpen, false)
  assert.equal(record.agentCompletionSignal, 'shell-command-end')
  assert.equal(record.agentBusy, false)
})

test('a command-end mark split across two pty writes still counts', () => {
  const record = { agentMarkCarry: '' }
  assert.equal(__test.consumeCommandEndMark(record, 'building\r\n\u001b]13'), false)
  assert.equal(__test.consumeCommandEndMark(record, '3;D;0'), true)
  assert.equal(__test.consumeCommandEndMark(record, 'ordinary agent output'), false)
})

test('an unconfirmed turn keeps blocking retirement while a signalled one does not', () => {
  const quiet = __test.summarizeUpgradeReadiness([
    { id: 'quiet-agent', exited: false, agentBusy: false, agentTurnOpen: true },
  ], 0)
  assert.equal(quiet.busyAgentCount, 1)
  assert.deepEqual(quiet.busyTerminalIds, ['quiet-agent'])
  assert.equal(quiet.unconfirmedTurnCount, 1)
  assert.equal(quiet.safe, false)

  const signalled = __test.summarizeUpgradeReadiness([
    { id: 'quiet-agent', exited: false, agentBusy: false, agentTurnOpen: false },
  ], 0)
  assert.equal(signalled.busyAgentCount, 0)
  assert.equal(signalled.unconfirmedTurnCount, 0)
})

// --- signed spawn-helper staging -------------------------------------------
// The helper copied into private storage is the executable node-pty hands to
// posix_spawn, so anything pre-created on that path is treated as hostile.

function helperFixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-helper-root-'))
  t.after(() => fs.rmSync(base, { recursive: true, force: true }))
  const outside = path.join(base, 'attacker')
  fs.mkdirSync(outside, { mode: 0o700 })
  const source = path.join(base, 'signed-spawn-helper')
  fs.writeFileSync(source, 'signed-helper-bytes', { mode: 0o600 })
  return { base, outside, source, root: path.join(base, 'storage', '.native') }
}

test('helper staging rejects a symlinked root planted before launch', (t) => {
  const { outside, root } = helperFixture(t)
  fs.mkdirSync(path.dirname(root), { mode: 0o700 })
  fs.symlinkSync(outside, root)

  assert.throws(() => __test.prepareHelperDir(root, process.arch), /helper path component is a symlink/)
  assert.deepEqual(fs.readdirSync(outside), [], 'nothing is created outside private storage')
})

test('helper staging rejects a symlinked architecture directory', (t) => {
  const { outside, root } = helperFixture(t)
  fs.mkdirSync(root, { recursive: true, mode: 0o700 })
  fs.symlinkSync(outside, path.join(root, `darwin-${process.arch}`))

  assert.throws(() => __test.prepareHelperDir(root, process.arch), /helper path component is a symlink/)
  assert.deepEqual(fs.readdirSync(outside), [])
})

test('helper staging rejects a plain file planted at the root path', (t) => {
  const { root } = helperFixture(t)
  fs.mkdirSync(path.dirname(root), { mode: 0o700 })
  fs.writeFileSync(root, '', { mode: 0o600 })

  assert.throws(() => __test.prepareHelperDir(root, process.arch), /helper path component is not a directory/)
})

test('helper staging rejects an ancestor other users can write', (t) => {
  const { root } = helperFixture(t)
  const storage = path.dirname(root)
  fs.mkdirSync(storage, { mode: 0o700 })
  fs.chmodSync(storage, 0o777)

  assert.throws(() => __test.prepareHelperDir(root, process.arch), /helper path component is writable by other users/)
})

test('helper staging tightens a loose pre-created directory back to owner-only', (t) => {
  const { root } = helperFixture(t)
  fs.mkdirSync(root, { recursive: true, mode: 0o700 })
  fs.chmodSync(root, 0o777)

  const helperDir = __test.prepareHelperDir(root, process.arch)
  assert.equal(helperDir, path.join(fs.realpathSync(root), `darwin-${process.arch}`))
  assert.equal(fs.lstatSync(fs.realpathSync(root)).mode & 0o777, 0o700)
  assert.equal(fs.lstatSync(helperDir).mode & 0o777, 0o700)
})

test('helper install replaces a symlinked helper instead of writing through it', (t) => {
  const { outside, source, root } = helperFixture(t)
  const decoy = path.join(outside, 'target')
  fs.writeFileSync(decoy, 'untouched', { mode: 0o600 })
  const helperDir = __test.prepareHelperDir(root, process.arch)
  fs.symlinkSync(decoy, path.join(helperDir, 'spawn-helper'))

  const helper = __test.installSpawnHelper(source, helperDir)
  assert.equal(fs.readFileSync(decoy, 'utf8'), 'untouched', 'the symlink target is never written')
  assert.equal(fs.lstatSync(helper).isSymbolicLink(), false)
  assert.equal(fs.readFileSync(helper, 'utf8'), 'signed-helper-bytes')
  assert.equal(fs.lstatSync(helper).mode & 0o777, 0o700)
  assert.deepEqual(fs.readdirSync(helperDir), ['spawn-helper'], 'no temp file survives the install')
})

test('helper install refuses a symlink pre-planted at the temp path', (t) => {
  const { outside, source, root } = helperFixture(t)
  const decoy = path.join(outside, 'target')
  fs.writeFileSync(decoy, 'untouched', { mode: 0o600 })
  const helperDir = __test.prepareHelperDir(root, process.arch)
  // Pin the random suffix so the test can plant the exact entry an attacker
  // would otherwise have to guess, then watch exclusive creation refuse it.
  t.mock.method(crypto, 'randomBytes', () => Buffer.alloc(8, 0xab))
  fs.symlinkSync(decoy, path.join(helperDir, `spawn-helper.${process.pid}.${'ab'.repeat(8)}.tmp`))

  assert.throws(() => __test.installSpawnHelper(source, helperDir), /EEXIST/)
  assert.equal(fs.readFileSync(decoy, 'utf8'), 'untouched', 'the symlink target is never written')
  assert.equal(fs.existsSync(path.join(helperDir, 'spawn-helper')), false)
})

test('helper install creates its temp file exclusively', (t) => {
  const { source, root } = helperFixture(t)
  const helperDir = __test.prepareHelperDir(root, process.arch)
  const opened = []
  const openSync = fs.openSync
  t.mock.method(fs, 'openSync', (file, flags, mode) => {
    opened.push({ file, flags, mode })
    return openSync(file, flags, mode)
  })
  const copies = []
  t.mock.method(fs, 'copyFileSync', (from, to) => copies.push([from, to]))

  __test.installSpawnHelper(source, helperDir)

  const temp = opened.find((call) => call.file.endsWith('.tmp'))
  assert.ok(temp, 'the helper is staged through a temp file')
  assert.equal(temp.flags & fs.constants.O_EXCL, fs.constants.O_EXCL)
  assert.equal(temp.flags & fs.constants.O_CREAT, fs.constants.O_CREAT)
  assert.equal(temp.mode, 0o700)
  assert.deepEqual(copies, [], 'copyFileSync would follow a pre-planted symlink')
})

// Each of these awaits a promise that a broken cancel/cap/bound path would
// leave pending forever, so they carry an explicit timeout: the failure mode
// under test is a wait that never ends.
test('an exit wait is owned by its client and leaves when that client does', { timeout: 10_000 }, async (t) => {
  const id = 'exit-wait-follows-its-client'
  assert.ok(manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  }))
  t.after(() => manager.release(id))

  const gone = manager.waitForExit(id, { owner: 'window-a|3|kaisola' })
  const repeat = manager.waitForExit(id, { owner: 'window-a|3|kaisola' })
  const survivor = manager.waitForExit(id, { owner: 'window-b|3|kaisola' })
  assert.equal(repeat, gone, 'one client asking twice shares a single resolver')
  assert.equal(__test.exitWaiterCount(id), 2)

  assert.equal(manager.cancelExitWaitersPrefix('window-a|'), 1)
  assert.equal(__test.exitWaiterCount(id), 1, 'a departed client keeps no closure')
  await assert.rejects(gone, /terminal exit wait cancelled/)

  // Cancelling one client must not disturb the terminal or anyone else's wait.
  manager.kill(id)
  const status = await survivor
  assert.equal(Number.isInteger(status.exitCode), true)
  assert.equal(__test.exitWaiterCount(id), 0)
  assert.equal(manager.cancelExitWaiters(id, 'window-b|3|kaisola'), 0)
})

test('a terminal caps its exit waiters and answers every retained one on release', { timeout: 10_000 }, async (t) => {
  const id = 'exit-wait-cap'
  assert.ok(manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  }))
  t.after(() => manager.release(id))

  const waits = []
  for (let index = 0; index < __test.MAX_EXIT_WAITERS; index += 1) {
    waits.push(manager.waitForExit(id, { owner: `window-flood|${index}|kaisola` }))
  }
  assert.equal(__test.exitWaiterCount(id), __test.MAX_EXIT_WAITERS)

  await assert.rejects(
    manager.waitForExit(id, { owner: 'window-flood|overflow|kaisola' }),
    /too many terminal exit waiters/,
  )
  assert.equal(__test.exitWaiterCount(id), __test.MAX_EXIT_WAITERS, 'a refused wait adds nothing')

  // Release deletes the record, so its pty exit can never answer these: they
  // must fail now instead of staying pending for the broker's lifetime.
  manager.release(id)
  const settled = await Promise.allSettled(waits)
  assert.deepEqual(
    [...new Set(settled.map((result) => `${result.status}:${result.reason?.message ?? ''}`))],
    ['rejected:Terminal is no longer available.'],
  )
  assert.equal(__test.exitWaiterCount(id), 0)
})

test('an exit wait accepts a bound and drops itself when the bound expires', { timeout: 10_000 }, async (t) => {
  const id = 'exit-wait-bound'
  assert.ok(manager.spawn({
    id,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  }))
  t.after(() => manager.release(id))

  await assert.rejects(
    manager.waitForExit(id, { owner: 'window-c|3|kaisola', timeoutMs: 25 }),
    /terminal exit wait timed out/,
  )
  assert.equal(__test.exitWaiterCount(id), 0, 'an expired wait leaves nothing behind')
  assert.equal(manager.diagnostics().find((row) => row.id === id)?.exitWaiterCount, 0)
})
