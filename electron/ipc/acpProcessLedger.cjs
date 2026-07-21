// Exact ownership ledger for ACP adapter process trees. Every child receives a
// random, install-local owner token plus a per-launch/per-connection marker.
// On the next launch we reclaim ONLY processes whose environment contains all
// recorded markers. No command-name matching and no broad pkill is ever used.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const LEDGER_VERSION = 1

function atomicWrite(file, value) {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { mode: 0o600 })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

/** Full process-table scan with environment. Returns an array of rows, or
 * NULL when the scan itself failed (ps missing, EAGAIN under fork pressure,
 * ENOBUFS when a busy machine's env dump exceeds maxBuffer). Callers must
 * treat null as "unknown", never as "no processes": pruning ownership
 * records on a failed scan would leak orphaned adapter trees forever. */
function readPs() {
  if (process.platform === 'win32') return []
  // /bin/ps on macOS and merged-usr Linux; fall back to PATH resolution for
  // layouts where ps lives elsewhere.
  for (const psPath of ['/bin/ps', 'ps']) {
    try {
      const raw = execFileSync(psPath, ['eww', '-axo', 'pid=,pgid=,command='], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 })
      return raw.split('\n').map((line) => {
        const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)
        return m ? { pid: Number(m[1]), pgid: Number(m[2]), command: m[3] } : null
      }).filter(Boolean)
    } catch { /* try the next candidate */ }
  }
  return null
}

class AcpProcessLedger {
  constructor(dir, deps = {}) {
    this.dir = dir
    this.file = path.join(dir, 'acp-processes.json')
    this.kill = deps.kill || process.kill.bind(process)
    this.scan = deps.scan || readPs
    this.hardKillDelay = deps.hardKillDelay === undefined ? 1500 : deps.hardKillDelay
    this.instanceId = crypto.randomBytes(12).toString('hex')
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
    let prior = {}
    try { prior = JSON.parse(fs.readFileSync(this.file, 'utf8')) || {} } catch { /* first launch */ }
    this.ownerId = typeof prior.ownerId === 'string' && prior.ownerId.length >= 24
      ? prior.ownerId
      : crypto.randomBytes(24).toString('hex')
    // Trust records only from a layout we can actually interpret. A file
    // written by a future format (or the planned Swift runtime) is dropped
    // explicitly rather than half-parsed into wrong kill decisions.
    const versionOk = prior.version == null || prior.version === LEDGER_VERSION
    this.records = versionOk && Array.isArray(prior.records) ? prior.records.filter((r) => r && r.token && r.instanceId) : []
    this.reclaimed = []
    this._save()
  }

  _save() {
    try { atomicWrite(this.file, { version: LEDGER_VERSION, ownerId: this.ownerId, records: this.records }) } catch { /* diagnostics must never block agents */ }
  }

  markers(token) {
    return {
      KAISOLA_ACP_OWNER: this.ownerId,
      KAISOLA_ACP_INSTANCE: this.instanceId,
      KAISOLA_ACP_CONNECTION: token,
    }
  }

  newToken() {
    return crypto.randomBytes(16).toString('hex')
  }

  recordSpawn({ token, pid, pgid, presetId, command }) {
    if (!token || !Number.isInteger(pid) || pid <= 1) return
    this.records = this.records.filter((r) => r.token !== token)
    this.records.push({ token, pid, pgid: Number(pgid) || pid, presetId, command, instanceId: this.instanceId, spawnedAt: Date.now() })
    this._save()
  }

  recordExit(token) {
    const record = this.records.find((r) => r.token === token)
    if (!record) return
    // The adapter root may exit before its model CLI child. Keep the ownership
    // record whenever any exact-marker descendant remains, so next launch can
    // reclaim it. This is the orphan case the ledger exists to solve.
    const owner = `KAISOLA_ACP_OWNER=${this.ownerId}`
    const instance = `KAISOLA_ACP_INSTANCE=${record.instanceId}`
    const conn = `KAISOLA_ACP_CONNECTION=${record.token}`
    const rows = this.scan()
    // A failed scan proves nothing about descendants — keep the record so the
    // next launch can still reclaim a surviving tree.
    if (rows === null) return
    if (rows.some((r) => r.command.includes(owner) && r.command.includes(instance) && r.command.includes(conn))) return
    const next = this.records.filter((r) => r.token !== token)
    if (next.length === this.records.length) return
    this.records = next
    this._save()
  }

  reclaimStale() {
    const stale = this.records.filter((r) => r.instanceId !== this.instanceId)
    if (!stale.length) return { matched: 0, signalled: 0 }
    const rows = this.scan()
    // A failed scan is indistinguishable from "everything exited" only if we
    // guess — don't. Retain every stale record unchanged and let a later
    // launch (or the hard-kill retry) reclaim once ps is answering again.
    if (rows === null) return { matched: 0, signalled: 0, scanFailed: true }
    let matched = 0
    let signalled = 0
    const stillRecorded = []
    for (const rec of stale) {
      const owner = `KAISOLA_ACP_OWNER=${this.ownerId}`
      const instance = `KAISOLA_ACP_INSTANCE=${rec.instanceId}`
      const conn = `KAISOLA_ACP_CONNECTION=${rec.token}`
      const owned = rows.filter((r) => r.command.includes(owner) && r.command.includes(instance) && r.command.includes(conn))
      if (!owned.length) continue
      matched += owned.length
      // A detached ACP root owns its process group. Kill that group only when a
      // marker-verified member still has the exact recorded pgid; otherwise kill
      // the individually marker-verified pids. Never infer by executable name.
      const groupVerified = Number(rec.pgid) > 1 && owned.some((r) => r.pgid === Number(rec.pgid))
      try {
        if (groupVerified) this.kill(-Number(rec.pgid), 'SIGTERM')
        else for (const row of owned) this.kill(row.pid, 'SIGTERM')
        signalled += groupVerified ? 1 : owned.length
        this.reclaimed.push({ token: rec.token, presetId: rec.presetId, pids: owned.map((r) => r.pid), at: Date.now() })
        if (this.hardKillDelay >= 0) {
          const hard = setTimeout(() => {
            const rescan = this.scan()
            if (rescan === null) return // unknown state — keep the record for the next launch
            const remaining = rescan.filter((r) => r.command.includes(owner) && r.command.includes(instance) && r.command.includes(conn))
            if (!remaining.length) { this.recordExit(rec.token); return }
            const groupStillVerified = Number(rec.pgid) > 1 && remaining.some((r) => r.pgid === Number(rec.pgid))
            try {
              if (groupStillVerified) this.kill(-Number(rec.pgid), 'SIGKILL')
              else for (const row of remaining) this.kill(row.pid, 'SIGKILL')
            } catch { /* exited during verification */ }
          }, this.hardKillDelay)
          hard.unref?.()
        }
      } catch { /* it exited between scan and signal */ }
      stillRecorded.push(rec)
    }
    // Unknown/unmatched stale records are gone (or unverifiable) and are
    // pruned. Matched records remain until the next launch as a SIGKILL retry
    // safety net if graceful group shutdown did not complete.
    this.records = [...stillRecorded, ...this.records.filter((r) => r.instanceId === this.instanceId)]
    this._save()
    return { matched, signalled }
  }

  diagnostics() {
    return { ownerId: this.ownerId, instanceId: this.instanceId, records: this.records.map(({ token: _token, ...r }) => r), reclaimed: this.reclaimed }
  }
}

module.exports = { AcpProcessLedger, readPs }
