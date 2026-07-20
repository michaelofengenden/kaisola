const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key)

const boundedText = (value, max) => {
  if (value === null) return null
  if (typeof value !== 'string') return undefined
  return value.slice(0, max)
}

/** Pop-out renderers are read-only views of the durable store. Only this
 * bounded subset may be mirrored back to the full window that owns the
 * project; arbitrary renderer objects never cross the relay. */
function sanitizeTerminalMirror(value, expectedTerminalId, expectedProjectId) {
  if (!value || typeof value !== 'object') return null
  if (value.termId !== expectedTerminalId || value.projectId !== expectedProjectId) return null
  const result = { termId: expectedTerminalId, projectId: expectedProjectId }
  let changed = false

  if (value.meta && typeof value.meta === 'object' && !Array.isArray(value.meta)) {
    const meta = {}
    for (const [key, max] of Object.entries({ fgProcess: 240, cwd: 4096, root: 4096, repo: 512, branch: 512, oscTitle: 240 })) {
      if (!own(value.meta, key)) continue
      const clean = boundedText(value.meta[key], max)
      if (clean !== undefined) meta[key] = clean
    }
    for (const key of ['running', 'agentBusy']) {
      if (typeof value.meta[key] === 'boolean') meta[key] = value.meta[key]
    }
    for (const key of ['agentCompletedAt', 'agentRespondedAt']) {
      if (!own(value.meta, key)) continue
      const at = Number(value.meta[key])
      if (value.meta[key] === null) meta[key] = null
      else if (Number.isFinite(at) && at >= 0) meta[key] = Math.round(at)
    }
    if (own(value.meta, 'lastExit')) {
      const exit = Number(value.meta.lastExit)
      if (value.meta.lastExit === null) meta.lastExit = null
      else if (Number.isInteger(exit) && exit >= -255 && exit <= 255) meta.lastExit = exit
    }
    if (Array.isArray(value.meta.ports)) {
      meta.ports = [...new Set(value.meta.ports.map(Number).filter((port) => Number.isInteger(port) && port > 0 && port < 49152))].slice(0, 2)
    }
    if (Object.keys(meta).length) { result.meta = meta; changed = true }
  }

  if (own(value, 'draft') && typeof value.draft === 'string') {
    result.draft = value.draft.slice(0, 64 * 1024)
    changed = true
  }
  if (own(value, 'resume') && typeof value.resume === 'string') {
    result.resume = value.resume.slice(0, 2048)
    changed = true
  }
  return changed ? result : null
}

function mergeTerminalMirror(previous, next) {
  if (!previous) return next
  return {
    ...previous,
    ...next,
    ...(previous.meta || next.meta ? { meta: { ...(previous.meta || {}), ...(next.meta || {}) } } : {}),
  }
}

function tabListOwnsProject(list, projectId) {
  return typeof projectId === 'string' && Array.isArray(list) && list.some((tab) => tab?.id === projectId)
}

function popCloseAckMatches(record, ack) {
  return !!record?.closed && Number.isSafeInteger(record.revision) && record.revision > 0 &&
    !!record.state && typeof ack === 'object' && ack !== null &&
    ack.termId === record.state.termId && ack.projectId === record.state.projectId &&
    Number.isSafeInteger(ack.revision) && ack.revision === record.revision
}

/**
 * Main-process cache for terminal state emitted by a read-only pop renderer.
 *
 * Active records stay only as long as their BrowserWindow. Closing converts the
 * record into a revisioned handoff which survives a missing/reloading owner and
 * is removed only by an exact project+revision ACK or the bounded expiry. The
 * injected timer functions make all retention and cleanup behavior testable
 * without Electron.
 */
function createPopMirrorCache({
  retentionMs = 60_000,
  maxClosed = 128,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
} = {}) {
  const records = new Map()
  let revisionSeq = 0

  const clearRecord = (termId) => {
    const record = records.get(termId)
    if (!record) return false
    if (record.timer != null) clearTimeoutFn(record.timer)
    records.delete(termId)
    return true
  }

  const trimClosed = () => {
    const closed = [...records.entries()].filter(([, record]) => record.closed)
    while (closed.length > maxClosed) {
      const [termId] = closed.shift()
      clearRecord(termId)
    }
  }

  const activate = (termId, projectId) => {
    clearRecord(termId)
    const state = { termId, projectId }
    records.set(termId, { state, closed: false, revision: 0, timer: null })
    return state
  }

  const update = (next) => {
    if (!next || typeof next.termId !== 'string' || typeof next.projectId !== 'string') return null
    const current = records.get(next.termId)
    if (current?.closed || (current && current.state.projectId !== next.projectId)) return null
    const state = mergeTerminalMirror(current?.state, next)
    records.set(next.termId, { state, closed: false, revision: 0, timer: null })
    return state
  }

  const close = (termId, projectId) => {
    const current = records.get(termId)
    if (current?.state?.projectId && current.state.projectId !== projectId) return null
    if (current?.timer != null) clearTimeoutFn(current.timer)
    const record = {
      state: current?.state ?? { termId, projectId },
      closed: true,
      revision: ++revisionSeq,
      timer: null,
    }
    // Reinsert so bounded eviction is oldest-closed-first even after a prior
    // active update of this same terminal id.
    records.delete(termId)
    records.set(termId, record)
    const timer = setTimeoutFn(() => {
      if (records.get(termId) === record) records.delete(termId)
    }, Math.max(1, retentionMs))
    timer?.unref?.()
    record.timer = timer
    trimClosed()
    return { state: record.state, closed: true, revision: record.revision }
  }

  const acknowledge = (ack) => {
    const record = records.get(ack?.termId)
    if (!popCloseAckMatches(record, ack)) return false
    clearRecord(ack.termId)
    return true
  }

  const values = () => [...records.values()].map((record) => ({
    state: record.state,
    closed: record.closed,
    revision: record.revision,
  }))

  const get = (termId) => {
    const record = records.get(termId)
    return record ? { state: record.state, closed: record.closed, revision: record.revision } : null
  }

  return {
    acknowledge,
    activate,
    close,
    discard: clearRecord,
    get,
    update,
    values,
    get size() { return records.size },
  }
}

module.exports = {
  createPopMirrorCache,
  mergeTerminalMirror,
  popCloseAckMatches,
  sanitizeTerminalMirror,
  tabListOwnsProject,
}
