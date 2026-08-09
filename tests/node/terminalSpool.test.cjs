'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  TerminalSpool,
  SPOOL_APPEND_DEBOUNCE_MS,
} = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

// Three UTF-8 bytes each, so a cap of 10 lands inside a scalar and the tail has
// to move forward to the next character boundary.
const SNOWMAN = '☃'

function fixture(t, options = {}) {
  const dir = options.dir || fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-'))
  const spool = new TerminalSpool({
    dir,
    id: options.id || 'terminal-spool-test',
    hotCap: options.hotCap || 1024,
    queueCap: options.queueCap || 1024 * 1024,
    ...(options.historyQuota === undefined ? {} : { historyQuota: options.historyQuota }),
    ...(options.totalHistoryQuota === undefined ? {} : { totalHistoryQuota: options.totalHistoryQuota }),
    ...(options.onQuota ? { onQuota: options.onQuota } : {}),
  })
  t.after(() => {
    spool.close()
    if (!options.dir) fs.rmSync(dir, { recursive: true, force: true })
  })
  return spool
}

/** Push `bytes` of interactive output through the same eager-append path the
 * pty uses, flushing each chunk so the quota sees a realistic segment size. */
function pushBytes(spool, bytes, chunkSize = 1024) {
  for (let written = 0; written < bytes; written += chunkSize) {
    spool.push('x'.repeat(Math.min(chunkSize, bytes - written)))
    spool.flush()
  }
}

test('visible output reaches the durable spool on the eager append debounce', async (t) => {
  const spool = fixture(t)
  spool.push('visible-before-restart')

  await new Promise((resolve) => setTimeout(resolve, SPOOL_APPEND_DEBOUNCE_MS + 350))

  assert.equal(fs.readFileSync(spool.file, 'utf8'), 'visible-before-restart')
})

test('evicting the durable hot tail never queues bytes a second time', (t) => {
  const spool = fixture(t, { hotCap: 4 })
  const chunks = ['alpha', '-', 'beta', '-', 'gamma']

  for (const chunk of chunks) spool.push(chunk)
  spool.flush()

  assert.equal(fs.readFileSync(spool.file, 'utf8'), chunks.join(''))
  assert.equal(spool.snapshot(1024).output, chunks.join(''))
})

test('a lone oversized chunk is trimmed to the hot cap on a character boundary', (t) => {
  const spool = fixture(t, { hotCap: 10 })

  spool.push(SNOWMAN.repeat(8)) // 24 bytes in a single write
  spool.flush()

  const retained = spool.chunks.join('')
  assert.equal(retained, SNOWMAN.repeat(3)) // 9 bytes: the 10th would split a scalar
  assert.equal(spool.stats().ramBytes, 9)
  assert.ok(!retained.includes('\uFFFD'))
  assert.equal(fs.readFileSync(spool.file, 'utf8'), SNOWMAN.repeat(8)) // durable copy is whole
})

test('a lone oversized chunk is trimmed in the disk-failure fallback too', (t) => {
  const spool = fixture(t, { hotCap: 10 })
  // A directory where the log belongs makes every append fail, which is the
  // path that retains a hot tail in RAM instead of on disk.
  fs.mkdirSync(spool.file)
  spool.setVisible(false) // isolate the fallback from the visible read cache

  spool.push(SNOWMAN.repeat(8))
  spool.flush()

  const retained = spool.fallbackChunks.join('')
  assert.ok(spool.diskError)
  assert.equal(retained, SNOWMAN.repeat(3))
  assert.equal(spool.fallbackLen, 9)
  assert.ok(!retained.includes('\uFFFD'))
})

test('a hot cap smaller than the trailing scalar retains nothing', (t) => {
  const spool = fixture(t, { hotCap: 1 })

  spool.push(SNOWMAN)
  spool.flush()

  assert.deepEqual(spool.chunks, [])
  assert.equal(spool.stats().ramBytes, 0)
})

