'use strict'

const crypto = require('node:crypto')
const { validateIdentifier } = require('../companion/protocol.cjs')

const STORE_KEY = 'kaisola-attention-service:v1'
const STORE_VERSION = 1
const DEFAULT_MAX_RECORDS = 512
const DEFAULT_MAX_ACTIVE = 200
const DEFAULT_MAX_SESSIONS = 500
const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1_000
const ATTENTION_KINDS = new Set(['permission', 'question', 'review', 'blocked', 'failed', 'completed'])
const SESSION_STATUSES = new Set(['idle', 'running', 'waiting', 'done', 'failed'])
const SEVERITIES = new Set(['info', 'warning', 'critical'])
const OUTCOME_KINDS = new Set(['question', 'failed', 'completed'])
const ACTOR_CAPABILITY = Symbol('kaisola.attention.actor-capability')

function cloneJson(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value))
}

function safeId(value, label, max = 240) {
  return validateIdentifier(value, label, max)
}

function safeText(value, fallback, max = 240) {
  const text = typeof value === 'string'
    ? value.replace(/[\0\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').trim()
    : ''
  return (text || fallback).slice(0, max)
}

function safeTime(value, fallback) {
  return Number.isSafeInteger(value) && value >= 0 ? value : fallback
}

function sessionKey(projectId, sessionId) {
  return `${projectId}\0${sessionId}`
}

function sourceKey(projectId, source, sourceId) {
  return `${projectId}\0${source}\0${sourceId}`
}

function attentionEventId({ projectId, source, sourceId }) {
  safeId(projectId, 'attention projectId')
  const cleanSource = safeId(source, 'attention source', 80)
  const cleanSourceId = safeId(sourceId, 'attention sourceId', 500)
  const digest = crypto.createHash('sha256')
    .update(`kaisola-attention-v1\0${projectId}\0${cleanSource}\0${cleanSourceId}`)
    .digest('hex')
    .slice(0, 32)
  return `attention-${digest}`
}

function createAttentionActorCapability({ id, surface, projectId, capabilities } = {}) {
  const cleanId = safeId(id, 'attention actor id', 240)
  if (surface !== 'desktop' && surface !== 'companion') throw new Error('Attention actor surface is invalid.')
  const cleanProjectId = safeId(projectId, 'attention actor projectId')
  const list = Array.isArray(capabilities) ? capabilities : capabilities instanceof Set ? [...capabilities] : []
  const unique = new Set(list)
  if (!unique.has('observe') || unique.size !== list.length || [...unique].some((capability) => !['observe', 'agent-control', 'terminal-control'].includes(capability))) {
    throw new Error('Attention actor lacks observe capability.')
  }
  return Object.freeze({
    [ACTOR_CAPABILITY]: true,
    id: cleanId,
    surface,
    projectId: cleanProjectId,
    capabilities: Object.freeze([...unique]),
  })
}

function publicEvent(record) {
  return Object.freeze({
    id: record.id,
    eventId: record.id,
    projectId: record.projectId,
    kind: record.kind,
    title: record.title,
    createdAt: record.createdAt,
    severity: record.severity,
    ...(record.sessionId ? { sessionId: record.sessionId } : {}),
    ...(record.detail ? { detail: record.detail } : {}),
    ...(record.windowId ? { windowId: record.windowId } : {}),
  })
}

function emittedEvent(type, record, extra = {}) {
  return Object.freeze({
    type,
    eventId: record.id,
    projectId: record.projectId,
    kind: record.kind,
    ...(record.sessionId ? { sessionId: record.sessionId } : {}),
    ...(type === 'attention.raised' ? {
      title: record.title,
      createdAt: record.createdAt,
      severity: record.severity,
      ...(record.detail ? { detail: record.detail } : {}),
    } : {}),
    ...(record.windowId ? { windowId: record.windowId } : {}),
    ...extra,
  })
}

function cleanRecord(raw, now) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  try {
    const id = safeId(raw.id, 'attention event id')
    const projectId = safeId(raw.projectId, 'attention projectId')
    if (!ATTENTION_KINDS.has(raw.kind)) return null
    const status = raw.status === 'active' ? 'active' : raw.status === 'cleared' ? 'cleared' : null
    if (!status) return null
    const sources = Array.isArray(raw.sources)
      ? [...new Set(raw.sources.flatMap((item) => {
          if (!item || typeof item !== 'object' || Array.isArray(item)) return []
          try {
            return [{
              source: safeId(item.source, 'attention source', 80),
              sourceId: safeId(item.sourceId, 'attention sourceId', 500),
            }]
          } catch { return [] }
        }).map((item) => JSON.stringify(item)))].map((item) => JSON.parse(item)).slice(0, 8)
      : []
    if (!sources.length) return null
    return {
      id,
      projectId,
      kind: raw.kind,
      title: safeText(raw.title, 'Attention needed'),
      detail: typeof raw.detail === 'string' ? safeText(raw.detail, '', 240) : undefined,
      severity: SEVERITIES.has(raw.severity) ? raw.severity : 'info',
      createdAt: safeTime(raw.createdAt, now),
      updatedAt: safeTime(raw.updatedAt, now),
      status,
      ...(typeof raw.sessionId === 'string' ? { sessionId: safeId(raw.sessionId, 'attention sessionId') } : {}),
      ...(typeof raw.windowId === 'string' ? { windowId: safeId(raw.windowId, 'attention windowId') } : {}),
      ...(status === 'cleared' ? {
        clearedAt: safeTime(raw.clearedAt, now),
        clearReason: safeText(raw.clearReason, 'acknowledged', 80),
      } : {}),
      sources,
    }
  } catch {
    return null
  }
}

function cleanSession(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  try {
    const projectId = safeId(raw.projectId, 'attention session projectId')
    const id = safeId(raw.id, 'attention session id')
    return {
      id,
      projectId,
      kind: raw.kind === 'agent' || raw.kind === 'terminal' || raw.kind === 'panel' ? raw.kind : 'agent',
      title: safeText(raw.title, 'Session'),
      status: SESSION_STATUSES.has(raw.status) ? raw.status : 'idle',
      updatedAt: safeTime(raw.updatedAt, 0),
      ...(typeof raw.provider === 'string' ? { provider: safeText(raw.provider, '', 120) } : {}),
      ...(typeof raw.windowId === 'string' ? { windowId: safeId(raw.windowId, 'attention windowId') } : {}),
    }
  } catch {
    return null
  }
}

class AttentionService {
  constructor({
    get = () => null,
    set = () => {},
    now = Date.now,
    maxRecords = DEFAULT_MAX_RECORDS,
    maxActive = DEFAULT_MAX_ACTIVE,
    maxSessions = DEFAULT_MAX_SESSIONS,
    retentionMs = DEFAULT_RETENTION_MS,
  } = {}) {
    if (typeof get !== 'function' || typeof set !== 'function' || typeof now !== 'function') {
      throw new Error('Attention service storage is invalid.')
    }
    if (![maxRecords, maxActive, maxSessions, retentionMs].every((value) => Number.isSafeInteger(value) && value > 0)) {
      throw new Error('Attention service bounds are invalid.')
    }
    this.get = get
    this.set = set
    this.now = now
    this.maxRecords = maxRecords
    this.maxActive = Math.min(maxActive, maxRecords)
    this.maxSessions = maxSessions
    this.retentionMs = retentionMs
    this.records = new Map()
    this.sourceIndex = new Map()
    this.sessions = new Map()
    this.surfaces = new Map()
    this.projectionSources = new Map()
    this.subscribers = new Set()
    this.revision = 0
    this.#load()
  }

  subscribe(listener) {
    if (typeof listener !== 'function') throw new Error('Attention subscriber is invalid.')
    this.subscribers.add(listener)
    let active = true
    return () => {
      if (!active) return false
      active = false
      return this.subscribers.delete(listener)
    }
  }

  raise(input = {}) {
    const now = this.now()
    const projectId = safeId(input.projectId, 'attention projectId')
    const kind = ATTENTION_KINDS.has(input.kind) ? input.kind : null
    if (!kind) throw new Error('Attention kind is invalid.')
    const source = safeId(input.source, 'attention source', 80)
    const sourceId = safeId(input.sourceId, 'attention sourceId', 500)
    const key = sourceKey(projectId, source, sourceId)
    const indexed = this.sourceIndex.get(key)
    if (indexed) {
      const existing = this.records.get(indexed)
      if (existing) {
        const changed = this.#enhance(existing, input, now)
        if (changed) {
          this.revision++
          this.#persist()
          if (existing.status === 'active') this.#emit(emittedEvent('attention.raised', existing, { updated: true }))
        }
        return { ok: true, duplicate: true, active: existing.status === 'active', event: publicEvent(existing) }
      }
      this.sourceIndex.delete(key)
    }

    const sessionId = input.sessionId == null ? null : safeId(input.sessionId, 'attention sessionId')
    if (input.coalesceTarget === true && sessionId) {
      const target = this.#latestActive(projectId, sessionId, kind)
      if (target && now - target.createdAt <= 30_000) {
        target.sources.push({ source, sourceId })
        this.sourceIndex.set(key, target.id)
        while (target.sources.length > 8) {
          const dropped = target.sources.shift()
          this.sourceIndex.delete(sourceKey(target.projectId, dropped.source, dropped.sourceId))
        }
        const changed = this.#enhance(target, input, now)
        this.revision++
        this.#persist()
        if (changed) this.#emit(emittedEvent('attention.raised', target, { updated: true }))
        return { ok: true, duplicate: true, active: true, event: publicEvent(target) }
      }
    }

    if (sessionId && OUTCOME_KINDS.has(kind)) {
      for (const record of this.records.values()) {
        if (record.status !== 'active' || record.projectId !== projectId || record.sessionId !== sessionId || !OUTCOME_KINDS.has(record.kind)) continue
        this.#clear(record, 'superseded', 'service')
      }
    }

    const id = attentionEventId({ projectId, source, sourceId })
    const visible = sessionId && this.isVisible(projectId, sessionId)
    const record = {
      id,
      projectId,
      kind,
      title: safeText(input.title, kind === 'completed' ? 'Session finished' : kind === 'failed' ? 'Session failed' : 'Attention needed'),
      detail: typeof input.detail === 'string' ? safeText(input.detail, '', 240) : undefined,
      severity: SEVERITIES.has(input.severity) ? input.severity : kind === 'failed' ? 'critical' : kind === 'blocked' ? 'warning' : 'info',
      createdAt: safeTime(input.createdAt, now),
      updatedAt: now,
      status: visible ? 'cleared' : 'active',
      ...(sessionId ? { sessionId } : {}),
      ...(typeof input.windowId === 'string' ? { windowId: safeId(input.windowId, 'attention windowId') } : {}),
      ...(visible ? { clearedAt: now, clearReason: 'observed' } : {}),
      sources: [{ source, sourceId }],
    }
    this.records.set(id, record)
    this.sourceIndex.set(key, id)
    this.revision++
    this.#trim()
    this.#persist()
    if (record.status === 'active') this.#emit(emittedEvent('attention.raised', record))
    return { ok: true, duplicate: false, active: record.status === 'active', observed: visible, event: publicEvent(record) }
  }

  acknowledge(actor, { projectId, eventId, reason = 'acknowledged' } = {}) {
    if (!actor || actor[ACTOR_CAPABILITY] !== true || !actor.capabilities.includes('observe')) {
      return { ok: false, status: 'rejected', message: 'Attention actor lacks observe capability.' }
    }
    let cleanProjectId
    let cleanEventId
    try {
      cleanProjectId = safeId(projectId, 'attention projectId')
      cleanEventId = safeId(eventId, 'attention event id')
    } catch (error) {
      return { ok: false, status: 'rejected', message: error.message }
    }
    if (actor.projectId !== cleanProjectId) {
      return { ok: false, status: 'rejected', message: 'Project capability does not match the attention target.' }
    }
    const record = this.records.get(cleanEventId)
    if (!record) return { ok: false, status: 'stale', message: 'Attention event is stale or unavailable.' }
    if (record.projectId !== cleanProjectId) {
      return { ok: false, status: 'rejected', message: 'Attention event belongs to another project.' }
    }
    if (record.status !== 'active') {
      return { ok: false, status: 'stale', eventId: record.id, message: 'Attention event is already cleared.' }
    }
    this.#clear(record, safeText(reason, 'acknowledged', 80), actor.id)
    return { ok: true, status: 'applied', eventId: record.id, message: 'Attention event cleared.' }
  }

  clearSource({ projectId, source, sourceId, reason = 'resolved', actorId = 'service' } = {}) {
    try {
      const cleanProjectId = safeId(projectId, 'attention projectId')
      const cleanSource = safeId(source, 'attention source', 80)
      const cleanSourceId = safeId(sourceId, 'attention sourceId', 500)
      const id = this.sourceIndex.get(sourceKey(cleanProjectId, cleanSource, cleanSourceId))
      const record = id ? this.records.get(id) : null
      if (!record || record.projectId !== cleanProjectId || record.status !== 'active') return false
      return this.#clear(record, reason, actorId)
    } catch {
      return false
    }
  }

  updateSurface({ windowId, focused, projectId, visibleSessionIds = [], projects = [] } = {}) {
    const cleanWindowId = safeId(windowId, 'attention windowId')
    const cleanProjectId = projectId == null ? null : safeId(projectId, 'attention projectId')
    const visible = [...new Set((Array.isArray(visibleSessionIds) ? visibleSessionIds : []).slice(0, 32).map((id) => safeId(id, 'visible sessionId')))]
    const aliases = new Map()
    for (const item of (Array.isArray(projects) ? projects : []).slice(0, 64)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      let id
      try { id = safeId(item.projectId, 'attention projectId') } catch { continue }
      const alias = typeof item.alias === 'string' && item.alias.length <= 4096 ? item.alias : null
      if (alias) aliases.set(alias, id)
    }
    this.surfaces.set(cleanWindowId, {
      windowId: cleanWindowId,
      focused: focused === true,
      projectId: cleanProjectId,
      visibleSessionIds: new Set(visible),
      aliases,
      updatedAt: this.now(),
    })
    const cleared = []
    if (focused === true && cleanProjectId) {
      for (const sessionId of visible) {
        cleared.push(...this.acknowledgeVisibleSession({ windowId: cleanWindowId, projectId: cleanProjectId, sessionId }))
      }
    }
    return { ok: true, cleared }
  }

  acknowledgeVisibleSession({ windowId, projectId, sessionId } = {}) {
    const cleanWindowId = safeId(windowId, 'attention windowId')
    const cleanProjectId = safeId(projectId, 'attention projectId')
    const cleanSessionId = safeId(sessionId, 'attention sessionId')
    const actor = createAttentionActorCapability({
      id: `desktop-${cleanWindowId}`,
      surface: 'desktop',
      projectId: cleanProjectId,
      capabilities: ['observe'],
    })
    const cleared = []
    for (const record of [...this.records.values()]) {
      if (record.status !== 'active' || record.projectId !== cleanProjectId || record.sessionId !== cleanSessionId) continue
      const result = this.acknowledge(actor, { projectId: cleanProjectId, eventId: record.id, reason: 'desktop_observed' })
      if (result.ok) cleared.push(record.id)
    }
    return cleared
  }

  removeSurface(windowId) {
    try { return this.surfaces.delete(safeId(windowId, 'attention windowId')) } catch { return false }
  }

  isVisible(projectId, sessionId) {
    for (const surface of this.surfaces.values()) {
      if (surface.focused && surface.projectId === projectId && surface.visibleSessionIds.has(sessionId)) return true
    }
    return false
  }

  projectIdForAlias(alias) {
    if (typeof alias !== 'string' || !alias) return null
    const matches = new Set()
    for (const surface of this.surfaces.values()) {
      const projectId = surface.aliases.get(alias)
      if (projectId) matches.add(projectId)
    }
    return matches.size === 1 ? [...matches][0] : null
  }

  windowIdForProject(projectId) {
    const matches = [...this.surfaces.values()]
      .filter((surface) => surface.projectId === projectId || [...surface.aliases.values()].includes(projectId))
      .sort((a, b) => Number(b.focused) - Number(a.focused) || b.updatedAt - a.updatedAt)
    return matches[0]?.windowId ?? null
  }

  handleAcpEvent(event = {}) {
    const projectId = event.projectId
    if (typeof projectId !== 'string' || !projectId) return null
    const attentionSessionId = event.attentionSessionId || event.sessionId || event.targetId
    if (event.type === 'agent.permission.requested' && event.permId) {
      return this.raise({
        projectId,
        sessionId: attentionSessionId,
        source: 'permission',
        sourceId: event.permId,
        kind: 'permission',
        title: event.title || `${event.agent || 'Agent'} needs you`,
        detail: event.kind,
        severity: event.sensitive ? 'warning' : 'info',
        windowId: this.windowIdForProject(projectId) || undefined,
        authoritativeSession: true,
      })
    }
    if (event.type === 'agent.permission.resolved' && event.permId) {
      return this.clearSource({ projectId, source: 'permission', sourceId: event.permId, reason: event.resolution || 'permission_resolved' })
    }
    if (event.type === 'agent.turn.completed' && event.turnId) {
      const failed = event.ok !== true || (event.stopReason && event.stopReason !== 'end_turn')
      const sessionId = attentionSessionId
      if (sessionId) this.#upsertSession({
        id: sessionId,
        projectId,
        kind: 'agent',
        title: event.agent || event.targetId || 'Agent',
        status: failed ? 'failed' : 'done',
        updatedAt: this.now(),
        provider: event.agent,
        windowId: this.windowIdForProject(projectId) || undefined,
      })
      return this.raise({
        projectId,
        sessionId,
        source: 'agent-turn',
        sourceId: `${event.targetId || 'agent'}:${event.turnId}`,
        kind: failed ? 'failed' : 'completed',
        title: failed ? `${event.agent || 'Agent'} failed` : `${event.agent || 'Agent'} finished`,
        detail: event.stopReason,
        severity: failed ? 'critical' : 'info',
        windowId: this.windowIdForProject(projectId) || undefined,
        coalesceTarget: true,
        authoritativeSession: true,
      })
    }
    return null
  }

  handleTerminalEvent(event = {}) {
    const projectId = event.projectId
    const sessionId = event.sessionId || event.id
    if (typeof projectId !== 'string' || !projectId || typeof sessionId !== 'string' || !sessionId) return null
    if (event.busy === true) {
      this.#upsertSession({ ...event, id: sessionId, projectId, kind: 'terminal', status: 'running', updatedAt: this.now() })
      return { ok: true, running: true }
    }
    const hasExit = Number.isInteger(event.exitCode)
    const completedAt = safeTime(event.completedAt, this.now())
    if (!hasExit && event.completedAt == null) return null
    const failed = hasExit && event.exitCode !== 0
    this.#upsertSession({ ...event, id: sessionId, projectId, kind: 'terminal', status: failed ? 'failed' : 'done', updatedAt: completedAt })
    return this.raise({
      projectId,
      sessionId,
      source: hasExit ? 'terminal-exit' : 'terminal-completion',
      sourceId: `${sessionId}:${event.streamEpoch || 'stream'}:${event.offset ?? completedAt}:${hasExit ? event.exitCode : 'done'}`,
      kind: failed ? 'failed' : 'completed',
      title: failed ? `${event.title || 'Terminal'} failed` : `${event.title || 'Terminal'} finished`,
      detail: failed ? `Exited with code ${event.exitCode}.` : undefined,
      createdAt: completedAt,
      severity: failed ? 'critical' : 'info',
      windowId: event.windowId || this.windowIdForProject(projectId) || undefined,
      coalesceTarget: true,
      authoritativeSession: true,
    })
  }

  handleLedgerEvent({ task, projectId } = {}) {
    if (!task || typeof task !== 'object' || typeof task.id !== 'string') return null
    const exactProjectId = projectId || task.projectId || this.projectIdForAlias(task.project)
    if (!exactProjectId) return null
    if (task.status === 'review' || task.status === 'blocked') {
      const occurrence = `${task.id}:${safeTime(task.updatedAt, this.now())}:${task.status}`
      const existingId = this.sourceIndex.get(sourceKey(exactProjectId, 'ledger', occurrence))
      if (!existingId) this.#clearSourcePrefix(exactProjectId, 'ledger', `${task.id}:`, 'ledger_updated')
      return this.raise({
        projectId: exactProjectId,
        source: 'ledger',
        sourceId: occurrence,
        kind: task.status,
        title: task.title || (task.status === 'review' ? 'Review agent result' : 'Agent task blocked'),
        detail: task.result || task.detail,
        severity: task.status === 'blocked' ? 'warning' : 'info',
        createdAt: task.updatedAt,
        windowId: this.windowIdForProject(exactProjectId) || undefined,
      })
    }
    return this.#clearSourcePrefix(exactProjectId, 'ledger', `${task.id}:`, `ledger_${task.status || 'updated'}`)
  }

  synchronizeProjections(records = []) {
    const projectOwner = new Map()
    const chosen = []
    for (const record of Array.isArray(records) ? records : []) {
      if (!record?.projection || typeof record.windowId !== 'string') continue
      for (const project of record.projection.projects || []) {
        if (projectOwner.has(project.id)) continue
        projectOwner.set(project.id, record.windowId)
        chosen.push({ projectId: project.id, windowId: record.windowId, projection: record.projection })
      }
    }
    const presentProjects = new Set(projectOwner.keys())

    // A missing renderer is not an acknowledgement. Retain its durable session
    // state until a replacement projection for that exact project arrives.
    const nextSessions = new Map(
      [...this.sessions].filter(([, session]) => !presentProjects.has(session.projectId)),
    )
    const derived = new Map()
    for (const { projectId, windowId, projection } of chosen) {
      const explicitSessionIds = new Set([
        ...(projection.attention || []).map((item) => item.sessionId).filter(Boolean),
        ...(projection.permissions || []).map((item) => item.sessionId).filter(Boolean),
      ])
      for (const session of projection.sessions || []) {
        if (session.projectId !== projectId) continue
        const clean = cleanSession({ ...session, windowId })
        if (!clean) continue
        nextSessions.set(sessionKey(projectId, clean.id), clean)
        if (session.needsYou === true && !explicitSessionIds.has(clean.id)) {
          const key = sourceKey(projectId, 'projection-session', `${clean.id}:${clean.updatedAt}`)
          derived.set(key, {
            projectId,
            sessionId: clean.id,
            source: 'projection-session',
            sourceId: `${clean.id}:${clean.updatedAt}`,
            kind: clean.status === 'failed' ? 'failed' : 'completed',
            title: clean.status === 'failed' ? `${clean.title} failed` : `${clean.title} finished`,
            createdAt: clean.updatedAt,
            severity: clean.status === 'failed' ? 'critical' : 'info',
            windowId,
            coalesceTarget: true,
          })
        }
      }
      for (const item of projection.attention || []) {
        if (item.projectId !== projectId) continue
        const isLedger = /^attention-task-/.test(item.id) || (item.kind === 'review' || item.kind === 'blocked')
        const source = isLedger ? 'ledger' : 'projection-attention'
        const ledgerId = item.id.replace(/^attention-/, '')
        const sourceId = isLedger ? `${ledgerId}:${item.createdAt}:${item.kind}` : item.id
        const key = sourceKey(projectId, source, sourceId)
        derived.set(key, {
          projectId,
          sessionId: item.sessionId,
          source,
          sourceId,
          kind: item.kind,
          title: item.title,
          detail: item.detail,
          createdAt: item.createdAt,
          severity: item.severity,
          windowId,
          coalesceTarget: true,
        })
      }
      for (const permission of projection.permissions || []) {
        if (permission.projectId !== projectId) continue
        const key = sourceKey(projectId, 'permission', permission.permId)
        derived.set(key, {
          projectId,
          sessionId: permission.sessionId,
          source: 'permission',
          sourceId: permission.permId,
          kind: 'permission',
          title: permission.title || `${permission.agent || 'Agent'} needs you`,
          createdAt: permission.requestedAt,
          windowId,
          coalesceTarget: true,
        })
      }
    }

    for (const [key, eventId] of this.projectionSources) {
      if (derived.has(key)) continue
      const record = this.records.get(eventId)
      if (!record) continue
      if (!presentProjects.has(record.projectId)) continue
      if (record.status === 'active') this.#clear(record, 'projection_acknowledged', 'desktop-projection')
    }
    const nextProjectionSources = new Map()
    for (const [key, eventId] of this.projectionSources) {
      const record = this.records.get(eventId)
      if (record && !presentProjects.has(record.projectId)) nextProjectionSources.set(key, eventId)
    }
    for (const [key, input] of derived) {
      const result = this.raise(input)
      if (result?.event?.id) nextProjectionSources.set(key, result.event.id)
    }
    while (nextProjectionSources.size > this.maxRecords * 8) {
      nextProjectionSources.delete(nextProjectionSources.keys().next().value)
    }
    this.projectionSources = nextProjectionSources
    const boundedSessions = new Map(
      [...nextSessions.entries()]
        .sort((a, b) => b[1].updatedAt - a[1].updatedAt)
        .slice(0, this.maxSessions),
    )
    const sessionsChanged = JSON.stringify([...this.sessions]) !== JSON.stringify([...boundedSessions])
    this.sessions = boundedSessions
    if (sessionsChanged) {
      this.revision++
      this.#persist()
    }
    return this.boardState()
  }

  mergeProjection(projection) {
    const projects = new Set((projection?.projects || []).map((project) => project.id))
    const active = [...this.records.values()].filter((record) => record.status === 'active' && projects.has(record.projectId))
    const bySession = new Map()
    for (const record of active) {
      if (!record.sessionId) continue
      const key = sessionKey(record.projectId, record.sessionId)
      const list = bySession.get(key) || []
      list.push(record)
      bySession.set(key, list)
    }
    const sessionIds = new Set((projection?.sessions || []).map((session) => sessionKey(session.projectId, session.id)))
    const sessions = (projection?.sessions || []).map((session) => {
      const events = bySession.get(sessionKey(session.projectId, session.id)) || []
      const failed = events.some((event) => event.kind === 'failed')
      const needsYou = events.length > 0
      let status = session.status
      if (failed) status = 'failed'
      else if (needsYou) status = 'waiting'
      else if (session.needsYou || status === 'waiting') {
        const latest = this.#latestRecordForSession(session.projectId, session.id)
        status = latest?.kind === 'completed' ? 'done' : latest?.kind === 'failed' ? 'failed' : 'idle'
      }
      return { ...session, status, needsYou, unread: needsYou }
    })
    const attention = active.map((record) => ({
      id: record.id,
      projectId: record.projectId,
      kind: record.kind,
      title: record.title,
      createdAt: record.createdAt,
      severity: record.severity,
      ...(record.sessionId && sessionIds.has(sessionKey(record.projectId, record.sessionId)) ? { sessionId: record.sessionId } : {}),
      ...(record.detail ? { detail: record.detail } : {}),
    }))
    return { ...projection, sessions, attention }
  }

  boardState() {
    const attention = [...this.records.values()].filter((record) => record.status === 'active').map(publicEvent)
    const eventsBySession = new Map()
    for (const event of attention) {
      if (!event.sessionId) continue
      const key = sessionKey(event.projectId, event.sessionId)
      const list = eventsBySession.get(key) || []
      list.push(event)
      eventsBySession.set(key, list)
    }
    const sessions = [...this.sessions.values()].map((session) => {
      const events = eventsBySession.get(sessionKey(session.projectId, session.id)) || []
      const needsYou = events.length > 0
      const failed = events.some((event) => event.kind === 'failed')
      let status = failed ? 'failed' : needsYou ? 'waiting' : session.status
      if (!needsYou && status === 'waiting') {
        const latest = this.#latestRecordForSession(session.projectId, session.id)
        status = latest?.kind === 'completed' ? 'done' : latest?.kind === 'failed' ? 'failed' : 'idle'
      }
      return { ...cloneJson(session), needsYou, status }
    })
    const projects = new Map()
    for (const session of sessions) {
      const counts = projects.get(session.projectId) || { running: 0, needsYou: 0, done: 0, failed: 0 }
      if (session.status === 'running') counts.running++
      if (session.needsYou) counts.needsYou++
      if (session.status === 'done') counts.done++
      if (session.status === 'failed') counts.failed++
      projects.set(session.projectId, counts)
    }
    const knownSessions = new Set(sessions.map((session) => sessionKey(session.projectId, session.id)))
    for (const event of attention) {
      if (event.sessionId && knownSessions.has(sessionKey(event.projectId, event.sessionId))) continue
      const counts = projects.get(event.projectId) || { running: 0, needsYou: 0, done: 0, failed: 0 }
      counts.needsYou++
      if (event.kind === 'failed') counts.failed++
      projects.set(event.projectId, counts)
    }
    return Object.freeze({
      revision: this.revision,
      projects: [...projects].map(([projectId, counts]) => ({ projectId, ...counts })),
      sessions,
      attention,
    })
  }

  activeEvents(projectId) {
    return [...this.records.values()]
      .filter((record) => record.status === 'active' && (projectId == null || record.projectId === projectId))
      .sort((a, b) => b.createdAt - a.createdAt || a.id.localeCompare(b.id))
      .map(publicEvent)
  }

  stats() {
    return {
      revision: this.revision,
      active: [...this.records.values()].filter((record) => record.status === 'active').length,
      records: this.records.size,
      sessions: this.sessions.size,
      surfaces: this.surfaces.size,
      maxActive: this.maxActive,
      maxRecords: this.maxRecords,
      maxSessions: this.maxSessions,
      retentionMs: this.retentionMs,
    }
  }

  #upsertSession(input) {
    const clean = cleanSession(input)
    if (!clean) return false
    const key = sessionKey(clean.projectId, clean.id)
    this.sessions.delete(key)
    this.sessions.set(key, clean)
    while (this.sessions.size > this.maxSessions) this.sessions.delete(this.sessions.keys().next().value)
    this.revision++
    this.#persist()
    return true
  }

  #enhance(record, input, now) {
    let changed = false
    const title = safeText(input.title, record.title)
    const detail = typeof input.detail === 'string' ? safeText(input.detail, '', 240) : record.detail
    const sessionId = input.sessionId == null
      ? record.sessionId
      : input.authoritativeSession === true || !record.sessionId
        ? safeId(input.sessionId, 'attention sessionId')
        : record.sessionId
    const windowId = typeof input.windowId === 'string' ? safeId(input.windowId, 'attention windowId') : record.windowId
    const kind = ATTENTION_KINDS.has(input.kind) ? input.kind : record.kind
    const severity = SEVERITIES.has(input.severity) ? input.severity : record.severity
    for (const [key, value] of Object.entries({ title, detail, sessionId, windowId, kind, severity })) {
      if (value !== undefined && record[key] !== value) { record[key] = value; changed = true }
    }
    if (changed) record.updatedAt = now
    return changed
  }

  #latestActive(projectId, sessionId, kind) {
    return [...this.records.values()]
      .filter((record) => record.status === 'active' && record.projectId === projectId && record.sessionId === sessionId && (record.kind === kind || (OUTCOME_KINDS.has(record.kind) && OUTCOME_KINDS.has(kind))))
      .sort((a, b) => b.createdAt - a.createdAt)[0] || null
  }

  #latestRecordForSession(projectId, sessionId) {
    return [...this.records.values()]
      .filter((record) => record.projectId === projectId && record.sessionId === sessionId)
      .sort((a, b) => b.createdAt - a.createdAt || b.updatedAt - a.updatedAt)[0] || null
  }

  #clearSourcePrefix(projectId, source, prefix, reason) {
    let cleared = false
    for (const record of this.records.values()) {
      if (record.status !== 'active' || record.projectId !== projectId) continue
      if (!(record.sources || []).some((item) => item.source === source && (item.sourceId === prefix.slice(0, -1) || item.sourceId.startsWith(prefix)))) continue
      cleared = this.#clear(record, reason, 'service') || cleared
    }
    return cleared
  }

  #clear(record, reason, actorId) {
    if (!record || record.status !== 'active') return false
    record.status = 'cleared'
    record.clearedAt = this.now()
    record.updatedAt = record.clearedAt
    record.clearReason = safeText(reason, 'acknowledged', 80)
    this.revision++
    this.#trim()
    this.#persist()
    this.#emit(emittedEvent('attention.cleared', record, {
      clearedAt: record.clearedAt,
      reason: record.clearReason,
      actorId: safeText(actorId, 'service', 240),
    }))
    return true
  }

  #emit(event) {
    for (const subscriber of this.subscribers) {
      try { subscriber(event) } catch { /* one surface cannot break attention authority */ }
    }
  }

  #trim() {
    const now = this.now()
    for (const [id, record] of this.records) {
      if (record.status === 'cleared' && now - (record.clearedAt || record.updatedAt) > this.retentionMs) this.#deleteRecord(id, record)
    }
    let active = [...this.records.values()].filter((record) => record.status === 'active')
    if (active.length > this.maxActive) {
      active = active.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id))
      for (const record of active.slice(0, active.length - this.maxActive)) this.#clear(record, 'bounded_eviction', 'service')
    }
    while (this.records.size > this.maxRecords) {
      const cleared = [...this.records.values()]
        .filter((record) => record.status === 'cleared')
        .sort((a, b) => (a.clearedAt || a.updatedAt) - (b.clearedAt || b.updatedAt))[0]
      const candidate = cleared || [...this.records.values()].sort((a, b) => a.createdAt - b.createdAt)[0]
      if (!candidate) break
      this.#deleteRecord(candidate.id, candidate)
    }
  }

  #deleteRecord(id, record) {
    this.records.delete(id)
    for (const item of record.sources || []) this.sourceIndex.delete(sourceKey(record.projectId, item.source, item.sourceId))
  }

  #load() {
    let parsed
    try {
      const raw = this.get(STORE_KEY)
      parsed = typeof raw === 'string' ? JSON.parse(raw) : null
    } catch { parsed = null }
    if (!parsed || parsed.storeVersion !== STORE_VERSION) return
    this.revision = Number.isSafeInteger(parsed.revision) && parsed.revision >= 0 ? parsed.revision : 0
    const now = this.now()
    for (const raw of Array.isArray(parsed.records) ? parsed.records.slice(-this.maxRecords) : []) {
      const record = cleanRecord(raw, now)
      if (!record) continue
      this.records.set(record.id, record)
      for (const item of record.sources) this.sourceIndex.set(sourceKey(record.projectId, item.source, item.sourceId), record.id)
    }
    for (const raw of Array.isArray(parsed.sessions) ? parsed.sessions.slice(-this.maxSessions) : []) {
      const session = cleanSession(raw)
      if (session) this.sessions.set(sessionKey(session.projectId, session.id), session)
    }
    this.#trim()
  }

  #persist() {
    const value = JSON.stringify({
      storeVersion: STORE_VERSION,
      revision: this.revision,
      records: [...this.records.values()],
      sessions: [...this.sessions.values()],
    })
    this.set(STORE_KEY, value)
  }
}

module.exports = {
  AttentionService,
  DEFAULT_MAX_ACTIVE,
  DEFAULT_MAX_RECORDS,
  DEFAULT_MAX_SESSIONS,
  DEFAULT_RETENTION_MS,
  STORE_KEY,
  STORE_VERSION,
  attentionEventId,
  createAttentionActorCapability,
}
