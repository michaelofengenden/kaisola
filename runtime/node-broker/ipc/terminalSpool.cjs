// Disk-backed terminal scrollback. Every byte is eagerly appended while a
// live/visible terminal keeps only an xterm-sized read tail in RAM; detaching
// drops that cache and the pty continues without a hidden renderer or a
// megabyte ring. The pty is NEVER stopped by this class.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const intEnv = (name, fallback, min, max) => {
  const n = Number(process.env[name])
  return Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n))) : fallback
}

// Explicit ACP terminal/output requests may set a retention cap. Interactive
// user terminals do not: their append-only log is the durable first-message
// truth surface, while snapshots and renderer scrollback stay independently
// bounded. The legacy env cap remains the default only for bounded rotation.
const DEFAULT_DISK_CAP = intEnv('KAISOLA_TERMINAL_DISK_MB', 64, 2, 512) * 1024 * 1024
const DEFAULT_HOT_CAP = intEnv('KAISOLA_TERMINAL_HOT_KB', 1024, 128, 4096) * 1024
// How much retained output one reattach/resubscribe returns.
//
// Deliberately independent of the hot cap. The hot cap bounds the RAM the
// broker holds live per terminal; this bounds a single read from the disk
// spool. They used to be the same constant, so reattaching to a terminal that
// had produced more than 1 MiB since you left returned a short tail, which the
// client treats as a stream discontinuity — resetting the terminal and wiping
// the user's scrollback. That is the "history disappears after switching tabs"
// half of the scrollback problem.
const DEFAULT_SNAPSHOT_CAP = intEnv('KAISOLA_TERMINAL_SNAPSHOT_KB', 4096, 256, 16_384) * 1024
const DEFAULT_QUEUE_CAP = intEnv('KAISOLA_TERMINAL_SPOOL_BATCH_KB', 256, 32, 1024) * 1024
const DEFAULT_COLD_TAIL_CAP = 512 * 1024
const SPOOL_APPEND_DEBOUNCE_MS = 750
// Meta is what a restart resurrects a terminal from — exit evidence, cursor
// epoch, DEC modes, view state — so a failed write cannot be dropped the way a
// missed cache write can: the next launch would resurrect a still-running
// terminal from stale state. A failure keeps the spool dirty and retries on a
// bounded backoff, and the last error stays readable through stats().
const META_RETRY_BASE_MS = 250
const META_RETRY_MAX_MS = 8000
const META_RETRY_ATTEMPTS = 6

function safeBase(id) {
  return crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 32)
}

