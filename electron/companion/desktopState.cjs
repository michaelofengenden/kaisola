'use strict'

const { CompanionEventLog } = require('./eventLog.cjs')
const { PROJECTION_KIND, sanitizeProjection } = require('./redaction.cjs')

class CompanionDesktopState {
  constructor({ epoch, projectionStore, now = Date.now, eventLog } = {}) {
    if (!projectionStore?.list) throw new Error('companion projection store is required')
    this.projectionStore = projectionStore
    this.now = now
    this.eventLog = eventLog ?? new CompanionEventLog({ epoch })
    this.snapshotRevision = 0
  }

  projectionPublished(windowId, result) {
    if (!result?.ok || !result.projection || result.duplicate || result.stale) return null
    this.snapshotRevision++
    return this.eventLog.append({
      type: 'project.updated',
      payload: {
        windowId,
        revision: result.projection.revision,
        projection: result.projection,
      },
      at: this.now(),
    })
  }

  projectionRemoved(windowId) {
    this.snapshotRevision++
    return this.eventLog.append({
      type: 'project.updated',
      payload: { windowId, removed: true, revision: this.snapshotRevision },
      at: this.now(),
    })
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
    return this.eventLog.append({ type, payload: cleanPayload, at: this.now() })
  }

  snapshot() {
    const records = this.projectionStore.list()
    const projectOwner = new Map()
    const projects = []
    for (const record of records) {
      for (const project of record.projection.projects) {
        if (projectOwner.has(project.id)) continue
        projectOwner.set(project.id, record.windowId)
        projects.push(project)
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
        sessions.push(session)
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
    return sanitizeProjection({
      projectionKind: PROJECTION_KIND,
      revision: this.snapshotRevision,
      generatedAt: this.now(),
      freshness: records.length > 0 && records.every((record) => record.projection.freshness === 'live') ? 'live' : 'stale',
      projects,
      sessions,
      attention,
      permissions,
    })
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
    return { snapshotRevision: this.snapshotRevision, eventLog: this.eventLog.stats() }
  }
}

module.exports = { CompanionDesktopState }
