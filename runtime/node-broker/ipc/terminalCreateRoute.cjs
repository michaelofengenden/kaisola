'use strict'

const os = require('node:os')

/** The authenticated `terminal.create` operation after access selection. Kept
 * separate from the executable broker so the additive resurrection wire can
 * be contract-tested without binding its AF_UNIX listener. */
function terminalCreateRoute({
  manager,
  params = {},
  owner,
  clientInstanceId,
  requireAllowed,
  brokerPid = process.pid,
  now = Date.now,
}) {
  if (!manager.available()) return { ok: false, message: 'node-pty unavailable in session broker' }
  const id = String(params.id || '').slice(0, 240)
  if (!id) return { ok: false, message: 'terminal id required' }
  if (manager.has(id)) requireAllowed(id, true)

  const existed = manager.isLive(id)
  const restore = params.restore === true
  if (restore && !manager.has(id)) {
    // A restore for an id this broker process no longer remembers must still
    // prove project ownership before any retained spool is served:
    // `requireAllowed` has nothing to check against after a broker restart,
    // and the retained spool may hold another project's transcript. The id
    // embeds its project (`term-<project>-<hex8>`), so bind the claim there.
    const embedded = /^term-(.+)-[0-9a-f]{8}$/.exec(id)
    const requested = String(params.projectId ?? '')
    if (!embedded || !requested || embedded[1] !== requested) {
      return { ok: false, message: 'terminal restore denied: project mismatch' }
    }
  }
  const rec = manager.spawn({
    id,
    command: typeof params.command === 'string' ? params.command : undefined,
    args: Array.isArray(params.args) ? params.args.map(String).slice(0, 200) : undefined,
    cwd: typeof params.cwd === 'string' ? params.cwd : os.homedir(),
    env: params.env && typeof params.env === 'object' ? params.env : undefined,
    outputByteLimit: Number.isFinite(Number(params.outputByteLimit))
      ? Math.max(0, Math.min(Math.floor(Number(params.outputByteLimit)), 8 * 1024 * 1024))
      : undefined,
    cols: Number(params.cols) || 80,
    rows: Number(params.rows) || 24,
    sender: owner,
    restore,
  })
  if (!rec) return { ok: false, message: 'could not start terminal' }

  const continuity = manager.setSender(id, owner)
  const previousInstance = continuity?.previousOwner?.split('|')[0]
  const continuation = continuity && previousInstance && previousInstance !== clientInstanceId
    ? { ...continuity, acrossRestart: true, reattachedAt: now(), brokerPid, terminalPid: rec.pty?.pid }
    : null
  const recovered = restore
    && !existed
    && rec.recovered
    && typeof rec.recovered.text === 'string'
    ? { text: rec.recovered.text, truncated: !!rec.recovered.truncated }
    : null
  return {
    ok: true,
    existed,
    pid: rec.pty?.pid,
    continuation,
    ...manager.snapshot(id),
    recovered,
  }
}

module.exports = { terminalCreateRoute }
