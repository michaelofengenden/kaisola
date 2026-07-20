'use strict'

const { CompanionEventLog } = require('./eventLog.cjs')
const { validateIdentifier } = require('./protocol.cjs')
const { PROJECTION_KIND, sanitizeAcpSessionEvent, sanitizeProjection } = require('./redaction.cjs')
const { DEFAULT_SNAPSHOT_BYTES, makeBoundedSnapshot } = require('./terminalCursor.cjs')

const ACP_EVENT_TYPES = new Set([
  'agent.turn.delta',
  'agent.turn.completed',
  'agent.permission.requested',
  'agent.permission.resolved',
])
function optionalText(value, max) {
  if (typeof value !== 'string') return undefined
  const text = value.replace(/[\0\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').trim()
  return text ? text.slice(0, max) : undefined
}

class CompanionDesktopState {
  constructor({ epoch, projectionStore, attentionService = null, windowLabel = null, now = Date.now, eventLog } = {}) {
    if (!projectionStore?.list) throw new Error('companion projection store is required')
    this.projectionStore = projectionStore
    this.attentionService = attentionService
    this.windowLabel = typeof windowLabel === 'function' ? windowLabel : null
    this.now = now
    this.eventLog = eventLog ?? new CompanionEventLog({ epoch })
    this.snapshotRevision = 0
    this.listeners = new Set()
    this.unsubscribeAttention = attentionService?.subscribe?.((event) => {
      const { type, ...payload } = event
      if (type !== 'attention.raised' && type !== 'attention.cleared') return
      this.#append({ type, payload, at: event.createdAt ?? event.clearedAt ?? this.now() })
    }) ?? null
  }

  projectionPublished(windowId, result) {
    if (!result?.ok || !result.projection || result.duplicate || result.stale) return null
    this.snapshotRevision++
    const event = this.#append({
      type: 'project.updated',
      payload: {
        windowId,
        revision: result.projection.revision,
        projection: this.#projectionForWindow(windowId, result.projection),
      },
      at: this.now(),
    })
    this.attentionService?.synchronizeProjections?.(this.projectionStore.list())
    return event
  }

  projectionRemoved(windowId) {
    this.snapshotRevision++
    const event = this.#append({
      type: 'project.updated',
      payload: { windowId, removed: true, revision: this.snapshotRevision },
      at: this.now(),
    })
    this.attentionService?.synchronizeProjections?.(this.projectionStore.list())
    return event
  }

  terminalObserverEvent(projectId, { channel, payload } = {}) {
    if (typeof projectId !== 'string' || !projectId || !payload || typeof payload !== 'object') return null
    const terminalId = typeof payload.id === 'string' ? payload.id : null
    if (!terminalId) return null
    let type
    let cleanPayload
    if (channel === 'terminal:observer-output') {
      type = 'terminal.output'
      cleanPayload = {
        projectId,
        terminalId,
        streamEpoch: payload.streamEpoch,
        startOffset: payload.startOffset,
        endOffset: payload.endOffset,
        data: payload.data,
      }
    } else if (channel === 'terminal:observer-exit') {
      type = 'terminal.exit'
      cleanPayload = {
        projectId,
        terminalId,
        streamEpoch: payload.streamEpoch,
        offset: payload.offset,
        exitStatus: payload.exitStatus,
      }
    } else if (channel === 'terminal:observer-activity') {
      type = 'session.updated'
      cleanPayload = {
        projectId,
        sessionId: terminalId,
        streamEpoch: payload.streamEpoch,
        offset: payload.offset,
        busy: payload.busy === true,
        completedAt: payload.completedAt ?? null,
      }
    } else if (channel === 'terminal:observer-snapshot-required') {
      type = 'terminal.snapshot'
      cleanPayload = {
        projectId,
        terminalId,
        streamEpoch: payload.streamEpoch,
        endOffset: payload.endOffset,
        snapshotRequired: true,
        reason: payload.reason,
      }
    } else return null
    return this.#append({ type, payload: cleanPayload, at: this.now() })
  }

  terminalObserverSnapshot(projectId, terminalId, result = {}, { audience } = {}) {
    if (typeof projectId !== 'string' || !projectId || typeof terminalId !== 'string' || !terminalId) return null
    let snapshot
    try {
      if (result.mode === 'snapshot' && result.snapshot) {
        snapshot = makeBoundedSnapshot({
          streamEpoch: result.snapshot.streamEpoch,
          output: result.snapshot.output ?? '',
          endOffset: result.snapshot.endOffset,
          maxBytes: DEFAULT_SNAPSHOT_BYTES,
          truncated: result.snapshot.truncated,
          exited: result.snapshot.exited,
          exitStatus: result.snapshot.exitStatus,
        })
      } else if (result.mode === 'current' && result.cursor) {
        snapshot = makeBoundedSnapshot({
          streamEpoch: result.cursor.streamEpoch,
          output: '',
          endOffset: result.cursor.offset,
          maxBytes: DEFAULT_SNAPSHOT_BYTES,
          truncated: result.cursor.offset > 0,
          exited: false,
        })
      } else return null
    } catch {
      return null
    }
    return this.#append({
      type: 'terminal.snapshot',
      payload: {
        projectId,
        terminalId,
        mode: result.mode,
        ...snapshot,
        ...(typeof result.resetReason === 'string' ? { resetReason: result.resetReason.slice(0, 80) } : {}),
      },
      at: this.now(),
      audience,
    })
  }

  projectIds() {
    const projects = new Set()
    for (const record of this.projectionStore.list()) {
      for (const project of record.projection.projects) projects.add(project.id)
    }
    return [...projects]
  }

  projectIdsForWindow(windowId) {
    const claimed = new Set()
    const owned = []
    for (const record of this.projectionStore.list()) {
      for (const project of record.projection.projects) {
        if (claimed.has(project.id)) continue
        claimed.add(project.id)
        if (record.windowId === windowId) owned.push(project.id)
      }
    }
    return owned
  }

  snapshot() {
    const records = this.projectionStore.list()
    this.attentionService?.synchronizeProjections?.(records)
    const projectOwner = new Map()
    const projects = []
    for (const record of records) {
      for (const project of record.projection.projects) {
        if (projectOwner.has(project.id)) continue
        projectOwner.set(project.id, record.windowId)
        projects.push(this.#projectForWindow(record.windowId, project))
      }
    }

    const sessions = []
    const attention = []
    const permissions = []
    const sessionIds = new Set()
    const attentionIds = new Set()
    const permissionIds = new Set()
    for (const record of records) {
      for (const session of record.projection.sessions) {
        if (projectOwner.get(session.projectId) !== record.windowId || sessionIds.has(session.id)) continue
        sessionIds.add(session.id)
        sessions.push({ ...session, windowId: record.windowId })
      }
      for (const item of record.projection.attention) {
        if (projectOwner.get(item.projectId) !== record.windowId || attentionIds.has(item.id)) continue
        attentionIds.add(item.id)
        attention.push(item)
      }
      for (const permission of record.projection.permissions) {
        if (projectOwner.get(permission.projectId) !== record.windowId || permissionIds.has(permission.permId)) continue
        permissionIds.add(permission.permId)
        permissions.push(permission)
      }
    }

    const maxRevision = records.reduce((max, record) => Math.max(max, record.projection.revision), 0)
    this.snapshotRevision = Math.max(this.snapshotRevision, maxRevision)
    const projection = sanitizeProjection({
      projectionKind: PROJECTION_KIND,
      revision: this.snapshotRevision,
      generatedAt: this.now(),
      freshness: records.length > 0 && records.every((record) => record.projection.freshness === 'live') ? 'live' : 'stale',
      projects,
      sessions,
      attention,
      permissions,
    })
    return this.attentionService
      ? sanitizeProjection(this.attentionService.mergeProjection(projection))
      : projection
  }

  #projectForWindow(windowId, project) {
    const name = optionalText(this.windowLabel?.(windowId), 240)
    return {
      ...project,
      windowId,
      ...(name ? { windowName: name } : {}),
    }
  }

  #projectionForWindow(windowId, projection) {
    return sanitizeProjection({
      ...projection,
      projects: projection.projects.map((project) => this.#projectForWindow(windowId, project)),
      sessions: projection.sessions.map((session) => ({ ...session, windowId })),
    })
  }

  acpSessionEvent(event, { recordReplay = true } = {}) {
    if (!event || !ACP_EVENT_TYPES.has(event.type) || typeof event.projectId !== 'string' || !event.projectId) return null
    let clean
    try { clean = sanitizeAcpSessionEvent(event, { requestedAt: this.now() }) } catch { return null }
    if (!recordReplay) {
      this.eventLog.invalidate()
      this.attentionService?.handleAcpEvent?.(clean)
      return null
    }
    const { type, ...payload } = clean
    let appended
    try { appended = this.#append({ type, payload, at: this.now() }) } catch { appended = null }
    this.attentionService?.handleAcpEvent?.(clean)
    return appended
  }

  attentionEvent(event) {
    return this.acpSessionEvent(event)
  }

  terminalAttention(event) {
    return this.attentionService?.handleTerminalEvent?.(event) ?? null
  }

  ledgerEvent(event = {}) {
    const task = event.task
    if (!task || typeof task !== 'object' || Array.isArray(task)) return null
    let projectId = typeof task.projectId === 'string' ? task.projectId : null
    if (!projectId && typeof task.project === 'string') {
      projectId = this.attentionService?.projectIdForAlias?.(task.project) ?? null
    }
    if (!projectId) return this.attentionService?.handleLedgerEvent?.({ task }) ?? null
    try {
      validateIdentifier(projectId, 'ledger.projectId', 240)
      validateIdentifier(task.id, 'ledger.taskId', 240)
    } catch {
      return null
    }
    const cleanTask = {
      id: task.id,
      status: optionalText(task.status, 40) ?? 'open',
      title: optionalText(task.title, 300) ?? 'Agent task',
      ...(optionalText(task.project, 240) ? { project: optionalText(task.project, 240) } : {}),
      ...(optionalText(task.owner, 120) ? { owner: optionalText(task.owner, 120) } : {}),
      ...(optionalText(task.createdBy, 120) ? { createdBy: optionalText(task.createdBy, 120) } : {}),
      ...(optionalText(task.detail, 8_000) ? { detail: optionalText(task.detail, 8_000) } : {}),
      ...(optionalText(task.result, 8_000) ? { result: optionalText(task.result, 8_000) } : {}),
      ...(Number.isSafeInteger(task.createdAt) && task.createdAt >= 0 ? { createdAt: task.createdAt } : {}),
      ...(Number.isSafeInteger(task.updatedAt) && task.updatedAt >= 0 ? { updatedAt: task.updatedAt } : {}),
    }
    const appended = this.#append({
      type: 'ledger.task.updated',
      payload: { projectId, task: cleanTask, change: optionalText(event.type, 40) ?? 'updated' },
      at: this.now(),
    })
    this.attentionService?.handleLedgerEvent?.({ task: { ...task, projectId }, projectId })
    return appended
  }

  ledgerAttention(event) {
    return this.ledgerEvent(event)
  }

  acknowledgeAttention(actor, target) {
    if (!this.attentionService?.acknowledge) {
      return { ok: false, status: 'unavailable', message: 'Attention authority is unavailable.' }
    }
    return this.attentionService.acknowledge(actor, target)
  }

  subscribe(listener) {
    if (typeof listener !== 'function') throw new Error('desktop state subscriber is invalid')
    this.listeners.add(listener)
    let active = true
    return () => {
      if (!active) return false
      active = false
      return this.listeners.delete(listener)
    }
  }

  replay(cursor) {
    return this.eventLog.replay(cursor)
  }

  acknowledge(clientId, seq) {
    return this.eventLog.acknowledge(clientId, seq)
  }

  disconnect(clientId) {
    return this.eventLog.dropClient(clientId)
  }

  stats() {
    return {
      snapshotRevision: this.snapshotRevision,
      eventLog: this.eventLog.stats(),
      ...(this.attentionService?.stats ? { attention: this.attentionService.stats() } : {}),
    }
  }

  #append(event) {
    const appended = this.eventLog.append(event)
    for (const listener of this.listeners) {
      try { listener(appended) } catch { /* one gateway cannot break state */ }
    }
    return appended
  }
}

module.exports = { CompanionDesktopState }