test('late pty output after close({remove}) cannot resurrect the deleted spool file', async (t) => {
  const spool = fixture(t)
  spool.push('before-close')
  spool.close({ remove: true })
  assert.equal(fs.existsSync(spool.file), false)

  // The kernel can deliver buffered onData after release() already deleted
  // the spool; the debounced append must not recreate the file.
  spool.push('buffered-after-close')
  spool.flush()
  await new Promise((resolve) => setTimeout(resolve, SPOOL_APPEND_DEBOUNCE_MS + 350))
  assert.equal(fs.existsSync(spool.file), false)
})

test('exit evidence and the epoch boundary survive a fresh meta read', (t) => {
  const id = 'terminal-spool-exit-evidence'
  const spool = fixture(t, { id })
  spool.push('completed output')
  spool.markExited({ exitCode: 0, signal: null })

  const meta = TerminalSpool.readMeta(id, path.dirname(spool.file))
  assert.ok(Number.isSafeInteger(meta.exitedAt))
  assert.deepEqual(meta.exitStatus, { exitCode: 0, signal: null })
  assert.equal(meta.epochStartOffset, 0)
  assert.deepEqual(spool.exitEvidence(), {
    exitedAt: meta.exitedAt,
    exitStatus: { exitCode: 0, signal: null },
  })
})

test('a spool without a natural-exit stamp has no exit evidence', (t) => {
  const id = 'terminal-spool-no-exit-evidence'
  const spool = fixture(t, { id })
  spool.persistMeta()

  const meta = TerminalSpool.readMeta(id, path.dirname(spool.file))
  assert.equal(meta.exitedAt, undefined)
  assert.equal(meta.exitStatus, undefined)
  assert.equal(meta.epochStartOffset, 0)
  assert.equal(spool.exitEvidence(), null)
})

test('an interactive terminal stops at its history quota instead of growing without bound', (t) => {
  const quota = 8 * 1024
  const spool = fixture(t, { id: 'terminal-spool-history-quota', historyQuota: quota })

  pushBytes(spool, 64 * 1024)

  // Two bounded segments, each retired a little past quota/2, so the ceiling is
  // the quota plus at most one in-flight chunk per segment.
  assert.ok(
    spool.retainedByteCount() <= quota + 4 * 1024,
    `retained ${spool.retainedByteCount()} bytes for an ${quota}-byte quota`,
  )
  assert.equal(spool.truncated, true)
  assert.ok(spool.truncationEvidence().evictedBytes > 0)
})

test('an explicitly unbounded spool keeps the append-only contract', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-unbounded', historyQuota: null })

  pushBytes(spool, 64 * 1024)

  assert.equal(spool.retainedByteCount(), 64 * 1024)
  assert.equal(spool.truncated, false)
  assert.equal(spool.truncationEvidence(), null)
})

test('the history quota warns before it evicts and keeps the provenance after', (t) => {
  const id = 'terminal-spool-quota-provenance'
  const events = []
  const quota = 8 * 1024
  const spool = fixture(t, { id, historyQuota: quota, onQuota: (event) => events.push(event) })

  pushBytes(spool, 64 * 1024)

  const firstWarning = events.findIndex((event) => event.phase === 'warning')
  const firstEviction = events.findIndex((event) => event.phase === 'evicted')
  assert.ok(firstWarning >= 0, 'no quota warning was emitted')
  assert.ok(firstEviction >= 0, 'no eviction was reported')
  assert.ok(firstWarning < firstEviction, 'the warning must precede the first eviction')
  assert.equal(events[firstWarning].scope, 'terminal')
  assert.equal(events[firstWarning].quotaBytes, quota)
  assert.ok(events[firstEviction].evictedBytes > 0)

  const evidence = spool.truncationEvidence()
  assert.equal(evidence.reason, 'terminal-quota')
  assert.ok(evidence.evictions > 0)
  assert.ok(Number.isSafeInteger(evidence.firstAt))
  assert.deepEqual(spool.snapshot(1024).truncation, evidence)
  assert.deepEqual(spool.historyPage(0, 1024).truncation, evidence)

  // Provenance is durable: a terminal reopened after a broker restart still
  // reports the history its quota dropped.
  const meta = TerminalSpool.readMeta(id, path.dirname(spool.file))
  assert.deepEqual(meta.truncation, evidence)
  const reopened = new TerminalSpool({ dir: path.dirname(spool.file), id, historyQuota: quota })
  t.after(() => reopened.close())
  assert.equal(reopened.truncated, true)
  assert.deepEqual(reopened.truncationEvidence(), evidence)
})

