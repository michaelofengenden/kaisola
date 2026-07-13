const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const fsp = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')

const { TerminalSpool } = require('./ipc/terminalSpool.cjs')
const { AcpProcessLedger } = require('./ipc/acpProcessLedger.cjs')
const { AssistantArchive, scopeKey } = require('./ipc/assistantArchive.cjs')
const { adapterPreset, claudePreset, codexPreset, freshenControls, _acpTest } = require('./ipc/acpHandler.cjs')

test('detached terminal moves scrollback and viewport to disk with zero hot output RAM', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-spool-test-'))
  try {
    const spool = new TerminalSpool({ dir, id: 'term-a', hotCap: 64 * 1024, diskCap: 2 * 1024 * 1024, queueCap: 8 * 1024 })
    const tail = 'final-visible-tail'
    spool.push('a'.repeat(200 * 1024))
    spool.push(tail)
    assert.ok(spool.stats().ramBytes <= 64 * 1024 + tail.length)
    spool.setVisible(false, { scrollFromBottom: 19, cols: 120, rows: 40 })
    const stats = spool.stats()
    assert.equal(stats.ramBytes, 0)
    assert.ok(stats.diskBytes >= 200 * 1024)
    assert.match(spool.snapshot().output, /final-visible-tail$/)

    const restored = new TerminalSpool({ dir, id: 'term-a', hotCap: 64 * 1024, diskCap: 2 * 1024 * 1024 })
    assert.deepEqual(restored.snapshot().viewState, { scrollFromBottom: 19, cols: 120, rows: 40 })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('terminal spool degrades to bounded RAM instead of throwing on disk failure', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-spool-fault-test-'))
  const spool = new TerminalSpool({ dir, id: 'term-fault', hotCap: 128 * 1024, queueCap: 8 * 1024 })
  const original = fs.appendFileSync
  try {
    fs.appendFileSync = () => { const err = new Error('disk full'); err.code = 'ENOSPC'; throw err }
    assert.doesNotThrow(() => {
      spool.setVisible(false)
      spool.push('survives-disk-full'.repeat(1024))
      spool.flush()
    })
    const stats = spool.stats()
    assert.equal(stats.diskError, 'ENOSPC')
    assert.ok(stats.ramBytes > 0 && stats.ramBytes <= 128 * 1024)
    assert.match(spool.snapshot().output, /survives-disk-full/)
  } finally {
    fs.appendFileSync = original
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('terminal output caps preserve zero and truncate only at UTF-8 boundaries', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-spool-utf8-test-'))
  try {
    const spool = new TerminalSpool({ dir, id: 'term-utf8' })
    spool.push('A😀B')
    spool.setVisible(false)
    const fourBytes = spool.snapshot(4)
    assert.equal(fourBytes.output, 'B')
    assert.equal(fourBytes.output.includes('\uFFFD'), false)
    assert.ok(Buffer.byteLength(fourBytes.output, 'utf8') <= 4)
    assert.equal(fourBytes.truncated, true)
    const zero = spool.snapshot(0)
    assert.equal(zero.output, '')
    assert.equal(zero.truncated, true)

    const discard = new TerminalSpool({ dir, id: 'term-zero-retention', retentionCap: 0 })
    discard.push('sensitive output must never land')
    discard.setVisible(false)
    const discardedStats = discard.stats()
    assert.equal(discardedStats.ramBytes, 0)
    assert.equal(discardedStats.diskBytes, 0)
    assert.deepEqual(discard.snapshot(0), { output: '', truncated: true, viewState: null })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('assistant archive preserves evicted turns in order and pages them without hydration', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-assistant-archive-test-'))
  const archive = new AssistantArchive(dir)
  const key = scopeKey({ projectId: 'project-a', threadId: 'thread-a' })
  try {
    const turns = Array.from({ length: 250 }, (_, i) => ({ kind: i % 2 ? 'assistant' : 'user', text: `turn-${i}`, at: i }))
    await archive.append(key, 'batch-1', turns.slice(0, 90))
    await archive.append(key, 'batch-2', turns.slice(90, 180))
    await archive.append(key, 'batch-3', turns.slice(180))

    const latest = await archive.page(key, undefined, 60)
    assert.equal(latest.ok, true)
    assert.equal(latest.total, 250)
    assert.equal(latest.before, 190)
    assert.equal(latest.hasMore, true)
    assert.equal(latest.turns.length, 60)
    assert.equal(latest.turns[0].text, 'turn-190')
    assert.equal(latest.turns.at(-1).text, 'turn-249')

    const older = await archive.page(key, latest.before, 100)
    assert.equal(older.before, 90)
    assert.equal(older.turns[0].text, 'turn-90')
    assert.equal(older.turns.at(-1).text, 'turn-189')

    const files = archive.files(key)
    if (process.platform !== 'win32') {
      assert.equal(fs.statSync(dir).mode & 0o777, 0o700)
      assert.equal(fs.statSync(files.log).mode & 0o777, 0o600)
    }
    // Simulate a crash after the fsynced log append but before metadata rename.
    // Reconciliation finds the orphan batch, and retrying its id is a no-op.
    fs.appendFileSync(files.log, JSON.stringify({ v: 2, batchId: 'crash-batch', turns: [{ kind: 'assistant', text: 'recovered-tail' }] }) + '\n')
    assert.equal((await archive.info(key)).total, 251)
    assert.equal((await archive.append(key, 'crash-batch', [{ kind: 'assistant', text: 'recovered-tail' }])).duplicate, true)
    assert.equal((await archive.page(key, undefined, 1)).turns[0].text, 'recovered-tail')

    fs.appendFileSync(files.log, '{"v":2,"batchId":"interrupted"')
    assert.equal((await archive.info(key)).total, 251)
    assert.equal(fs.readFileSync(files.log, 'utf8').endsWith('\n'), true)
    assert.equal((await archive.append(key, 'interrupted', [{ kind: 'user', text: 'retry-after-truncate' }])).count, 252)

    const tooMany = await archive.append(key, 'oversize-count', Array.from({ length: 101 }, () => ({ kind: 'user', text: 'x' })))
    assert.equal(tooMany.ok, false)

    const other = scopeKey({ projectId: 'project-b', threadId: 'thread-a' })
    await archive.append(other, 'other-1', [{ kind: 'user', text: 'isolated' }])
    assert.equal((await archive.info(other)).total, 1)
    assert.equal((await archive.info(key)).total, 252)

    // Byte accounting is per selected turn, not a batch-line average: two
    // neighboring large turns from heterogeneous batches must not cross the
    // compact 6 MiB main→renderer page bound.
    const boundedKey = scopeKey({ projectId: 'project-byte-bound', threadId: 'thread-byte-bound' })
    const large = 'x'.repeat(4 * 1024 * 1024)
    await archive.append(boundedKey, 'hetero-a', [...Array.from({ length: 99 }, () => ({ kind: 'user', text: 'x' })), { kind: 'assistant', text: large }])
    await archive.append(boundedKey, 'hetero-b', [{ kind: 'assistant', text: large }, ...Array.from({ length: 99 }, () => ({ kind: 'user', text: 'x' }))])
    const bounded = await archive.page(boundedKey, 101, 2)
    assert.equal(bounded.turns.length, 1)
    assert.ok(bounded.bytes <= 6 * 1024 * 1024)
    await archive.clear(boundedKey)

    const pressureKey = scopeKey({ projectId: 'project-pressure', threadId: 'thread-pressure' })
    const firstWrite = archive.append(pressureKey, 'pressure-a', [{ kind: 'user', text: 'first' }])
    const overlapping = await archive.append(pressureKey, 'pressure-b', [{ kind: 'user', text: 'second' }])
    assert.equal(overlapping.ok, false)
    assert.equal(overlapping.retryable, true)
    await firstWrite
    assert.equal(archive.pendingBytes, 0)
    await archive.clear(pressureKey)

    await archive.clear(key)
    assert.equal(fs.existsSync(files.log), false)
    assert.equal((await archive.page(key)).total, 0)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('assistant archive reports clear failures instead of exposing old history as reset', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-assistant-clear-test-'))
  const archive = new AssistantArchive(dir)
  const key = scopeKey({ projectId: 'project-clear', threadId: 'thread-clear' })
  const original = fsp.unlink
  try {
    await archive.append(key, 'batch-clear', [{ kind: 'user', text: 'keep-on-failure' }])
    fsp.unlink = async (file) => {
      if (String(file).endsWith('.jsonl')) {
        const error = new Error('permission denied')
        error.code = 'EACCES'
        throw error
      }
      return original(file)
    }
    await assert.rejects(archive.clear(key), /permission denied/)
    assert.equal(fs.existsSync(archive.files(key).log), true)
  } finally {
    fsp.unlink = original
    await archive.clear(key).catch(() => {})
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('ACP stale cleanup signals only the exact owner+instance+connection process group', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-ledger-test-'))
  try {
    const first = new AcpProcessLedger(dir, { scan: () => [], kill: () => {} })
    const token = first.newToken()
    first.recordSpawn({ token, pid: 401, pgid: 401, presetId: 'codex', command: '/safe/codex-acp' })
    const owner = first.ownerId
    const instance = first.instanceId
    const calls = []
    const exact = `codex-acp KAISOLA_ACP_OWNER=${owner} KAISOLA_ACP_INSTANCE=${instance} KAISOLA_ACP_CONNECTION=${token}`
    const second = new AcpProcessLedger(dir, {
      scan: () => [
        { pid: 401, pgid: 401, command: exact },
        { pid: 999, pgid: 999, command: 'codex-acp from Zed' },
        { pid: 998, pgid: 998, command: `codex-acp KAISOLA_ACP_OWNER=${owner} KAISOLA_ACP_INSTANCE=other KAISOLA_ACP_CONNECTION=${token}` },
      ],
      kill: (pid, signal) => calls.push({ pid, signal }),
    })
    assert.deepEqual(second.reclaimStale(), { matched: 1, signalled: 1 })
    assert.deepEqual(calls, [{ pid: -401, signal: 'SIGTERM' }])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('cached ACP adapters resolve directly without an npx wrapper', () => {
  const codex = adapterPreset({ id: 'codex', name: 'Codex', packageName: '@zed-industries/codex-acp', binName: 'codex-acp' })
  const claude = adapterPreset({ id: 'claude-code', name: 'Claude', packageName: '@zed-industries/claude-code-acp', binName: 'claude-code-acp' })
  // Legacy packages are optional cache fallbacks; CI may have no ~/.npm/_npx.
  if (codex.direct) assert.notEqual(codex.command, 'npx')
  if (claude.direct) assert.notEqual(claude.command, 'npx')
  const modern = codexPreset()
  assert.equal(modern.modern, true)
  assert.equal(modern.adapterVersion, '1.1.2')
  assert.ok(modern.env.CODEX_PATH)
  assert.doesNotMatch(modern.env.CODEX_PATH, /codex\.js$/)
  const modernClaude = claudePreset()
  assert.equal(modernClaude.modern, true)
  assert.equal(modernClaude.adapterVersion, '0.58.1')
  assert.notEqual(modernClaude.command, 'npx')
})

test('Codex effort labels preserve provider wire values and expose the modern Ultra value', () => {
  const controls = freshenControls('codex', {
    modes: null,
    configOptions: [{
      id: 'reasoning_effort', name: 'Reasoning effort', category: 'thought_level', currentValue: 'high',
      options: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].map((value) => ({ value, name: value })),
    }],
  })
  assert.deepEqual(controls.configOptions[0].options.map((o) => [o.value, o.name]), [
    ['low', 'Light'], ['medium', 'Medium'], ['high', 'High'], ['xhigh', 'Extra High'], ['ultra', 'Ultra'],
  ])

  const luna = freshenControls('codex', {
    modes: null,
    configOptions: [{ id: 'reasoning_effort', name: 'Reasoning effort', category: 'thought_level', currentValue: 'max', options: ['low', 'medium', 'high', 'xhigh', 'max'].map((value) => ({ value, name: value })) }],
  }, { modern: true })
  assert.deepEqual(luna.configOptions[0].options.at(-1), { value: 'max', name: 'Ultra', description: 'Maximum reasoning available for this model' })

  const retainedMax = freshenControls('codex', {
    modes: null,
    configOptions: [{ id: 'reasoning_effort', name: 'Reasoning effort', category: 'thought_level', currentValue: 'max', options: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].map((value) => ({ value, name: value })) }],
  }, { modern: true })
  assert.deepEqual(retainedMax.configOptions[0].options.map((option) => option.value), ['low', 'medium', 'high', 'xhigh', 'max'])
  assert.equal(retainedMax.configOptions[0].currentValue, 'max')
})

test('modern Codex live catalog is authoritative and legacy hardcoding cannot invent models', () => {
  const controls = freshenControls('codex', {
    modes: null,
    configOptions: [{ id: 'model', name: 'Model', category: 'model', currentValue: 'account-model', options: [{ value: 'account-model', name: 'Account model' }] }],
  }, { modern: true })
  assert.deepEqual(controls.configOptions[0].options.map((o) => o.value), ['account-model'])
})

test('idle ACP park gate refuses running, non-resumable, or unsaved sessions', () => {
  const base = { current: { channel: null }, inFlightTurns: 0, conn: { alive: true, canLoadSession: true }, meta: { sessionId: 'sess-1' } }
  assert.equal(_acpTest.canIdlePark(base), true)
  assert.equal(_acpTest.canIdlePark({ ...base, current: { channel: 'turn' } }), false)
  assert.equal(_acpTest.canIdlePark({ ...base, conn: { alive: true, canLoadSession: false } }), false)
  assert.equal(_acpTest.canIdlePark({ ...base, meta: {} }), false)
  assert.equal(_acpTest.canIdlePark({ ...base, inFlightTurns: 1 }), false)
  assert.equal(_acpTest.canIdlePark({ ...base, conn: { alive: true, canLoadSession: false, canResumeSession: true } }), true)
})

test('renderer-window glass swap is blocked during an active ACP turn', () => {
  const sender = { id: 701 }
  const key = '701|codex'
  _acpTest.connections.set(key, { sender, current: { channel: 'acp:update:req-1' }, inFlightTurns: 1 })
  try {
    assert.deepEqual(_acpTest.acpRendererSwapState(sender), { safe: false, busy: true, connecting: false, awaitingPermission: false })
    _acpTest.connections.get(key).current = { channel: null }
    _acpTest.connections.get(key).inFlightTurns = 0
    assert.deepEqual(_acpTest.acpRendererSwapState(sender), { safe: true, busy: false, connecting: false, awaitingPermission: false })
  } finally {
    _acpTest.connections.delete(key)
  }
})

test('process-wide ACP restart gate fails closed for connections, turns, and permissions', async () => {
  const sender = { id: 751 }
  const key = '751|codex'
  const entry = { sender, current: { channel: 'acp:update:req-restart' }, inFlightTurns: 1 }
  _acpTest.connections.set(key, entry)
  _acpTest.connectTasks.set('751|claude', { sender })
  _acpTest.pendingPermissions.set('perm-restart', { entry })
  try {
    const blocked = _acpTest.acpRestartSafetyState()
    assert.equal(blocked.safe, false)
    assert.equal(blocked.connectingCount, 1)
    assert.equal(blocked.inFlightTurns, 1)
    assert.equal(blocked.pendingPermissionCount, 1)
    assert.deepEqual(blocked.blockers, ['connecting', 'active-turns', 'permission'])

    const timeout = await _acpTest.waitForAcpRestartSafe({ timeoutMs: 0 })
    assert.equal(timeout.ok, false)
    assert.equal(timeout.timedOut, true)
    assert.equal(timeout.safe, false)

    _acpTest.connectTasks.delete('751|claude')
    _acpTest.pendingPermissions.delete('perm-restart')
    entry.current = { channel: null }
    entry.inFlightTurns = 0
    const safe = await _acpTest.waitForAcpRestartSafe({ timeoutMs: 0 })
    assert.equal(safe.ok, true)
    assert.equal(safe.safe, true)
  } finally {
    _acpTest.connections.delete(key)
    _acpTest.connectTasks.delete('751|claude')
    _acpTest.pendingPermissions.delete('perm-restart')
  }
})

test('cancelling an ACP entry immediately fails closed every pending permission', () => {
  const sent = []
  const sender = { isDestroyed: () => false, send: (channel, payload) => sent.push([channel, payload]) }
  const entry = { sender, current: { channel: null }, inFlightTurns: 1, autonomy: 'sprint', cancelRequested: false }
  const decisions = []
  const timer = setTimeout(() => {}, 60_000)
  timer.unref?.()
  _acpTest.pendingPermissions.set('perm-stop', { entry, timer, resolve: (decision) => decisions.push(decision) })
  try {
    assert.equal(_acpTest.beginEntryCancellation(entry), true)
    assert.deepEqual(decisions, ['cancel'])
    assert.equal(_acpTest.pendingPermissions.has('perm-stop'), false)
    assert.deepEqual(sent, [['acp:permission-resolved', { permId: 'perm-stop' }]])
    // A new provider permission arriving after Stop is still rejected, even
    // though Sprint would otherwise auto-allow it.
    assert.equal(_acpTest.immediatePermissionDecision(entry), 'cancel')
    entry.inFlightTurns = 0
    entry.cancelRequested = false
    assert.equal(_acpTest.immediatePermissionDecision(entry), 'allow')
  } finally {
    clearTimeout(timer)
    _acpTest.pendingPermissions.delete('perm-stop')
  }
})

test('ACP status remains busy until a cancelled provider turn actually settles', () => {
  const sender = { id: 799 }
  const key = '799|codex::thread-cancelled'
  const entry = {
    sender,
    meta: { key: 'codex::thread-cancelled', name: 'Codex', presetId: 'codex' },
    current: { sender: null, channel: null },
    inFlightTurns: 1,
    conn: { alive: true, authMethods: [], sessionMcpServers: () => [] },
  }
  _acpTest.connections.set(key, entry)
  try {
    assert.equal(_acpTest.agentSummary(sender)[0].busy, true)
    entry.inFlightTurns = 0
    assert.equal(_acpTest.agentSummary(sender)[0].busy, false)
  } finally {
    _acpTest.connections.delete(key)
  }
})

test('idle project-scoped ACP connection and lease move between renderers without restart', async () => {
  const from = { id: 801 }
  const to = { id: 802 }
  const scope = 'proj-transfer'
  const rendererKey = `codex::thread-1@@${scope}`
  const oldKey = `${from.id}|${rendererKey}`
  const newKey = `${to.id}|${rendererKey}`
  const entry = {
    sender: from,
    meta: { key: rendererKey, presetId: 'codex', scope, sessionId: 'sess-transfer' },
    current: { sender: null, channel: null },
    inFlightTurns: 0,
    conn: { alive: true, canLoadSession: true },
  }
  _acpTest.connections.set(oldKey, entry)
  _acpTest.connectionLeases.set(oldKey, new Set(['thread-1']))
  try {
    assert.deepEqual(_acpTest.acpProjectTransferState(from, scope), { safe: true, busy: false, connecting: false, awaitingPermission: false })
    const moved = await _acpTest.transferAcpProject(from, to, scope)
    assert.equal(moved.ok, true)
    assert.equal(moved.moved, 1)
    assert.equal(_acpTest.connections.has(oldKey), false)
    assert.equal(_acpTest.connections.get(newKey), entry)
    assert.equal(entry.sender, to)
    assert.deepEqual([..._acpTest.connectionLeases.get(newKey)], ['thread-1'])
    await moved.rollback()
    assert.equal(_acpTest.connections.get(oldKey), entry)
    assert.equal(_acpTest.connections.has(newKey), false)
    assert.equal(entry.sender, from)

    entry.current = { sender: from, channel: 'acp:update:busy' }
    entry.inFlightTurns = 1
    assert.deepEqual(_acpTest.acpProjectTransferState(from, scope), { safe: false, busy: true, connecting: false, awaitingPermission: false })
    assert.equal((await _acpTest.transferAcpProject(from, to, scope)).ok, false)
  } finally {
    _acpTest.connections.delete(oldKey)
    _acpTest.connections.delete(newKey)
    _acpTest.connectionLeases.delete(oldKey)
    _acpTest.connectionLeases.delete(newKey)
  }
})