// Private DEC modes that change how the terminal interprets INPUT (bracketed
// paste, cursor keys, mouse, focus) or renders the cursor. They are tracked
// out-of-band because snapshot output must remain an exact stream tail for
// observer byte cursors — and because the enabling sequence routinely scrolls
// past the bounded tail, which made reattached renderers paste multi-line text
// as line-by-line submits (?2004 lost).
const TRACKED_DEC_MODES = new Set([1, 25, 1000, 1002, 1003, 1004, 1006, 2004])
const DEC_MODE_DEFAULTS = { 25: true } // cursor visible; every other tracked mode defaults off
// Also match RIS (ESC c) and DECSTR (CSI ! p): `reset` after a crashed TUI
// emits these instead of individual DECRST sequences, and replaying stale
// mouse/paste enables into a remounted terminal corrupts every click.
const DEC_MODE_RE = /\x1b\[\?([0-9;]+)([hl])|\x1bc|\x1b\[!p/g
// The carry must hold the longest incomplete sequence we track (multi-param
// DECSET like ?1000;1002;1003;1004;1006;2004 is ~34 chars) — a window smaller
// than the sequence drops its ESC prefix and silently loses the modes.
const DEC_CARRY_MAX = 48
const DEC_CARRY_RE = /\x1b(?:\[(?:[?!][0-9;]{0,40})?)?$/

const { atomicJson } = require('./brokerWire.cjs')

// On-disk meta layout version. Readers treat an unknown version as "no prior
// state" (matching projectionStore's fail-closed-to-absent behavior) so the
// format can evolve — or be written by the future Swift runtime — without
// silently misreading a restructured viewState/decModes shape.
const META_VERSION = 1

/** Return at most `bytes` from the end without starting inside a multi-byte
 * UTF-8 code point. ACP explicitly requires character-boundary truncation. */
function utf8Tail(value, bytes) {
  const cap = Number.isFinite(Number(bytes)) ? Math.max(0, Math.floor(Number(bytes))) : 0
  if (cap === 0) return ''
  const buffer = Buffer.isBuffer(value) ? value : Buffer.from(String(value ?? ''), 'utf8')
  if (buffer.length <= cap) return buffer.toString('utf8')
  let start = buffer.length - cap
  while (start < buffer.length && (buffer[start] & 0xc0) === 0x80) start++
  return buffer.subarray(start).toString('utf8')
}

function readTail(file, bytes) {
  if (!bytes || !fs.existsSync(file)) return ''
  let fd
  try {
    const size = fs.statSync(file).size
    const cap = Math.max(0, Math.floor(Number(bytes) || 0))
    const take = Math.min(size, cap + 3)
    if (!take) return ''
    const b = Buffer.allocUnsafe(take)
    fd = fs.openSync(file, 'r')
    fs.readSync(fd, b, 0, take, size - take)
    return utf8Tail(b, cap)
  } catch {
    return ''
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

function readRange(file, start, length) {
  if (!length || !fs.existsSync(file)) return Buffer.alloc(0)
  let fd
  try {
    const size = fs.statSync(file).size
    const offset = Math.max(0, Math.min(size, Math.floor(Number(start) || 0)))
    const take = Math.max(0, Math.min(size - offset, Math.floor(Number(length) || 0)))
    if (!take) return Buffer.alloc(0)
    const buffer = Buffer.allocUnsafe(take)
    fd = fs.openSync(file, 'r')
    const read = fs.readSync(fd, buffer, 0, take, offset)
    return read === take ? buffer : buffer.subarray(0, read)
  } catch {
    return Buffer.alloc(0)
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

class TerminalSpool {
  static readMeta(id, dir) {
    const terminalId = String(id)
    const metaFile = path.join(dir, `${safeBase(terminalId)}.json`)
    try {
      const meta = JSON.parse(fs.readFileSync(metaFile, 'utf8'))
      if (!meta || meta.id !== terminalId || (meta.v != null && meta.v !== META_VERSION)) return null
      return meta
    } catch {
      return null
    }
  }

  static coldTail(id, dir, maxBytes = DEFAULT_COLD_TAIL_CAP) {
    const base = safeBase(id)
    const currentFile = path.join(dir, `${base}.log`)
    const prevFile = path.join(dir, `${base}.prev.log`)
    const segments = []
    for (const file of [prevFile, currentFile]) {
      try {
        const size = fs.statSync(file).size
        segments.push({ file, size })
      } catch { /* no retained segment */ }
    }
    if (!segments.length) return null

    const capValue = Number(maxBytes)
    const cap = Number.isFinite(capValue)
      ? Math.max(0, Math.floor(capValue))
      : DEFAULT_COLD_TAIL_CAP
    const totalBytes = segments.reduce((sum, segment) => sum + segment.size, 0)
    const current = readTail(currentFile, cap)
    const remaining = Math.max(0, cap - Buffer.byteLength(current))
    const previous = remaining ? readTail(prevFile, remaining) : ''
    return {
      text: previous + current,
      truncated: totalBytes > cap,
    }
  }

  constructor({ dir, id, diskCap = DEFAULT_DISK_CAP, hotCap = DEFAULT_HOT_CAP, queueCap = DEFAULT_QUEUE_CAP, retentionCap = null, fresh = false }) {
    this.id = String(id)
    this.diskCap = diskCap
    this.hotCap = hotCap
    this.queueCap = queueCap
    this.retentionCap = Number.isFinite(retentionCap) ? Math.max(0, Math.floor(retentionCap)) : null
    this.visible = true
    this.chunks = []
    this.chunksLen = 0
    this.queued = []
    this.queuedLen = 0
    this.appendTimer = null
    this.truncated = false
    this.viewState = null
    this.epochStartOffset = 0
    this.exitedAt = null
    this.exitStatus = null
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
    const base = safeBase(this.id)
    this.file = path.join(dir, `${base}.log`)
    this.prevFile = path.join(dir, `${base}.prev.log`)
    this.metaFile = path.join(dir, `${base}.json`)
    if (fresh) {
      for (const file of [this.file, this.prevFile, this.metaFile]) {
        try { fs.unlinkSync(file) } catch { /* absent or already unavailable */ }
      }
    }
    this.fallbackChunks = []
    this.fallbackLen = 0
    this.diskError = null
    this.metaError = null
    this.metaDirty = false
    this.metaRetryTimer = null
    this.metaRetries = 0
    this.decModes = new Map()
    this.decCarry = ''
    const meta = TerminalSpool.readMeta(this.id, dir)
    if (meta) {
      this.viewState = meta.viewState || null
      if (Number.isSafeInteger(meta.epochStartOffset) && meta.epochStartOffset >= 0) {
        this.epochStartOffset = meta.epochStartOffset
      }
      if (Number.isSafeInteger(meta.exitedAt) && meta.exitedAt >= 0) {
        this.exitedAt = meta.exitedAt
        this.exitStatus = meta.exitStatus ?? null
      }
      if (meta.decModes && typeof meta.decModes === 'object') {
        for (const [mode, set] of Object.entries(meta.decModes)) {
          const n = Number(mode)
          if (TRACKED_DEC_MODES.has(n)) this.decModes.set(n, !!set)
        }
      }
    }
  }

  _trackModes(data) {
    const text = this.decCarry + data
    DEC_MODE_RE.lastIndex = 0
    let m
    while ((m = DEC_MODE_RE.exec(text))) {
      if (m[1] == null) { // RIS or DECSTR — every private mode reverts to default
        this.decModes.clear()
        continue
      }
      const set = m[2] === 'h'
      for (const param of m[1].split(';')) {
        const mode = Number(param)
        if (TRACKED_DEC_MODES.has(mode)) this.decModes.set(mode, set)
      }
    }
    const carry = text.slice(-DEC_CARRY_MAX).match(DEC_CARRY_RE)
    this.decCarry = carry ? carry[0] : ''
  }

  _modePrefix() {
    let prefix = ''
    for (const mode of [...this.decModes.keys()].sort((a, b) => a - b)) {
      const set = this.decModes.get(mode)
      if (set === !!DEC_MODE_DEFAULTS[mode]) continue // default state: nothing to replay
      prefix += `\x1b[?${mode}${set ? 'h' : 'l'}`
    }
    return prefix
  }

  _queue(text) {
    if (!text) return
    if (this.retentionCap === 0) { this.truncated = true; return }
    this.queued.push(text)
    this.queuedLen += Buffer.byteLength(text)
    if (this.queuedLen >= this.queueCap) {
      this.flush()
    } else if (!this.appendTimer) {
      this.appendTimer = setTimeout(() => {
        this.appendTimer = null
        this.flush()
      }, SPOOL_APPEND_DEBOUNCE_MS)
      this.appendTimer.unref?.()
    }
  }

  _append(text) {
    if (!text) return
    if (this.retentionCap === 0) { this.truncated = true; return }
    const recovery = this.fallbackChunks.join('')
    const payload = recovery + text
    let appended = false
    try {
      fs.appendFileSync(this.file, payload, { mode: 0o600 })
      appended = true
      this.fallbackChunks = []
      this.fallbackLen = 0
      this.diskError = null
      try { fs.chmodSync(this.file, 0o600) } catch { /* noop */ }
      const size = fs.statSync(this.file).size
      // Interactive terminals are append-only until the user explicitly closes
      // the session. That is what makes terminal.history able to reach the
      // literal first byte. ACP-created capture terminals can request an
      // explicit retentionCap; only those use the bounded two-segment rotation.
      if (this.retentionCap != null && size > Math.max(1, Math.floor(this.diskCap / 2))) {
        const discarded = fs.existsSync(this.prevFile)
        let discardedBytes = 0
        if (discarded) try { discardedBytes = fs.statSync(this.prevFile).size } catch { /* unavailable */ }
        try { fs.unlinkSync(this.prevFile) } catch { /* first segment */ }
        if (discardedBytes) this.epochStartOffset = Math.max(0, this.epochStartOffset - discardedBytes)
        fs.renameSync(this.file, this.prevFile)
        if (discarded) this.truncated = true
      }
    } catch (err) {
      this.diskError = String((err && err.code) || (err && err.message) || err || 'disk-write-failed')
      this.truncated = true
      // Disk-full/permission errors must never crash Electron main. If append
      // did not land, retain a bounded hot tail so the live shell stays usable.
      if (!appended) this._retainFallback(text)
    }
  }

  _retainFallback(text) {
    if (!text) return
    this.fallbackChunks.push(text)
    this.fallbackLen += Buffer.byteLength(text)
    while (this.fallbackChunks.length > 1 && this.fallbackLen > this.hotCap) {
      const old = this.fallbackChunks.shift()
      this.fallbackLen -= Buffer.byteLength(old)
    }
  }

  _diskSegments(startOffset = 0) {
    const segments = []
    let skip = Math.max(0, Math.floor(Number(startOffset) || 0))
    for (const file of [this.prevFile, this.file]) {
      try {
        const size = fs.statSync(file).size
        const fileStart = Math.min(size, skip)
        skip -= fileStart
        if (size > fileStart) segments.push({ file, fileStart, length: size - fileStart })
      } catch { /* absent */ }
    }
    return segments
  }

  _diskTail(bytes, startOffset = 0) {
    const cap = Math.max(0, Math.floor(Number(bytes) || 0))
    if (!cap) return ''
    const segments = this._diskSegments(startOffset)
    const totalBytes = segments.reduce((sum, segment) => sum + segment.length, 0)
    // Read a few extra bytes so utf8Tail can move a boundary that lands in the
    // middle of a multi-byte scalar without returning less history than needed.
    const startByte = Math.max(0, totalBytes - cap - 3)
    const slices = []
    let segmentStart = 0
    for (const segment of segments) {
      const segmentEnd = segmentStart + segment.length
      const sliceStart = Math.max(startByte, segmentStart)
      if (segmentEnd > sliceStart) {
        const localStart = sliceStart - segmentStart
        slices.push(readRange(segment.file, segment.fileStart + localStart, segmentEnd - sliceStart))
      }
      segmentStart = segmentEnd
    }
    return utf8Tail(Buffer.concat(slices), cap)
  }

  flush() {
    if (this.appendTimer) {
      clearTimeout(this.appendTimer)
      this.appendTimer = null
    }
    if (!this.queuedLen) return
    const text = this.queued.join('')
    this.queued = []
    this.queuedLen = 0
    this._append(text)
  }

  push(data) {
    if (!data || this.closed) return
    this._trackModes(data) // input modes matter even when output is not retained
    if (this.retentionCap === 0) { this.truncated = true; return }
    // Every byte is queued exactly once regardless of renderer visibility.
    // `chunks` below is only a bounded read cache; its evictions are already
    // durable (or represented in the disk-failure fallback) and must never be
    // re-queued.
    this._queue(data)
    if (!this.visible) return
    this.chunks.push(data)
    this.chunksLen += Buffer.byteLength(data)
    while (this.chunks.length > 1 && this.chunksLen > this.hotCap) {
      const old = this.chunks.shift()
      this.chunksLen -= Buffer.byteLength(old)
    }
  }

  setVisible(visible, viewState) {
    this.visible = !!visible
    if (viewState && typeof viewState === 'object') this.viewState = viewState
    if (!this.visible) {
      this.chunks = []
      this.chunksLen = 0
      this.flush()
      this.persistMeta()
    }
  }

  /** Persist the resurrection metadata now. Every explicit caller (visibility,
   * exit, epoch, close) is writing newer state, so each one restarts the retry
   * budget rather than inheriting an exhausted one. */
  persistMeta() {
    this.metaRetries = 0
    this._clearMetaRetry()
    return this._writeMeta()
  }

  _writeMeta() {
    // A closed spool has nothing left to resurrect, and close({remove}) already
    // deleted the meta file: a late retry must not recreate it.
    if (this.closed) return false
    const exitEvidence = this.exitEvidence()
    try {
      atomicJson(this.metaFile, {
        v: META_VERSION,
        id: this.id,
        viewState: this.viewState,
        decModes: Object.fromEntries(this.decModes),
        epochStartOffset: this.epochStartOffset,
        ...(exitEvidence || {}),
        touchedAt: Date.now(),
      })
      this.metaDirty = false
      this.metaError = null
      this.metaRetries = 0
      return true
    } catch (err) {
      // Never fatal to the live shell, but never silent either: the state stays
      // dirty, the error stays readable, and the write is retried.
      this.metaDirty = true
      this.metaError = String((err && err.code) || (err && err.message) || err || 'meta-write-failed')
      this._scheduleMetaRetry()
      return false
    }
  }

  _scheduleMetaRetry() {
    if (this.metaRetryTimer || this.closed) return
    // Budget exhausted: stop spinning on a disk that is not coming back. The
    // spool stays dirty and the error stays visible until the next explicit
    // persistMeta, which is also the next state actually worth writing.
    if (this.metaRetries >= META_RETRY_ATTEMPTS) return
    const delay = Math.min(META_RETRY_MAX_MS, META_RETRY_BASE_MS * (2 ** this.metaRetries))
    this.metaRetries += 1
    this.metaRetryTimer = setTimeout(() => {
      this.metaRetryTimer = null
      this._writeMeta()
    }, delay)
    this.metaRetryTimer.unref?.()
  }

  _clearMetaRetry() {
    if (!this.metaRetryTimer) return
    clearTimeout(this.metaRetryTimer)
    this.metaRetryTimer = null
  }

  markExited(status) {
    if (this.closed) return null
    this.flush()
    this.exitedAt = Date.now()
    this.exitStatus = status ?? null
    this.persistMeta()
    return this.exitEvidence()
  }

  exitEvidence() {
    if (!Number.isSafeInteger(this.exitedAt) || this.exitedAt < 0) return null
    return { exitedAt: this.exitedAt, exitStatus: this.exitStatus }
  }

  retainedByteCount() {
    this.flush()
    let diskBytes = 0
    for (const file of [this.prevFile, this.file]) {
      try { diskBytes += fs.statSync(file).size } catch { /* absent */ }
    }
    return diskBytes + this.fallbackLen
  }

  startEpoch(offset = this.retainedByteCount()) {
    this.epochStartOffset = Math.max(0, Math.floor(Number(offset) || 0))
    this.persistMeta()
    return this.epochStartOffset
  }

  snapshot(outputCap = DEFAULT_HOT_CAP) {
    this.flush()
    const cap = Number.isFinite(Number(outputCap)) ? Math.max(0, Math.floor(Number(outputCap))) : DEFAULT_HOT_CAP
    const hot = this.chunks.join('')
    const hotBytes = Buffer.byteLength(hot)
    const fallback = this.fallbackChunks.join('')
    const fallbackBytes = Buffer.byteLength(fallback)
    // Eager append means the hot tail overlaps the end of the disk log. Use it
    // directly only when it can satisfy the whole read; otherwise read the
    // authoritative disk tail and append only disk-write fallback bytes.
    const output = !fallbackBytes && !this.diskError && hotBytes >= cap
      ? utf8Tail(hot, cap)
      : utf8Tail(this._diskTail(cap, this.epochStartOffset) + fallback, cap)
    let diskBytes = 0
    for (const file of [this.prevFile, this.file]) {
      try { diskBytes += fs.statSync(file).size } catch { /* absent */ }
    }
    const liveDiskBytes = Math.max(0, diskBytes - this.epochStartOffset)
    return { output, truncated: this.truncated || liveDiskBytes + fallbackBytes > cap, viewState: this.viewState, modePrefix: this._modePrefix() }
  }

  /** Return one bounded page ending `distanceFromEnd` bytes before the live
   * cursor. Offsets are relative to the complete retained spool (the complete
   * session for interactive terminals) and are
   * translated to absolute stream offsets by terminalManager. */
  historyPage(distanceFromEnd = 0, outputCap = DEFAULT_SNAPSHOT_CAP) {
    this.flush()
    const segments = this._diskSegments()
    // `chunks` is a cache of the already-appended disk suffix. Only fallback
    // bytes represent output not present in the disk segments.
    for (const value of [this.fallbackChunks.join('')]) {
      const buffer = Buffer.from(value, 'utf8')
      if (buffer.length > 0) segments.push({ buffer, length: buffer.length })
    }

    const totalBytes = segments.reduce((sum, segment) => sum + segment.length, 0)
    const distance = Math.max(0, Math.floor(Number(distanceFromEnd) || 0))
    const cap = Math.max(0, Math.floor(Number(outputCap) || 0))
    const endByte = Math.max(0, totalBytes - Math.min(totalBytes, distance))
    let startByte = Math.max(0, endByte - cap)
    const slices = []
    let segmentStart = 0
    for (const segment of segments) {
      const segmentEnd = segmentStart + segment.length
      const sliceStart = Math.max(startByte, segmentStart)
      const sliceEnd = Math.min(endByte, segmentEnd)
      if (sliceEnd > sliceStart) {
        const localStart = sliceStart - segmentStart
        const length = sliceEnd - sliceStart
        slices.push(segment.buffer
          ? segment.buffer.subarray(localStart, localStart + length)
          : readRange(segment.file, segment.fileStart + localStart, length))
      }
      segmentStart = segmentEnd
    }
    let output = Buffer.concat(slices)
    // Page boundaries may fall inside a multi-byte scalar. Move forward to the
    // first UTF-8 boundary; the skipped continuation bytes remain available in
    // the preceding page, so pages still concatenate exactly as valid text.
    let skipped = 0
    while (skipped < output.length && (output[skipped] & 0xc0) === 0x80) skipped++
    if (skipped) {
      output = output.subarray(skipped)
      startByte += skipped
    }
    return {
      output: output.toString('utf8'),
      startByte,
      endByte,
      totalBytes,
      hasMore: startByte > 0,
      truncated: this.truncated,
    }
  }

  stats() {
    let diskBytes = 0
    for (const file of [this.prevFile, this.file]) {
      try { diskBytes += fs.statSync(file).size } catch { /* absent */ }
    }
    return { id: this.id, visible: this.visible, ramBytes: this.chunksLen + this.queuedLen + this.fallbackLen, diskBytes, diskError: this.diskError, metaError: this.metaError, metaDirty: this.metaDirty, viewState: this.viewState }
  }

  close({ remove = false } = {}) {
    this.flush()
    this.persistMeta()
    // Late PTY output must not resurrect a closed spool: release() deletes
    // the files synchronously, but the kernel can still deliver buffered
    // onData afterwards through the pty handler's captured spool reference —
    // and a debounced append 750ms later would silently recreate the file
    // the user just asked to be wiped.
    this.closed = true
    if (this.appendTimer) {
      clearTimeout(this.appendTimer)
      this.appendTimer = null
    }
    this._clearMetaRetry()
    if (!remove) return
    try { fs.unlinkSync(this.file) } catch { /* absent */ }
    try { fs.unlinkSync(this.prevFile) } catch { /* absent */ }
    try { fs.unlinkSync(this.metaFile) } catch { /* absent */ }
  }
}

module.exports = {
  TerminalSpool,
  DEFAULT_DISK_CAP,
  DEFAULT_HOT_CAP,
  DEFAULT_SNAPSHOT_CAP,
  DEFAULT_QUEUE_CAP,
  DEFAULT_COLD_TAIL_CAP,
  SPOOL_APPEND_DEBOUNCE_MS,
  META_RETRY_BASE_MS,
  META_RETRY_MAX_MS,
  META_RETRY_ATTEMPTS,
  readTail,
  utf8Tail,
  readRange,
}
