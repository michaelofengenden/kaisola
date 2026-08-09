'use strict'

const { after, test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const manager = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const { TerminalSpool } = require('../../runtime/node-broker/ipc/terminalSpool.cjs')
const { __test } = manager

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
  assert.equal(__test.resizeRecord(record, 80.5, 24), false)
  assert.equal(__test.resizeRecord(record, 80, Number.NaN), false)
  assert.equal(record.cols, 80)
  assert.equal(record.rows, 24)
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
