'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  TerminalSpool,
  SPOOL_APPEND_DEBOUNCE_MS,
  META_RETRY_BASE_MS,
} = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

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

/** atomicJson stages the meta through `${metaFile}.${pid}.tmp`; a directory
 * parked on that path makes every write fail with EISDIR until it is removed,
 * which is the closest thing to a disk-full window a test can hold open. */
function blockMetaWrites(spool) {
  const tmp = `${spool.metaFile}.${process.pid}.tmp`
  fs.mkdirSync(tmp, { recursive: true })
  return () => fs.rmSync(tmp, { recursive: true, force: true })
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

test('a failed meta write stays dirty, reports the error, and retries onto disk', async (t) => {
  const id = 'terminal-spool-meta-retry'
  const spool = fixture(t, { id })
  spool.push('output before the disk went away')
  spool.flush()

  const unblock = blockMetaWrites(spool)
  spool.markExited({ exitCode: 3, signal: null })

  assert.equal(TerminalSpool.readMeta(id, path.dirname(spool.metaFile)), null)
  assert.equal(spool.metaDirty, true)
  assert.equal(spool.stats().metaDirty, true)
  assert.equal(spool.stats().metaError, 'EISDIR')

  unblock()
  await new Promise((resolve) => setTimeout(resolve, META_RETRY_BASE_MS + 400))

  const meta = TerminalSpool.readMeta(id, path.dirname(spool.metaFile))
  assert.ok(meta, 'the bounded retry must land the metadata once the disk recovers')
  assert.deepEqual(meta.exitStatus, { exitCode: 3, signal: null })
  assert.equal(spool.metaDirty, false)
  assert.equal(spool.stats().metaError, null)
})

test('a terminal restarted after an injected meta write failure resurrects its state', async (t) => {
  const id = 'terminal-spool-meta-retry-restart'
  const spool = fixture(t, { id })
  const dir = path.dirname(spool.metaFile)
  spool.push('\x1b[?2004h\x1b[?1000h') // bracketed paste + mouse reporting
  spool.setVisible(false, { scrollTop: 42 })

  const unblock = blockMetaWrites(spool)
  spool.markExited({ exitCode: 0, signal: null })
  assert.equal(spool.metaDirty, true)

  unblock()
  await new Promise((resolve) => setTimeout(resolve, META_RETRY_BASE_MS + 400))

  // Restart: a fresh spool over the same directory is what resurrection reads.
  const restarted = new TerminalSpool({ dir, id })
  t.after(() => restarted.close())
  assert.deepEqual(restarted.exitEvidence(), {
    exitedAt: spool.exitedAt,
    exitStatus: { exitCode: 0, signal: null },
  })
  assert.deepEqual(restarted.viewState, { scrollTop: 42 })
  assert.equal(restarted._modePrefix(), '\x1b[?1000h\x1b[?2004h')
})

test('close({remove}) cancels a pending meta retry instead of recreating the file', async (t) => {
  const id = 'terminal-spool-meta-retry-close'
  const spool = fixture(t, { id })
  const unblock = blockMetaWrites(spool)
  spool.markExited({ exitCode: 0, signal: null })
  assert.equal(spool.metaDirty, true)

  // The retry is still pending when the user wipes the session. Letting the
  // disk recover afterwards must not put the meta file back.
  spool.close({ remove: true })
  unblock()
  await new Promise((resolve) => setTimeout(resolve, META_RETRY_BASE_MS + 400))

  assert.equal(fs.existsSync(spool.metaFile), false)
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
