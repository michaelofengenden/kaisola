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
