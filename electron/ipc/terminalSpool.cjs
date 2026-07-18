// Disk-backed terminal scrollback. A live/visible terminal keeps only the hot
// xterm-sized tail in RAM; once its renderer detaches, every byte is flushed to
// this spool and the pty continues without a hidden renderer or a megabyte ring.
// The pty is NEVER stopped by this class.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const intEnv = (name, fallback, min, max) => {
  const n = Number(process.env[name])
  return Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n))) : fallback
}

const DEFAULT_DISK_CAP = intEnv('KAISOLA_TERMINAL_DISK_MB', 16, 2, 256) * 1024 * 1024
const DEFAULT_HOT_CAP = intEnv('KAISOLA_TERMINAL_HOT_KB', 1024, 128, 4096) * 1024
const DEFAULT_QUEUE_CAP = intEnv('KAISOLA_TERMINAL_SPOOL_BATCH_KB', 256, 32, 1024) * 1024

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
const DEC_CARRY_RE = /\x1b(?:\[(?:[?!][0-9;]{0,12})?)?$/

function atomicJson(file, value) {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

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

class TerminalSpool {
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
    this.truncated = false
    this.viewState = null
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
    this.decModes = new Map()
    this.decCarry = ''
    try {
      const m = JSON.parse(fs.readFileSync(this.metaFile, 'utf8'))
      if (m && m.id === this.id) {
        this.viewState = m.viewState || null
        if (m.decModes && typeof m.decModes === 'object') {
          for (const [mode, set] of Object.entries(m.decModes)) {
            const n = Number(mode)
            if (TRACKED_DEC_MODES.has(n)) this.decModes.set(n, !!set)
          }
        }
      }
    } catch { /* no prior state */ }
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
    const carry = text.slice(-16).match(DEC_CARRY_RE)
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
    if (this.queuedLen >= this.queueCap) this.flush()
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
      // Two bounded segments avoid rewriting a 12MB tail on Electron's main
      // thread. Rotation is a metadata rename; total history stays <= diskCap.
      if (size > Math.max(1, Math.floor(this.diskCap / 2))) {
        const discarded = fs.existsSync(this.prevFile)
        try { fs.unlinkSync(this.prevFile) } catch { /* first segment */ }
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

  _diskTail(bytes) {
    if (!bytes) return ''
    const current = readTail(this.file, bytes)
    const remaining = Math.max(0, bytes - Buffer.byteLength(current))
    return (remaining ? readTail(this.prevFile, remaining) : '') + current
  }

  flush() {
    if (!this.queuedLen) return
    const text = this.queued.join('')
    this.queued = []
    this.queuedLen = 0
    this._append(text)
  }

  push(data) {
    if (!data) return
    this._trackModes(data) // input modes matter even when output is not retained
    if (this.retentionCap === 0) { this.truncated = true; return }
    if (!this.visible) {
      this._queue(data)
      return
    }
    this.chunks.push(data)
    this.chunksLen += Buffer.byteLength(data)
    while (this.chunks.length > 1 && this.chunksLen > this.hotCap) {
      const old = this.chunks.shift()
      this.chunksLen -= Buffer.byteLength(old)
      this._queue(old)
    }
  }

  setVisible(visible, viewState) {
    this.visible = !!visible
    if (viewState && typeof viewState === 'object') this.viewState = viewState
    if (!this.visible) {
      for (const chunk of this.chunks) this._queue(chunk)
      this.chunks = []
      this.chunksLen = 0
      this.flush()
      this.persistMeta()
    }
  }

  persistMeta() {
    try { atomicJson(this.metaFile, { id: this.id, viewState: this.viewState, decModes: Object.fromEntries(this.decModes), touchedAt: Date.now() }) } catch { /* cache failure is non-fatal */ }
  }

  snapshot(outputCap = DEFAULT_HOT_CAP) {
    this.flush()
    const cap = Number.isFinite(Number(outputCap)) ? Math.max(0, Math.floor(Number(outputCap))) : DEFAULT_HOT_CAP
    const hot = this.chunks.join('')
    const hotBytes = Buffer.byteLength(hot)
    const fallback = this.fallbackChunks.join('')
    const fallbackBytes = Buffer.byteLength(fallback)
    const liveBytes = Math.min(cap, hotBytes + fallbackBytes)
    const old = this._diskTail(Math.max(0, cap - liveBytes))
    let output = old + fallback + hot
    if (Buffer.byteLength(output) > cap) output = utf8Tail(output, cap)
    let diskBytes = 0
    for (const file of [this.prevFile, this.file]) {
      try { diskBytes += fs.statSync(file).size } catch { /* absent */ }
    }
    return { output, truncated: this.truncated || diskBytes + hotBytes + fallbackBytes > cap, viewState: this.viewState, modePrefix: this._modePrefix() }
  }

  stats() {
    let diskBytes = 0
    for (const file of [this.prevFile, this.file]) {
      try { diskBytes += fs.statSync(file).size } catch { /* absent */ }
    }
    return { id: this.id, visible: this.visible, ramBytes: this.chunksLen + this.queuedLen + this.fallbackLen, diskBytes, diskError: this.diskError, viewState: this.viewState }
  }

  close({ remove = false } = {}) {
    this.flush()
    this.persistMeta()
    if (!remove) return
    try { fs.unlinkSync(this.file) } catch { /* absent */ }
    try { fs.unlinkSync(this.prevFile) } catch { /* absent */ }
    try { fs.unlinkSync(this.metaFile) } catch { /* absent */ }
  }
}

module.exports = { TerminalSpool, DEFAULT_DISK_CAP, DEFAULT_HOT_CAP, DEFAULT_QUEUE_CAP, readTail, utf8Tail }
