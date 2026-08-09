'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const {
  TerminalSpool,
  SPOOL_APPEND_DEBOUNCE_MS,
  readTail,
  readRange,
} = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

function fixture(t, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-'))
  const spool = new TerminalSpool({
    dir,
    id: 'terminal-spool-test',
    hotCap: 1024,
    queueCap: 1024 * 1024,
    ...options,
  })
  t.after(() => {
    spool.close()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  return spool
}

/** A file outside the spool that a local attacker would want the broker to
 * read from or write to. Its mode is asserted alongside its bytes because the
 * old append path chmod-ed its destination to 0600 by path. */
function bystander(t, contents) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-spool-bystander-'))
  const file = path.join(dir, 'private.txt')
  fs.writeFileSync(file, contents)
  fs.chmodSync(file, 0o644)
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return file
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

// Spool paths are a hash of the terminal id, so any local process can name
// them before the terminal exists. A link planted at one of them must never
// turn a spool read into "read that file" or a spool append into "overwrite
// that file" under broker authority.

test('a symlinked current segment is never read back as terminal output', (t) => {
  const id = 'terminal-spool-link-read'
  const spool = fixture(t, { id })
  const dir = path.dirname(spool.file)
  const bystanderFile = bystander(t, 'ANTHROPIC_API_KEY=sk-do-not-exfiltrate\n')
  fs.symlinkSync(bystanderFile, spool.file)

  assert.equal(spool.snapshot(4096).output, '')
  assert.equal(spool.historyPage(0, 4096).output, '')
  assert.equal(spool.historyPage(0, 4096).totalBytes, 0)
  assert.equal(spool.stats().diskBytes, 0)
  assert.equal(spool.retainedByteCount(), 0)
  assert.equal(TerminalSpool.coldTail(id, dir), null)
  assert.equal(readTail(spool.file, 4096), '')
  assert.equal(readRange(spool.file, 0, 4096).length, 0)
})

test('a symlinked current segment refuses the append instead of writing through it', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-link-append' })
  const bystanderFile = bystander(t, 'original-contents')
  fs.symlinkSync(bystanderFile, spool.file)

  spool.push('pty-output-that-must-not-land-there')
  spool.flush()

  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), 'original-contents')
  assert.equal(fs.statSync(bystanderFile).mode & 0o777, 0o644)
  assert.equal(fs.lstatSync(spool.file).isSymbolicLink(), true)
  assert.ok(spool.stats().diskError, 'a refused segment must surface as a disk error')
  // The refusal must not cost the user their live terminal: the bytes that
  // could not land stay in the bounded hot fallback.
  assert.equal(spool.snapshot(4096).output, 'pty-output-that-must-not-land-there')
})

test('a fifo planted at the segment path is refused instead of parking the broker', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-fifo' })
  execFileSync('/usr/bin/mkfifo', [spool.file])

  assert.equal(readTail(spool.file, 4096), '')
  spool.push('output-with-nowhere-safe-to-go')
  spool.flush()

  assert.ok(spool.stats().diskError, 'a non-regular segment must surface as a disk error')
  assert.equal(fs.lstatSync(spool.file).isFIFO(), true)
})

test('a segment owned by another uid is refused for both reads and appends', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-foreign-owner' })
  spool.push('bytes-written-while-we-owned-the-segment')
  spool.flush()
  assert.ok(spool.stats().diskBytes > 0)

  // Creating a file owned by another user needs root, so stand the check on
  // its head: make this process look like a different uid to everything that
  // consults process.getuid.
  const realGetuid = process.getuid
  process.getuid = () => realGetuid.call(process) + 1
  t.after(() => { process.getuid = realGetuid })

  assert.equal(spool.stats().diskBytes, 0)
  assert.equal(spool.snapshot(4096).output, '')
  assert.equal(readTail(spool.file, 4096), '')
  spool.push('append-under-a-foreign-owner')
  spool.flush()
  assert.equal(spool.stats().diskError, 'ESPOOLNOTOWNED')
})

test('rotation retires a planted previous-segment link without crediting its bytes', (t) => {
  const spool = fixture(t, {
    id: 'terminal-spool-link-rotate',
    diskCap: 64,
    retentionCap: 4096,
  })
  spool.push('seed')
  spool.flush()
  assert.equal(spool.startEpoch(), 4)

  const bystanderFile = bystander(t, 'x'.repeat(1024))
  fs.symlinkSync(bystanderFile, spool.prevFile)
  spool.push('a'.repeat(64))
  spool.flush()

  // Rotation ran: the current segment became the previous one and the planted
  // link is gone. Its target keeps its bytes, and its size never moved the
  // epoch boundary that history offsets are measured from.
  assert.equal(fs.existsSync(spool.file), false)
  assert.equal(fs.lstatSync(spool.prevFile).isFile(), true)
  assert.equal(fs.readFileSync(spool.prevFile, 'utf8'), `seed${'a'.repeat(64)}`)
  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), 'x'.repeat(1024))
  assert.equal(spool.epochStartOffset, 4)
  assert.equal(spool.truncated, false)
})

test('readMeta refuses a symlinked meta path instead of trusting its JSON', (t) => {
  const id = 'terminal-spool-link-meta-read'
  const spool = fixture(t, { id })
  const planted = bystander(t, JSON.stringify({
    v: 1,
    id,
    viewState: { rows: 1, cols: 1 },
    epochStartOffset: 999,
  }))
  fs.symlinkSync(planted, spool.metaFile)

  assert.equal(TerminalSpool.readMeta(id, path.dirname(spool.metaFile)), null)
})

test('persisting meta refuses a symlinked scratch path instead of writing through it', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-link-meta-write' })
  const bystanderFile = bystander(t, 'scratch-decoy')
  fs.symlinkSync(bystanderFile, `${spool.metaFile}.${process.pid}.tmp`)

  spool.persistMeta() // a cache failure is non-fatal and must stay non-fatal

  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), 'scratch-decoy')
  assert.equal(fs.statSync(bystanderFile).mode & 0o777, 0o644)
})

test('close({remove}) drops planted entries and leaves what they pointed at alone', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-link-delete' })
  const logBystander = bystander(t, 'log-decoy')
  const prevBystander = bystander(t, 'prev-decoy')
  const metaBystander = bystander(t, 'meta-decoy')
  fs.symlinkSync(logBystander, spool.file)
  fs.symlinkSync(prevBystander, spool.prevFile)
  fs.symlinkSync(metaBystander, spool.metaFile)

  spool.close({ remove: true })

  for (const file of [spool.file, spool.prevFile, spool.metaFile]) {
    assert.equal(fs.existsSync(file), false)
    assert.throws(() => fs.lstatSync(file), { code: 'ENOENT' })
  }
  assert.equal(fs.readFileSync(logBystander, 'utf8'), 'log-decoy')
  assert.equal(fs.readFileSync(prevBystander, 'utf8'), 'prev-decoy')
  assert.equal(fs.readFileSync(metaBystander, 'utf8'), 'meta-decoy')
})
