'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  TerminalSpool,
  SPOOL_APPEND_DEBOUNCE_MS,
  READ_ABSENT,
  READ_EMPTY,
  READ_FAILED,
  readTail,
  readRange,
} = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

/** Replace a spool segment with a path that stats like a file with bytes and
 * refuses every read (EISDIR). This reproduces a transient permission or media
 * failure without chmod, so the test behaves the same for a root runner. */
function breakSegmentReads(file) {
  fs.rmSync(file, { force: true })
  fs.mkdirSync(file)
}

function fixture(t, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-'))
  const spool = new TerminalSpool({
    dir,
    id: options.id || 'terminal-spool-test',
    hotCap: options.hotCap || 1024,
    queueCap: options.queueCap || 1024 * 1024,
  })
  t.after(() => {
    spool.close()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  return spool
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

test('a segment read separates absent, empty and failed instead of one empty string', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-read-status-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const absent = path.join(dir, 'never-written.log')
  const empty = path.join(dir, 'empty.log')
  const unreadable = path.join(dir, 'unreadable.log')
  fs.writeFileSync(empty, '', { mode: 0o600 })
  breakSegmentReads(unreadable)

  assert.deepEqual(readTail(absent, 64), { status: READ_ABSENT, text: '', error: null })
  assert.deepEqual(readTail(empty, 64), { status: READ_EMPTY, text: '', error: null })
  const failedTail = readTail(unreadable, 64)
  assert.equal(failedTail.status, READ_FAILED)
  assert.equal(failedTail.text, '')
  assert.equal(failedTail.error, 'EISDIR')

  assert.equal(readRange(absent, 0, 64).status, READ_ABSENT)
  assert.equal(readRange(empty, 0, 64).status, READ_EMPTY)
  const failedRange = readRange(unreadable, 0, 64)
  assert.equal(failedRange.status, READ_FAILED)
  assert.equal(failedRange.buffer.length, 0)
  assert.equal(failedRange.error, 'EISDIR')
})

test('a failed spool read is reported, not answered as an empty transcript', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-read-failure' })
  spool.push('retained-history')
  spool.flush()
  // Detaching drops the RAM read cache, so the disk spool is the only source
  // left — the state a reattach or a cold selection reads from.
  spool.setVisible(false)
  const healthy = spool.snapshot(1024)
  assert.equal(healthy.output, 'retained-history')
  assert.equal(healthy.readError, undefined)

  breakSegmentReads(spool.file)

  const snapshot = spool.snapshot(1024)
  assert.equal(snapshot.readError, 'EISDIR')
  assert.equal(snapshot.output, '')
  assert.equal(snapshot.truncated, true)

  const page = spool.historyPage(0, 1024)
  assert.equal(page.readError, 'EISDIR')
  assert.equal(page.output, '')
  assert.equal(page.truncated, true)
})

test('a terminal that produced nothing still reads as an authoritative empty spool', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-genuinely-empty' })
  spool.push('')
  spool.flush()
  fs.writeFileSync(spool.file, '', { mode: 0o600 })
  spool.setVisible(false)

  const snapshot = spool.snapshot(1024)
  assert.equal(snapshot.output, '')
  assert.equal(snapshot.truncated, false)
  assert.equal(snapshot.readError, undefined)
})

test('a failed read keeps the RAM tail the spool can still prove', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-read-failure-hot' })
  spool.push('retained-history')
  spool.flush()
  breakSegmentReads(spool.file)

  // The renderer is still attached, so the hot cache holds an exact suffix of
  // the stream. It is the most history the spool can honestly return.
  const snapshot = spool.snapshot(1024)
  assert.equal(snapshot.output, 'retained-history')
  assert.equal(snapshot.readError, 'EISDIR')
  assert.equal(snapshot.truncated, true)
})

test('coldTail separates a terminal with no spool from one it cannot read', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-cold-read-'))
  const spool = new TerminalSpool({ dir, id: 'cold-read-failure' })
  t.after(() => {
    spool.close()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  assert.equal(TerminalSpool.coldTail('cold-read-failure', dir, 1024), null)

  spool.push('cold-history')
  spool.flush()
  assert.deepEqual(TerminalSpool.coldTail('cold-read-failure', dir, 1024), {
    text: 'cold-history',
    truncated: false,
  })

  breakSegmentReads(spool.file)
  const cold = TerminalSpool.coldTail('cold-read-failure', dir, 1024)
  assert.equal(cold.readError, 'EISDIR')
  assert.equal(cold.text, '')
  assert.equal(cold.truncated, true)
})