test('a capture terminal keeps its retentionCap rotation and stays off the quota warning', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-capture-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const events = []
  const spool = new TerminalSpool({
    dir,
    id: 'terminal-spool-capture',
    diskCap: 4 * 1024,
    retentionCap: 4 * 1024,
    historyQuota: 64 * 1024,
    onQuota: (event) => events.push(event),
  })
  t.after(() => spool.close())

  pushBytes(spool, 32 * 1024)

  // The explicit cap still wins over the far larger interactive quota…
  assert.ok(spool.retainedByteCount() <= 8 * 1024, `retained ${spool.retainedByteCount()} bytes`)
  assert.equal(spool.truncated, true)
  assert.equal(spool.truncationEvidence().reason, 'retention-cap')
  // …and rotating inside a cap the caller asked for is not a quota event.
  assert.deepEqual(events, [])
})

test('a quota rotation after restore keeps the epoch boundary on the same byte', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-epoch-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const id = 'terminal-spool-epoch-under-quota'
  const quota = 8 * 1024

  const before = new TerminalSpool({ dir, id, historyQuota: quota })
  pushBytes(before, 2 * 1024)
  before.close()

  const restored = new TerminalSpool({ dir, id, historyQuota: quota })
  t.after(() => restored.close())
  restored.startEpoch()
  assert.equal(restored.epochStartOffset, 2 * 1024)
  assert.equal(restored.snapshot(4 * 1024).output, '', 'a restored terminal replays no pre-restart bytes')

  // Rotating without evicting anything leaves the boundary exactly where it was.
  restored.push('N'.repeat(3 * 1024))
  restored.flush()
  assert.equal(restored.epochStartOffset, 2 * 1024)
  assert.equal(restored.snapshot(8 * 1024).output, 'N'.repeat(3 * 1024))

  // The rotation that does evict retires the last pre-restart bytes with it, so
  // the boundary walks back by exactly what stopped being retained rather than
  // pointing into the middle of this session's output.
  restored.push('M'.repeat(5 * 1024))
  restored.flush()
  assert.equal(restored.epochStartOffset, 0)
  assert.equal(restored.snapshot(16 * 1024).output, 'M'.repeat(5 * 1024))
})

test('the directory quota reclaims segments a closed terminal left behind', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-total-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const totalHistoryQuota = 20 * 1024

  // Seed the retained segments directly: this pins the directory sweep on its
  // own, independent of whether the per-terminal quota happened to rotate.
  const closed = new TerminalSpool({ dir, id: 'closed-terminal', totalHistoryQuota })
  fs.writeFileSync(closed.prevFile, 'o'.repeat(9 * 1024), { mode: 0o600 })
  fs.writeFileSync(closed.file, 'o'.repeat(3 * 1024), { mode: 0o600 })
  closed.close()
  // Nothing else in the broker ever deletes a retained-but-closed spool, and a
  // same-millisecond mtime would make the sweep order ambiguous.
  const aged = new Date(Date.now() - 60_000)
  for (const file of [closed.prevFile, closed.file]) {
    fs.utimesSync(file, aged, aged)
  }

  const events = []
  const live = fixture(t, {
    dir,
    id: 'live-terminal',
    historyQuota: 16 * 1024,
    totalHistoryQuota,
    onQuota: (event) => events.push(event),
  })
  pushBytes(live, 48 * 1024)

  assert.equal(fs.existsSync(closed.prevFile), false, 'the orphan segment survived the directory quota')
  assert.equal(fs.existsSync(live.file), true, 'a live terminal must keep the tail it is writing')
  const directoryEviction = events.find((event) => event.scope === 'directory' && event.phase === 'evicted')
  assert.ok(directoryEviction, 'no directory eviction was reported')
  assert.equal(directoryEviction.id, 'closed-terminal')

  // The closed terminal can still be restored, and it still knows what it lost.
  const orphanMeta = TerminalSpool.readMeta('closed-terminal', dir)
  assert.equal(orphanMeta.truncation.reason, 'directory-quota')
  assert.ok(orphanMeta.truncation.evictedBytes > 0)
})
